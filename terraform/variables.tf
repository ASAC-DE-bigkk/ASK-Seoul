variable "region" {
  description = "배포 리전. 서울 고정 — R2/서울시 API 지연과 요금 산정 근거가 전부 ap-northeast-2 기준이다."
  type        = string
  default     = "ap-northeast-2"
}

variable "az" {
  description = <<-EOT
    단일 AZ. Trino↔Airflow 트래픽이 크므로(transit 실측 Trino OUT 16GB/21h) 반드시 같은 AZ에 둔다.
    AZ 간 전송은 양방향 GB당 과금되지만 같은 AZ 프라이빗 IP 통신은 무료다.
  EOT
  type        = string
  default     = "ap-northeast-2a"
}

variable "project" {
  type    = string
  default = "ask-seoul"
}

variable "env" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "admin_cidr" {
  description = "Airflow UI·SSH 접근을 허용할 CIDR. 반드시 /32 단위 고정 IP로 좁힌다."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "유효한 CIDR이어야 한다. 예: 222.108.125.33/32"
  }
}

# ---------------------------------------------------------------------------
# 인스턴스 사양 — 전부 실측 기반. 근거는 resource-reports/ 참조.
# ---------------------------------------------------------------------------

variable "airflow_instance_type" {
  description = <<-EOT
    Airflow + Postgres.
    근거: 전 도메인 서버 08-01 피크 동시 28 태스크 x ~200MB(LocalExecutor 프로세스)
          + Airflow 코어 2.5GiB = 약 8.1GiB -> 16GiB.
          dag-processor 가 세 호스트 모두 상시 1코어를 점유하므로 2 vCPU 는 불가.
  EOT
  type        = string
  default     = "m7g.xlarge" # 4 vCPU / 16 GiB
}

variable "trino_instance_type" {
  description = <<-EOT
    Trino 단일 노드.
    근거: 현장 최대 mem_limit 이 12GiB(traffic/weather 호스트)이고 cgroup peak 가 한도의 97%까지 찬다.
          16GiB 노드가 이를 수용한다. task.concurrency=2 라 2 vCPU 로 충분.
          r7gd 를 고른 이유는 NVMe 인스턴스 스토어 — spill-enabled=true 인데
          EBS 는 네트워크 스토리지라 spill 이 느리다.
    commerce 수령 후 쿼리 peak 가 1.32GiB(현재 최대 관측치)를 크게 넘으면
    r7g.xlarge(4 vCPU / 32 GiB)로 상향한다. 정지->타입변경->시작 5분.
  EOT
  type        = string
  default     = "r7gd.large" # 2 vCPU / 16 GiB / NVMe 118 GB
}

variable "airflow_root_gb" {
  description = "Airflow 루트 볼륨. 이미지 3.44GB + dbt target + 로그(관측 980MB, 증가 중)"
  type        = number
  default     = 100
}

variable "trino_root_gb" {
  description = "Trino 루트 볼륨. 이미지 2.39GB. spill 은 NVMe 로 분리하므로 작아도 된다."
  type        = number
  default     = 40
}

# ---------------------------------------------------------------------------
# 접근 방식
# ---------------------------------------------------------------------------

variable "airflow_ui_port" {
  description = <<-EOT
    Airflow UI 가 호스트에 발행되는 포트.
    docker-compose.yml 의 airflow-apiserver 가 "30585:8080" 으로 발행하므로 30585 다.
    컨테이너 내부 포트(8080)와 혼동하지 말 것 — 8080 을 열면 UI 에 닿지 않는다.
  EOT
  type        = number
  default     = 30585
}

variable "enable_ssh" {
  description = <<-EOT
    기본은 false — SSM Session Manager 로 접속한다(포트 22 미개방, 키 관리 불필요).
    true 로 두면 admin_cidr 에서 22번을 열고 key_name 이 필요하다.
  EOT
  type        = bool
  default     = false
}

variable "key_name" {
  description = "enable_ssh = true 일 때만 사용할 EC2 키페어 이름"
  type        = string
  default     = null
}

variable "ssm_secret_prefix" {
  description = "시크릿을 둘 SSM Parameter Store 경로 접두사"
  type        = string
  default     = "/ask-seoul"
}
