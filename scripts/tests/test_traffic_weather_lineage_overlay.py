from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
BASE_COMPOSE = ROOT / "docker-compose.yml"
OVERLAY_COMPOSE = ROOT / "docker-compose.traffic-weather-lineage.yml"
GUIDE = ROOT / "docs" / "traffic-weather-lineage.md"
AIRFLOW_DOCKERFILE = ROOT / "Dockerfile.airflow"

AIRFLOW_SERVICES = {
    "airflow-init",
    "airflow-apiserver",
    "airflow-scheduler",
    "airflow-dag-processor",
    "airflow-triggerer",
}

EXPECTED_OPENLINEAGE_ENVIRONMENT = {
    "AIRFLOW__OPENLINEAGE__TRANSPORT": (
        '{"type": "http", "url": "http://marquez-api:5000", '
        '"endpoint": "api/v1/lineage"}'
    ),
    "AIRFLOW__OPENLINEAGE__NAMESPACE": "ask-seoul-dev-airflow",
    "AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE": "true",
    "AIRFLOW__OPENLINEAGE__DISABLE_SOURCE_CODE": "true",
    "AIRFLOW__OPENLINEAGE__INCLUDE_FULL_TASK_INFO": "false",
    "AIRFLOW__OPENLINEAGE__DEBUG_MODE": "false",
    "ASK_SEOUL_DBT_OPENLINEAGE_ENABLED": "true",
    "ASK_SEOUL_DBT_OPENLINEAGE_URL": "http://marquez-api:5000",
    "ASK_SEOUL_DBT_OPENLINEAGE_ENDPOINT": "api/v1/lineage",
    "ASK_SEOUL_DBT_OPENLINEAGE_NAMESPACE": "ask-seoul-dev-dbt",
}


def inspect_mounted_trino_lineage_config(
    compose_model: dict[str, object],
) -> tuple[list[Path], list[Path]]:
    """Return mounted Trino config files and files containing lineage config."""
    services = compose_model.get("services")
    if not isinstance(services, dict):
        return [], []
    trino_service = services.get("trino")
    if not isinstance(trino_service, dict):
        return [], []
    volumes = trino_service.get("volumes")
    if not isinstance(volumes, list):
        return [], []

    trino_config_root = PurePosixPath("/etc/trino")
    mounted_files: set[Path] = set()
    for volume in volumes:
        if not isinstance(volume, dict) or volume.get("type") != "bind":
            continue
        source = volume.get("source")
        target = volume.get("target")
        if not isinstance(source, str) or not isinstance(target, str):
            continue
        target_path = PurePosixPath(target)
        if (
            target_path != trino_config_root
            and trino_config_root not in target_path.parents
        ):
            continue

        source_path = Path(source)
        if not source_path.exists():
            raise AssertionError(
                f"mounted Trino config source does not exist: {source_path}"
            )
        if source_path.is_file():
            mounted_files.add(source_path)
        elif source_path.is_dir():
            mounted_files.update(
                path for path in source_path.rglob("*") if path.is_file()
            )
        else:
            raise AssertionError(
                f"mounted Trino config source is not a file or directory: {source_path}"
            )

    ordered_files = sorted(mounted_files, key=lambda path: str(path).lower())
    forbidden_pattern = re.compile(
        r"openlineage|event-listener(?:\.|\s*=)", re.IGNORECASE
    )
    violations = [
        path
        for path in ordered_files
        if forbidden_pattern.search(path.read_text(encoding="utf-8", errors="replace"))
    ]
    return ordered_files, violations


class TrafficWeatherLineageOverlayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.base = BASE_COMPOSE.read_text(encoding="utf-8")
        cls.overlay = OVERLAY_COMPOSE.read_text(encoding="utf-8")
        cls.airflow_dockerfile = AIRFLOW_DOCKERFILE.read_text(encoding="utf-8")

    def test_airflow_lineage_dependencies_are_exactly_pinned(self) -> None:
        self.assertIn(
            '"apache-airflow-providers-openlineage==2.19.0"',
            self.airflow_dockerfile,
        )
        self.assertIn(
            '"openlineage-dbt==1.51.0"',
            self.airflow_dockerfile,
        )

    def test_trino_lineage_guard_detects_mounted_listener_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            mounted_directory = Path(temporary_directory)
            listener_config = mounted_directory / "event-listener.properties"
            listener_config.write_text(
                "event-listener.name=openlineage\n",
                encoding="utf-8",
            )
            compose_model = {
                "services": {
                    "trino": {
                        "volumes": [
                            {
                                "type": "bind",
                                "source": str(mounted_directory),
                                "target": "/etc/trino",
                            }
                        ]
                    }
                }
            }

            mounted_files, violations = inspect_mounted_trino_lineage_config(
                compose_model
            )

            self.assertEqual([listener_config], mounted_files)
            self.assertEqual([listener_config], violations)

    def test_overlay_only_overrides_airflow_services(self) -> None:
        service_names = set(re.findall(r"(?m)^  ([a-z][a-z0-9-]+):\r?$", self.overlay))

        self.assertEqual(service_names, AIRFLOW_SERVICES)
        self.assertNotRegex(self.overlay, r"(?m)^trino:")
        self.assertNotRegex(self.overlay, r"(?m)^volumes:")
        self.assertNotRegex(self.overlay, r"(?m)^networks:")

    def test_every_airflow_service_gets_the_scoped_environment_contract(self) -> None:
        for service_name in AIRFLOW_SERVICES:
            with self.subTest(service=service_name):
                self.assertRegex(
                    self.overlay,
                    rf"(?m)^  {re.escape(service_name)}:\r?$"
                    rf"\n^    environment: \*traffic-weather-lineage-environment\r?$",
                )

        for key, value in EXPECTED_OPENLINEAGE_ENVIRONMENT.items():
            with self.subTest(environment_variable=key):
                self.assertRegex(
                    self.overlay,
                    rf"(?m)^  {re.escape(key)}: ['\"]{re.escape(value)}['\"]\r?$",
                )

    def test_overlay_has_no_global_trino_listener_or_secret_material(self) -> None:
        overlay_text = self.overlay.lower()

        forbidden_fragments = (
            "openlineage-event-listener",
            "event-listener.name",
            "kma_service_key",
            "seoul_open_api_key",
            "servicekey",
            "password",
        )
        for fragment in forbidden_fragments:
            with self.subTest(fragment=fragment):
                self.assertNotIn(fragment, overlay_text)
        self.assertNotRegex(
            self.overlay, r"(?m)^  OPENLINEAGE_(URL|ENDPOINT|NAMESPACE):"
        )

    def test_base_compose_keeps_the_commerce_default_contract(self) -> None:
        self.assertIn(
            'AIRFLOW__OPENLINEAGE__NAMESPACE: "commerce-elt"',
            self.base,
        )
        self.assertNotIn("AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE", self.base)
        self.assertNotIn("AIRFLOW__OPENLINEAGE__DISABLE_SOURCE_CODE", self.base)

    def test_marquez_host_ports_remain_loopback_only(self) -> None:
        expected_bindings = (
            '"127.0.0.1:5000:5000"',
            '"127.0.0.1:5001:5001"',
            '"127.0.0.1:3000:3000"',
        )
        for binding in expected_bindings:
            with self.subTest(binding=binding):
                self.assertIn(binding, self.base)

    def test_marquez_services_are_always_on_and_supervised(self) -> None:
        for service_name in ("marquez-db", "marquez-api", "marquez-web"):
            with self.subTest(service=service_name):
                service_block = re.search(
                    rf"(?ms)^  {re.escape(service_name)}:\r?\n(?P<block>.*?)(?=^  [a-z][a-z0-9-]+:|\Z)",
                    self.base,
                )
                self.assertIsNotNone(service_block)
                block = service_block.group("block")
                self.assertNotIn("profiles:", block)
                self.assertIn("restart: unless-stopped", block)
                self.assertNotIn("mem_limit:", block)

    def test_marquez_api_disables_search_and_has_admin_healthcheck(self) -> None:
        self.assertIn('SEARCH_ENABLED: "false"', self.base)
        self.assertNotIn("JAVA_OPTS:", self.base)
        self.assertIn("http://localhost:5001/healthcheck", self.base)
        self.assertRegex(
            self.base,
            r"(?ms)^  marquez-api:\r?\n.*?healthcheck:\r?\n.*?curl --fail http://localhost:5001/healthcheck",
        )
        self.assertRegex(
            self.base,
            r"(?ms)^  marquez-web:\r?\n.*?depends_on:\r?\n      marquez-api:\r?\n        condition: service_healthy",
        )

    def test_docker_compose_merges_environment_without_global_listener(self) -> None:
        if shutil.which("docker") is None:
            self.skipTest("Docker CLI is not installed")

        result = subprocess.run(
            [
                "docker",
                "compose",
                "-f",
                str(BASE_COMPOSE),
                "-f",
                str(OVERLAY_COMPOSE),
                "--profile",
                "lineage",
                "config",
                "--no-env-resolution",
                "--format",
                "json",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            self.fail("docker compose could not render the base + lineage overlay")

        merged = json.loads(result.stdout)
        for service_name in AIRFLOW_SERVICES:
            with self.subTest(service=service_name):
                environment = merged["services"][service_name]["environment"]
                for key, value in EXPECTED_OPENLINEAGE_ENVIRONMENT.items():
                    self.assertEqual(environment[key], value)
                self.assertEqual(
                    environment["AIRFLOW__CORE__EXECUTOR"], "LocalExecutor"
                )

        mounted_files, violations = inspect_mounted_trino_lineage_config(merged)
        self.assertTrue(
            mounted_files, "no mounted /etc/trino config files were inspected"
        )
        self.assertEqual(
            [],
            violations,
            "global OpenLineage configuration exists in mounted Trino files: "
            + ", ".join(str(path) for path in violations),
        )

        for service_name in ("marquez-api", "marquez-web"):
            with self.subTest(service=service_name):
                ports = merged["services"][service_name]["ports"]
                self.assertTrue(ports)
                self.assertTrue(
                    all(port["host_ip"] == "127.0.0.1" for port in ports),
                    f"{service_name} exposes a non-loopback host port",
                )

    def test_korean_guide_documents_usage_and_domain_boundary(self) -> None:
        if not GUIDE.is_file():
            self.fail(f"required file is missing: {GUIDE.relative_to(ROOT)}")

        guide = GUIDE.read_text(encoding="utf-8")
        required_fragments = (
            "docker-compose.traffic-weather-lineage.yml",
            "--profile lineage",
            "enable_lineage()",
            "ask-seoul-dev-airflow",
            "commerce-elt",
            "AIRFLOW__OPENLINEAGE__DISABLE_SOURCE_CODE",
            "ASK_SEOUL_DBT_OPENLINEAGE_ENABLED",
            "dbt-ol",
            "ask-seoul-dev-dbt",
            "Trino OpenLineage event listener",
            "Traffic",
            "Weather",
            "apache-airflow-providers-openlineage==2.19.0",
            "openlineage-dbt==1.51.0",
            "probe_dbt_openlineage_fail_open.py",
            "--network none",
            "--no-introspect",
            "--no-populate-cache",
            "docker compose build airflow-init",
            "provider_openlineage_version_expected=2.19.0",
            "provider_openlineage_version_match=true",
            "openlineage_dbt_version_expected=1.51.0",
            "openlineage_dbt_version_match=true",
            "image_version_gate_passed=true",
            "lineage_warning_observed=true",
            "endpoint_contact_observed=true",
            "DAG/DBT commit",
            "gitlink",
        )
        for fragment in required_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, guide)

if __name__ == "__main__":
    unittest.main()
