# ASAC-ASK-Seoul #17 작업 보고서

## 변경 범위

- `docker-compose.yml`의 `x-airflow-common` 환경 anchor에만 `AIRFLOW__API__BASE_URL: http://localhost:30585`를 추가했습니다.
- `AIRFLOW__CORE__EXECUTION_API_SERVER_URL`의 내부 주소(`http://airflow-apiserver:8080/execution/`)는 변경하지 않았습니다.
- apiserver healthcheck의 컨테이너 내부 주소(`http://localhost:8080/...`)와 포트 매핑(`30585:8080`)도 변경하지 않았습니다.
- DAG 콜백, secret, 서비스별 환경 설정은 수정하지 않았습니다.

## 검증

검증에는 저장소 루트의 `.env`를 작업 worktree에 임시 복사해 Compose interpolation에만 사용했습니다. 검증 직후 임시 파일을 삭제했으며, 원본 `.env`는 수정하지 않았습니다.

- 변경 전 이력 확인: `HEAD:docker-compose.yml`에는 `AIRFLOW__API__BASE_URL`이 없습니다. 작업 worktree에는 `.env`가 없으므로 변경 전 `docker compose config`는 env file 부재로 실행되지 않았습니다.
- 변경 후 `docker compose config -q`: exit `0`
- 변경 후 `docker compose config --format json` 확인: `airflow-apiserver`, `airflow-scheduler`, `airflow-dag-processor`, `airflow-triggerer` 모두 `AIRFLOW__API__BASE_URL=http://localhost:30585`를 상속했습니다.
- 내부 execution URL은 네 서비스 모두 `http://airflow-apiserver:8080/execution/`로 유지되었습니다.
- apiserver healthcheck는 `http://localhost:8080/api/v2/monitor/health`, 포트 매핑은 published `30585` → target `8080`으로 유지되었습니다.
- `git diff --check`: exit `0`
- 임시 `.env` 삭제 후 `git status`에서 `.env` 미추적 파일 없음 확인
- 운영 스택 재생성/재라우팅은 task brief 지시에 따라 수행하지 않았습니다.

## 커밋

- 구현 커밋: `80b8381`
- 메시지: `fix(airflow): configure external task log URL`

## 상태

`DONE_WITH_CONCERNS` — Compose 정적 검증은 통과했지만, 운영 컨테이너를 재생성하지 않았으므로 실제 Airflow `TaskInstance.log_url` 런타임 값은 별도 배포 후 확인해야 합니다.

## 커밋 후 재검증 출력

- `docker compose config -q`: exit `0`
- `docker compose config --format json`: exit `0`
- 네 Airflow 서비스의 base URL 상속: `True`
- 내부 execution URL 8080 보존: `True`
- apiserver healthcheck 8080 보존: `True`
- published port 30585 보존: `True`
- `git diff --check HEAD^`: exit `0`
- 임시 `.env` 존재 여부: `false`
