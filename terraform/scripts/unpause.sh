#!/bin/bash
set -uo pipefail

APP=/opt/ask-seoul
CF="-f docker-compose.yml -f docker-compose.cloud-airflow.yml"
REGION=ap-northeast-2
BUCKET=ask-seoul-test-staging-068381293928

aws s3 cp "s3://$BUCKET/dags-to-enable.txt" /tmp/dags.txt --region "$REGION" --quiet
cd "$APP"

# 주의: `while read < file` 안에서 `docker compose exec -T` 를 쓰면 stdin 을 먹어
# 첫 줄만 처리된다(실측). 파일을 컨테이너 stdin 으로 한 번에 넘기고 안에서 루프를 돈다.
docker compose $CF exec -T airflow-scheduler bash -s <<'INNER' < /dev/null
INNER

docker compose $CF exec -T airflow-scheduler bash -c '
ok=0; fail=0
while IFS= read -r d; do
  [ -z "$d" ] && continue
  if airflow dags unpause "$d" >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    fail=$((fail+1)); echo "FAILED: $d"
  fi
done
echo "unpaused=$ok failed=$fail"
' < /tmp/dags.txt

echo "=== paused 상태 집계 ==="
docker compose $CF exec -T airflow-scheduler airflow dags list --output json </dev/null 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
act = [x['dag_id'] for x in d if str(x.get('is_paused')).lower() in ('false','0')]
pau = [x['dag_id'] for x in d if str(x.get('is_paused')).lower() in ('true','1')]
print('활성:', len(act), '/ 일시정지:', len(pau))
print('활성 목록:')
for i in sorted(act): print(' ', i)
"
