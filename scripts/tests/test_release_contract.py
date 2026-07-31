from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "release_contract.py"


def _module():
    spec = importlib.util.spec_from_file_location("release_contract", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _prod_values() -> dict[str, str]:
    return {
        "DBT_TARGET": "prod",
        "R2_BUCKET_NAME": "seoul",
        "R2_ENDPOINT": "https://account.r2.cloudflarestorage.com",
        "R2_ACCESS_KEY_ID": "access",
        "R2_SECRET_ACCESS_KEY": "secret",
        "R2_DATA_CATALOG_URI": "https://catalog.example.invalid",
        "R2_DATA_CATALOG_WAREHOUSE": "warehouse",
        "R2_DATA_CATALOG_TOKEN": "catalog-token",
        "TRINO_ICEBERG_CATALOG": "iceberg",
        "SMOKE_SCHEMA": "ops_smoke",
        "ASK_SEOUL_SCHEMA": "weather_traffic_bronze",
        "SERVING_CLOUDFLARE_ACCOUNT_ID": "account",
        "SERVING_D1_DATABASE_ID": "database",
        "ASK_SEOUL_AIRFLOW_IMAGE": "ghcr.io/example/airflow@sha256:" + "a" * 64,
    }


class ReleaseContractTest(unittest.TestCase):
    def test_prod_preflight_rejects_dev_names_duplicate_keys_and_target_alias(self):
        module = _module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env.prod"
            values = _prod_values()
            values["R2_DEV_BUCKET_NAME"] = "seoul-dev"
            values["ASK_SEOUL_TARGET"] = "prod"
            env_file.write_text(
                "\n".join(f"{key}={value}" for key, value in values.items())
                + "\nDBT_TARGET=prod\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(module.ReleaseContractError, "duplicated"):
                module.load_env_file(env_file)

            env_file.write_text(
                "\n".join(f"{key}={value}" for key, value in values.items()),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(module.ReleaseContractError, "ASK_SEOUL_TARGET"):
                module.validate_prod_environment(module.load_env_file(env_file))

    def test_prod_preflight_accepts_full_single_target_tuple(self):
        module = _module()
        module.validate_prod_environment(_prod_values())

    def test_prod_preflight_rejects_dev_schema(self):
        module = _module()
        values = _prod_values()
        values["ASK_SEOUL_SCHEMA"] = "dev_mason"

        with self.assertRaisesRegex(module.ReleaseContractError, "dev schema"):
            module.validate_prod_environment(values)

    def test_release_artifact_pins_all_components_and_immutable_image(self):
        module = _module()
        commits = {name: "a" * 40 for name in ("root", "dags", "dbt", "dashboard")}
        artifact = module.build_release_artifact(
            release_name="weather-traffic-prod-canary",
            commits=commits,
            airflow_image="ghcr.io/example/airflow@sha256:" + "b" * 64,
        )

        self.assertEqual("ask-seoul-release/v1", artifact["schema_version"])
        self.assertEqual(commits, artifact["components"])
        self.assertEqual(
            "ghcr.io/example/airflow@sha256:" + "b" * 64,
            artifact["images"]["airflow"],
        )
        module.validate_release_artifact(artifact)
        self.assertEqual(
            json.loads(json.dumps(artifact, sort_keys=True))["components"], commits
        )

    def test_preflight_requires_checked_out_component_shas_and_matching_image(self):
        module = _module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            env_file = temporary_root / ".env.prod"
            artifact_file = temporary_root / "release.json"
            values = _prod_values()
            env_file.write_text(
                "\n".join(f"{name}={value}" for name, value in values.items()),
                encoding="utf-8",
            )
            artifact_file.write_text(
                json.dumps(
                    module.build_release_artifact(
                        release_name="weather-traffic-prod-test",
                        commits=module._current_component_commits(ROOT),
                        airflow_image=values["ASK_SEOUL_AIRFLOW_IMAGE"],
                    )
                ),
                encoding="utf-8",
            )

            with mock.patch.object(module, "_component_is_clean", return_value=True):
                module.preflight(env_file=env_file, artifact_file=artifact_file)

    def test_preflight_rejects_a_dirty_root_or_submodule(self):
        module = _module()
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            env_file = temporary_root / ".env.prod"
            artifact_file = temporary_root / "release.json"
            values = _prod_values()
            commits = module._current_component_commits(ROOT)
            env_file.write_text(
                "\n".join(f"{name}={value}" for name, value in values.items()),
                encoding="utf-8",
            )
            artifact_file.write_text(
                json.dumps(
                    module.build_release_artifact(
                        release_name="weather-traffic-prod-test",
                        commits=commits,
                        airflow_image=values["ASK_SEOUL_AIRFLOW_IMAGE"],
                    )
                ),
                encoding="utf-8",
            )

            with mock.patch.object(
                module,
                "_component_is_clean",
                return_value=False,
                create=True,
            ):
                with self.assertRaisesRegex(module.ReleaseContractError, "not clean"):
                    module.preflight(env_file=env_file, artifact_file=artifact_file)

    def test_prod_overlay_mounts_only_prod_catalog(self):
        compose = (ROOT / "docker-compose.prod.yml").read_text(encoding="utf-8")
        self.assertIn("./trino/catalog-prod:/etc/trino/catalog:ro", compose)
        self.assertNotIn("./trino/catalog:/etc/trino/catalog:ro", compose)

    def test_prod_compose_renders_with_one_prod_catalog_mount(self):
        if shutil.which("docker") is None:
            self.skipTest("Docker CLI is not installed")
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env.prod"
            env_file.write_text(
                "\n".join(
                    f"{name}={value}" for name, value in _prod_values().items()
                )
                + "\nAIRFLOW_FERNET_KEY=test\n"
                + "AIRFLOW_SECRET_KEY=test\n"
                + "POSTGRES_USER=airflow\n"
                + "POSTGRES_PASSWORD=test\n"
                + "POSTGRES_DB=airflow\n"
                + "AIRFLOW_UID=50000\n"
                + "AIRFLOW_ADMIN_USERNAME=admin\n"
                + "AIRFLOW_ADMIN_PASSWORD=test\n"
                + "AIRFLOW_ADMIN_EMAIL=test@example.invalid\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["ASK_SEOUL_PROD_ENV_FILE"] = str(env_file)
            result = subprocess.run(
                [
                    "docker",
                    "compose",
                    "--env-file",
                    str(env_file),
                    "-f",
                    "docker-compose.yml",
                    "-f",
                    "docker-compose.prod.yml",
                    "config",
                    "--quiet",
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
