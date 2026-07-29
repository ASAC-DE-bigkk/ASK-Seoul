import json
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
        }
        self.assertTrue(expected_config.issubset(set(self.config.splitlines())))
        expected_compose = {
            "TRINO_QUERY_MAX_MEMORY_PER_NODE: ${TRINO_QUERY_MAX_MEMORY_PER_NODE:-2GB}",
            "TRINO_MEMORY_HEAP_HEADROOM_PER_NODE: ${TRINO_MEMORY_HEAP_HEADROOM_PER_NODE:-2GB}",
            "TRINO_QUERY_MAX_MEMORY: ${TRINO_QUERY_MAX_MEMORY:-2GB}",
            "TRINO_QUERY_MAX_TOTAL_MEMORY: ${TRINO_QUERY_MAX_TOTAL_MEMORY:-4GB}",
        }
        for setting in expected_compose:
            self.assertIn(setting, self.compose)

    def test_safe_defaults_are_documented(self):
        expected = {
            "TRINO_MEMORY_LIMIT=9g",
            "TRINO_TASK_CONCURRENCY=2",
            "TRINO_QUERY_MAX_MEMORY_PER_NODE=2GB",
            "TRINO_MEMORY_HEAP_HEADROOM_PER_NODE=2GB",
            "TRINO_QUERY_MAX_MEMORY=2GB",
            "TRINO_QUERY_MAX_TOTAL_MEMORY=4GB",
        }
        self.assertTrue(expected.issubset(set(self.env_example.splitlines())))

    def test_global_resource_group_allows_one_running_query(self):
        resource_groups = ROOT / "trino/resource-groups.json"
        self.assertTrue(resource_groups.exists(), "resource-groups.json must exist")
        data = json.loads(resource_groups.read_text(encoding="utf-8"))
        self.assertEqual(1, len(data["rootGroups"]))
        group = data["rootGroups"][0]
        self.assertEqual("global", group["name"])
        self.assertEqual(1, group["hardConcurrencyLimit"])
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

    def test_airflow_pools_are_bootstrapped_idempotently(self):
        expected_pool_commands = {
            'airflow pools set trino_traffic_heavy 1 "Serialize Traffic Trino writes and exact tests"',
            'airflow pools set trino_traffic_ingest 1 "Serialize Traffic Bronze materialization"',
            'airflow pools set trino_traffic_transform 1 "Serialize Traffic transform and Gold writes"',
            'airflow pools set trino_weather_heavy 1 "Serialize Weather Trino writes and recovery"',
            'airflow pools set trino_weather_legacy_heavy 1 "Serialize legacy Weather transform writes"',
            'airflow pools set trino_weather_recovery_heavy 1 "Serialize Weather observation recovery"',
            'airflow pools set trino_heavy 1 "Serialize Trino/dbt memory-heavy tasks"',
        }
        for command in expected_pool_commands:
            with self.subTest(command=command):
                self.assertIn(command, self.compose)


if __name__ == "__main__":
    unittest.main()
