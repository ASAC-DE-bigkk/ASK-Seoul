# Airflow task log 외부 URL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 모든 Airflow task log URL이 Docker host port 30585를 사용하게 한다.

**Architecture:** Compose 공통 Airflow environment anchor에 Airflow 3 `[api] base_url` 환경 변수를 설정한다. DAG callback, 내부 API URL, container healthcheck는 변경하지 않는다.

**Tech Stack:** Docker Compose, Airflow 3 configuration.

## Global Constraints

- 외부 URL만 `localhost:30585`로 설정한다.
- container 내부 8080 service communication을 변경하지 않는다.
- `.env`와 secret을 변경·출력하지 않는다.

---

### Task 1: 공통 base URL 설정·runtime 검증

**Files:**

- Modify: `docker-compose.yml:10-26`

**Interfaces:**

- Produces: 모든 Airflow service에 `AIRFLOW__API__BASE_URL=http://localhost:30585`.

- [ ] **Step 1: Confirm the pre-change configuration**

Run: `docker compose config`

Expected: `AIRFLOW__API__BASE_URL` is absent.

- [ ] **Step 2: Write the minimal configuration**

```yaml
AIRFLOW__API__BASE_URL: http://localhost:30585
```

Add the line to the common Airflow environment anchor only.

- [ ] **Step 3: Verify effective Compose configuration**

Run: `docker compose config -q; docker compose config`

Expected: syntax succeeds and scheduler/apiserver inherit the value.

- [ ] **Step 4: Recreate and verify the runtime**

Run: `docker compose up -d --force-recreate airflow-apiserver airflow-scheduler airflow-dag-processor airflow-triggerer`

Expected: `conf.get('api', 'base_url')` and a sample `TaskInstance.log_url` start with `http://localhost:30585/`.

- [ ] **Step 5: Commit**

Commit: `git commit -m "fix(airflow): configure external task log URL"`
