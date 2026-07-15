from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "scripts" / "tests" / "fixtures" / "lineage_fail_open"

PROBE_IMPORT_ERROR: ImportError | None = None
try:
    from scripts.lineage.probe_dbt_openlineage_fail_open import (
        CommandResult,
        EXPECTED_OPENLINEAGE_DBT_VERSION,
        EXPECTED_PROVIDER_OPENLINEAGE_VERSION,
        build_image_version_commands,
        build_docker_commands,
        evaluate_image_version_results,
        evaluate_probe_results,
        main,
    )
except ImportError as error:
    PROBE_IMPORT_ERROR = error


class DbtOpenLineageFailOpenProbeTest(unittest.TestCase):
    def setUp(self) -> None:
        if PROBE_IMPORT_ERROR is not None:
            self.fail(
                "fail-open probe module is unavailable: "
                f"{type(PROBE_IMPORT_ERROR).__name__}"
            )

    def test_docker_commands_use_isolated_network_and_read_only_fixture(self) -> None:
        raw_command, wrapped_command = build_docker_commands(
            image="probe-image:local",
            fixture=FIXTURE,
        )

        expected_mount = f"type=bind,source={FIXTURE.resolve()},target=/probe,readonly"
        for command in (raw_command, wrapped_command):
            with self.subTest(entrypoint=command[command.index("--entrypoint") + 1]):
                self.assertIn("--network", command)
                self.assertEqual("none", command[command.index("--network") + 1])
                self.assertIn(expected_mount, command)
                self.assertNotIn("--env-file", command)

        self.assertEqual(
            "/home/airflow/dbt-venv/bin/dbt",
            raw_command[raw_command.index("--entrypoint") + 1],
        )
        self.assertEqual(
            "/home/airflow/dbt-venv/bin/dbt-ol",
            wrapped_command[wrapped_command.index("--entrypoint") + 1],
        )
        self.assertEqual(
            raw_command[raw_command.index("probe-image:local") + 1 :],
            wrapped_command[wrapped_command.index("probe-image:local") + 1 :],
        )
        self.assertIn("--no-introspect", raw_command)
        self.assertIn("--no-populate-cache", raw_command)
        self.assertIn("OPENLINEAGE_URL=http://127.0.0.1:1", wrapped_command)
        self.assertIn("OPENLINEAGE_ENDPOINT=api/v1/lineage", wrapped_command)
        self.assertIn(
            "OPENLINEAGE_NAMESPACE=ask-seoul-dev-dbt-fail-open-probe",
            wrapped_command,
        )

    def test_equal_success_exit_codes_with_warning_and_contact_pass(self) -> None:
        raw = CommandResult(returncode=0, output="dbt compile complete")
        wrapped = CommandResult(
            returncode=0,
            output=(
                "OpenLineage client failed to emit event COMPLETE "
                "HTTPConnectionPool(host='127.0.0.1', port=1)"
            ),
        )

        verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)

        self.assertTrue(verdict.ok)
        self.assertTrue(verdict.primary_command_succeeded)
        self.assertTrue(verdict.exit_codes_match)
        self.assertTrue(verdict.lineage_warning_observed)
        self.assertTrue(verdict.endpoint_contact_observed)

    def test_bounded_multiline_exception_block_passes(self) -> None:
        raw = CommandResult(returncode=0, output="dbt compile complete")
        wrapped = CommandResult(
            returncode=0,
            output=(
                "OpenLineage client failed to emit event COMPLETE\n"
                "Traceback (most recent call last):\n"
                '  File "transport.py", line 1, in emit\n'
                "requests.exceptions.ConnectionError: "
                "HTTPConnectionPool(host='127.0.0.1', port=1): "
                "Max retries exceeded: Connection refused"
            ),
        )

        verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)

        self.assertTrue(verdict.ok)
        self.assertTrue(verdict.endpoint_contact_observed)

    def test_config_only_endpoint_text_does_not_prove_contact(self) -> None:
        raw = CommandResult(returncode=0, output="dbt compile complete")
        wrapped = CommandResult(
            returncode=0,
            output=(
                "OpenLineage client failed to emit event; "
                "configured endpoint is http://127.0.0.1:1"
            ),
        )

        verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)

        self.assertFalse(verdict.ok)
        self.assertTrue(verdict.lineage_warning_observed)
        self.assertFalse(verdict.endpoint_contact_observed)

    def test_warning_and_connection_failure_in_separate_log_records_fail(self) -> None:
        raw = CommandResult(returncode=0, output="dbt compile complete")
        wrapped = CommandResult(
            returncode=0,
            output=(
                "WARNING OpenLineage client failed to emit event COMPLETE\n"
                "INFO HTTPConnectionPool(host='127.0.0.1', port=1): "
                "Max retries exceeded: Connection refused"
            ),
        )

        verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)

        self.assertFalse(verdict.ok)
        self.assertTrue(verdict.lineage_warning_observed)
        self.assertFalse(verdict.endpoint_contact_observed)

    def test_exit_code_mismatch_fails(self) -> None:
        raw = CommandResult(returncode=0, output="")
        wrapped = CommandResult(
            returncode=1,
            output=(
                "OpenLineage client failed to emit event COMPLETE "
                "HTTPConnectionPool(host='127.0.0.1', port=1)"
            ),
        )

        verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)

        self.assertFalse(verdict.ok)
        self.assertFalse(verdict.exit_codes_match)

    def test_missing_lineage_warning_fails(self) -> None:
        raw = CommandResult(returncode=0, output="")
        wrapped = CommandResult(
            returncode=0,
            output="HTTPConnectionPool(host='127.0.0.1', port=1)",
        )

        verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)

        self.assertFalse(verdict.ok)
        self.assertFalse(verdict.lineage_warning_observed)

    def test_missing_endpoint_contact_fails(self) -> None:
        raw = CommandResult(returncode=0, output="")
        wrapped = CommandResult(
            returncode=0,
            output="OpenLineage client failed to emit event COMPLETE",
        )

        verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)

        self.assertFalse(verdict.ok)
        self.assertFalse(verdict.endpoint_contact_observed)

    def test_summary_never_includes_subprocess_output(self) -> None:
        raw = CommandResult(returncode=0, output="RAW_SECRET_SENTINEL")
        wrapped = CommandResult(
            returncode=0,
            output=(
                "WRAPPED_SECRET_SENTINEL OpenLineage client failed to emit event "
                "HTTPConnectionPool(host='127.0.0.1', port=1)"
            ),
        )

        summary = "\n".join(
            evaluate_probe_results(raw=raw, wrapped=wrapped).summary_lines()
        )

        self.assertNotIn("RAW_SECRET_SENTINEL", summary)
        self.assertNotIn("WRAPPED_SECRET_SENTINEL", summary)
        self.assertIn("raw_exit_code=0", summary)
        self.assertIn("wrapped_exit_code=0", summary)
        self.assertIn("probe_status=pass", summary)

    def test_image_version_commands_are_network_isolated_and_deterministic(
        self,
    ) -> None:
        provider_command, dbt_command = build_image_version_commands(
            image="probe-image:local"
        )

        for command in (provider_command, dbt_command):
            with self.subTest(entrypoint=command[command.index("--entrypoint") + 1]):
                self.assertEqual("none", command[command.index("--network") + 1])
                self.assertNotIn("--mount", command)
                self.assertNotIn("--env-file", command)
                self.assertEqual("probe-image:local", command[-3])
                self.assertEqual("-c", command[-2])

        self.assertEqual(
            "/usr/local/bin/python",
            provider_command[provider_command.index("--entrypoint") + 1],
        )
        self.assertIn("apache-airflow-providers-openlineage", provider_command[-1])
        self.assertEqual(
            "/home/airflow/dbt-venv/bin/python",
            dbt_command[dbt_command.index("--entrypoint") + 1],
        )
        self.assertIn("openlineage-dbt", dbt_command[-1])

    def test_image_version_gate_accepts_only_exact_pins(self) -> None:
        verdict = evaluate_image_version_results(
            provider=CommandResult(
                returncode=0,
                output=f"{EXPECTED_PROVIDER_OPENLINEAGE_VERSION}\n",
            ),
            openlineage_dbt=CommandResult(
                returncode=0,
                output=f"{EXPECTED_OPENLINEAGE_DBT_VERSION}\n",
            ),
        )

        self.assertTrue(verdict.ok)
        summary = "\n".join(verdict.summary_lines())
        self.assertIn(
            f"provider_openlineage_version_expected="
            f"{EXPECTED_PROVIDER_OPENLINEAGE_VERSION}",
            summary,
        )
        self.assertIn("provider_openlineage_version_match=true", summary)
        self.assertIn(
            f"openlineage_dbt_version_expected={EXPECTED_OPENLINEAGE_DBT_VERSION}",
            summary,
        )
        self.assertIn("openlineage_dbt_version_match=true", summary)

    def test_image_version_gate_rejects_mismatch_without_exposing_observed_value(
        self,
    ) -> None:
        verdict = evaluate_image_version_results(
            provider=CommandResult(returncode=0, output="2.17.0\n"),
            openlineage_dbt=CommandResult(
                returncode=0,
                output=f"{EXPECTED_OPENLINEAGE_DBT_VERSION}\n",
            ),
        )

        self.assertFalse(verdict.ok)
        summary = "\n".join(verdict.summary_lines())
        self.assertIn("provider_openlineage_version_match=false", summary)
        self.assertNotIn("2.17.0", summary)

    @mock.patch(
        "scripts.lineage.probe_dbt_openlineage_fail_open.image_is_available",
        return_value=True,
    )
    @mock.patch(
        "scripts.lineage.probe_dbt_openlineage_fail_open.shutil.which",
        return_value="docker",
    )
    @mock.patch("scripts.lineage.probe_dbt_openlineage_fail_open.run_command")
    def test_version_mismatch_fails_before_raw_or_wrapped_dbt_runs(
        self,
        run_command_mock: mock.Mock,
        _which_mock: mock.Mock,
        _image_mock: mock.Mock,
    ) -> None:
        run_command_mock.side_effect = (
            CommandResult(returncode=0, output="2.17.0\n"),
            CommandResult(
                returncode=0,
                output=f"{EXPECTED_OPENLINEAGE_DBT_VERSION}\n",
            ),
        )
        stdout = io.StringIO()

        with redirect_stdout(stdout):
            exit_code = main(
                (
                    "--image",
                    "probe-image:local",
                    "--fixture",
                    str(FIXTURE),
                )
            )

        self.assertEqual(1, exit_code)
        self.assertEqual(2, run_command_mock.call_count)
        summary = stdout.getvalue()
        self.assertIn("provider_openlineage_version_match=false", summary)
        self.assertIn("probe_status=fail", summary)
        self.assertNotIn("raw_exit_code", summary)
        self.assertNotIn("2.17.0", summary)


class DbtOpenLineageFailOpenFixtureTest(unittest.TestCase):
    def test_fixture_is_compile_only_and_has_no_connection_secret(self) -> None:
        project_path = FIXTURE / "dbt_project.yml"
        profile_path = FIXTURE / "profiles.yml"
        model_path = FIXTURE / "models" / "probe.sql"
        missing_paths = [
            path.relative_to(ROOT)
            for path in (project_path, profile_path, model_path)
            if not path.is_file()
        ]
        self.assertEqual(
            [], missing_paths, f"required probe fixtures are missing: {missing_paths}"
        )

        project = project_path.read_text(encoding="utf-8")
        profile = profile_path.read_text(encoding="utf-8")
        model = model_path.read_text(encoding="utf-8")

        self.assertIn("lineage_fail_open_probe", project)
        self.assertIn("flags:", project)
        self.assertIn("send_anonymous_usage_stats: false", project.lower())
        self.assertNotIn("send_anonymous_usage_stats", profile.lower())
        self.assertEqual("select 1 as probe_value\n", model)
        fixture_text = "\n".join((project, profile, model)).lower()
        for forbidden in ("password", "token", "secret", "service_key"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, fixture_text)


if __name__ == "__main__":
    unittest.main()
