from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import threading
import types
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "safe_trigger_dag.py"

EXPECTED_WEATHER_DAGS = {
    "weather_vilage_fcst_bronze",
    "weather_vilage_fcst_recollect",
    "weather_vilage_fcst_bronze_backfill",
    "weather_vilage_fcst_transform",
    "weather_w1_contract_smoke",
    "weather_w2_canonical_transform",
    "weather_w2_canonical_contract_audit",
    "weather_w2_observation_recovery",
    "weather_serving_export",
    "weather_bronze_reliability_report",
    "ask_seoul_iceberg_maintenance",
}

EXPECTED_TRAFFIC_DAGS = {
    "traffic_incident_landing",
    "traffic_incident_bronze",
    "traffic_incident_recollect",
    "traffic_incident_bronze_backfill",
    "traffic_flow_bronze",
    "traffic_link_reference_backfill",
    "traffic_link_reference_sync",
    "traffic_incident_transform",
    "traffic_flow_transform",
    "traffic_gold_transform",
    "traffic_cross_domain_gold_transform",
    "traffic_cross_domain_serving_export",
    "traffic_snapshot_recovery",
    "traffic_serving_export",
    "traffic_bronze_reliability_report",
    "ask_seoul_iceberg_maintenance",
}


def _module():
    assert MODULE_PATH.is_file(), "safe trigger implementation module must exist"
    spec = importlib.util.spec_from_file_location("safe_trigger_dag", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StaticResultRunner:
    def __init__(self, result: subprocess.CompletedProcess[str]) -> None:
        self.result = result
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.commands.append(command)
        return self.result


class RecordingTriggerRunner:
    def __init__(self, *, returncode: int = 0, stdout: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.commands.append(command)
        return subprocess.CompletedProcess(
            command, self.returncode, self.stdout, "ignored trigger stderr"
        )


class _ScalarResult:
    def __init__(self, value: bool) -> None:
        self.value = value

    def scalar(self) -> bool:
        return self.value


class _AdvisoryLockSession:
    def __init__(self, shared_lock: threading.Lock, lock_denied: threading.Event) -> None:
        self.shared_lock = shared_lock
        self.lock_denied = lock_denied
        self.acquired = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        if self.acquired:
            self.shared_lock.release()
            self.acquired = False

    def execute(self, statement: str, parameters: dict[str, int]) -> _ScalarResult:
        del parameters
        if "pg_try_advisory_lock" in statement:
            self.acquired = self.shared_lock.acquire(blocking=False)
            if not self.acquired:
                self.lock_denied.set()
            return _ScalarResult(self.acquired)
        if "pg_advisory_unlock" in statement:
            if not self.acquired:
                return _ScalarResult(False)
            self.shared_lock.release()
            self.acquired = False
            return _ScalarResult(True)
        raise AssertionError(f"unexpected SQL: {statement}")


class _ScriptedSession:
    def __init__(
        self,
        *,
        lock_result: bool = True,
        unlock_result: bool = True,
        lock_error: Exception | None = None,
        unlock_error: Exception | None = None,
        exit_error: Exception | None = None,
    ) -> None:
        self.lock_result = lock_result
        self.unlock_result = unlock_result
        self.lock_error = lock_error
        self.unlock_error = unlock_error
        self.exit_error = exit_error
        self.statements: list[str] = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        if self.exit_error is not None:
            raise self.exit_error
        return None

    def execute(self, statement: str, parameters: dict[str, int]) -> _ScalarResult:
        self.assert_lock_key(parameters)
        self.statements.append(statement)
        if "pg_try_advisory_lock" in statement:
            if self.lock_error is not None:
                raise self.lock_error
            return _ScalarResult(self.lock_result)
        if "pg_advisory_unlock" in statement:
            if self.unlock_error is not None:
                raise self.unlock_error
            return _ScalarResult(self.unlock_result)
        raise AssertionError(f"unexpected SQL: {statement}")

    @staticmethod
    def assert_lock_key(parameters: dict[str, int]) -> None:
        if parameters != {"lock_key": 1234}:
            raise AssertionError(f"unexpected lock parameters: {parameters}")


class _FakeColumn:
    def in_(self, values):
        return tuple(values)


class _GeneratedScriptDagRun:
    dag_id = _FakeColumn()
    run_id = _FakeColumn()
    state = _FakeColumn()


class _GeneratedScriptSession:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        return None

    def execute(self, statement: str, parameters: dict[str, int]) -> _ScalarResult:
        del parameters
        if "pg_try_advisory_lock" in statement:
            return _ScalarResult(True)
        if "pg_advisory_unlock" in statement:
            return _ScalarResult(True)
        raise AssertionError(f"unexpected SQL: {statement}")

    def query(self, *columns):
        del columns
        return self

    def filter(self, *predicates):
        del predicates
        return self

    def all(self) -> list[tuple[str, str, str]]:
        return []


def _critical_section_call(
    module,
    *,
    session: _ScriptedSession,
    rows: list[tuple[str, str, str]] | None = None,
    active_run_query=None,
    trigger_runner=None,
    trigger_args: list[str] | None = None,
    check_only: bool = False,
) -> dict[str, object]:
    if active_run_query is None:
        active_run_query = lambda current_session, dag_ids: rows or []
    if trigger_runner is None:
        trigger_runner = RecordingTriggerRunner()
    return module._scheduler_critical_section(
        dag_id="traffic_flow_bronze",
        conflict_dags=["traffic_flow_bronze"],
        trigger_args=trigger_args or [],
        check_only=check_only,
        lock_key=1234,
        session_factory=lambda: session,
        sql_text=lambda statement: statement,
        active_run_query=active_run_query,
        trigger_runner=trigger_runner,
    )


class SafeTriggerDagTest(unittest.TestCase):
    def test_concurrent_guards_invoke_at_most_one_trigger_while_lock_is_held(self):
        module = _module()
        self.assertTrue(
            hasattr(module, "_scheduler_critical_section"),
            "scheduler-side critical section must own query and trigger",
        )
        shared_lock = threading.Lock()
        lock_denied = threading.Event()
        release_trigger = threading.Event()
        start = threading.Barrier(2)
        trigger_count = 0
        trigger_count_lock = threading.Lock()

        def trigger_runner(command: list[str]) -> subprocess.CompletedProcess[str]:
            nonlocal trigger_count
            with trigger_count_lock:
                trigger_count += 1
            self.assertTrue(release_trigger.wait(timeout=2))
            return subprocess.CompletedProcess(command, 0, "", "")

        def invoke_guard() -> dict[str, object]:
            start.wait(timeout=2)
            return module._scheduler_critical_section(
                dag_id="traffic_flow_bronze",
                conflict_dags=["traffic_flow_bronze"],
                trigger_args=[],
                check_only=False,
                lock_key=1234,
                session_factory=lambda: _AdvisoryLockSession(
                    shared_lock, lock_denied
                ),
                sql_text=lambda statement: statement,
                active_run_query=lambda session, dag_ids: [],
                trigger_runner=trigger_runner,
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(invoke_guard) for _ in range(2)]
            self.assertTrue(lock_denied.wait(timeout=2))
            release_trigger.set()
            outcomes = [future.result(timeout=2) for future in futures]

        self.assertEqual(1, trigger_count)
        self.assertEqual(
            ["lock_unavailable", "triggered"],
            sorted(outcome["status"] for outcome in outcomes),
        )

    def test_main_runs_guard_and_trigger_in_one_scheduler_process(self):
        module = _module()
        runner = StaticResultRunner(
            subprocess.CompletedProcess(
                ["scheduler-guard"], 0, '{"status":"triggered"}', ""
            )
        )

        exit_code = module.main(["traffic_flow_bronze"], runner=runner)

        self.assertEqual(0, exit_code)
        self.assertEqual(1, len(runner.commands))
        self.assertEqual(
            [
                "docker",
                "compose",
                "exec",
                "-T",
                "airflow-scheduler",
                "python",
                "-c",
            ],
            runner.commands[0][:7],
        )
        compile(runner.commands[0][7], "<scheduler-guard>", "exec")
        payload = json.loads(runner.commands[0][8])
        self.assertEqual("traffic_flow_bronze", payload["dag_id"])
        self.assertEqual([], payload["trigger_args"])
        self.assertFalse(payload["check_only"])
        self.assertEqual(module.ADVISORY_LOCK_KEY, payload["lock_key"])

    def test_main_ignores_airflow_startup_logs_before_guard_result(self):
        module = _module()
        runner = StaticResultRunner(
            subprocess.CompletedProcess(
                ["scheduler-guard"],
                0,
                "2026-08-08T09:12:51Z [info] setup plugin\n"
                'ASK_SAFE_TRIGGER_RESULT={"status":"clear"}\n',
                "",
            )
        )

        exit_code = module.main(
            ["weather_vilage_fcst_transform", "--check-only"], runner=runner
        )

        self.assertEqual(0, exit_code)

    def test_main_fails_closed_without_exact_guard_result_marker(self):
        module = _module()
        runner = StaticResultRunner(
            subprocess.CompletedProcess(
                ["scheduler-guard"],
                0,
                'startup log\n{"status":"clear"}\n',
                "",
            )
        )

        exit_code = module.main(
            ["weather_vilage_fcst_transform", "--check-only"], runner=runner
        )

        self.assertNotEqual(0, exit_code)

    def test_serialized_scheduler_script_uses_argv_and_suppresses_trigger_output(self):
        module = _module()
        airflow_module = types.ModuleType("airflow")
        models_module = types.ModuleType("airflow.models")
        dagrun_module = types.ModuleType("airflow.models.dagrun")
        utils_module = types.ModuleType("airflow.utils")
        session_module = types.ModuleType("airflow.utils.session")
        sqlalchemy_module = types.ModuleType("sqlalchemy")
        dagrun_module.DagRun = _GeneratedScriptDagRun
        session_module.create_session = _GeneratedScriptSession
        sqlalchemy_module.text = lambda statement: statement
        airflow_module.models = models_module
        airflow_module.utils = utils_module
        models_module.dagrun = dagrun_module
        utils_module.session = session_module
        fake_modules = {
            "airflow": airflow_module,
            "airflow.models": models_module,
            "airflow.models.dagrun": dagrun_module,
            "airflow.utils": utils_module,
            "airflow.utils.session": session_module,
            "sqlalchemy": sqlalchemy_module,
        }
        payload = json.dumps(
            {
                "dag_id": "traffic_flow_bronze",
                "conflict_dags": ["traffic_flow_bronze"],
                "trigger_args": [
                    "--conf",
                    '{"token":"sensitive-value;$(echo blocked)"}',
                ],
                "check_only": False,
                "lock_key": module.ADVISORY_LOCK_KEY,
            }
        )
        trigger_calls: list[tuple[list[str], dict[str, object]]] = []

        def fake_run(command: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
            trigger_calls.append((command, kwargs))
            return subprocess.CompletedProcess(
                command,
                0,
                "sensitive trigger stdout",
                "sensitive trigger stderr",
            )

        output = io.StringIO()
        with (
            mock.patch.dict(sys.modules, fake_modules),
            mock.patch.object(sys, "argv", ["scheduler-guard", payload]),
            mock.patch("subprocess.run", side_effect=fake_run),
            redirect_stdout(output),
        ):
            exec(compile(module._scheduler_script(), "<scheduler-guard>", "exec"), {})

        self.assertEqual(
            'ASK_SAFE_TRIGGER_RESULT={"status": "triggered"}\n',
            output.getvalue(),
        )
        self.assertNotIn("sensitive", output.getvalue())
        self.assertEqual(1, len(trigger_calls))
        command, kwargs = trigger_calls[0]
        self.assertEqual(
            [
                "airflow",
                "dags",
                "trigger",
                "traffic_flow_bronze",
                "--conf",
                '{"token":"sensitive-value;$(echo blocked)"}',
            ],
            command,
        )
        self.assertIs(subprocess.DEVNULL, kwargs["stdout"])
        self.assertIs(subprocess.DEVNULL, kwargs["stderr"])
        self.assertNotIn("shell", kwargs)

    def test_declared_families_cover_weather_traffic_serving_and_maintenance(self):
        module = _module()

        weather = module.conflict_set_for("weather_serving_export")
        traffic = module.conflict_set_for("traffic_incident_landing")
        maintenance = module.conflict_set_for("ask_seoul_iceberg_maintenance")

        self.assertEqual(EXPECTED_WEATHER_DAGS, weather)
        self.assertEqual(EXPECTED_TRAFFIC_DAGS, traffic)
        self.assertEqual(EXPECTED_WEATHER_DAGS | EXPECTED_TRAFFIC_DAGS, maintenance)

    def test_unknown_dag_fails_before_subprocess_trigger(self):
        module = _module()
        runner = StaticResultRunner(
            subprocess.CompletedProcess(["scheduler-guard"], 0, "{}", "")
        )

        exit_code = module.main(["unknown_dag"], runner=runner)

        self.assertNotEqual(0, exit_code)
        self.assertEqual([], runner.commands)

    def test_active_family_run_blocks_trigger(self):
        module = _module()
        for state in ("queued", "running"):
            with self.subTest(state=state):
                session = _ScriptedSession()
                trigger_runner = RecordingTriggerRunner()

                outcome = _critical_section_call(
                    module,
                    session=session,
                    rows=[
                        (
                            "traffic_flow_bronze",
                            f"manual__{state}",
                            state,
                        )
                    ],
                    trigger_runner=trigger_runner,
                )

                self.assertEqual("active", outcome["status"])
                self.assertEqual([], trigger_runner.commands)
                self.assertEqual(2, len(session.statements))
                self.assertIn("pg_advisory_unlock", session.statements[-1])

    def test_guard_process_failure_and_malformed_output_block_trigger(self):
        module = _module()
        cases = (
            subprocess.CompletedProcess(
                ["scheduler-guard"], 1, "", "database unavailable"
            ),
            subprocess.CompletedProcess(["scheduler-guard"], 0, "not json", ""),
        )

        for guard_result in cases:
            with self.subTest(guard_result=guard_result):
                runner = StaticResultRunner(guard_result)

                exit_code = module.main(["weather_vilage_fcst_bronze"], runner=runner)

                self.assertNotEqual(0, exit_code)
                self.assertEqual(1, len(runner.commands))

    def test_scheduler_dependency_failures_fail_closed_and_release_acquired_lock(self):
        module = _module()

        lock_failure_session = _ScriptedSession(
            lock_error=RuntimeError("metadata database unavailable")
        )
        self.assertEqual(
            {"status": "lock_failed"},
            _critical_section_call(module, session=lock_failure_session),
        )
        self.assertEqual(1, len(lock_failure_session.statements))

        query_failure_session = _ScriptedSession()

        def failed_query(session, dag_ids):
            raise RuntimeError("DagRun query failed")

        self.assertEqual(
            {"status": "query_failed"},
            _critical_section_call(
                module,
                session=query_failure_session,
                active_run_query=failed_query,
            ),
        )
        self.assertIn("pg_advisory_unlock", query_failure_session.statements[-1])

        trigger_failure_session = _ScriptedSession()
        self.assertEqual(
            {"status": "trigger_failed"},
            _critical_section_call(
                module,
                session=trigger_failure_session,
                trigger_runner=RecordingTriggerRunner(returncode=1),
            ),
        )
        self.assertIn("pg_advisory_unlock", trigger_failure_session.statements[-1])

        unlock_failure_session = _ScriptedSession(
            unlock_error=RuntimeError("unlock failed")
        )
        self.assertEqual(
            {"status": "triggered_unlock_failed"},
            _critical_section_call(module, session=unlock_failure_session),
        )

        cleanup_failure_session = _ScriptedSession(
            exit_error=RuntimeError("session cleanup failed")
        )
        self.assertEqual(
            {"status": "triggered_cleanup_failed"},
            _critical_section_call(module, session=cleanup_failure_session),
        )

    def test_successful_trigger_with_unlock_failure_warns_before_retry(self):
        module = _module()
        runner = StaticResultRunner(
            subprocess.CompletedProcess(
                ["scheduler-guard"],
                0,
                json.dumps({"status": "triggered_unlock_failed"}),
                "",
            )
        )
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            exit_code = module.main(["traffic_flow_bronze"], runner=runner)

        self.assertNotEqual(0, exit_code)
        self.assertIn("trigger command succeeded", stderr.getvalue())
        self.assertIn("inspect Airflow before retry", stderr.getvalue())
        self.assertNotIn("trigger blocked", stderr.getvalue())

    def test_all_guard_failure_statuses_return_nonzero(self):
        module = _module()
        for status in (
            "guard_failed",
            "lock_failed",
            "lock_unavailable",
            "query_failed",
            "trigger_failed",
            "triggered_cleanup_failed",
            "triggered_unlock_failed",
            "unlock_failed",
        ):
            with self.subTest(status=status):
                runner = StaticResultRunner(
                    subprocess.CompletedProcess(
                        ["scheduler-guard"], 0, json.dumps({"status": status}), ""
                    )
                )

                exit_code = module.main(
                    ["weather_vilage_fcst_bronze"], runner=runner
                )

                self.assertNotEqual(0, exit_code)

    def test_check_only_never_invokes_trigger(self):
        module = _module()
        session = _ScriptedSession()
        trigger_runner = RecordingTriggerRunner()

        outcome = _critical_section_call(
            module,
            session=session,
            check_only=True,
            trigger_runner=trigger_runner,
        )

        self.assertEqual({"status": "clear"}, outcome)
        self.assertEqual([], trigger_runner.commands)
        self.assertIn("pg_advisory_unlock", session.statements[-1])

    def test_no_conflict_invokes_one_exact_trigger_command(self):
        module = _module()
        session = _ScriptedSession()
        trigger_runner = RecordingTriggerRunner()

        outcome = _critical_section_call(
            module,
            session=session,
            trigger_runner=trigger_runner,
        )

        self.assertEqual({"status": "triggered"}, outcome)
        self.assertEqual(
            [
                [
                    "airflow",
                    "dags",
                    "trigger",
                    "traffic_flow_bronze",
                ]
            ],
            trigger_runner.commands,
        )
        self.assertIn("pg_advisory_unlock", session.statements[-1])

    def test_trigger_arguments_remain_separate_argv_entries(self):
        module = _module()
        session = _ScriptedSession()
        trigger_runner = RecordingTriggerRunner(stdout="sensitive trigger output")

        outcome = _critical_section_call(
            module,
            session=session,
            trigger_args=[
                "--conf",
                '{"x":"$(touch /tmp/blocked)"}',
                "--run-id",
                "manual;echo blocked",
            ],
            trigger_runner=trigger_runner,
        )

        self.assertEqual({"status": "triggered"}, outcome)
        self.assertNotIn("sensitive trigger output", repr(outcome))
        self.assertEqual(
            [
                "airflow",
                "dags",
                "trigger",
                "traffic_flow_bronze",
                "--conf",
                '{"x":"$(touch /tmp/blocked)"}',
                "--run-id",
                "manual;echo blocked",
            ],
            trigger_runner.commands[0],
        )


if __name__ == "__main__":
    unittest.main()
