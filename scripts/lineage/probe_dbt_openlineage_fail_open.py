from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = ROOT / "scripts" / "tests" / "fixtures" / "lineage_fail_open"
DEFAULT_IMAGE = "elt-infra-airflow:local"
AIRFLOW_PYTHON = "/usr/local/bin/python"
DBT_BIN = "/home/airflow/dbt-venv/bin/dbt"
DBT_OL_BIN = "/home/airflow/dbt-venv/bin/dbt-ol"
DBT_PYTHON = "/home/airflow/dbt-venv/bin/python"
EXPECTED_PROVIDER_OPENLINEAGE_VERSION = "2.19.0"
EXPECTED_OPENLINEAGE_DBT_VERSION = "1.51.0"
CONTAINER_PATH = (
    "/home/airflow/dbt-venv/bin:/home/airflow/.local/bin:/usr/local/bin:"
    "/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
)
DBT_COMPILE_ARGS = (
    "compile",
    "--project-dir",
    "/probe",
    "--profiles-dir",
    "/probe",
    "--target-path",
    "/tmp/target",
    "--log-path",
    "/tmp/logs",
    "--no-introspect",
    "--no-populate-cache",
)
LINEAGE_WARNING_MARKERS = (
    "openlineage client failed to emit event",
    "failed to emit openlineage",
)
CONNECTION_FAILURE_MARKERS = (
    "connection refused",
    "failed to establish a new connection",
    "httpconnectionpool",
    "max retries exceeded",
    "maxretryerror",
    "newconnectionerror",
)
MAX_EXCEPTION_BLOCK_LINES = 8
ENDPOINT_PATTERN = re.compile(
    r"(?:127\.0\.0\.1\s*:\s*1\b|"
    r"host\s*=\s*['\"]127\.0\.0\.1['\"]\s*,\s*port\s*=\s*1\b)",
    re.IGNORECASE,
)
ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
LOG_RECORD_PREFIX_PATTERN = re.compile(
    r"^(?:(?:\d{2}:){2}\d{2}(?:\.\d+)?\s+)?"
    r"(?:debug|info|warning|warn|error|critical)\b",
    re.IGNORECASE,
)
EXCEPTION_CONTINUATION_PREFIXES = (
    "traceback (most recent call last):",
    "file ",
    "during handling of the above exception",
    "the above exception was the direct cause",
    "caused by:",
    "requests.",
    "urllib3.",
    "connectionerror",
    "newconnectionerror",
    "maxretryerror",
    "httpconnectionpool(",
    "[errno ",
)


def _boolean(value: bool) -> str:
    return "true" if value else "false"


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    output: str = field(repr=False)


@dataclass(frozen=True)
class ImageVersionVerdict:
    provider_openlineage_version_match: bool
    openlineage_dbt_version_match: bool

    @property
    def ok(self) -> bool:
        return all(
            (
                self.provider_openlineage_version_match,
                self.openlineage_dbt_version_match,
            )
        )

    def summary_lines(self) -> tuple[str, ...]:
        return (
            "provider_openlineage_version_expected="
            f"{EXPECTED_PROVIDER_OPENLINEAGE_VERSION}",
            "provider_openlineage_version_match="
            f"{_boolean(self.provider_openlineage_version_match)}",
            f"openlineage_dbt_version_expected={EXPECTED_OPENLINEAGE_DBT_VERSION}",
            "openlineage_dbt_version_match="
            f"{_boolean(self.openlineage_dbt_version_match)}",
            f"image_version_gate_passed={_boolean(self.ok)}",
        )


@dataclass(frozen=True)
class ProbeVerdict:
    raw_exit_code: int
    wrapped_exit_code: int
    primary_command_succeeded: bool
    exit_codes_match: bool
    lineage_warning_observed: bool
    endpoint_contact_observed: bool

    @property
    def ok(self) -> bool:
        return all(
            (
                self.primary_command_succeeded,
                self.exit_codes_match,
                self.lineage_warning_observed,
                self.endpoint_contact_observed,
            )
        )

    def summary_lines(self) -> tuple[str, ...]:
        return (
            f"raw_exit_code={self.raw_exit_code}",
            f"wrapped_exit_code={self.wrapped_exit_code}",
            f"primary_command_succeeded={_boolean(self.primary_command_succeeded)}",
            f"exit_codes_match={_boolean(self.exit_codes_match)}",
            f"lineage_warning_observed={_boolean(self.lineage_warning_observed)}",
            f"endpoint_contact_observed={_boolean(self.endpoint_contact_observed)}",
            f"probe_status={'pass' if self.ok else 'fail'}",
        )


