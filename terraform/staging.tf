# ---------------------------------------------------------------------------
# 배포 스테이징 버킷.
#
# 저장소 3개(ASK-Seoul / ASAC-DAG / ASAC-DBT)가 전부 private 이라 EC2 에서 git clone 하려면
# PAT 나 deploy key 를 심어야 한다. 게다가 지금 배포할 코드는 커밋되지 않은 작업트리이고
# (.env.test 는 gitignore 라 애초에 git 에 없다), 테스트 레인이라 커밋할 계획도 없다.
#
# 그래서 로컬 작업트리를 tar 로 묶어 이 버킷에 올리고 인스턴스가 IAM 역할로 내려받는다.
# git 자격증명을 노드에 심지 않아도 되고, 미커밋 변경이 그대로 반영된다.
#
# 시크릿은 여기 넣지 않는다 — .env 는 SSM SecureString 으로 따로 간다(iam.tf 참조).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "staging" {
  bucket        = "${var.project}-${var.env}-staging-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # 테스트 레인 — destroy 시 객체가 남아 삭제가 막히지 않게

  tags = { Name = "${var.project}-${var.env}-staging" }
}

# 퍼블릭 접근 전면 차단
resource "aws_s3_bucket_public_access_block" "staging" {
  bucket = aws_s3_bucket.staging.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 배포 아티팩트는 오래 둘 이유가 없다 — 7일 뒤 자동 삭제
resource "aws_s3_bucket_lifecycle_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }
  }
}

# 인스턴스가 아티팩트를 내려받을 수 있게
data "aws_iam_policy_document" "staging_read" {
  statement {
    sid       = "ReadStagingArtifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.staging.arn}/*"]
  }

  statement {
    sid       = "ListStagingBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.staging.arn]
  }
}

resource "aws_iam_role_policy" "staging_read" {
  name   = "${var.project}-${var.env}-staging-read"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.staging_read.json
}

output "staging_bucket" {
  description = "배포 아티팩트를 올릴 버킷"
  value       = aws_s3_bucket.staging.bucket
}
