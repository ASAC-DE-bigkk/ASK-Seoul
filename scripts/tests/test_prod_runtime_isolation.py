from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROD_ENV_TOOL = ROOT / "scripts" / "prod_env.py"
PROD_COMPOSE_TOOL = ROOT / "scripts" / "prod_compose.py"
AIRFLOW_SERVICES = {
    "airflow-init",
    "airflow-apiserver",
    "airflow-scheduler",
    "airflow-dag-processor",
    "airflow-triggerer",
}


def _source_env_text() -> str:
    return "\n".join(
        (
            "ASK_SEOUL_TARGET=dev",
            "DBT_TARGET=dev",
            "R2_BUCKET_NAME=seoul",
            "R2_ENDPOINT=https://prod.invalid",
            "R2_ACCESS_KEY_ID=prod-access-secret",
            "R2_SECRET_ACCESS_KEY=prod-secret-value",
            "R2_DATA_CATALOG_TOKEN=prod-catalog-secret",
            "R2_DATA_CATALOG_URI=https://catalog.prod.invalid",
            "R2_DATA_CATALOG_WAREHOUSE=prod-warehouse",
            "R2_RAW_PREFIX=raw",
            "TRINO_ICEBERG_CATALOG=iceberg",
            "SMOKE_SCHEMA=ops_smoke",
            "R2_DEV_BUCKET_NAME=seoul-dev",
            "R2_DEV_ENDPOINT=https://dev.invalid",
            "R2_DEV_ACCESS_KEY_ID=dev-access-secret",
            "R2_DEV_SECRET_ACCESS_KEY=dev-secret-value",
            "R2_DEV_DATA_CATALOG_TOKEN=dev-catalog-secret",
            "R2_DEV_DATA_CATALOG_URI=https://catalog.dev.invalid",
            "R2_DEV_DATA_CATALOG_WAREHOUSE=dev-warehouse",
            "TRINO_DEV_ICEBERG_CATALOG=iceberg_dev",
            "DEV_SMOKE_SCHEMA=dev_tester",
            "ASK_SEOUL_DEV_RAW_PREFIX=dev/tester/raw",
            "KMA_SERVICE_KEY=weather-secret-to-preserve",
            "AIRFLOW_UID=50000",
            "AIRFLOW_ADMIN_USERNAME=admin",
            "AIRFLOW_ADMIN_PASSWORD=admin-secret",
            "AIRFLOW_ADMIN_EMAIL=admin@example.invalid",
            "AIRFLOW_FERNET_KEY=fernet-secret",
            "AIRFLOW_SECRET_KEY=airflow-secret",
            "POSTGRES_USER=airflow",
            "POSTGRES_PASSWORD=postgres-secret",
            "POSTGRES_DB=airflow",
            "TRINO_MEMORY_LIMIT=9g",
            "TRINO_TASK_CONCURRENCY=2",
            "TRINO_QUERY_MAX_MEMORY_PER_NODE=2GB",
            "TRINO_MEMORY_HEAP_HEADROOM_PER_NODE=2GB",
            "TRINO_QUERY_MAX_MEMORY=2GB",
            "TRINO_QUERY_MAX_TOTAL_MEMORY=4GB",
            "",
        )
    )


def _parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        values[name.strip()] = value.strip()
    return values


