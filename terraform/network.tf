# ---------------------------------------------------------------------------
# 전용 VPC. 기본 VPC(172.31.0.0/16)를 쓰지 않는다 — 태그·보안그룹·라우팅을
# 이 스택 전용으로 격리해야 비용 추적과 회수가 깨끗하다.
#
# NAT 게이트웨이를 두지 않는다. 시간당 $0.059 = 월 약 $43 로 Trino 노드값의 36%인데,
# 인스턴스 2대에 퍼블릭 IPv4 를 직접 붙이면 월 $7.3 이다. 인바운드는 보안그룹으로 막는다.
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-${var.env}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-${var.env}-igw" }
}

# 단일 퍼블릭 서브넷 — 단일 AZ 고정
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-${var.env}-public-${var.az}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-${var.env}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
