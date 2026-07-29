"""Run the isolated prod Compose project with validated prod credentials."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

from prod_env import ProdEnvError, validate_prod_env


ROOT = Path(__file__).resolve().parents[1]
PROJECT_NAME = "elt-infra-prod"
MINIMUM_COMPOSE_VERSION = (2, 24, 4)
EXPECTED_NETWORK_NAME = "elt-infra-prod-net"
EXPECTED_VOLUME_NAMES = {
    "postgres_data": "elt-infra-prod_postgres_data",
    "airflow_logs": "elt-infra-prod_airflow_logs",
}
CORE_SERVICES = {
    "postgres",
    "trino",
    "airflow-init",
    "airflow-apiserver",
    "airflow-scheduler",
    "airflow-dag-processor",
    "airflow-triggerer",
}
FORBIDDEN_ENV_NAMES = {
    "TRINO_DEV_ICEBERG_CATALOG",
    "DEV_SMOKE_SCHEMA",
    "ASK_SEOUL_DEV_RAW_PREFIX",
}
EXPECTED_PROD_ENVIRONMENT = {
    "ASK_SEOUL_TARGET": "prod",
    "DBT_TARGET": "prod",
    "R2_BUCKET_NAME": "seoul",
    "R2_RAW_PREFIX": "raw",
    "SMOKE_SCHEMA": "ops_smoke",
    "TRINO_ICEBERG_CATALOG": "iceberg",
}
TRINO_CATALOG_TARGET = "/etc/trino/catalog"
ALLOWED_COMPOSE_COMMANDS = {
    "attach",
    "build",
    "cp",
    "create",
    "down",
    "events",
    "exec",
    "images",
    "kill",
    "logs",
    "pause",
    "port",
    "ps",
    "pull",
    "restart",
    "rm",
    "run",
    "start",
    "stop",
    "top",
    "unpause",
    "up",
    "wait",
}


def _compose_version() -> tuple[int, int, int]:
    result = subprocess.run(
        ["docker", "compose", "version", "--short"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ProdEnvError("Docker Compose is not available")
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", result.stdout)
    if match is None:
        raise ProdEnvError("Docker Compose version could not be determined")
    version = tuple(int(part) for part in match.groups())
    if version < MINIMUM_COMPOSE_VERSION:
        required = ".".join(str(part) for part in MINIMUM_COMPOSE_VERSION)
        raise ProdEnvError(f"Docker Compose {required} or later is required")
    return version


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=Path(".env.prod"))
    parser.add_argument(
        "--compose-file",
        type=Path,
        action="append",
        default=[],
        help="additional local override file applied after the prod overlay",
    )
    parser.add_argument("compose_args", nargs=argparse.REMAINDER)
    return parser


def _compose_command(args: argparse.Namespace) -> list[str]:
    command = [
        "docker",
        "compose",
        "-p",
        PROJECT_NAME,
        "--env-file",
        str(args.env_file.resolve()),
        "-f",
        str(ROOT / "docker-compose.yml"),
        "-f",
        str(ROOT / "docker-compose.prod.yml"),
    ]
    for compose_file in args.compose_file:
        command.extend(("-f", str(compose_file.resolve())))
    return command


def _validate_compose_args(compose_args: list[str]) -> None:
    if not compose_args:
        raise ProdEnvError("a Compose command is required")

    subcommand = compose_args[0]
    if subcommand == "config" or subcommand.startswith("-"):
        raise ProdEnvError(
            "raw config and Compose global options can expose secrets; use check"
        )
    if subcommand != "check" and subcommand not in ALLOWED_COMPOSE_COMMANDS:
        raise ProdEnvError(f"unsupported Compose command: {subcommand}")


def _render_compose(
    command: list[str],
    environment: dict[str, str],
) -> dict[str, object]:
    rendered = subprocess.run(
        [*command, "config", "--format", "json"],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    if rendered.returncode != 0:
        raise ProdEnvError("final Compose config could not be rendered")
    try:
        compose = json.loads(rendered.stdout)
    except json.JSONDecodeError as exc:
        raise ProdEnvError("final Compose config is not valid JSON") from exc
    if not isinstance(compose, dict):
        raise ProdEnvError("final Compose config has an invalid root")
    return compose


def _service_environment(
    services: dict[str, object],
    service_name: str,
) -> dict[str, object]:
    service = services.get(service_name)
    if not isinstance(service, dict):
        raise ProdEnvError(f"required service is missing: {service_name}")
    environment = service.get("environment")
    if not isinstance(environment, dict):
        raise ProdEnvError(f"service environment is missing: {service_name}")
    return environment


def _validate_rendered_compose(compose: dict[str, object]) -> dict[str, object]:
    if compose.get("name") != PROJECT_NAME:
        raise ProdEnvError("final Compose project is not elt-infra-prod")

    networks = compose.get("networks")
    if not isinstance(networks, dict):
        raise ProdEnvError("final Compose networks are missing")
    elt_network = networks.get("elt_net")
    if not isinstance(elt_network, dict) or elt_network.get("name") != EXPECTED_NETWORK_NAME:
        raise ProdEnvError("final Compose elt_net is not prod-isolated")

    volumes = compose.get("volumes")
    if not isinstance(volumes, dict):
        raise ProdEnvError("final Compose volumes are missing")
    for volume_key, expected_name in EXPECTED_VOLUME_NAMES.items():
        volume = volumes.get(volume_key)
        if not isinstance(volume, dict) or volume.get("name") != expected_name:
            raise ProdEnvError(f"final Compose volume is not prod-isolated: {volume_key}")

    services = compose.get("services")
    if not isinstance(services, dict):
        raise ProdEnvError("final Compose services are missing")
    for service_name in sorted(CORE_SERVICES):
        environment = _service_environment(services, service_name)
        forbidden = sorted(
            name
            for name in environment
            if name.startswith("R2_DEV_") or name in FORBIDDEN_ENV_NAMES
        )
        if forbidden:
            raise ProdEnvError(
                f"forbidden dev environment names in {service_name}: "
                + ", ".join(forbidden)
            )
        for name, expected_value in EXPECTED_PROD_ENVIRONMENT.items():
            if environment.get(name) != expected_value:
                raise ProdEnvError(f"{name} is not prod-safe in {service_name}")

        service = services[service_name]
        service_networks = service.get("networks")
        if not isinstance(service_networks, dict) or set(service_networks) != {"elt_net"}:
            raise ProdEnvError(f"service network is not prod-isolated: {service_name}")

    trino = services["trino"]
    trino_volumes = trino.get("volumes")
    if not isinstance(trino_volumes, list):
        raise ProdEnvError("Trino catalog mount is missing")
    catalog_mounts = [
        volume
        for volume in trino_volumes
        if isinstance(volume, dict) and volume.get("target") == TRINO_CATALOG_TARGET
    ]
    if len(catalog_mounts) != 1:
        raise ProdEnvError("Trino must have exactly one prod catalog mount")
    catalog_source = catalog_mounts[0].get("source")
    expected_catalog_source = str((ROOT / "trino" / "catalog-prod").resolve())
    if not isinstance(catalog_source, str) or str(Path(catalog_source).resolve()) != expected_catalog_source:
        raise ProdEnvError("Trino catalog source is not trino/catalog-prod")

    postgres = services["postgres"]
    postgres_volumes = postgres.get("volumes")
    if not isinstance(postgres_volumes, list) or not any(
        isinstance(volume, dict)
        and volume.get("target") == "/var/lib/postgresql/data"
        and volume.get("source") == "postgres_data"
        for volume in postgres_volumes
    ):
        raise ProdEnvError("Postgres metadata volume is not prod-isolated")

    for service_name in sorted(name for name in CORE_SERVICES if name.startswith("airflow-")):
        service = services[service_name]
        service_volumes = service.get("volumes")
        if not isinstance(service_volumes, list) or not any(
            isinstance(volume, dict)
            and volume.get("target") == "/opt/airflow/logs"
            and volume.get("source") == "airflow_logs"
            for volume in service_volumes
        ):
            raise ProdEnvError(f"Airflow logs volume is not prod-isolated: {service_name}")

    return {
        "project": PROJECT_NAME,
        "network": EXPECTED_NETWORK_NAME,
        "volumes": EXPECTED_VOLUME_NAMES,
        "trino_catalog_source": expected_catalog_source,
        "validated_services": sorted(CORE_SERVICES),
    }


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)

    try:
        _validate_compose_args(args.compose_args)
        validate_prod_env(args.env_file)
        _compose_version()
    except ProdEnvError as exc:
        print(f"prod compose error: {exc}", file=sys.stderr)
        return 2

    environment = os.environ.copy()
    environment["ASK_SEOUL_PROD_ENV_FILE"] = str(args.env_file.resolve())
    command = _compose_command(args)

    try:
        summary = _validate_rendered_compose(_render_compose(command, environment))
    except ProdEnvError as exc:
        print(f"prod compose error: {exc}", file=sys.stderr)
        return 2

    if args.compose_args == ["check"]:
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0

    return subprocess.run(
        [*command, *args.compose_args],
        env=environment,
        check=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