class ProdRuntimeIsolationTest(unittest.TestCase):
    def test_prepare_creates_prod_only_env_without_printing_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.env"
            output = root / "prod.env"
            source.write_text(_source_env_text(), encoding="utf-8")

            result = subprocess.run(
                [
                    "python",
                    str(PROD_ENV_TOOL),
                    "prepare",
                    "--source",
                    str(source),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            values = _parse_env(output)
            self.assertEqual("prod", values["ASK_SEOUL_TARGET"])
            self.assertEqual("prod", values["DBT_TARGET"])
            self.assertEqual("seoul", values["R2_BUCKET_NAME"])
            self.assertEqual("iceberg", values["TRINO_ICEBERG_CATALOG"])
            self.assertEqual("raw", values["R2_RAW_PREFIX"])
            self.assertEqual("ops_smoke", values["SMOKE_SCHEMA"])
            self.assertEqual(
                "weather-secret-to-preserve", values["KMA_SERVICE_KEY"]
            )
            forbidden = {
                name
                for name in values
                if name.startswith("R2_DEV_")
                or name
                in {
                    "TRINO_DEV_ICEBERG_CATALOG",
                    "DEV_SMOKE_SCHEMA",
                    "ASK_SEOUL_DEV_RAW_PREFIX",
                }
            }
            self.assertEqual(set(), forbidden)
            combined_output = result.stdout + result.stderr
            self.assertNotIn("prod-secret-value", combined_output)
            self.assertNotIn("weather-secret-to-preserve", combined_output)

    def test_validate_rejects_dev_keys_without_printing_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / "prod.env"
            env_file.write_text(
                _source_env_text().replace("ASK_SEOUL_TARGET=dev", "ASK_SEOUL_TARGET=prod")
                .replace("DBT_TARGET=dev", "DBT_TARGET=prod"),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python",
                    str(PROD_ENV_TOOL),
                    "validate",
                    "--env-file",
                    str(env_file),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn("R2_DEV_BUCKET_NAME", result.stderr)
            self.assertNotIn("dev-secret-value", result.stderr)

    def test_prepare_normalizes_duplicate_source_keys_to_the_last_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.env"
            output = root / "prod.env"
            source.write_text(
                "CLOUDFLARE_ACCOUNT_ID=old-account\n"
                + _source_env_text()
                + "CLOUDFLARE_ACCOUNT_ID=current-account\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python",
                    str(PROD_ENV_TOOL),
                    "prepare",
                    "--source",
                    str(source),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            prepared_text = output.read_text(encoding="utf-8")
            self.assertEqual(1, prepared_text.count("CLOUDFLARE_ACCOUNT_ID="))
            self.assertEqual(
                "current-account", _parse_env(output)["CLOUDFLARE_ACCOUNT_ID"]
            )

    def test_prepare_accepts_utf8_bom_and_writes_plain_utf8(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.env"
            output = root / "prod.env"
            source.write_text("\ufeff" + _source_env_text(), encoding="utf-8")

            result = subprocess.run(
                [
                    "python",
                    str(PROD_ENV_TOOL),
                    "prepare",
                    "--source",
                    str(source),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse(output.read_bytes().startswith(b"\xef\xbb\xbf"))
            self.assertEqual("prod", _parse_env(output)["ASK_SEOUL_TARGET"])

    def test_prepare_preserves_compose_compatible_hyphenated_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.env"
            output = root / "prod.env"
            source.write_text(
                _source_env_text() + "domain-option=preserved\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python",
                    str(PROD_ENV_TOOL),
                    "prepare",
                    "--source",
                    str(source),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("preserved", _parse_env(output)["domain-option"])

    def test_compose_uses_separate_project_prod_env_and_prod_only_catalog(self) -> None:
        if shutil.which("docker") is None:
            self.skipTest("Docker CLI is not installed")

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.env"
            prod_env = root / "prod.env"
            source.write_text(_source_env_text(), encoding="utf-8")
            prepared = subprocess.run(
                [
                    "python",
                    str(PROD_ENV_TOOL),
                    "prepare",
                    "--source",
                    str(source),
                    "--output",
                    str(prod_env),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, prepared.returncode, prepared.stderr)

            process_env = os.environ.copy()
            process_env["COMPOSE_PROJECT_NAME"] = "elt-infra"
            process_env["ASK_SEOUL_PROD_ENV_FILE"] = str(prod_env)
            rendered = subprocess.run(
                [
                    "python",
                    str(PROD_COMPOSE_TOOL),
                    "--env-file",
                    str(prod_env),
                    "check",
                ],
                cwd=ROOT,
                env=process_env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, rendered.returncode, rendered.stderr)
            summary = json.loads(rendered.stdout)

            self.assertEqual("elt-infra-prod", summary["project"])
            self.assertEqual("elt-infra-prod-net", summary["network"])
            self.assertEqual(
                "elt-infra-prod_postgres_data",
                summary["volumes"]["postgres_data"],
            )
            self.assertEqual(
                "elt-infra-prod_airflow_logs",
                summary["volumes"]["airflow_logs"],
            )
            self.assertEqual(
                sorted(AIRFLOW_SERVICES | {"postgres", "trino"}),
                summary["validated_services"],
            )
            catalog_source = Path(summary["trino_catalog_source"])
            self.assertEqual(ROOT / "trino" / "catalog-prod", catalog_source)
            mounted_catalogs = sorted(path.name for path in catalog_source.glob("*.properties"))
            self.assertEqual(["iceberg.properties"], mounted_catalogs)
            catalog_text = (catalog_source / "iceberg.properties").read_text(
                encoding="utf-8"
            )
            self.assertNotIn("R2_DEV_", catalog_text)
            combined_output = rendered.stdout + rendered.stderr
            for secret in (
                "prod-access-secret",
                "prod-secret-value",
                "prod-catalog-secret",
                "weather-secret-to-preserve",
                "admin-secret",
                "fernet-secret",
                "airflow-secret",
                "postgres-secret",
            ):
                with self.subTest(secret=secret):
                    self.assertNotIn(secret, combined_output)

    def test_compose_rejects_raw_config_and_hostile_overlay_without_printing_values(
        self,
    ) -> None:
        if shutil.which("docker") is None:
            self.skipTest("Docker CLI is not installed")

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.env"
            prod_env = root / "prod.env"
            hostile_overlay = root / "hostile.yml"
            misdirected_overlay = root / "misdirected.yml"
            source.write_text(_source_env_text(), encoding="utf-8")
            hostile_overlay.write_text(
                "services:\n"
                "  airflow-scheduler:\n"
                "    environment:\n"
                "      R2_DEV_BUCKET_NAME: should-never-print\n",
                encoding="utf-8",
            )
            misdirected_overlay.write_text(
                "services:\n"
                "  airflow-scheduler:\n"
                "    environment:\n"
                "      TRINO_ICEBERG_CATALOG: iceberg_dev\n",
                encoding="utf-8",
            )
            prepared = subprocess.run(
                [
                    "python",
                    str(PROD_ENV_TOOL),
                    "prepare",
                    "--source",
                    str(source),
                    "--output",
                    str(prod_env),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, prepared.returncode, prepared.stderr)

            raw_config = subprocess.run(
                [
                    "python",
                    str(PROD_COMPOSE_TOOL),
                    "--env-file",
                    str(prod_env),
                    "config",
                    "--format",
                    "json",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(0, raw_config.returncode)
            self.assertIn("check", raw_config.stderr)
            self.assertNotIn("prod-secret-value", raw_config.stdout + raw_config.stderr)

            raw_config_with_global_option = subprocess.run(
                [
                    "python",
                    str(PROD_COMPOSE_TOOL),
                    "--env-file",
                    str(prod_env),
                    "--",
                    "--profile",
                    "lineage",
                    "config",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(0, raw_config_with_global_option.returncode)
            self.assertIn("check", raw_config_with_global_option.stderr)
            self.assertNotIn(
                "prod-secret-value",
                raw_config_with_global_option.stdout
                + raw_config_with_global_option.stderr,
            )

            hostile = subprocess.run(
                [
                    "python",
                    str(PROD_COMPOSE_TOOL),
                    "--env-file",
                    str(prod_env),
                    "--compose-file",
                    str(hostile_overlay),
                    "check",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(0, hostile.returncode)
            self.assertIn("R2_DEV_BUCKET_NAME", hostile.stderr)
            self.assertNotIn("should-never-print", hostile.stdout + hostile.stderr)

            misdirected = subprocess.run(
                [
                    "python",
                    str(PROD_COMPOSE_TOOL),
                    "--env-file",
                    str(prod_env),
                    "--compose-file",
                    str(misdirected_overlay),
                    "check",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(0, misdirected.returncode)
            self.assertIn("TRINO_ICEBERG_CATALOG", misdirected.stderr)
            self.assertNotIn(
                "iceberg_dev",
                misdirected.stdout + misdirected.stderr,
            )


if __name__ == "__main__":
    unittest.main()
