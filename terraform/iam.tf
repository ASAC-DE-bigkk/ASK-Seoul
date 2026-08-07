# ---------------------------------------------------------------------------
# EC2 인스턴스 역할.
#   - SSM Session Manager 접속 (포트 22 미개방)
#   - SSM Parameter Store 에서 시크릿 읽기
#
# .env 를 인스턴스에 평문으로 복사하지 않는다. R2 토큰·Cloudflare API 토큰이
# EBS 와 스냅샷에 그대로 남기 때문이다. Parameter Store SecureString 은 무료이고
# IAM 으로 통제되며 접근이 CloudTrail 에 남는다.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.project}-${var.env}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "secrets_read" {
  statement {
    sid    = "ReadStackSecrets"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_secret_prefix}/*",
    ]
  }

  # SecureString 복호화 — AWS 관리 키(alias/aws/ssm) 사용
  statement {
    sid       = "DecryptSecureString"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "secrets_read" {
  name   = "${var.project}-${var.env}-secrets-read"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.secrets_read.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project}-${var.env}-node"
  role = aws_iam_role.node.name
}
