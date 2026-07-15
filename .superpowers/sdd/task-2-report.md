# Task 2 Report: origin/dev worktree refresh and deploy/verify public interface

## Review correction

- `verify-dev-deploy.ps1` now has an explicit zero-input interface and rejects any unexpected argument before reading deployment state.
- `Get-RunningDeploymentEvidence` no longer catches arbitrary scheduler command failures while checking the required dbt project. The scheduler probe returns explicit `exists`/`missing` evidence; only `missing` becomes `RequiredDbtProjectExists = $false`, while Docker/scheduler failures still surface with their original diagnostics.
- Added behavior coverage for bad/missing service mount evidence and missing/unhealthy apiserver/scheduler health evidence.

Correction RED command:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
```

Correction RED result:

- Exit code: `1`
- Passed: `14`
- Failed: `2`
- Failures reproduced unexpected verify arguments reaching lock loading, and scheduler dbt-project command failure being swallowed.

Correction GREEN command:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
```

Correction GREEN result:

- Exit code: `0`
- Passed: `16`
- Failed: `0`
- Skipped: `0`
- Pending: `0`
- Inconclusive: `0`

Correction parser/import check:

```powershell
powershell.exe -NoProfile -Command "& { ... Parser::ParseFile ... Import-Module ./scripts/lib/DevDeployHarness.psm1 ... }"
```

Result:

- Exit code: `0`
- Output included `parser/import ok`, `Resolve-DevRevision`, `Assert-RunningDeployment`, and `Get-RunningDeploymentEvidence`.

Correction WhatIf check:

```powershell
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1 -WhatIf
```

Result:

- Exit code: `0`
- Printed the locked `origin/dev` DAG/DBT revisions and compose override path without running a Docker mutation.

## Scope completed

- Updated `scripts/lib/DevDeployHarness.psm1` with:
  - `origin/dev` fetch-before-resolve for root `dags/` and `dbt`.
  - atomic UTF-8 deployment lock write and lock read support.
  - Docker Compose invocation helpers that surface external command failures.
  - Docker inspect/evidence collection for the running deployment.
  - `Assert-RunningDeployment` validation for all five Airflow service mounts, scheduler DAG/DBT HEADs, required dbt project existence, and apiserver/scheduler health.
- Added `scripts/deploy-dev.ps1` as the thin deploy interface.
  - Accepts only `-WhatIf`; no ref, branch, SHA, or feature-ref input.
  - Non-WhatIf path resolves literal `origin/dev`, refreshes `.runtime/dev/{dags,dbt}`, writes lock, writes compose override, runs `docker compose ... config --quiet`, then `up -d --build`.
  - `-WhatIf` skips fetch, runtime worktree changes, lock writes, compose writes, and Docker mutation. It prints only intended lock/override information.
- Added `scripts/verify-dev-deploy.ps1` as the thin verification interface.
  - Reads `.runtime/dev/deployment-lock.json`.
  - Collects Docker inspect/exec evidence and validates it through module logic.
- Updated `scripts/tests/DevDeployHarness.Tests.ps1` with Task 2 Pester coverage.

## TDD evidence

RED command:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
```

RED result:

- Exit code: `1`
- Existing Task 1 tests passed: `6`
- New Task 2 tests failed: `4`
- Failures were from missing `scripts/deploy-dev.ps1` and missing `Assert-RunningDeployment`.

GREEN command:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
```

GREEN result:

- Exit code: `0`
- Passed: `10`
- Failed: `0`
- Skipped: `0`
- Pending: `0`
- Inconclusive: `0`

## Parser/import checks

Parser/import command:

```powershell
@'
$files = @(
  './scripts/lib/DevDeployHarness.psm1',
  './scripts/deploy-dev.ps1',
  './scripts/verify-dev-deploy.ps1',
  './scripts/tests/DevDeployHarness.Tests.ps1'
)
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
  }
}
Import-Module ./scripts/lib/DevDeployHarness.psm1 -Force -DisableNameChecking
(Get-Command Resolve-DevRevision,Assert-RunningDeployment,Get-RunningDeploymentEvidence).Name
'@ | powershell.exe -NoProfile -Command -
```

Parser/import result:

- Exit code: `0`

Explicit exported-command check:

```powershell
@'
$ErrorActionPreference = 'Stop'
Import-Module ./scripts/lib/DevDeployHarness.psm1 -Force -DisableNameChecking
Get-Command Resolve-DevRevision,Assert-RunningDeployment,Get-RunningDeploymentEvidence | ForEach-Object { $_.Name }
'@ | powershell.exe -NoProfile -Command -
```

Output:

```text
Resolve-DevRevision
Assert-RunningDeployment
Get-RunningDeploymentEvidence
```

## WhatIf result

Command:

```powershell
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1 -WhatIf
```

Result:

- Exit code: `0`
- No `.runtime/` directory was created.
- No Docker mutation command was run by the script.

Output:

```text
WhatIf: requested_ref origin/dev
WhatIf: dags 9f1731c962bc209e98f43a298d6af69bd243d1da -> C:\Users\Dell3571\Desktop\Projects\ask-seoul-worktrees\sample-30-revision-locked-dev-deploy-harness\.runtime\dev\dags
WhatIf: dbt 9f1731c962bc209e98f43a298d6af69bd243d1da -> C:\Users\Dell3571\Desktop\Projects\ask-seoul-worktrees\sample-30-revision-locked-dev-deploy-harness\.runtime\dev\dbt
WhatIf: compose override C:\Users\Dell3571\Desktop\Projects\ask-seoul-worktrees\sample-30-revision-locked-dev-deploy-harness\.runtime\dev\docker-compose.generated.yml
```

## Additional checks

Command:

```powershell
git diff --check -- scripts/lib/DevDeployHarness.psm1 scripts/deploy-dev.ps1 scripts/verify-dev-deploy.ps1 scripts/tests/DevDeployHarness.Tests.ps1
```

Result:

- Exit code: `0`
- Git printed line-ending warnings for existing tracked PowerShell files, but no whitespace errors.

## Notes

- Root `dags/` and `dbt/` checkout state was not changed during verification.
- `deploy-dev.ps1 -WhatIf` intentionally uses `Resolve-DevRevision -SkipFetch` so WhatIf remains non-mutating.
- Full non-WhatIf Docker deploy was not run for this task; the brief requested WhatIf plus unit/parser verification before commit.
