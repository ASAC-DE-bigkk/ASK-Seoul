# ---------------------------------------------------------------------------
# 보안그룹 2개로 나눈다.
#   internal : 스택 구성원끼리 무제한 (Trino <-> Airflow, Postgres)
#   admin    : 관리자 IP 에서만 Airflow UI / (선택)SSH
# 인스턴스는 두 그룹을 모두 붙인다.
# ---------------------------------------------------------------------------

resource "aws_security_group" "internal" {
  name        = "${var.project}-${var.env}-internal"
  description = "Stack members talk to each other freely; egress to internet for R2/D1/APIs"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-${var.env}-internal" }
}

# 자기 참조 — 같은 SG 를 단 인스턴스끼리만 전 포트 허용.
# Trino(8080) <- Airflow, Postgres(5432) <- Airflow 를 개별 규칙 없이 덮는다.
resource "aws_vpc_security_group_ingress_rule" "internal_self" {
  security_group_id            = aws_security_group.internal.id
  referenced_security_group_id = aws_security_group.internal.id
  ip_protocol                  = "-1"
  description                  = "All traffic between stack members (same AZ, private IP = free)"
}

# R2(Cloudflare) · D1 · 서울시 열린데이터 · 기상청 · 패키지 저장소 · SSM
resource "aws_vpc_security_group_egress_rule" "internal_all" {
  security_group_id = aws_security_group.internal.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound to R2 / D1 / public APIs / SSM"
}

resource "aws_security_group" "admin" {
  name        = "${var.project}-${var.env}-admin"
  description = "Operator access from a fixed IP"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-${var.env}-admin" }
}

# Airflow UI 만 연다. **Trino 는 이 SG 를 달지 않는다**(compute.tf 참조).
#
# Trino 는 인증이 없으므로 관리자 IP 에도 열지 않는다. UI 가 필요하면 SSM 포트 포워딩:
#   aws ssm start-session --target <trino-instance-id> \
#     --document-name AWS-StartPortForwardingSession \
#     --parameters '{"portNumber":["8080"],"localPortNumber":["30586"]}'
# 이렇게 하면 포트를 열지 않고도 로컬 30586 으로 붙는다 — 원래의 "LAN 미노출" 의도에 가장 가깝다.
resource "aws_vpc_security_group_ingress_rule" "admin_airflow_ui" {
  security_group_id = aws_security_group.admin.id
  cidr_ipv4         = var.admin_cidr
  from_port         = var.airflow_ui_port
  to_port           = var.airflow_ui_port
  ip_protocol       = "tcp"
  description       = "Airflow UI only (Trino does not carry this SG)"
}

# 기본은 닫아둔다. SSM Session Manager 로 접속하면 22 번이 필요 없다.
resource "aws_vpc_security_group_ingress_rule" "admin_ssh" {
  count = var.enable_ssh ? 1 : 0

  security_group_id = aws_security_group.admin.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH (disabled by default; prefer SSM Session Manager)"
}
