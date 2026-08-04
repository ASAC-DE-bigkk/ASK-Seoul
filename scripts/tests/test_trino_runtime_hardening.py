import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class TrinoRuntimeHardeningTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        cls.config = (ROOT / "trino/config.properties").read_text(encoding="utf-8")
        cls.jvm = (ROOT / "trino/jvm.config").read_text(encoding="utf-8")
        cls.env_example = (ROOT / ".env.example").read_text(encoding="utf-8")

    def test_container_is_pinned_bounded_and_supervised(self):
        self.assertIn("image: trinodb/trino:482", self.compose)
        self.assertIn("restart: unless-stopped", self.compose)
        self.assertIn("mem_limit: ${TRINO_MEMORY_LIMIT:-9g}", self.compose)
        self.assertIn("-XX:MaxRAMPercentage=55", self.jvm)

    def test_query_memory_budget_is_explicit(self):
        expected_config = {
            "query.max-memory-per-node=${ENV:TRINO_QUERY_MAX_MEMORY_PER_NODE}",
            "memory.heap-headroom-per-node=${ENV:TRINO_MEMORY_HEAP_HEADROOM_PER_NODE}",
            "query.max-memory=${ENV:TRINO_QUERY_MAX_MEMORY}",
            "query.max-total-memory=${ENV:TRINO_QUERY_MAX_TOTAL_MEMORY}",
            # 풀 고갈 시 최대 점유 쿼리를 죽여 코디네이터 자멸(GC 폭주→announce 타임아웃)을
            # 막는다 — none 으로 되돌리면 동시성 3 이 다시 위험해진다(ASK-Seoul#94 실측).
            "query.low-memory-killer.policy=total-reservation-on-blocked-nodes",
        }
        self.assertTrue(expected_config.issubset(set(self.config.splitlines())))
        # 기본값은 #94 실측 재산정치 — headroom 2500MB(비쿼리 실사용 3.66GiB 반영),
        # per-node 800MB × 동시성 3 = 2.4GB 가 풀(≈2.47GB) 안에 들어온다.
        expected_compose = {
            "TRINO_QUERY_MAX_MEMORY_PER_NODE: ${TRINO_QUERY_MAX_MEMORY_PER_NODE:-800MB}",
            "TRINO_MEMORY_HEAP_HEADROOM_PER_NODE: ${TRINO_MEMORY_HEAP_HEADROOM_PER_NODE:-2500MB}",
            "TRINO_QUERY_MAX_MEMORY: ${TRINO_QUERY_MAX_MEMORY:-800MB}",
            "TRINO_QUERY_MAX_TOTAL_MEMORY: ${TRINO_QUERY_MAX_TOTAL_MEMORY:-1600MB}",
        }
        for setting in expected_compose:
            self.assertIn(setting, self.compose)

    def test_safe_defaults_are_documented(self):
        expected = {
            "TRINO_MEMORY_LIMIT=9g",
            "TRINO_TASK_CONCURRENCY=2",
            "TRINO_QUERY_MAX_MEMORY_PER_NODE=800MB",
            "TRINO_MEMORY_HEAP_HEADROOM_PER_NODE=2500MB",
            "TRINO_QUERY_MAX_MEMORY=800MB",
            "TRINO_QUERY_MAX_TOTAL_MEMORY=1600MB",
        }
        self.assertTrue(expected.issubset(set(self.env_example.splitlines())))

    def test_global_resource_group_bounds_concurrency(self):
        # 동시성 3 = 처리량(1 이던 시절 scheduling 167초·큐 16 적체)과 안정성의 절충(#94).
        # low-memory-killer(위 테스트)와 한 쌍 — killer 없이 이 값만 올리면 크래시가 재발한다.
        resource_groups = ROOT / "trino/resource-groups.json"
        self.assertTrue(resource_groups.exists(), "resource-groups.json must exist")
        data = json.loads(resource_groups.read_text(encoding="utf-8"))
        self.assertEqual(1, len(data["rootGroups"]))
        group = data["rootGroups"][0]
        self.assertEqual("global", group["name"])
        self.assertEqual(3, group["hardConcurrencyLimit"])
        self.assertEqual(100, group["maxQueued"])
        self.assertEqual("80%", group["softMemoryLimit"])
        self.assertEqual([{"user": ".*", "group": "global"}], data["selectors"])

    def test_resource_group_files_are_mounted(self):
        manager = ROOT / "trino/resource-groups.properties"
        self.assertTrue(manager.exists(), "resource-groups.properties must exist")
        manager_text = manager.read_text(encoding="utf-8")
        self.assertIn("resource-groups.configuration-manager=file", manager_text)
        self.assertIn(
            "resource-groups.config-file=/etc/trino/resource-groups.json",
            manager_text,
        )
        self.assertIn(
            "./trino/resource-groups.properties:/etc/trino/resource-groups.properties:ro",
            self.compose,
        )
        self.assertIn(
            "./trino/resource-groups.json:/etc/trino/resource-groups.json:ro",
            self.compose,
        )

    def test_airflow_pools_are_bootstrapped_from_registry(self):
        registry_commands = (
            "python /opt/airflow/dags/common/pools.py > "
            "/tmp/ask-seoul-airflow-pools.json || exit 1",
            "test -s /tmp/ask-seoul-airflow-pools.json || exit 1",
            "/entrypoint airflow pools import "
            "/tmp/ask-seoul-airflow-pools.json || exit 1",
        )
        for command in registry_commands:
            self.assertIn(command, self.compose)
        command_offsets = [self.compose.index(command) for command in registry_commands]
        self.assertEqual(sorted(command_offsets), command_offsets)
        self.assertEqual(1, self.compose.count("airflow pools import"))
        self.assertNotIn("airflow pools set", self.compose)

    def test_traffic_weather_manifest_is_bootstrapped_without_blocking_airflow_init(
        self,
    ):
        airflow_init = self.compose[
            self.compose.index("  airflow-init:") : self.compose.index(
                "  airflow-apiserver:"
            )
        ]
        bootstrap_commands = (
            "TW_DBT=/opt/airflow/dbt/domains/traffic_weather",
            '"$${DBT_BIN}" deps  --project-dir "$${TW_DBT}" --profiles-dir '
            '"$${TW_DBT}" --no-use-colors || true',
            '"$${DBT_BIN}" parse --project-dir "$${TW_DBT}" --profiles-dir '
            '"$${TW_DBT}" --target "$${DBT_TARGET:-dev}" --no-use-colors || true',
            'if test -s "$${TW_DBT}/target/manifest.json"; then',
            "traffic_weather dbt manifest ready",
            "WARNING: traffic_weather target/manifest.json is missing; "
            "Weather/Traffic serving DAGs may fail until dbt parse succeeds.",
            'chown -R "$${AIRFLOW_UID}:0" "$${TW_DBT}/target" '
            '"$${TW_DBT}/dbt_packages" 2>/dev/null || true',
        )
        for command in bootstrap_commands:
            with self.subTest(command=command):
                self.assertIn(command, airflow_init)
                self.assertEqual(1, airflow_init.count(command))

        if all(command in airflow_init for command in bootstrap_commands):
            command_offsets = [
                airflow_init.index(command) for command in bootstrap_commands
            ]
            self.assertEqual(sorted(command_offsets), command_offsets)
        self.assertNotIn(
            'test -s "$${TW_DBT}/target/manifest.json" || exit 1',
            airflow_init,
        )

    def test_pool_registry_cli_emits_airflow_import_payload(self):
        registry_script = ROOT / "dags/common/pools.py"
        self.assertTrue(registry_script.exists(), "pool registry CLI must exist")

        completed = subprocess.run(
            [sys.executable, "common/pools.py"],
            cwd=ROOT / "dags",
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(completed.stdout)
        expected_pool_names = {
            "trino_heavy",
            "trino_traffic_heavy",
            "trino_traffic_ingest",
            "trino_traffic_transform",
            "trino_transit_heavy",
            "trino_weather_heavy",
            "trino_weather_legacy_heavy",
            "trino_weather_recovery_heavy",
        }
        self.assertIsInstance(payload, dict)
        self.assertEqual(expected_pool_names, set(payload))
        for pool_name, pool_config in payload.items():
            with self.subTest(pool_name=pool_name):
                self.assertEqual(
                    {"slots", "description", "include_deferred"},
                    set(pool_config),
                )
                self.assertIs(type(pool_config["slots"]), int)
                self.assertGreater(pool_config["slots"], 0)
                self.assertIsInstance(pool_config["description"], str)
                self.assertTrue(pool_config["description"])
                self.assertIs(type(pool_config["include_deferred"]), bool)


if __name__ == "__main__":
    unittest.main()
