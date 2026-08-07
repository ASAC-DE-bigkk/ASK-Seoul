#!/bin/bash
set -euo pipefail

BUCKET=ask-seoul-test-staging-068381293928
REGION=ap-northeast-2
TRINO_IP=10.20.1.12
APP=/opt/ask-seoul

aws s3 cp "s3://$BUCKET/deploy.tar.gz" /tmp/deploy.tar.gz --region "$REGION" --quiet
tar -xzf /tmp/deploy.tar.gz -C "$APP"

aws ssm get-parameter --name /ask-seoul/test/env --with-decryption \
  --region "$REGION" --query Parameter.Value --output text > "$APP/.env"

# 노드별 오버라이드 — 이 노드는 Trino 를 사설 IP 에 발행한다(MIGRATION.md 8, B안).
{
  echo "TRINO_BIND_IP=$TRINO_IP"
  echo "TRINO_PUBLISH_PORT=8080"
} >> "$APP/.env"

chown -R ec2-user:ec2-user "$APP"
chmod 600 "$APP/.env"

cd "$APP"
docker compose -f docker-compose.yml -f docker-compose.cloud-trino.yml up -d trino

sleep 5
docker compose ps --format '{{.Name}}\t{{.State}}\t{{.Ports}}'
echo "--- spill 마운트 ---"
docker compose exec -T trino sh -c 'df -h /tmp/trino-spill | tail -1' 2>&1 || echo "(아직 기동 중)"
