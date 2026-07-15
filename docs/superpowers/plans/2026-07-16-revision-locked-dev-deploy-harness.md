# Revision-Locked Dev Deploy Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ASAC-DAG와 ASAC-DBT의 최신 `origin/dev` revision만 clean runtime worktree로 준비·mount·검증하는 로컬 Airflow 배포 harness를 만든다.

**Architecture:** `scripts/lib/DevDeployHarness.psm1`이 Git worktree, deployment lock, generated compose override, Docker 검증을 숨기는 deep module이다. `deploy-dev.ps1`과 `verify-dev-deploy.ps1`은 인자 없는 interface이며, root submodule의 작업 트리를 바꾸지 않고 `.runtime/dev`의 detached worktree만 사용한다.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4, Git worktree, Docker Compose v2, JSON, YAML.

## Global Constraints

- 배포 대상 ref는 항상 `origin/dev`이며 branch, SHA, feature ref 인자를 제공하지 않는다.
- root `dags/`와 `dbt/`에는 checkout, reset, merge, clean, submodule update를 실행하지 않는다.
- `.runtime/`, deployment lock, generated override에는 secret이나 `.env` 값을 기록하지 않는다.
- generated override는 Airflow 5개 service 모두에 동일한 DAG/DBT runtime source를 mount해야 한다.
- 실패 시 non-zero exit로 종료하고 성공처럼 보이는 부분 배포를 남기지 않는다.

---

### Task 1: Runtime lock과 generated compose를 소유하는 harness module

**Files:**

- Modify: `.gitignore`
- Create: `scripts/lib/DevDeployHarness.psm1`
- Create: `scripts/tests/DevDeployHarness.Tests.ps1`

**Interfaces:**

- Produces: `Resolve-DevRevision`, `Ensure-DevRuntimeWorktree`, `New-DeploymentLock`, `Write-DevComposeOverride`, `Assert-DevRuntimeWorktree`, `Assert-DeploymentMounts`.
- Consumes: root `dags/`와 `dbt/`의 Git `origin` remote, fixed `origin/dev`, absolute runtime root `<root>/.runtime/dev`.
- Invariant: lock의 `dags.sha`, `dbt.sha`, worktree path는 generated override와 동일하다.

- [ ] **Step 1: lock/override의 실패 계약을 Pester test로 작성한다.**

```powershell
Describe 'DevDeployHarness' {
  It 'writes every Airflow service with the locked DAG and DBT mount' {
    $lock = New-DeploymentLock -RootPath 'C:\repo' -DagSha ('a' * 40) -DbtSha ('b' * 40)
    $yaml = New-DevComposeOverrideText -Lock $lock
    foreach ($service in 'airflow-init','airflow-apiserver','airflow-scheduler','airflow-dag-processor','airflow-triggerer') {
      $yaml | Should Match "$service:`n"
    }
    $yaml | Should Match ([regex]::Escape($lock.dags.worktree_path))
    $yaml | Should Match ([regex]::Escape($lock.dbt.worktree_path))
  }

  It 'rejects a dirty runtime worktree before compose starts' {
    { Assert-DevRuntimeWorktree -Path 'C:\runtime\dags' -StatusLines @(' M domains/traffic/file.py') } |
      Should Throw '*dirty*'
  }

  It 'rejects a Docker mount that differs from the lock' {
    $lock = New-DeploymentLock -RootPath 'C:\repo' -DagSha ('a' * 40) -DbtSha ('b' * 40)
    { Assert-DeploymentMounts -Lock $lock -Mounts @(@{ Destination='/opt/airflow/dags'; Source='C:\wrong' }) } |
      Should Throw '*mount*'
  }
}
```

- [ ] **Step 2: test가 module 부재로 실패하는지 확인한다.**

Run:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
```

Expected: `New-DeploymentLock` 또는 module import가 없다는 실패.

- [ ] **Step 3: `.runtime/`을 ignore하고 module의 pure lock/YAML 구현을 작성한다.**

```powershell
function New-DeploymentLock {
  param([string]$RootPath, [string]$DagSha, [string]$DbtSha)
  $runtime = Join-Path $RootPath '.runtime/dev'
  [ordered]@{
    schema_version = 1
    requested_ref = 'origin/dev'
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    dags = @{ sha = $DagSha; worktree_path = (Join-Path $runtime 'dags') }
    dbt = @{ sha = $DbtSha; worktree_path = (Join-Path $runtime 'dbt') }
    compose_override_path = (Join-Path $runtime 'docker-compose.generated.yml')
    required_dbt_project = '/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml'
  }
}
```

