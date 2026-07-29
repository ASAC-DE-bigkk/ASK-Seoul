"""Prepare and validate a prod-only Docker Compose environment file.

The command never prints environment values. It exists to keep the shared
Mac mini runtime from loading dev R2 credentials or the dev Iceberg catalog.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")
_FORBIDDEN_NAMES = {
    "TRINO_DEV_ICEBERG_CATALOG",
    "DEV_SMOKE_SCHEMA",
    "ASK_SEOUL_DEV_RAW_PREFIX",
}
_PROD_OVERRIDES = {
    "ASK_SEOUL_TARGET": "prod",
    "DBT_TARGET": "prod",
    "R2_BUCKET_NAME": "seoul",
    "TRINO_ICEBERG_CATALOG": "iceberg",
    "SMOKE_SCHEMA": "ops_smoke",
    "R2_RAW_PREFIX": "raw",
}
_REQUIRED_NAMES = (
    "ASK_SEOUL_TARGET",
    "DBT_TARGET",
    "R2_BUCKET_NAME",
    "R2_ENDPOINT",
    "R2_ACCESS_KEY_ID",
    "R2_SECRET_ACCESS_KEY",
    "R2_DATA_CATALOG_TOKEN",
    "R2_DATA_CATALOG_URI",
    "R2_DATA_CATALOG_WAREHOUSE",
    "R2_RAW_PREFIX",
    "TRINO_ICEBERG_CATALOG",
    "SMOKE_SCHEMA",
)


class ProdEnvError(RuntimeError):
    """A sanitized prod environment contract failure."""


def _assignment(raw_line: str) -> tuple[str, str] | None:
    line = raw_line.strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith("export "):
        line = line.removeprefix("export ").lstrip()
    if "=" not in line:
        return None
    name, value = line.split("=", 1)
    name = name.strip()
    if not _ENV_NAME.fullmatch(name):
        raise ProdEnvError("environment file contains an invalid key name")
    return name, value.strip()


def parse_env_text(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        assignment = _assignment(raw_line)
        if assignment is None:
            continue
        name, value = assignment
        if name in values:
            raise ProdEnvError(f"environment key is duplicated: {name}")
        values[name] = value
    return values


def _normalized_value(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def validate_prod_values(values: dict[str, str]) -> None:
    for name in values:
        if name.startswith("R2_DEV_") or name in _FORBIDDEN_NAMES:
            raise ProdEnvError(f"prod environment contains forbidden dev key: {name}")

    for name in _REQUIRED_NAMES:
        value = _normalized_value(values.get(name, "")).strip()
        if not value or (value.startswith("<") and value.endswith(">")):
            raise ProdEnvError(f"prod environment key is missing: {name}")

    for name, expected in _PROD_OVERRIDES.items():
        if _normalized_value(values[name]).strip() != expected:
            raise ProdEnvError(f"prod environment key has an unsafe value: {name}")


def validate_prod_env(path: Path) -> None:
    if not path.is_file():
        raise ProdEnvError(f"environment file does not exist: {path}")
    validate_prod_values(parse_env_text(path.read_text(encoding="utf-8-sig")))


def prepare_prod_env(source: Path, output: Path, *, force: bool = False) -> None:
    if not source.is_file():
        raise ProdEnvError(f"source environment file does not exist: {source}")
    if output.exists() and not force:
        raise ProdEnvError(f"output environment file already exists: {output}")

    source_text = source.read_text(encoding="utf-8-sig")
    source_lines = source_text.splitlines()
    last_assignment: dict[str, int] = {}
    for index, raw_line in enumerate(source_lines):
        assignment = _assignment(raw_line)
        if assignment is not None:
            last_assignment[assignment[0]] = index

    preserved_lines: list[str] = []
    for index, raw_line in enumerate(source_lines):
        assignment = _assignment(raw_line)
        if assignment is None:
            preserved_lines.append(raw_line)
            continue
        name, _ = assignment
        if last_assignment[name] != index:
            continue
        if (
            name.startswith("R2_DEV_")
            or name in _FORBIDDEN_NAMES
            or name in _PROD_OVERRIDES
        ):
            continue
        preserved_lines.append(raw_line)

    while preserved_lines and not preserved_lines[-1].strip():
        preserved_lines.pop()
    prepared_lines = [
        *preserved_lines,
        "",
        "# Generated prod-only target selectors. Do not add R2_DEV_* keys.",
        *[f"{name}={value}" for name, value in _PROD_OVERRIDES.items()],
        "",
    ]
    prepared_text = "\n".join(prepared_lines)
    validate_prod_values(parse_env_text(prepared_text))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(prepared_text, encoding="utf-8", newline="\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    prepare = commands.add_parser("prepare", help="create a prod-only env file")
    prepare.add_argument("--source", type=Path, default=Path(".env"))
    prepare.add_argument("--output", type=Path, default=Path(".env.prod"))
    prepare.add_argument("--force", action="store_true")

    validate = commands.add_parser("validate", help="validate a prod-only env file")
    validate.add_argument("--env-file", type=Path, default=Path(".env.prod"))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "prepare":
            prepare_prod_env(args.source, args.output, force=args.force)
            print(f"prepared prod environment: {args.output}")
        else:
            validate_prod_env(args.env_file)
            print(f"validated prod environment: {args.env_file}")
    except ProdEnvError as exc:
        print(f"prod environment error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