def build_image_version_commands(
    image: str,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    common = ("docker", "run", "--rm", "--network", "none", "--entrypoint")
    provider = (
        *common,
        AIRFLOW_PYTHON,
        image,
        "-c",
        "from importlib.metadata import version; "
        "print(version('apache-airflow-providers-openlineage'))",
    )
    openlineage_dbt = (
        *common,
        DBT_PYTHON,
        image,
        "-c",
        "from importlib.metadata import version; print(version('openlineage-dbt'))",
    )
    return provider, openlineage_dbt


def build_docker_commands(
    image: str,
    fixture: Path,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    mount = f"type=bind,source={fixture.resolve()},target=/probe,readonly"
    common = (
        "docker",
        "run",
        "--rm",
        "--network",
        "none",
        "--mount",
        mount,
        "--workdir",
        "/probe",
        "--env",
        f"PATH={CONTAINER_PATH}",
    )
    raw = (*common, "--entrypoint", DBT_BIN, image, *DBT_COMPILE_ARGS)
    wrapped = (
        *common,
        "--env",
        "OPENLINEAGE_URL=http://127.0.0.1:1",
        "--env",
        "OPENLINEAGE_ENDPOINT=api/v1/lineage",
        "--env",
        "OPENLINEAGE_NAMESPACE=ask-seoul-dev-dbt-fail-open-probe",
        "--env",
        "OPENLINEAGE__FACETS__SOURCE_CODE_LOCATION__DISABLED=true",
        "--entrypoint",
        DBT_OL_BIN,
        image,
        *DBT_COMPILE_ARGS,
    )
    return raw, wrapped


def evaluate_image_version_results(
    provider: CommandResult,
    openlineage_dbt: CommandResult,
) -> ImageVersionVerdict:
    return ImageVersionVerdict(
        provider_openlineage_version_match=(
            provider.returncode == 0
            and provider.output.strip() == EXPECTED_PROVIDER_OPENLINEAGE_VERSION
        ),
        openlineage_dbt_version_match=(
            openlineage_dbt.returncode == 0
            and openlineage_dbt.output.strip() == EXPECTED_OPENLINEAGE_DBT_VERSION
        ),
    )


def _is_exception_continuation(line: str) -> bool:
    without_ansi = ANSI_ESCAPE_PATTERN.sub("", line)
    stripped = without_ansi.strip()
    if not stripped or LOG_RECORD_PREFIX_PATTERN.match(stripped):
        return False
    if without_ansi[:1].isspace():
        return True
    lowered = stripped.lower()
    return lowered.startswith(EXCEPTION_CONTINUATION_PREFIXES)


def _lineage_emission_failure_blocks(output: str) -> tuple[str, ...]:
    lines = output.splitlines()
    blocks: list[str] = []
    for index, line in enumerate(lines):
        lowered = line.lower()
        if not any(marker in lowered for marker in LINEAGE_WARNING_MARKERS):
            continue

        block = [line]
        for continuation in lines[index + 1 : index + MAX_EXCEPTION_BLOCK_LINES]:
            if not _is_exception_continuation(continuation):
                break
            block.append(continuation)
        blocks.append("\n".join(block))
    return tuple(blocks)


def _has_correlated_endpoint_failure(output: str) -> bool:
    for block in _lineage_emission_failure_blocks(output):
        lowered = block.lower()
        if ENDPOINT_PATTERN.search(block) and any(
            marker in lowered for marker in CONNECTION_FAILURE_MARKERS
        ):
            return True
    return False


def evaluate_probe_results(
    raw: CommandResult,
    wrapped: CommandResult,
) -> ProbeVerdict:
    wrapped_output = wrapped.output.lower()
    warning_observed = any(
        marker in wrapped_output for marker in LINEAGE_WARNING_MARKERS
    )
    endpoint_contact_observed = _has_correlated_endpoint_failure(wrapped.output)
    return ProbeVerdict(
        raw_exit_code=raw.returncode,
        wrapped_exit_code=wrapped.returncode,
        primary_command_succeeded=raw.returncode == 0,
        exit_codes_match=raw.returncode == wrapped.returncode,
        lineage_warning_observed=warning_observed,
        endpoint_contact_observed=endpoint_contact_observed,
    )


def run_command(command: Sequence[str], timeout_seconds: int) -> CommandResult:
    completed = subprocess.run(
        list(command),
        cwd=ROOT,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        timeout=timeout_seconds,
    )
    return CommandResult(
        returncode=completed.returncode,
        output=f"{completed.stdout}\n{completed.stderr}",
    )


def image_is_available(image: str, timeout_seconds: int) -> bool:
    completed = subprocess.run(
        ["docker", "image", "inspect", image],
        cwd=ROOT,
        capture_output=True,
        check=False,
        timeout=timeout_seconds,
    )
    return completed.returncode == 0


def blocked(reason: str) -> int:
    print("probe_status=blocked")
    print(f"blocked_reason={reason}")
    return 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Probe dbt-ol fail-open behavior against an unreachable local endpoint."
    )
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--timeout-seconds", type=int, default=120)
    args = parser.parse_args(argv)

    if shutil.which("docker") is None:
        return blocked("docker_cli_unavailable")
    if not args.fixture.is_dir():
        return blocked("probe_fixture_unavailable")
    try:
        if not image_is_available(args.image, args.timeout_seconds):
            return blocked("airflow_image_unavailable")
        provider_version_command, openlineage_dbt_version_command = (
            build_image_version_commands(args.image)
        )
        provider_version = run_command(
            provider_version_command,
            args.timeout_seconds,
        )
        openlineage_dbt_version = run_command(
            openlineage_dbt_version_command,
            args.timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        return blocked("probe_command_timeout")
    except OSError:
        return blocked("docker_command_unavailable")

    image_version_verdict = evaluate_image_version_results(
        provider=provider_version,
        openlineage_dbt=openlineage_dbt_version,
    )
    for line in image_version_verdict.summary_lines():
        print(line)
    if not image_version_verdict.ok:
        print("probe_status=fail")
        return 1

    try:
        raw_command, wrapped_command = build_docker_commands(
            image=args.image,
            fixture=args.fixture,
        )
        raw = run_command(raw_command, args.timeout_seconds)
        wrapped = run_command(wrapped_command, args.timeout_seconds)
    except subprocess.TimeoutExpired:
        return blocked("probe_command_timeout")
    except OSError:
        return blocked("docker_command_unavailable")

    verdict = evaluate_probe_results(raw=raw, wrapped=wrapped)
    for line in verdict.summary_lines():
        print(line)
    return 0 if verdict.ok else 1


if __name__ == "__main__":
    sys.exit(main())
