#!/bin/bash
set -uo pipefail
CF="-f docker-compose.yml -f docker-compose.cloud-airflow.yml"
cd /opt/ask-seoul
PSQL() { docker compose $CF exec -T postgres psql -U airflow -d airflow -t -A -F'|' -c "$1" </dev/null 2>/dev/null; }

echo "########## 1. DAG import 에러 ##########"
docker compose $CF exec -T airflow-dag-processor airflow dags list-import-errors </dev/null 2>/dev/null | head -30
echo "(위 비었으면 import 에러 없음)"

echo ""
echo "########## 2. DAG별 성패 (활성 45개) ##########"
PSQL "SELECT rpad(dag_id,34)||' ok='||lpad(count(*) FILTER (WHERE state='success')::text,4)
      ||' fail='||lpad(count(*) FILTER (WHERE state='failed')::text,3)
      ||' retry='||lpad(count(*) FILTER (WHERE state='up_for_retry')::text,3)
      ||' upfail='||lpad(count(*) FILTER (WHERE state='upstream_failed')::text,3)
      ||' run='||lpad(count(*) FILTER (WHERE state='running')::text,2)
 FROM task_instance GROUP BY dag_id
 HAVING count(*) FILTER (WHERE state IN ('failed','up_for_retry','upstream_failed')) > 0
 ORDER BY count(*) FILTER (WHERE state='failed') DESC, dag_id;"

echo ""
echo "########## 3. 실패 태스크와 실제 에러 메시지 ##########"
PSQL "SELECT DISTINCT dag_id||' :: '||task_id FROM task_instance WHERE state='failed' ORDER BY 1;"

echo ""
echo "########## 4. 한 번도 실행 안 된 활성 DAG ##########"
PSQL "SELECT d.dag_id FROM dag d
 WHERE d.is_paused = false
   AND NOT EXISTS (SELECT 1 FROM dag_run r WHERE r.dag_id = d.dag_id)
 ORDER BY 1;"

echo ""
echo "########## 5. DAG run 상태 요약 ##########"
PSQL "SELECT state||' = '||count(*) FROM dag_run GROUP BY state ORDER BY 2 DESC;"

echo ""
echo "########## 6. 최근 실패 로그 (에러 원인별 집계) ##########"
docker compose $CF logs --tail=1500 airflow-scheduler </dev/null 2>&1 \
  | grep -oE "(TABLE_NOT_FOUND|SCHEMA_NOT_FOUND|NoSuchKey|AccessDenied|NoSuchBucket|Connection refused|Timeout|TrinoUserError\([^)]*\)|D1_ERROR|401|403|404)" \
  | sort | uniq -c | sort -rn | head -15
echo "(위가 비었으면 알려진 에러 패턴 없음)"

echo ""
echo "########## 7. 최근 실패 원문 3건 ##########"
docker compose $CF logs --tail=1500 airflow-scheduler </dev/null 2>&1 \
  | grep -iE "error|exception" | grep -ivE "ERROR in [0-9]|ERROR creating|Completed with" | tail -6
