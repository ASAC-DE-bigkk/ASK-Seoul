#!/bin/bash
set -uo pipefail
CF="-f docker-compose.yml -f docker-compose.cloud-airflow.yml"
cd /opt/ask-seoul

PSQL() { docker compose $CF exec -T postgres psql -U airflow -d airflow -t -A -F'|' -c "$1" </dev/null 2>/dev/null; }

echo "=========== 1. 컨테이너 ==========="
docker compose $CF ps --format '{{.Name}}\t{{.State}}\t{{.Status}}' </dev/null

echo ""
echo "=========== 2. 태스크 상태 (전체) ==========="
PSQL "SELECT state, count(*) FROM task_instance GROUP BY state ORDER BY 2 DESC;"

echo ""
echo "=========== 3. 최근 30분 DAG run ==========="
PSQL "SELECT state, count(*) FROM dag_run WHERE start_date > now()-interval '30 minutes' GROUP BY state;"

echo ""
echo "=========== 4. 실패 태스크 상위 15 ==========="
PSQL "SELECT dag_id||' | '||task_id||' | try='||try_number
     FROM task_instance WHERE state='failed'
     ORDER BY end_date DESC NULLS LAST LIMIT 15;"

echo ""
echo "=========== 5. 지금 실행 중 ==========="
PSQL "SELECT dag_id||' | '||task_id||' | '||to_char(start_date,'HH24:MI:SS')
     FROM task_instance WHERE state IN ('running','queued') ORDER BY start_date LIMIT 15;"

echo ""
echo "=========== 6. 동시 실행 수 ==========="
PSQL "SELECT 'running='||count(*) FILTER (WHERE state='running')||' queued='||count(*) FILTER (WHERE state='queued') FROM task_instance;"

echo ""
echo "=========== 7. 리소스 ==========="
docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' </dev/null

echo ""
echo "=========== 8. 스케줄러 로그 에러 (최근 20줄) ==========="
docker compose $CF logs --tail=200 airflow-scheduler </dev/null 2>&1 \
  | grep -iE "error|exception|traceback|failed" | tail -20 || echo "(에러 없음)"
