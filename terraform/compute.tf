# ---------------------------------------------------------------------------
# EC2 2대.
#
# 3대(Trino 워커 추가)로 가지 않은 이유: 큐 대기가 전 호스트 0건이고
# 전 도메인 서버도 최대 12.5초(1건)였다. Trino 가 겪은 문제는 경합이 아니라
# 메모리(커널 OOM kill 4건)이고, 그건 노드 수가 아니라 노드 크기로 푸는 문제다.
# 근거 데이터는 resource-reports/ 참조.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  airflow_user_data = templatefile("${path.module}/user_data/common.sh.tftpl", {
    project    = var.project
    ssm_prefix = var.ssm_secret_prefix
    region     = var.region
    role       = "airflow"
  })

  trino_user_data = join("\n", [
    templatefile("${path.module}/user_data/common.sh.tftpl", {
      project    = var.project
      ssm_prefix = var.ssm_secret_prefix
      region     = var.region
      role       = "trino"
    }),
    file("${path.module}/user_data/trino_extra.sh.tftpl"),
  ])

  # Airflow 만 admin SG 를 단다 — UI 접근이 필요하기 때문.
  airflow_security_group_ids = [
    aws_security_group.internal.id,
    aws_security_group.admin.id,
  ]

  # Trino 는 internal 만. 인증이 없으므로 관리자 IP 에도 8080 을 열지 않는다.
  # UI 가 필요하면 SSM 포트 포워딩(security.tf 주석 참조).
  trino_security_group_ids = [
    aws_security_group.internal.id,
  ]
}

# ---------------------------------------------------------------------------
# 노드 1 — Airflow + Postgres
# ---------------------------------------------------------------------------
resource "aws_instance" "airflow" {
  ami           = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.airflow_instance_type
  subnet_id     = aws_subnet.public.id
  key_name      = var.enable_ssh ? var.key_name : null

  vpc_security_group_ids = local.airflow_security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.node.name

  user_data                   = local.airflow_user_data
  user_data_replace_on_change = false

  root_block_device {
    volume_type           = "gp3" # gp2 대비 20% 저렴, 3000 IOPS / 125 MB/s 기본 포함
    volume_size           = var.airflow_root_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${var.project}-${var.env}-airflow-root" }
  }

  # IMDSv2 강제 — SSRF 로 인스턴스 자격증명이 새는 경로를 막는다.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 컨테이너에서 메타데이터 접근 시 필요
  }

  tags = {
    Name = "${var.project}-${var.env}-airflow"
    Role = "airflow"
  }
}

# ---------------------------------------------------------------------------
# 노드 2 — Trino
# ---------------------------------------------------------------------------
resource "aws_instance" "trino" {
  ami           = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.trino_instance_type
  subnet_id     = aws_subnet.public.id
  key_name      = var.enable_ssh ? var.key_name : null

  vpc_security_group_ids = local.trino_security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.node.name

  user_data                   = local.trino_user_data
  user_data_replace_on_change = false

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.trino_root_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${var.project}-${var.env}-trino-root" }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project}-${var.env}-trino"
    Role = "trino"
  }
}
