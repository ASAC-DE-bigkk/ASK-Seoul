# Traffic/Weather Lineage Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Traffic/Weather lineage overlay의 dependency 재현성, Trino global listener 부재, Marquez 장애 fail-open을 자동 검증한다.

**Architecture:** 기존 overlay unittest가 Dockerfile과 렌더된 Compose mount source를 검사한다. 별도 Python probe는 custom Airflow image의 실제 package version을 먼저 gate한 뒤 최소 dbt fixture를 raw/wrapped compile하고, 한 bounded log block에 상관된 secret-safe 판정 결과만 반환한다.

**Tech Stack:** Python `unittest`, Docker CLI, Docker Compose, dbt 1.10, openlineage-dbt 1.51.0.

## Global Constraints

- `apache-airflow-providers-openlineage==2.19.0`과 `openlineage-dbt==1.51.0`을 사용한다.
- live Compose service, Trino query, data write를 사용하지 않는다.
- probe는 `--network none`과 닫힌 loopback endpoint만 사용한다.
- secret이나 원문 subprocess output을 출력하지 않는다.
- commit, push, PR 생성은 수행하지 않는다.

---

### Task 1: Dependency pin과 Trino mount 계약

**Files:**

- Modify: `Dockerfile.airflow:27,34`
- Modify: `scripts/tests/test_traffic_weather_lineage_overlay.py`

**Interfaces:**

- Produces: exact dependency pin test와 `/etc/trino` bind mount file scan.

- [ ] **Step 1: exact pin과 mounted config scan regression test를 추가한다.**
- [ ] **Step 2: 해당 test를 실행해 range pin 때문에 실패하는지 확인한다.**
- [ ] **Step 3: Dockerfile 두 dependency만 exact pin으로 변경한다.**
- [ ] **Step 4: malicious temporary Trino config가 탐지되고 실제 config가 통과하는지 확인한다.**

### Task 2: Marquez unavailable 실제 probe

**Files:**

- Create: `scripts/lineage/probe_dbt_openlineage_fail_open.py`
- Create: `scripts/tests/test_dbt_openlineage_fail_open_probe.py`
- Create: `scripts/tests/fixtures/lineage_fail_open/dbt_project.yml`
- Create: `scripts/tests/fixtures/lineage_fail_open/profiles.yml`
- Create: `scripts/tests/fixtures/lineage_fail_open/models/probe.sql`

**Interfaces:**

- Produces: image exact-version gate와 raw/wrapped exit code, 동일 log block의 warning/contact/failure evidence를 검증하는 secret-safe CLI.

- [ ] **Step 1: command isolation과 판정 실패 조건 unit test를 추가한다.**
- [ ] **Step 2: test가 probe 부재 또는 미구현으로 실패하는지 확인한다.**
- [ ] **Step 3: deterministic version command, bounded log parser, Docker command builder와 판정 로직을 최소 구현한다.**
- [ ] **Step 4: unit test를 통과시킨다.**
- [ ] **Step 5: stale image가 dbt 실행 전에 version gate에서 실패하는지 확인한다.**
- [ ] **Step 6: 현재 Dockerfile로 재빌드한 custom image에서 probe를 실행해 exit status 보존과 상관된 endpoint failure warning을 확인한다.**

### Task 3: 운영 문서와 전체 검증

**Files:**

- Modify: `docs/traffic-weather-lineage.md`

**Interfaces:**

- Produces: 안전한 probe 실행법, 성공 조건, 실패 해석.

- [ ] **Step 1: 한국어 문서에 exact version과 probe 안전 경계를 기록한다.**
- [ ] **Step 2: root unittest 전체를 실행한다.**
- [ ] **Step 3: base+overlay Compose config를 `--no-env-resolution`로 검증한다.**
- [ ] **Step 4: DAG/DBT commit 뒤 root submodule gitlink가 검증 대상 commit을 가리키는지 확인한다.**
- [ ] **Step 5: image를 rebuild하고 version gate가 포함된 probe를 fresh 실행해 secret-safe summary를 확인한다.**
- [ ] **Step 6: `git diff --check`, `git status`, 변경 범위를 확인한다.**