`Write-DevComposeOverride`는 lock의 absolute path만 사용하고 `!override` volumes와 `airflow_logs` volume을 5개 service에 반복한다. `Assert-DevRuntimeWorktree`는 Git status line이 비어 있지 않으면 실패한다. `Assert-DeploymentMounts`는 `/opt/airflow/dags`, `/opt/airflow/dbt` source가 lock과 완전히 일치하는지 검사한다.

- [ ] **Step 4: Pester test와 PowerShell parser를 통과시킨다.**

Run:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
powershell.exe -NoProfile -Command "Import-Module ./scripts/lib/DevDeployHarness.psm1 -Force; Get-Command New-DeploymentLock,Write-DevComposeOverride"
```

Expected: Pester green, 두 exported command가 출력.

- [ ] **Step 5: 첫 번째 커밋을 만든다.**

```powershell
git add .gitignore scripts/lib/DevDeployHarness.psm1 scripts/tests/DevDeployHarness.Tests.ps1
git commit -m "feat: add revision-locked deploy harness module"
```

### Task 2: origin/dev worktree refresh와 deploy/verify public interface

**Files:**

- Modify: `scripts/lib/DevDeployHarness.psm1`
- Create: `scripts/deploy-dev.ps1`
- Create: `scripts/verify-dev-deploy.ps1`
- Modify: `scripts/tests/DevDeployHarness.Tests.ps1`

**Interfaces:**

- Produces: `./scripts/deploy-dev.ps1`, `./scripts/verify-dev-deploy.ps1`.
- Consumes: Task 1의 lock/YAML contract, Docker Compose, Docker inspect, container Git command.
- Invariant: deploy는 `git -C <root>/dags fetch origin dev`와 `git -C <root>/dbt fetch origin dev`만 실행하고 root submodule HEAD를 변경하지 않는다.

- [ ] **Step 1: public command 계약 test를 추가한다.**

```powershell
It 'keeps deploy-dev argument-free and fixes the requested ref to origin/dev' {
  $script = Get-Content "$PSScriptRoot/../deploy-dev.ps1" -Raw
  $script | Should Match 'requested_ref.*origin/dev'
  $script | Should Not Match 'param\s*\(.*Ref'
}

It 'requires lock SHA and dbt project from a running scheduler' {
  { Assert-RunningDeployment -Lock $lock -ServiceMounts $mounts -DagHead ('c' * 40) -DbtHead $lock.dbt.sha -DbtProjectExists $true } |
    Should Throw '*DAG revision*'
}
```

- [ ] **Step 2: 추가 test가 새 public command와 runtime assertion 부재로 실패하는지 확인한다.**

Run:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
```

Expected: `Assert-RunningDeployment` 또는 public script contract 실패.

- [ ] **Step 3: detached worktree와 atomic lock write를 구현한다.**

```powershell
function Ensure-DevRuntimeWorktree {
  param([string]$RepositoryPath, [string]$RuntimePath)
  Invoke-External 'git' @('-C', $RepositoryPath, 'fetch', 'origin', 'dev')
  $sha = Invoke-External 'git' @('-C', $RepositoryPath, 'rev-parse', 'origin/dev')
  if (-not (Test-Path $RuntimePath)) {
    Invoke-External 'git' @('-C', $RepositoryPath, 'worktree', 'add', '--detach', $RuntimePath, $sha)
  } else {
    Assert-DevRuntimeWorktree -Path $RuntimePath
    Invoke-External 'git' @('-C', $RuntimePath, 'checkout', '--detach', $sha)
  }
  Assert-DevRuntimeWorktree -Path $RuntimePath
  return $sha.Trim()
}
```

`Write-DeploymentLockAtomically`는 `<lock>.tmp`에 UTF-8 JSON을 쓴 뒤 `Move-Item -Force`로 교체한다. `deploy-dev.ps1`는 runtime lock을 획득하고, DAG/DBT SHA를 resolve한 뒤 override와 lock을 생성하고 다음 명령만 실행한다.

```powershell
docker compose -f docker-compose.yml -f $lock.compose_override_path config --quiet
docker compose -f docker-compose.yml -f $lock.compose_override_path up -d --build
```

