output "airflow_public_ip" {
  description = "Airflow 노드 공인 IP"
  value       = aws_instance.airflow.public_ip
}

output "airflow_private_ip" {
  description = "Airflow 노드 사설 IP — Trino 가 이 주소로 붙는다(같은 AZ, 전송비 무료)"
  value       = aws_instance.airflow.private_ip
}

output "trino_public_ip" {
  value = aws_instance.trino.public_ip
}

output "trino_private_ip" {
  description = "compose 의 TRINO_HOST 에 넣을 주소"
  value       = aws_instance.trino.private_ip
}

output "airflow_ui" {
  description = "admin_cidr 에서만 열린다"
  value       = "http://${aws_instance.airflow.public_ip}:${var.airflow_ui_port}"
}

output "connect_airflow" {
  description = "SSM Session Manager 접속 (포트 22 불필요)"
  value       = "aws ssm start-session --target ${aws_instance.airflow.id} --region ${var.region}"
}

output "connect_trino" {
  value = "aws ssm start-session --target ${aws_instance.trino.id} --region ${var.region}"
}

output "monthly_cost_estimate" {
  description = "ap-northeast-2 온디맨드 기준 추정. R2 아웃바운드 전송비는 포함되지 않음."
  value = {
    airflow_instance = "${var.airflow_instance_type} : 실조회 단가 x 730h"
    trino_instance   = "${var.trino_instance_type} : 실조회 단가 x 730h"
    ebs_gp3          = "${var.airflow_root_gb + var.trino_root_gb} GB x 약 $0.09"
    public_ipv4      = "2 x $0.005/h = 약 $7.3"
    note             = "온디맨드 약 $286/월. Savings Plan 1년(선납없음) 적용 시 약 $206/월. 전송비 별도 — R2 대시보드 Class A 확인 필요."
  }
}
