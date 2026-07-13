# Airflow task log 외부 URL 설계

## 목표

Docker host에서 열리는 Airflow task log 링크가 `localhost:30585`를 사용하게 한다.

## 결정

- `docker-compose.yml`의 공통 Airflow environment anchor에 `AIRFLOW__API__BASE_URL: http://localhost:30585`만 추가한다.
- 내부 service 통신용 `AIRFLOW__CORE__EXECUTION_API_SERVER_URL`, apiserver healthcheck, container port 8080은 변경하지 않는다.
- DAG 콜백의 `ti.log_url` 소비 방식은 변경하지 않는다.

## 검증

- `docker compose config -q`가 통과한다.
- 재생성된 scheduler/apiserver가 `[api] base_url`을 `http://localhost:30585`로 읽는다.
- task instance `log_url`이 해당 host port와 DAG/run/task path를 생성한다.
