# Task 3 report: operational documentation and verification evidence

## 변경 요약

- `README.md`: `scripts/deploy.sh`가 `origin/main` 기반 경로이며 merged `dev` runtime validation에는 쓰지 않는다는 내용을 추가했다. `scripts/deploy-dev.ps1`와 `scripts/verify-dev-deploy.ps1`를 merged `origin/dev` 배포/검증 entry point로 문서화했다.
- `docs/agent/workflows/revision-locked-dev-deploy.md`: locked dev deployment workflow, lock 대상, runtime 검증 항목, safety gate, merge-to-local routine을 한국어 운영 문서로 추가했다.
- `LessonRun.md`: 이번 Task 3 문서화 작업의 기록 항목과 live deployment 미수행 제한을 남겼다.
- `scripts/tests/DevDeployHarness.Tests.ps1`: README가 `deploy-dev.ps1`, `origin/dev`, `deploy.sh` main 기반 동작을 문서화하는지 확인하는 documentation-contract test를 추가했다.

## TDD evidence

1. RED: documentation-contract test 추가 후 `Invoke-Pester .\scripts\tests\DevDeployHarness.Tests.ps1` 실행.
   - 결과: `documents deploy-dev as origin/dev entry point and deploy.sh as main-based path` 실패.
   - 실패 원인: 기존 `README.md`에 `deploy-dev.ps1` 문서가 없었다.
   - 참고: 이 환경의 기존 Pester는 실패가 있어도 process exit code를 0으로 반환했으므로 이후 green 검증은 `-EnableExit`로 실행했다.
2. GREEN: README/workflow/LessonRun 문서를 추가한 뒤 full Pester를 재실행했다.
   - 결과: 17 passed, 0 failed.

## Verification

- Pester: `powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"` -> Passed: 17, Failed: 0.
- Parser/import: PowerShell AST parse for `scripts/deploy-dev.ps1`, `scripts/verify-dev-deploy.ps1`, `scripts/lib/DevDeployHarness.psm1`, `scripts/tests/DevDeployHarness.Tests.ps1` -> `PowerShell parser OK`.
- Module import: `Import-Module ./scripts/lib/DevDeployHarness.psm1 -Force -DisableNameChecking; Get-Command Resolve-DevRevision,New-DeploymentLock,Assert-RunningDeployment` -> 세 함수 export 확인.
- WhatIf: `powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1 -WhatIf` -> `requested_ref origin/dev`, `dags 9f1731c962bc209e98f43a298d6af69bd243d1da`, `dbt 9f1731c962bc209e98f43a298d6af69bd243d1da`, compose override path 출력.
- Compose config: `.runtime/dev/docker-compose.generated.yml`가 없는 feature worktree라 `docker compose -f docker-compose.yml -f .runtime/dev/docker-compose.generated.yml config --quiet`는 실행하지 않고 `SKIP: .runtime/dev/docker-compose.generated.yml not present`로 기록했다.
- Whitespace: `git diff --check` -> exit 0. Git이 `README.md`와 `scripts/tests/DevDeployHarness.Tests.ps1`의 LF/CRLF 변환 경고를 출력했지만 whitespace error는 없었다.

## Limitation

- 사용자 지시대로 live Docker deployment는 수행하지 않았다.
- `.env` 값과 secret 값은 출력하거나 기록하지 않았다.
- 이 report는 documentation-contract와 non-mutating harness checks의 증거이며, 실제 dev smoke run id, task 상태, row count, 생성 object/table 증거는 local `.env`가 준비된 root에서 live `deploy-dev.ps1`/`verify-dev-deploy.ps1`를 실행한 뒤 `LessonRun.md`에 추가로 기록해야 한다.
