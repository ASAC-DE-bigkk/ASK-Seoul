# terraform/ — ASK-Seoul ELT 스택 AWS 인프라

로컬 도커 스택을 EC2로 옮기기 위한 최소 인프라. **호스트 준비까지가 범위**이고
앱 배포(compose·`.env`·DAG)는 포함하지 않는다.

## 만들어지는 것 (16개)

```
VPC 10.20.0.0/16
└── 퍼블릭 서브넷 10.20.1.0/24  (ap-northeast-2a 단일 AZ)
    ├── IGW + 라우트 테이블
    ├── EC2 airflow   m7g.xlarge   4 vCPU / 16 GiB   gp3 100 GB
    └── EC2 trino     r7gd.large   2 vCPU / 16 GiB   gp3 40 GB + NVMe 118 GB
보안그룹 internal (자기참조 전포트)  ·  admin (8080 from admin_cidr)
IAM 역할 + 인스턴스 프로파일 (SSM Session Manager + Parameter Store 읽기)
```

## 설계 근거

전부 `resource-reports/` 실측에서 나왔다.

| 결정 | 근거 |
|---|---|
| **EC2 2대** (워커 없음) | 큐 대기가 전 호스트 0건, 서버도 최대 12.5초 1건. Trino 문제는 경합이 아니라 메모리(커널 OOM kill 4건) |
| **Airflow m7g.xlarge** | 서버 08-01 피크 동시 28 태스크 × ~200MB + 코어 2.5GiB ≈ 8.1GiB → 16GiB. `dag-processor`가 세 호스트 모두 상시 1코어 점유 → 2 vCPU 불가 |
| **Trino r7gd.large** | 현장 최대 `mem_limit` 12GiB(traffic/weather)이고 cgroup peak가 한도의 97%까지 참. NVMe는 `spill-enabled=true` 때문 — EBS는 네트워크 스토리지라 spill이 느림 |
| **단일 AZ** | Trino↔Airflow 트래픽이 큼(transit 실측 Trino OUT 16GB/21h). AZ 간은 양방향 과금, 같은 AZ 사설 IP는 무료 |
| **NAT 게이트웨이 없음** | 월 $43로 Trino 노드값의 36%. 퍼블릭 IPv4 직접 부착이 월 $7.3 |
| **Graviton(arm64)** | Trino 482·Airflow·Postgres 전부 멀티아치. x86 대비 ~20% 저렴 |
| **gp3** | gp2 대비 20% 저렴, 3,000 IOPS / 125 MB/s 기본 포함 |
| **SSM Session Manager** | 포트 22 미개방, 키 관리 불필요 |

## 비용

| 항목 | $/월 |
|---|---:|
| m7g.xlarge | 146.4 |
| r7gd.large | 119.4 |
| EBS gp3 140 GB | ~13 |
| 퍼블릭 IPv4 × 2 | 7.3 |
| **온디맨드 합계** | **~$286 · 약 39만원** |
| Savings Plan 1년(선납없음, ~30%) 적용 시 | ~$206 · 약 28만원 |

**R2 아웃바운드 전송비는 미포함.** transit 단독 실측이 월 544 GB이고 전 도메인 값은
R2 대시보드 Class A 확인이 필요하다. 이 값이 인스턴스비를 넘을 수 있다.

## 사용법

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# admin_cidr 를 본인 IP 로 수정:  curl -s https://checkip.amazonaws.com

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

접속:

```bash
aws ssm start-session --target <instance-id> --region ap-northeast-2
```

인스턴스 ID는 `terraform output`에 나온다.

## 시크릿 — SSM Parameter Store

`.env`를 인스턴스에 평문 복사하지 않는다. R2 토큰·Cloudflare API 토큰이 EBS와
스냅샷에 그대로 남기 때문이다. Parameter Store SecureString은 무료이고 IAM으로
통제되며 접근이 CloudTrail에 남는다.

값 등록 (**로컬에서 직접 실행 — 값을 다른 곳에 붙여넣지 말 것**):

```bash
aws ssm put-parameter --name "/ask-seoul/R2_ACCESS_KEY_ID"     --type SecureString --value "..." --region ap-northeast-2
aws ssm put-parameter --name "/ask-seoul/R2_SECRET_ACCESS_KEY" --type SecureString --value "..." --region ap-northeast-2
aws ssm put-parameter --name "/ask-seoul/R2_DATA_CATALOG_TOKEN" --type SecureString --value "..." --region ap-northeast-2
aws ssm put-parameter --name "/ask-seoul/CLOUDFLARE_API_TOKEN"  --type SecureString --value "..." --region ap-northeast-2
# 나머지 키는 .env.example 참조
```

인스턴스에서 읽기:

```bash
aws ssm get-parameters-by-path --path /ask-seoul --with-decryption --region ap-northeast-2
```

## 아직 없는 것 (별도 단계)

- **앱 배포** — compose 2벌 분리(Airflow가 `trino:8080`을 사설 IP로 해석하도록), `.env` 생성, 이미지 빌드
- **Trino `mem_limit` 결정** — 9 GiB(compose 기본)냐 12 GiB(traffic/weather 현행)냐. commerce 수령 후 판단
- **Savings Plan** — 1년 가동 확정 후 콘솔에서 구매
- **백업** — Airflow 메타DB(Postgres) 스냅샷 정책
- **모니터링** — CloudWatch 알람(메모리는 기본 지표에 없어 에이전트 필요)

## 회수

```bash
terraform destroy
```

EBS는 `delete_on_termination = true`라 함께 사라진다. **Airflow 메타DB가 그 안에 있으므로
destroy 전에 백업**해야 한다. R2·D1 데이터는 영향 없다.

## 나중에 키우기

인스턴스 타입 변경은 정지→변경→시작 5분이고 EBS 루트라 데이터가 유지된다.

```hcl
# commerce 쿼리 peak 가 1.32GiB(현재 최대 관측치)를 크게 넘으면
trino_instance_type = "r7g.xlarge"   # 4 vCPU / 32 GiB, 월 +$69
```
