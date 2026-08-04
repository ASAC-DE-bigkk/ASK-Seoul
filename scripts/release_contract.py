"""Create and validate the immutable shared prod release contract.

The release artifact is intentionally generated *after* an exact root commit
and image have been selected.  This avoids a self-referential root SHA while
still making every deploy input immutable and independently checkable.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Mapping


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = "ask-seoul-release/v1"
COMPONENTS = ("root", "dags", "dbt", "dashboard")
_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")
_SHA = re.compile(r"^[0-9a-f]{40}$")
_IMAGE = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
_FORBIDDEN_PROD_NAMES = {
    "ASK_SEOUL_TARGET",
    "TRINO_DEV_ICEBERG_CATALOG",
    "DEV_SMOKE_SCHEMA",
    "ASK_SEOUL_DEV_RAW_PREFIX",
}
_REQUIRED_PROD_VALUES = {
    "DBT_TARGET": "prod",
    "R2_BUCKET_NAME": "seoul",
    "TRINO_ICEBERG_CATALOG": "iceberg",
    "SMOKE_SCHEMA": "ops_smoke",
}
_REQUIRED_PROD_NAMES = (
    "R2_ENDPOINT",
    "R2_ACCESS_KEY_ID",
    "R2_SECRET_ACCESS_KEY",
    "R2_DATA_CATALOG_URI",
    "R2_DATA_CATALOG_WAREHOUSE",
    "R2_DATA_CATALOG_TOKEN",
    "ASK_SEOUL_SCHEMA",
    "SERVING_CLOUDFLARE_ACCOUNT_ID",
    "SERVING_D1_DATABASE_ID",
    "ASK_SEOUL_AIRFLOW_IMAGE",
    "MARQUEZ_POSTGRES_USER",
    "MARQUEZ_POSTGRES_PASSWORD",
    "MARQUEZ_POSTGRES_DB",
)


class ReleaseContractError(RuntimeError):
    """A sanitized release-contract validation failure."""


def _assignment(raw_line: str) -> tuple[str, str] | None:
    line = raw_line.strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith("export "):
        line = line.removeprefix("export ").lstrip()
    if "=" not in line:
        raise ReleaseContractError("environment file contains a malformed line")
    name, value = line.split("=", 1)
    name = name.strip()
    if not _ENV_NAME.fullmatch(name):
        raise ReleaseContractError("environment file contains an invalid key name")
    return name, value.strip()


def load_env_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise ReleaseContractError("environment file does not exist")
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        assignment = _assignment(raw_line)
        if assignment is None:
            continue
        name, value = assignment
        if name in values:
            raise ReleaseContractError(f"environment key is duplicated: {name}")
        values[name] = value
    return values


def _value(values: Mapping[str, str], name: str) -> str:
    value = values.get(name, "").strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1].strip()
    if not value or (value.startswith("<") and value.endswith(">")):
        raise ReleaseContractError(f"prod environment key is missing: {name}")
    return value


def validate_prod_environment(values: Mapping[str, str]) -> None:
    forbidden = sorted(
        name
        for name in values
        if name.startswith("R2_DEV_") or name in _FORBIDDEN_PROD_NAMES
    )
    if forbidden:
        raise ReleaseContractError(
            "prod environment contains forbidden dev or alias key: "
            + ", ".join(forbidden)
        )
    for name, expected in _REQUIRED_PROD_VALUES.items():
        if _value(values, name) != expected:
            raise ReleaseContractError(f"prod environment key has an unsafe value: {name}")
    for name in _REQUIRED_PROD_NAMES:
        _value(values, name)
    if _value(values, "ASK_SEOUL_SCHEMA").lower().startswith("dev_"):
        raise ReleaseContractError("ASK_SEOUL_SCHEMA must not select a dev schema")
    if not _IMAGE.fullmatch(_value(values, "ASK_SEOUL_AIRFLOW_IMAGE")):
        raise ReleaseContractError("ASK_SEOUL_AIRFLOW_IMAGE must be pinned by sha256 digest")


def build_release_artifact(
    *,
    release_name: str,
    commits: Mapping[str, str],
    airflow_image: str,
) -> dict[str, object]:
    artifact = {
        "schema_version": SCHEMA_VERSION,
        "release_name": release_name,
        "components": {name: str(commits[name]).lower() for name in COMPONENTS},
        "images": {"airflow": airflow_image},
    }
    validate_release_artifact(artifact)
    return artifact


def validate_release_artifact(artifact: Mapping[str, object]) -> None:
    if artifact.get("schema_version") != SCHEMA_VERSION:
        raise ReleaseContractError("release artifact schema_version is unsupported")
    release_name = artifact.get("release_name")
    if not isinstance(release_name, str) or not release_name.strip():
        raise ReleaseContractError("release artifact release_name is missing")
    components = artifact.get("components")
    if not isinstance(components, Mapping) or set(components) != set(COMPONENTS):
        raise ReleaseContractError("release artifact must pin root, dags, dbt, and dashboard")
    for name in COMPONENTS:
        value = components.get(name)
        if not isinstance(value, str) or not _SHA.fullmatch(value):
            raise ReleaseContractError(f"release artifact component SHA is invalid: {name}")
    images = artifact.get("images")
    if not isinstance(images, Mapping) or set(images) != {"airflow"}:
        raise ReleaseContractError("release artifact must pin one Airflow image")
    airflow_image = images.get("airflow")
    if not isinstance(airflow_image, str) or not _IMAGE.fullmatch(airflow_image):
        raise ReleaseContractError("release artifact Airflow image must use an immutable sha256 digest")


def _current_component_commits(root: Path) -> dict[str, str]:
    paths = {"root": root, "dags": root / "dags", "dbt": root / "dbt", "dashboard": root / "dashboard"}
    commits: dict[str, str] = {}
    for name, path in paths.items():
        expected_toplevel = path.resolve()
        if not path.exists():
            raise ReleaseContractError(f"component checkout path is missing: {name}")
        toplevel_result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
        if (
            toplevel_result.returncode != 0
            or Path(toplevel_result.stdout.strip()).resolve() != expected_toplevel
        ):
            raise ReleaseContractError(f"component checkout is not initialized: {name}")
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        sha = result.stdout.strip().lower()
        if result.returncode != 0 or not _SHA.fullmatch(sha):
            raise ReleaseContractError(f"cannot resolve checked-out component SHA: {name}")
        commits[name] = sha
    return commits


def _component_is_clean(path: Path) -> bool:
    result = subprocess.run(
        ["git", "-C", str(path), "status", "--porcelain=v1", "--untracked-files=no"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0 and not result.stdout.strip()


def _load_artifact(path: Path) -> dict[str, object]:
    if not path.is_file():
        raise ReleaseContractError("release artifact does not exist")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ReleaseContractError("release artifact is not valid JSON") from exc
    if not isinstance(document, dict):
        raise ReleaseContractError("release artifact root must be an object")
    validate_release_artifact(document)
    return document


def preflight(*, env_file: Path, artifact_file: Path, root: Path = ROOT) -> None:
    values = load_env_file(env_file)
    validate_prod_environment(values)
    artifact = _load_artifact(artifact_file)
    component_paths = {
        "root": root,
        "dags": root / "dags",
        "dbt": root / "dbt",
        "dashboard": root / "dashboard",
    }
    for name, path in component_paths.items():
        if not _component_is_clean(path):
            raise ReleaseContractError(f"release component checkout is not clean: {name}")
    components = artifact["components"]
    assert isinstance(components, Mapping)
    if _current_component_commits(root) != dict(components):
        raise ReleaseContractError("checked-out root or submodule SHA differs from release artifact")
    images = artifact["images"]
    assert isinstance(images, Mapping)
    if _value(values, "ASK_SEOUL_AIRFLOW_IMAGE") != images["airflow"]:
        raise ReleaseContractError("Airflow image differs from release artifact")


def run_prod_compose(*, env_file: Path, artifact_file: Path, compose_args: list[str]) -> int:
    if not compose_args:
        raise ReleaseContractError("a Docker Compose command is required")
    preflight(env_file=env_file, artifact_file=artifact_file)
    environment = dict(os.environ)
    environment["ASK_SEOUL_PROD_ENV_FILE"] = str(env_file.resolve())
    return subprocess.run(
        [
            "docker",
            "compose",
            "--profile",
            "lineage",
            "--env-file",
            str(env_file.resolve()),
            "-f",
            str(ROOT / "docker-compose.yml"),
            "-f",
            str(ROOT / "docker-compose.prod.yml"),
            *compose_args,
        ],
        cwd=ROOT,
        env=environment,
        check=False,
    ).returncode


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--release-name", required=True)
    for component in COMPONENTS:
        create.add_argument(f"--{component}-sha", required=True)
    create.add_argument("--airflow-image", required=True)
    create.add_argument("--output", type=Path, required=True)
    validate = commands.add_parser("preflight")
    validate.add_argument("--env-file", type=Path, required=True)
    validate.add_argument("--artifact", type=Path, required=True)
    compose = commands.add_parser("compose")
    compose.add_argument("--env-file", type=Path, required=True)
    compose.add_argument("--artifact", type=Path, required=True)
    compose.add_argument("compose_args", nargs=argparse.REMAINDER)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "create":
            artifact = build_release_artifact(
                release_name=args.release_name,
                commits={name: getattr(args, f"{name}_sha") for name in COMPONENTS},
                airflow_image=args.airflow_image,
            )
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(
                json.dumps(artifact, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            print(f"release artifact written: {args.output}")
        elif args.command == "preflight":
            preflight(env_file=args.env_file, artifact_file=args.artifact)
            print("release preflight passed")
        else:
            return run_prod_compose(
                env_file=args.env_file,
                artifact_file=args.artifact,
                compose_args=args.compose_args,
            )
    except ReleaseContractError as exc:
        print(f"release contract error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
