#!/bin/bash
set -euo pipefail

BUCKET=ask-seoul-test-staging-068381293928
REGION=ap-northeast-2
TRINO_IP=10.20.1.12
UI_PORT=30585
APP=/opt/ask-seoul
CF="-f docker-compose.yml -f docker-compose.cloud-airflow.yml"

aws s3 cp "s3://$BUCKET/deploy.tar.gz" /tmp/deploy.tar.gz --region "$REGION" --quiet
tar -xzf /tmp/deploy.tar.gz -C "$APP"

aws ssm get-parameter --name /ask-seoul/test/env --with-decryption \
  --region "$REGION" --query Parameter.Value --output text > "$APP/.env"

# 공인 IP 는 IMDSv2 로 읽는다(하드코딩하면 IP 재할당 때 UI 가 다시 깨진다).
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PUBIP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

{
  echo "TRINO_HOST=$TRINO_IP"
  echo "TRINO_PORT=8080"
  # 이게 없으면 UI 접속 시 localhost 로 리다이렉트된다(실측).
  echo "AIRFLOW_API_BASE_URL=http://${PUBIP}:${UI_PORT}"
} >> "$APP/.env"

install -d -o 1000 -g 0 "$APP/logs" "$APP/plugins" "$APP/config"
chown -R ec2-user:ec2-user "$APP"
chmod 600 "$APP/.env"

cd "$APP"
docker compose $CF up -d --force-recreate \
  airflow-apiserver airflow-scheduler airflow-dag-processor airflow-triggerer

sleep 15
echo "=== BASE_URL 적용 확인 ==="
docker compose $CF exec -T airflow-apiserver \
  printenv AIRFLOW__API__BASE_URL </dev/null
echo "=== 상태 ==="
docker compose $CF ps --format '{{.Name}}\t{{.State}}' </dev/null
echo "=== UI 응답 ==="
curl -s -o /dev/null -w "local curl HTTP %{http_code}\n" "http://127.0.0.1:${UI_PORT}/" --max-time 10
