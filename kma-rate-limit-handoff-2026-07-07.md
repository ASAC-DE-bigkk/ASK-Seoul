# KMA API Rate Limit Handoff (2026-07-07)

## 목적
집에서 IP를 변경해 테스트를 이어 할 수 있도록, 오늘 진행한 KMA rate-limit 확인 사항을 정리합니다.

## 현재 상태 요약
- 브랜치: `feat/177-kma-runtime-image-airflow`
- origin: `https://github.com/ASAC-DE-bigkk/sample.git`
- 동일 환경에서 `test`/`prod` 키 모두 즉시 429을 반환한 상태에서 시작했고,
  1분~60분 체크에서도 `429` 유지가 관측되었습니다.
- 응답 본문은 `API token quota exceeded`가 반복됐고, `Retry-After`, `X-RateLimit-*` 헤더는 관측치에 없음.

## 오늘 만든/사용한 파일
1) `.omx/kma_rate_probe_80_blockwatch/recovery-checks.csv`
- `2026-07-07 15:48:12` 기준 업데이트
- `request_id` 1,2,3,5,10,15,20,30,40,50,60 모두 `429`
- body_snippet 모두 `API token quota exceeded`

> 참고: 이전 세션에서 임시로 만들었던 probe 스크립트/좌표 파일은 현재 작업트리에서 보존되지 않았습니다.  
> (아래 커맨드로 동일 조건을 재생성해 바로 이어서 실험 가능합니다.)

## 오늘 측정한 핵심 결과
- 즉시 1회 호출
  - `KMA_SERVICE_KEY_TEST` => 429
  - `KMA_SERVICE_KEY` => 429
- 간격(10~20초) 반복 호출: `test key` 5회 모두 429
- 이전(락 전 구간) 캡acity 스냅샷(부분):
  - `rps=10`, `12`, `14`: mostly success
  - `rps=16`: 일부 429/other 혼입
  - `rps=18`: 200 일부 + other 에러
  - `rps=20`, `25`: all 429 (고부하 구간)
- 현재 락 유지 구간(요약): `recovery-check`에서 1~60분까지 연속 429

## 집에서 할 수 있는 바로 이어서 실행 절차

### 1) 환경 체크
```powershell
Get-Location
$env:KMA_SERVICE_KEY_TEST
$env:KMA_SERVICE_KEY
```

### 2) 즉시 단건 sanity check (둘 다 통과되는지)
```powershell
$baseUrl = "https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0"
$params = "serviceKey={0}&pageNo=1&numOfRows=50&dataType=JSON&base_date=20260707&base_time=1400&nx=60&ny=127"

function Test-Kma([string]$key){
  $url = "$baseUrl/getVilageFcst?" + ($params -f [uri]::EscapeDataString($key))
  try {
    $r = Invoke-WebRequest -Uri $url -Headers @{ Accept = "application/json" } -UseBasicParsing -TimeoutSec 12
    Write-Host "$key => $($r.StatusCode)"
  } catch {
    if ($_.Exception.Response) {
      Write-Host "$key => $($_.Exception.Response.StatusCode.value__)"
    } else {
      Write-Host "$key => ERR"
    }
  }
}

Test-Kma $env:KMA_SERVICE_KEY_TEST
Test-Kma $env:KMA_SERVICE_KEY
```

### 3) 즉시 1분 주기 복구 확인(1,2,3,5,10,15분)
```powershell
$start = Get-Date
foreach ($m in 1,2,3,5,10,15) {
  Start-Sleep -Seconds (($m * 60) - [int](New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds)
  Test-Kma $env:KMA_SERVICE_KEY_TEST
}
```

## 다음 판단 기준
1. `200`가 보이면 rps를 1,2,4... 식으로 천천히 올려 재측정.
2. 429면 `Retry-After` 헤더 유무만 확인하고 중단 후 최소 60분 재시도.
3. 동일 IP에서 60분 이상 429가 계속되면 공용키/네트워크 쿼터 의심을 추가 점검.

## 커밋/푸시 가이드
- 본 handoff는 `kma-rate-limit-handoff-2026-07-07.md` 하나로 전달합니다.
- 원격 브랜치에 올릴 때는 `origin` 기준으로 같은 브랜치에 commit 후 push.