- [ ] **Step 4: runtime 검증을 구현한다.**

`verify-dev-deploy.ps1`는 lock을 읽고 각 Airflow container의 `docker inspect` mount JSON을 `Assert-DeploymentMounts`로 검사한다. scheduler에서 다음을 실행해 lock SHA와 required dbt project를 검사한다.

```powershell
git -C /opt/airflow/dags rev-parse HEAD
git -C /opt/airflow/dbt rev-parse HEAD
test -f /opt/airflow/dbt/domains/traffic_weather/dbt_project.yml
```

apiserver/scheduler health가 `healthy`가 아니면 실패한다. 오류 출력에는 path와 SHA만 포함하고 environment 값을 출력하지 않는다.

- [ ] **Step 5: Pester 및 non-mutating compose contract를 통과시킨다.**

Run:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1 -WhatIf
```

Expected: Pester green, `-WhatIf`는 origin/dev SHA와 generated override만 출력하고 Docker를 기동하지 않음.

- [ ] **Step 6: 두 번째 커밋을 만든다.**

```powershell
git add scripts/lib/DevDeployHarness.psm1 scripts/deploy-dev.ps1 scripts/verify-dev-deploy.ps1 scripts/tests/DevDeployHarness.Tests.ps1
git commit -m "feat: deploy locked origin dev worktrees"
```

### Task 3: 운영 문서와 실제 dev deployment 검증

**Files:**

- Modify: `README.md`
- Create: `docs/agent/workflows/revision-locked-dev-deploy.md`
- Modify: `LessonRun.md`

**Interfaces:**

- Consumes: Task 2의 public commands와 deployment lock summary.
- Produces: 사람이 수동 override나 `scripts/deploy.sh` 대신 실행할 하나의 dev deployment 경로.

- [ ] **Step 1: 운영 문서 계약 test를 작성한다.**

```powershell
It 'documents deploy-dev as the only dev merged-revision command' {
  $readme = Get-Content "$PSScriptRoot/../../README.md" -Raw
  $readme | Should Match 'deploy-dev.ps1'
  $readme | Should Match 'origin/dev'
  $readme | Should Match 'deploy.sh.*main'
}
```

- [ ] **Step 2: test가 문서 부재로 실패하는지 확인한다.**

Run:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
```

Expected: README command/guardrail assertion 실패.

- [ ] **Step 3: README와 workflow 문서를 작성한다.**

문서는 `deploy.sh`가 `main`을 대상으로 하므로 dev 병합본에 사용하면 안 된다는 점, `deploy-dev.ps1`가 lock을 만들고 root dirty checkout을 보존한다는 점, 실패 시 `verify-dev-deploy.ps1`를 재실행해 mount/SHA를 확인하는 방법을 명시한다.

- [ ] **Step 4: 실제 local dev deployment를 실행한다.**

Run:

```powershell
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1
powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1
docker compose -f docker-compose.yml -f .runtime/dev/docker-compose.generated.yml ps
```

Expected: DAG/DBT lock SHA와 container HEAD가 동일하고 scheduler/apiserver가 healthy. root `dags/`, `dbt/`의 Git status는 변경되지 않음.

- [ ] **Step 5: smoke evidence를 LessonRun에 기록하고 전체 검증을 통과시킨다.**

Run:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester ./scripts/tests/DevDeployHarness.Tests.ps1 -EnableExit"
docker compose -f docker-compose.yml -f .runtime/dev/docker-compose.generated.yml config --quiet
git diff --check
git status --short
```

Expected: Pester green, compose config success, `.runtime/`이 Git status에 나타나지 않음.

- [ ] **Step 6: 세 번째 커밋을 만든다.**

```powershell
git add README.md docs/agent/workflows/revision-locked-dev-deploy.md LessonRun.md
git commit -m "docs: document locked dev deployment workflow"
```

## Plan Self-Review

- Spec coverage: origin/dev 고정, clean worktree, generated mount, lock, runtime SHA/dbt project, health, root dirty 보존, Pester·compose·integration 검증이 각각 Task 1~3에 대응한다.
- Placeholder scan: 모든 구현 task는 파일 경로, command, 실패 조건, code contract를 명시한다.
- Type consistency: Task 1의 lock object는 Task 2의 deploy/verify가 소비하고, Task 3의 문서와 integration command가 동일한 `.runtime/dev` lock path를 사용한다.
