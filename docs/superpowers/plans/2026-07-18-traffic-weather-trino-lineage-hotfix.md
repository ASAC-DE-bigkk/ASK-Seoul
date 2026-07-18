# Traffic/Weather Trino Lineage Hotfix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** local dev deploy에서 Marquez lineage backend를 항상 기동하고, Traffic/Weather Airflow pool starvation을 제거하며, Trino `hardConcurrencyLimit=1` 기본 보호와 명시적 `hardConcurrencyLimit=2` canary를 분리한다.

**Architecture:** root runtime은 `docker-compose.yml`에서 Marquez를 always-on service로 만들고, revision-locked `DevDeployHarness`가 base compose + Traffic/Weather lineage overlay + generated exact-ref override를 항상 같은 순서로 병합한다. Airflow pool bootstrap은 root `airflow-init`에서 domain lane 2개와 legacy pool을 idempotent upsert하고, Trino engine concurrency 2는 기본 deploy에 섞지 않는 별도 canary overlay로만 켠다.

**Tech Stack:** Docker Compose, Airflow LocalExecutor, Marquez 0.50.0, Trino 482, PowerShell module/Pester, Python `unittest`.

## Global Constraints

- 작업 기준 branch는 `fix/38-trino-openlineage-starvation`이며 base는 `origin/dev`다.
- root repo만 구현한다. `dags/`와 `dbt/` submodule 내부 task-level pool 이관은 이 plan의 코드 변경 범위가 아니다.
- 설계/계획 문서는 한국어로 작성하고, code/config/path/product/library 고유명사는 원문 표기를 유지한다.
- secret 값은 compose config, test output, verify output, docs에 출력하지 않는다.
- Marquez는 제거하거나 OpenLineage를 상시 비활성화하지 않는다. Marquez는 local dev lineage backend로 always-on 유지한다.
- `query.low-memory-killer.policy=none`, spill 설정, Trino JVM `-XX:MaxRAMPercentage=55`, Trino container `mem_limit: ${TRINO_MEMORY_LIMIT:-9g}`는 유지한다.
- Stage1 기본 deploy는 `hardConcurrencyLimit=1`이다.
- Stage2 `hardConcurrencyLimit=2`는 별도 canary overlay로만 실행하고 `deploy-dev.ps1` 기본 경로에 포함하지 않는다.
- deployment lock은 `schema_version=2`이며 현재 `docker-compose.traffic-weather-lineage.yml` SHA-256과 ordered exact 3-file compose set을 검증한다.
- Stage2 overlay는 base `.env`의 `TRINO_*` 값이 새어 들지 않도록 전용 `TRINO_CANARY_*` interpolation 변수만 사용하고, `TRINO_CANARY_MEMORY_HEAP_HEADROOM_PER_NODE=2GB`, `TRINO_CANARY_TASK_CONCURRENCY=2`를 고정 기본값으로 둔다.
- Traffic/Weather domain lane은 각각 1 slot이다: `trino_traffic_heavy=1`, `trino_weather_heavy=1`.
- legacy `trino_heavy=1`은 inventory 완료 전까지 유지한다.
- Marquez optional search는 도입하지 않고 `SEARCH_ENABLED=false`를 명시한다.
- root `deploy-dev.ps1`는 여전히 literal `origin/dev`만 대상으로 하고 ref/branch/SHA parameter를 추가하지 않는다.
- implementation 전에 이 계획의 각 task에서 지정한 failing test를 먼저 작성한다.

---

## File Map

**Modify**
- `docker-compose.yml:67-123`: Marquez `profiles` 제거, restart policy, healthcheck, search off, memory caps, API JVM cap.
- `docker-compose.yml:164-181`: Airflow pool bootstrap을 Traffic/Weather domain lane + legacy pool로 확장.
- `scripts/lib/DevDeployHarness.psm1:1-10`: compose overlay constant와 Airflow/Marquez service lists.
- `scripts/lib/DevDeployHarness.psm1:107-133`: 기존 external runner 유지. 새 helper는 이 근처 또는 `New-DeploymentLock` 앞에 배치한다.
- `scripts/lib/DevDeployHarness.psm1:170-203`: deployment lock에 lineage overlay path, sha256, compose file set 추가.
- `scripts/lib/DevDeployHarness.psm1:434-489`: running deployment assertion에 compose label, scheduler env, pool, Marquez health 검증 추가.
- `scripts/lib/DevDeployHarness.psm1:491-507`: 모든 docker compose 호출이 3-file set을 사용하도록 변경.
- `scripts/lib/DevDeployHarness.psm1:570-615`: runtime evidence 수집에 Marquez, scheduler env, pools, compose labels 추가.
- `scripts/deploy-dev.ps1:14-19`: `-WhatIf` output에 lineage overlay path/sha256 추가.
- `scripts/deploy-dev.ps1:35-40`: success output에 lineage overlay path 추가.
- `scripts/verify-dev-deploy.ps1:14-19`: 새 evidence/verify parameter 전달.
- `scripts/verify-dev-deploy.ps1:21-26`: non-secret verification summary 확장.
- `scripts/tests/test_traffic_weather_lineage_overlay.py:100-263`: Marquez always-on/static compose tests 추가/수정.
- `scripts/tests/test_trino_runtime_hardening.py:17-85`: pool bootstrap, Stage1/Stage2 canary config tests 추가/수정.
- `scripts/tests/DevDeployHarness.Tests.ps1:263-505`: 3-file compose, lock fingerprint, verifier failure cases 추가/수정.
- `docs/traffic-weather-lineage.md`: Marquez always-on, root deploy overlay merge, verify evidence, fail-open boundary 문서화.
- `docs/agent/workflows/revision-locked-dev-deploy.md`: `deploy-dev.ps1` compose set과 verification evidence 업데이트.
- `README.md`: local dev deploy command examples의 compose file set 업데이트.
- `.env.example:50-56`: Stage1 기본 Trino memory guardrail 유지, Stage2 전용 `TRINO_CANARY_*` 값은 주석으로만 문서화한다.

**Create**
- `trino/resource-groups.canary-hard2.json`: Stage2 canary 전용 resource group file.
- `docker-compose.trino-hard2-canary.yml`: Stage2 canary 전용 Trino config/memory overlay.

**Do Not Modify**
- `dags/**`: root plan에서는 task-level pool assignment를 구현하지 않는다.
- `dbt/**`: root plan에서는 dbt model code를 수정하지 않는다.
- `.env`, `.env.*`: secret 파일은 읽거나 수정하지 않는다.
- `.gitmodules`: main tracking 의도는 변경하지 않는다.

## Handoff Boundary

root 구현 완료 후 ASAC-DAG 후속 작업이 필요하다. 후속 작업은 `dags/` submodule에서 Traffic Bronze/resolver/Silver/Gold/recovery task가 `pool="trino_traffic_heavy"`를 사용하고, Weather Bronze/transform/W1/W2 smoke/recovery task가 `pool="trino_weather_heavy"`를 사용하도록 resource adapter를 바꾼다. `dbt_deps`는 Trino query를 실행하지 않으므로 heavy pool을 사용하지 않는다.

## Acceptance Criteria

- `docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml -f .runtime/dev/docker-compose.generated.yml config --quiet`가 성공한다.
- 기본 `pwsh -File scripts/deploy-dev.ps1`가 Marquez DB/API/Web을 profile 없이 기동한다.
- `scripts/verify-dev-deploy.ps1`가 current overlay SHA mismatch, Marquez running/healthy/resource/restart/OOM, scheduler DNS, scheduler lineage boolean checks, Traffic/Weather pools, ordered exact normalized compose label 3-file set mismatch를 실패로 판정한다.
- Stage1 기본 resource group은 `hardConcurrencyLimit=1`이다.
- Stage2 canary는 `docker-compose.trino-hard2-canary.yml`을 명시적으로 추가할 때만 `hardConcurrencyLimit=2`, `1280MB/2560MB` query cap, `2GB` heap headroom, task concurrency `2`를 적용하며 최소 3 cycle을 실제 실행한다.
- Marquez search unavailable 상태는 deployment failure가 아니며 `SEARCH_ENABLED=false`로 optional search를 사용하지 않는다.
- OpenLineage/dbt fail-open probe는 계속 통과한다.
- 실행 보고에는 DAG run id, task state/time, row count, object/table, Trino memory/restart, Marquez POST status를 `LessonRun.md`에 기록할 수 있는 verification path가 있다.

### Task 1: Marquez Always-On Compose Contract

**Files:**
- Modify: `docker-compose.yml:67-123`
- Test: `scripts/tests/test_traffic_weather_lineage_overlay.py:100-263`

**Interfaces:**
- Consumes: existing services `marquez-db`, `marquez-api`, `marquez-web` in `docker-compose.yml`.
- Produces: always-on Marquez services that `DevDeployHarness` and runtime verifier can assume exist in the base compose.

- [ ] **Step 1: Write failing Marquez always-on tests**

Add these methods to `TrafficWeatherLineageOverlayTest` in `scripts/tests/test_traffic_weather_lineage_overlay.py`:

```python
    def test_marquez_services_are_always_on_and_supervised(self) -> None:
        for service_name in ("marquez-db", "marquez-api", "marquez-web"):
            with self.subTest(service=service_name):
                service_block = re.search(
                    rf"(?ms)^  {re.escape(service_name)}:\r?\n(?P<block>.*?)(?=^  [a-z][a-z0-9-]+:|\Z)",
                    self.base,
                )
                self.assertIsNotNone(service_block)
                block = service_block.group("block")
                self.assertNotIn("profiles:", block)
                self.assertIn("restart: unless-stopped", block)

        self.assertRegex(
            self.base,
            r"(?ms)^  marquez-db:\r?\n.*?mem_limit: 512m",
        )
        self.assertRegex(
            self.base,
            r"(?ms)^  marquez-api:\r?\n.*?mem_limit: 1536m",
        )
        self.assertRegex(
            self.base,
            r"(?ms)^  marquez-web:\r?\n.*?mem_limit: 256m",
        )

    def test_marquez_api_disables_search_and_has_admin_healthcheck(self) -> None:
        self.assertIn('SEARCH_ENABLED: "false"', self.base)
        self.assertIn('JAVA_OPTS: "-XX:MaxRAMPercentage=50"', self.base)
        self.assertIn("http://localhost:5001/healthcheck", self.base)
        self.assertRegex(
            self.base,
            r"(?ms)^  marquez-api:\r?\n.*?healthcheck:\r?\n.*?curl --fail http://localhost:5001/healthcheck",
        )
        self.assertRegex(
            self.base,
            r"(?ms)^  marquez-web:\r?\n.*?depends_on:\r?\n      marquez-api:\r?\n        condition: service_healthy",
        )
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```powershell
python -m unittest scripts.tests.test_traffic_weather_lineage_overlay -v
```

Expected: FAIL. Failure messages should mention missing `restart: unless-stopped`, existing `profiles:`, missing `SEARCH_ENABLED`, missing `JAVA_OPTS`, or missing Marquez API healthcheck.

- [ ] **Step 3: Implement Marquez always-on compose changes**

Change `docker-compose.yml:67-123` to this shape while keeping existing comments concise and Korean:

```yaml
  marquez-db:
    image: postgres:16-alpine
    restart: unless-stopped
    mem_limit: 512m
    environment:
      POSTGRES_USER: ${MARQUEZ_POSTGRES_USER:-marquez}
      POSTGRES_PASSWORD: ${MARQUEZ_POSTGRES_PASSWORD:-marquez}
      POSTGRES_DB: ${MARQUEZ_POSTGRES_DB:-marquez}
    volumes:
      - marquez_db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${MARQUEZ_POSTGRES_USER:-marquez} -d ${MARQUEZ_POSTGRES_DB:-marquez}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    networks:
      - elt_net

  marquez-api:
    image: marquezproject/marquez:0.50.0
    restart: unless-stopped
    mem_limit: 1536m
    environment:
      MARQUEZ_PORT: "5000"
      MARQUEZ_ADMIN_PORT: "5001"
      SEARCH_ENABLED: "false"
      JAVA_OPTS: "-XX:MaxRAMPercentage=50"
      POSTGRES_HOST: marquez-db
      POSTGRES_PORT: "5432"
      POSTGRES_DB: ${MARQUEZ_POSTGRES_DB:-marquez}
      POSTGRES_USER: ${MARQUEZ_POSTGRES_USER:-marquez}
      POSTGRES_PASSWORD: ${MARQUEZ_POSTGRES_PASSWORD:-marquez}
    ports:
      - "127.0.0.1:5000:5000"
      - "127.0.0.1:5001:5001"
    depends_on:
      marquez-db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl --fail http://localhost:5001/healthcheck >/dev/null 2>&1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - elt_net

  marquez-web:
    image: marquezproject/marquez-web:0.50.0
    restart: unless-stopped
    mem_limit: 256m
    environment:
      MARQUEZ_HOST: marquez-api
      MARQUEZ_PORT: "5000"
      WEB_PORT: "3000"
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      marquez-api:
        condition: service_healthy
    networks:
      - elt_net
```

- [ ] **Step 4: Run Marquez compose tests**

Run:

```powershell
python -m unittest scripts.tests.test_traffic_weather_lineage_overlay -v
```

Expected: PASS for new Marquez tests and existing loopback/overlay tests.

- [ ] **Step 5: Commit Task 1**

```powershell
git add docker-compose.yml scripts/tests/test_traffic_weather_lineage_overlay.py
git commit -m "fix(compose): keep local Marquez lineage backend always on"
```

Expected: commit succeeds. If user has not approved commits in the active session, stop before this command and ask for approval because root `AGENTS.md` forbids unapproved commits.

### Task 2: Airflow Domain Pool Bootstrap

**Files:**
- Modify: `docker-compose.yml:164-181`
- Test: `scripts/tests/test_trino_runtime_hardening.py:81-85`

**Interfaces:**
- Consumes: Airflow CLI in `airflow-init`.
- Produces: three idempotent pools available to DAG tasks: `trino_traffic_heavy`, `trino_weather_heavy`, `trino_heavy`.

- [ ] **Step 1: Write failing pool bootstrap test**

Replace `test_airflow_pool_is_bootstrapped_idempotently` in `scripts/tests/test_trino_runtime_hardening.py`:

```python
    def test_airflow_pools_are_bootstrapped_idempotently(self):
        expected_pool_commands = {
            'airflow pools set trino_traffic_heavy 1 "Serialize Traffic Trino writes and exact tests"',
            'airflow pools set trino_weather_heavy 1 "Serialize Weather Trino writes and recovery"',
            'airflow pools set trino_heavy 1 "Serialize Trino/dbt memory-heavy tasks"',
        }
        for command in expected_pool_commands:
            with self.subTest(command=command):
                self.assertIn(command, self.compose)
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```powershell
python -m unittest scripts.tests.test_trino_runtime_hardening.TrinoRuntimeHardeningTest.test_airflow_pools_are_bootstrapped_idempotently -v
```

Expected: FAIL because only legacy `trino_heavy` exists.

- [ ] **Step 3: Implement pool bootstrap**

Change `docker-compose.yml:180` command block to include all three lines:

```yaml
        /entrypoint airflow pools set trino_traffic_heavy 1 "Serialize Traffic Trino writes and exact tests"
        /entrypoint airflow pools set trino_weather_heavy 1 "Serialize Weather Trino writes and recovery"
        /entrypoint airflow pools set trino_heavy 1 "Serialize Trino/dbt memory-heavy tasks"
```

- [ ] **Step 4: Run Trino hardening tests**

Run:

```powershell
python -m unittest scripts.tests.test_trino_runtime_hardening -v
```

Expected: PASS. Existing Stage1 `hardConcurrencyLimit=1`, memory, mount tests still pass.

- [ ] **Step 5: Commit Task 2**

```powershell
git add docker-compose.yml scripts/tests/test_trino_runtime_hardening.py
git commit -m "fix(airflow): bootstrap Traffic and Weather Trino pools"
```

Expected: commit succeeds after explicit user approval for committing.

### Task 3: Revision-Locked Deploy Uses 3-File Compose Set

**Files:**
- Modify: `scripts/lib/DevDeployHarness.psm1:1-10,107-203,491-507,618-635`
- Modify: `scripts/deploy-dev.ps1:14-19,35-40`
- Test: `scripts/tests/DevDeployHarness.Tests.ps1:263-325`

**Interfaces:**
- Consumes: existing `New-DeploymentLock -RootPath <string> -DagSha <40hex> -DbtSha <40hex>`.
- Produces:
  - `Get-DevFileSha256 -Path <string> -> <lowercase hex sha256>`
  - `Get-DevComposeFileArguments -RootPath <string> -Lock <object> -> string[]`
  - deployment lock `schema_version=2` and fields `lineage_overlay_path`, `lineage_overlay_sha256`, `compose_files`.

- [ ] **Step 1: Write failing Pester tests for lock and compose file order**

Add this TestDrive-backed fixture helper near `New-TestRunningDeploymentArgs`; all existing hard-coded `C:\repo` fixtures in this test file must use this helper and `$fixture.RootPath` so `Get-DevFileSha256` always receives a real overlay file:

```powershell
function New-TestDeploymentLock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [string]$DagSha = ('a' * 40),
    [string]$DbtSha = ('b' * 40)
  )

  $root = Join-Path $TestDrive $Name
  New-Item -ItemType Directory -Path (Join-Path $root '.runtime\dev') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $root 'docker-compose.yml') -Value 'services: {}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $root 'docker-compose.traffic-weather-lineage.yml') -Value 'services: {}' -Encoding UTF8

  return [pscustomobject]@{
    RootPath = $root
    Lock = New-DeploymentLock -RootPath $root -DagSha $DagSha -DbtSha $DbtSha
  }
}
```

For every existing test, replace `New-DeploymentLock -RootPath 'C:\repo' ...` with a uniquely named fixture. Replace the remaining direct `Resolve-DevRevision`, `Invoke-DevDockerCompose`, and `Get-RunningDeploymentEvidence` `C:\repo` roots with `$fixture.RootPath`. Add this guard without embedding the forbidden literal contiguously:

```powershell
  It 'uses TestDrive for every repository fixture' {
    $forbiddenRoot = 'C:' + [IO.Path]::DirectorySeparatorChar + 'repo'
    (Get-Content -Raw -LiteralPath $PSCommandPath) | Should Not Match ([regex]::Escape($forbiddenRoot))
  }
```

Add tests near existing deploy-dev tests:

```powershell
  It 'records the Traffic/Weather lineage overlay in the deployment lock' {
    $fixture = New-TestDeploymentLock -Name 'lock-overlay'
    $root = $fixture.RootPath
    $lock = $fixture.Lock
    $overlay = Join-Path $root 'docker-compose.traffic-weather-lineage.yml'

    $lock.schema_version | Should Be 2
    $lock.lineage_overlay_path | Should Be $overlay
    $lock.lineage_overlay_sha256 | Should Match '^[0-9a-f]{64}$'
    @($lock.compose_files).Count | Should Be 3
    @($lock.compose_files)[0] | Should Be (Join-Path $root 'docker-compose.yml')
    @($lock.compose_files)[1] | Should Be $overlay
    @($lock.compose_files)[2] | Should Be $lock.compose_override_path
  }

  It 'fails deployment lock creation when the required lineage overlay is missing' {
    $root = Join-Path $TestDrive 'missing-overlay'
    New-Item -ItemType Directory -Path (Join-Path $root '.runtime\dev') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'docker-compose.yml') -Value 'services: {}' -Encoding UTF8

    Assert-TestThrows -Pattern 'required file missing for sha256 fingerprint.*docker-compose\.traffic-weather-lineage\.yml' -ScriptBlock {
      New-DeploymentLock -RootPath $root -DagSha ('a' * 40) -DbtSha ('b' * 40)
    }
  }

  It 'runs docker compose with base, lineage overlay, then generated override' {
    $fixture = New-TestDeploymentLock -Name 'compose-order'
    $lock = $fixture.Lock
    Mock Invoke-DevHarnessExternal {
      param([string]$FilePath, [string[]]$Arguments)
      $Arguments -join ' '
    } -ModuleName DevDeployHarness

    $output = Invoke-DevDockerCompose -RootPath $fixture.RootPath -Lock $lock -Arguments @('config', '--quiet')

    $expected = "compose -f $($lock.compose_files[0]) -f $($lock.compose_files[1]) -f $($lock.compose_files[2]) config --quiet"
    ($output -join ' ') | Should Match ([regex]::Escape($expected))
  }
```

Update the existing string assertion around `scripts/tests/DevDeployHarness.Tests.ps1:278` so it still looks for:

```powershell
Invoke-DevDockerCompose -RootPath `$root -Lock `$lock -Arguments @('up', '-d', '--build', '--wait')
```

and add an assertion that `deploy-dev.ps1 -WhatIf` prints `WhatIf: lineage overlay`.

- [ ] **Step 2: Run Pester and verify it fails**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path scripts/tests/DevDeployHarness.Tests.ps1 -Output Detailed"
```

Expected: FAIL because lock is still `schema_version=1`, lacks overlay fields, and `Invoke-DevDockerCompose` uses only two `-f` files.

- [ ] **Step 3: Implement helper functions and lock fields**

Add near the top of `scripts/lib/DevDeployHarness.psm1`:

```powershell
$script:TrafficWeatherLineageOverlay = 'docker-compose.traffic-weather-lineage.yml'
```

Add before `New-DeploymentLock`:

```powershell
function Get-DevFileSha256 {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "required file missing for sha256 fingerprint: $Path"
  }

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DevComposeFileArguments {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    $Lock
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
  $composeFiles = @(
    (Join-Path $root 'docker-compose.yml'),
    $Lock.lineage_overlay_path,
    $Lock.compose_override_path
  )

  $arguments = @()
  foreach ($composeFile in $composeFiles) {
    $arguments += @('-f', $composeFile)
  }
  return $arguments
}
```

Modify `New-DeploymentLock` return object:

```powershell
  $overlayPath = Join-Path $root $script:TrafficWeatherLineageOverlay
  $generatedOverridePath = Join-Path $runtime 'docker-compose.generated.yml'

  return [ordered]@{
    schema_version = 2
    requested_ref = 'origin/dev'
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    dags = [ordered]@{
      sha = $DagSha
      worktree_path = (Join-Path $runtime 'dags')
    }
    dbt = [ordered]@{
      sha = $DbtSha
      worktree_path = (Join-Path $runtime 'dbt')
    }
    deployment_lock_path = (Join-Path $runtime 'deployment-lock.json')
    compose_override_path = $generatedOverridePath
    lineage_overlay_path = $overlayPath
    lineage_overlay_sha256 = (Get-DevFileSha256 -Path $overlayPath)
    compose_files = @(
      (Join-Path $root 'docker-compose.yml'),
      $overlayPath,
      $generatedOverridePath
    )
    required_dbt_project = '/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml'
  }
```

Modify `Invoke-DevDockerCompose`:

```powershell
  $root = Normalize-DevHarnessPath -Path $RootPath
  $composeArgs = (Get-DevComposeFileArguments -RootPath $root -Lock $Lock) + $Arguments
```

Export new helpers by adding to `Export-ModuleMember`:

```powershell
  'Get-DevFileSha256',
  'Get-DevComposeFileArguments',
```

- [ ] **Step 4: Update deploy-dev non-secret output**

Modify `scripts/deploy-dev.ps1` `-WhatIf` block:

```powershell
  Write-Output "WhatIf: lineage overlay $($lock.lineage_overlay_path)"
  Write-Output "WhatIf: lineage overlay sha256 $($lock.lineage_overlay_sha256)"
```

Modify success block:

```powershell
  Write-Output "lineage overlay $($lock.lineage_overlay_path)"
  Write-Output "lineage overlay sha256 $($lock.lineage_overlay_sha256)"
```

- [ ] **Step 5: Run Pester task tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path scripts/tests/DevDeployHarness.Tests.ps1 -Output Detailed"
```

Expected: PASS for lock fingerprint, compose file order, and existing deploy-dev origin/dev tests.

- [ ] **Step 6: Commit Task 3**

```powershell
git add scripts/lib/DevDeployHarness.psm1 scripts/deploy-dev.ps1 scripts/tests/DevDeployHarness.Tests.ps1
git commit -m "fix(deploy): include Traffic Weather lineage overlay in locked dev compose"
```

Expected: commit succeeds after explicit user approval for committing.

### Task 4: Deployment Verifier Checks Marquez, Overlay Env, Pools, Compose Labels

**Files:**
- Modify: `scripts/lib/DevDeployHarness.psm1:434-615`
- Modify: `scripts/verify-dev-deploy.ps1:14-26`
- Test: `scripts/tests/DevDeployHarness.Tests.ps1:445-505`

**Interfaces:**
- Consumes:
  - `Invoke-DevDockerCompose -Arguments @('ps', '-aq', <service>)`, including completed `airflow-init`.
  - `docker inspect` service labels/state/memory/restart count.
  - `Invoke-DevSchedulerCommand`.
- Produces:
  - Mandatory evidence keys `CurrentLineageOverlaySha256`, `ComposeLabels`, `SchedulerLineageChecks`, `AirflowPools`, `MarquezRuntime`, `MarquezEndpointChecks`.
  - Assertion failures for current overlay fingerprint drift, missing Marquez/DNS, false scheduler lineage checks, wrong pool slots, wrong ordered exact normalized 3-file labels, wrong Marquez memory/restart/OOM state.

- [ ] **Step 1: Write failing verifier tests**

Add `New-TestComposeLabels` and extend `New-TestRunningDeploymentArgs` with valid mandatory evidence defaults:

```powershell
function New-TestComposeLabels {
  param([Parameter(Mandatory = $true)]$Lock)
  $value = (@($Lock.compose_files) -join ',')
  $labels = @{}
  foreach ($service in @(
    'postgres', 'marquez-db', 'marquez-api', 'marquez-web', 'trino',
    'airflow-init', 'airflow-apiserver', 'airflow-scheduler',
    'airflow-dag-processor', 'airflow-triggerer'
  )) {
    $labels[$service] = @{
      'com.docker.compose.project.config_files' = $value
    }
  }
  return $labels
}

function New-TestRunningDeploymentArgs {
  param([Parameter(Mandatory = $true)]$Lock)
  $schedulerChecks = @{}
  foreach ($key in @(
    'AIRFLOW__OPENLINEAGE__TRANSPORT',
    'AIRFLOW__OPENLINEAGE__NAMESPACE',
    'AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE',
    'AIRFLOW__OPENLINEAGE__DISABLE_SOURCE_CODE',
    'AIRFLOW__OPENLINEAGE__INCLUDE_FULL_TASK_INFO',
    'AIRFLOW__OPENLINEAGE__DEBUG_MODE',
    'ASK_SEOUL_DBT_OPENLINEAGE_ENABLED',
    'ASK_SEOUL_DBT_OPENLINEAGE_URL',
    'ASK_SEOUL_DBT_OPENLINEAGE_ENDPOINT',
    'ASK_SEOUL_DBT_OPENLINEAGE_NAMESPACE'
  )) {
    $schedulerChecks[$key] = $true
  }

  return @{
    Lock = $Lock
    ServiceMounts = New-TestServiceMounts -Lock $Lock
    RuntimeGitHeads = @{ dags = $Lock.dags.sha; dbt = $Lock.dbt.sha }
    RequiredDbtProjectExists = $true
    ServiceHealth = @{ 'airflow-apiserver' = 'healthy'; 'airflow-scheduler' = 'healthy' }
    CurrentLineageOverlaySha256 = $Lock.lineage_overlay_sha256
    ComposeLabels = New-TestComposeLabels -Lock $Lock
    SchedulerLineageChecks = $schedulerChecks
    AirflowPools = @{ trino_traffic_heavy = 1; trino_weather_heavy = 1; trino_heavy = 1 }
    MarquezRuntime = @{
      'marquez-db' = @{ Status = 'running'; Health = 'healthy'; Memory = 536870912L; RestartPolicy = 'unless-stopped'; RestartCount = 0; OOMKilled = $false }
      'marquez-api' = @{ Status = 'running'; Health = 'healthy'; Memory = 1610612736L; RestartPolicy = 'unless-stopped'; RestartCount = 0; OOMKilled = $false }
      'marquez-web' = @{ Status = 'running'; Health = ''; Memory = 268435456L; RestartPolicy = 'unless-stopped'; RestartCount = 0; OOMKilled = $false }
    }
    MarquezEndpointChecks = @{ Dns = $true; AdminHttpStatus = 200; MetadataHttpStatus = 200 }
  }
}
```

Add the failing cases below. Every case uses `New-TestDeploymentLock`, and all pre-existing direct `Assert-RunningDeployment` calls are converted to `New-TestRunningDeploymentArgs` plus mutation of only the evidence under test; this is required because every new evidence parameter is mandatory.

```powershell
  It 'rejects a changed current lineage overlay fingerprint' {
    $fixture = New-TestDeploymentLock -Name 'overlay-drift'
    $lock = $fixture.Lock
    Set-Content -LiteralPath $lock.lineage_overlay_path -Value 'services: { changed: {} }' -Encoding UTF8
    $args = New-TestRunningDeploymentArgs -Lock $lock
    $args.CurrentLineageOverlaySha256 = Get-DevFileSha256 -Path $lock.lineage_overlay_path

    Assert-TestThrows -Pattern 'lineage overlay sha256 mismatch' -ScriptBlock {
      Assert-RunningDeployment @args
    }
  }

  It 'rejects reordered compose config file labels' {
    $fixture = New-TestDeploymentLock -Name 'labels-reordered'
    $lock = $fixture.Lock
    $args = New-TestRunningDeploymentArgs -Lock $lock
    $args.ComposeLabels['airflow-scheduler']['com.docker.compose.project.config_files'] = @(
      $lock.compose_files[1], $lock.compose_files[0], $lock.compose_files[2]
    ) -join ','

    Assert-TestThrows -Pattern 'compose file set mismatch.*airflow-scheduler.*index 0' -ScriptBlock {
      Assert-RunningDeployment @args
    }
  }

  It 'rejects a false scheduler lineage boolean without retaining raw env' {
    $fixture = New-TestDeploymentLock -Name 'scheduler-check'
    $lock = $fixture.Lock
    $args = New-TestRunningDeploymentArgs -Lock $lock
    $args.SchedulerLineageChecks['AIRFLOW__OPENLINEAGE__NAMESPACE'] = $false

    Assert-TestThrows -Pattern 'scheduler lineage check failed.*AIRFLOW__OPENLINEAGE__NAMESPACE' -ScriptBlock {
      Assert-RunningDeployment @args
    }
  }

  It 'rejects a missing Weather pool slot' {
    $fixture = New-TestDeploymentLock -Name 'pool-slot'
    $args = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $args.AirflowPools['trino_weather_heavy'] = 0

    Assert-TestThrows -Pattern 'Airflow pool.*trino_weather_heavy.*expected 1.*got 0' -ScriptBlock {
      Assert-RunningDeployment @args
    }
  }

  It 'rejects a wrong Marquez memory cap restart policy count or OOM state' {
    $fixture = New-TestDeploymentLock -Name 'marquez-runtime'
    $args = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $args.MarquezRuntime['marquez-api'].Memory = 0L
    $args.MarquezRuntime['marquez-api'].RestartPolicy = 'no'
    $args.MarquezRuntime['marquez-api'].RestartCount = 1
    $args.MarquezRuntime['marquez-api'].OOMKilled = $true

    Assert-TestThrows -Pattern 'Marquez marquez-api memory expected 1610612736 bytes, got 0' -ScriptBlock {
      Assert-RunningDeployment @args
    }
  }

  It 'passes every mandatory evidence argument for legacy SHA assertions' {
    $fixture = New-TestDeploymentLock -Name 'legacy-dag-sha'
    $args = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $args.RuntimeGitHeads.dags = ('c' * 40)

    Assert-TestThrows -Pattern 'DAG.*SHA.*mismatch' -ScriptBlock {
      Assert-RunningDeployment @args
    }
  }
```

- [ ] **Step 2: Run verifier tests and verify they fail**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path scripts/tests/DevDeployHarness.Tests.ps1 -Output Detailed"
```

Expected: FAIL because `Assert-RunningDeployment` does not accept or check the new evidence keys.

- [ ] **Step 3: Implement assertion helpers**

Add these functions before `Assert-RunningDeployment`:

```powershell
function Assert-CurrentLineageOverlayFingerprint {
  param(
    [Parameter(Mandatory = $true)]$Lock,
    [Parameter(Mandatory = $true)][string]$CurrentLineageOverlaySha256
  )
  if ($CurrentLineageOverlaySha256 -ne $Lock.lineage_overlay_sha256) {
    throw "lineage overlay sha256 mismatch: lock $($Lock.lineage_overlay_sha256), current $CurrentLineageOverlaySha256"
  }
}

function Assert-DeploymentComposeLabels {
  param(
    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [hashtable]$ComposeLabels
  )

  $expected = @($Lock.compose_files | ForEach-Object { Normalize-DevHarnessPath -Path $_ })
  if ($expected.Count -ne 3) {
    throw "deployment lock compose_files expected exactly 3 entries, got $($expected.Count)"
  }
  foreach ($service in $script:DeploymentComposeLabelServices) {
    if (-not $ComposeLabels.ContainsKey($service)) {
      throw "compose labels missing for service $service"
    }
    $actual = @(([string]$ComposeLabels[$service]['com.docker.compose.project.config_files'] -split ',') |
      ForEach-Object { Normalize-DevHarnessPath -Path $_.Trim() })
    if ($actual.Count -ne 3) {
      throw "compose file set mismatch for $service`: expected exactly 3 entries, got $($actual.Count)"
    }
    for ($index = 0; $index -lt 3; $index++) {
      if ($actual[$index] -ne $expected[$index]) {
        throw "compose file set mismatch for $service at index $index`: expected $($expected[$index]), got $($actual[$index])"
      }
    }
  }
}

function Assert-SchedulerLineageChecks {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$SchedulerLineageChecks
  )

  foreach ($key in @(
    'AIRFLOW__OPENLINEAGE__TRANSPORT', 'AIRFLOW__OPENLINEAGE__NAMESPACE',
    'AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE', 'AIRFLOW__OPENLINEAGE__DISABLE_SOURCE_CODE',
    'AIRFLOW__OPENLINEAGE__INCLUDE_FULL_TASK_INFO', 'AIRFLOW__OPENLINEAGE__DEBUG_MODE',
    'ASK_SEOUL_DBT_OPENLINEAGE_ENABLED', 'ASK_SEOUL_DBT_OPENLINEAGE_URL',
    'ASK_SEOUL_DBT_OPENLINEAGE_ENDPOINT', 'ASK_SEOUL_DBT_OPENLINEAGE_NAMESPACE'
  )) {
    if (-not $SchedulerLineageChecks.ContainsKey($key) -or $SchedulerLineageChecks[$key] -ne $true) {
      throw "scheduler lineage check failed for $key"
    }
  }
}

function Assert-AirflowPools {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$AirflowPools
  )

  foreach ($poolName in 'trino_traffic_heavy', 'trino_weather_heavy', 'trino_heavy') {
    if (-not $AirflowPools.ContainsKey($poolName)) {
      throw "Airflow pool missing: $poolName"
    }
    if ([int]$AirflowPools[$poolName] -ne 1) {
      throw "Airflow pool $poolName expected 1 slot, got $($AirflowPools[$poolName])"
    }
  }
}

function Assert-MarquezDeploymentRuntime {
  param(
    [Parameter(Mandatory = $true)][hashtable]$MarquezRuntime,
    [Parameter(Mandatory = $true)][hashtable]$MarquezEndpointChecks
  )

  $expectedMemory = @{ 'marquez-db' = 536870912L; 'marquez-api' = 1610612736L; 'marquez-web' = 268435456L }
  foreach ($service in $expectedMemory.Keys) {
    $runtime = $MarquezRuntime[$service]
    if ($runtime.Status -ne 'running') { throw "Marquez $service status expected running, got $($runtime.Status)" }
    if ($service -ne 'marquez-web' -and $runtime.Health -ne 'healthy') { throw "Marquez $service health expected healthy, got $($runtime.Health)" }
    if ([int64]$runtime.Memory -ne $expectedMemory[$service]) { throw "Marquez $service memory expected $($expectedMemory[$service]) bytes, got $($runtime.Memory)" }
    if ($runtime.RestartPolicy -ne 'unless-stopped') { throw "Marquez $service RestartPolicy expected unless-stopped, got $($runtime.RestartPolicy)" }
    if ([int]$runtime.RestartCount -ne 0) { throw "Marquez $service RestartCount expected 0, got $($runtime.RestartCount)" }
    if ([bool]$runtime.OOMKilled) { throw "Marquez $service OOMKilled must be false" }
  }
  if ($MarquezEndpointChecks.Dns -ne $true) {
    throw 'Marquez DNS missing in airflow-scheduler'
  }
  if ([int]$MarquezEndpointChecks.AdminHttpStatus -ne 200) {
    throw "Marquez admin healthcheck expected HTTP 200, got $($MarquezEndpointChecks.AdminHttpStatus)"
  }
  if ([int]$MarquezEndpointChecks.MetadataHttpStatus -ne 200) {
    throw "Marquez metadata API expected HTTP 200, got $($MarquezEndpointChecks.MetadataHttpStatus)"
  }
}
```

Modify `Assert-RunningDeployment` signature and body:

```powershell
    [Parameter(Mandatory = $true)]
    [string]$CurrentLineageOverlaySha256,

    [Parameter(Mandatory = $true)]
    [hashtable]$ComposeLabels,

    [Parameter(Mandatory = $true)]
    [hashtable]$SchedulerLineageChecks,

    [Parameter(Mandatory = $true)]
    [hashtable]$AirflowPools,

    [Parameter(Mandatory = $true)]
    [hashtable]$MarquezRuntime,

    [Parameter(Mandatory = $true)]
    [hashtable]$MarquezEndpointChecks
```

Call after existing Airflow service health checks:

```powershell
  Assert-CurrentLineageOverlayFingerprint -Lock $Lock -CurrentLineageOverlaySha256 $CurrentLineageOverlaySha256
  Assert-DeploymentComposeLabels -Lock $Lock -ComposeLabels $ComposeLabels
  Assert-SchedulerLineageChecks -SchedulerLineageChecks $SchedulerLineageChecks
  Assert-AirflowPools -AirflowPools $AirflowPools
  Assert-MarquezDeploymentRuntime -MarquezRuntime $MarquezRuntime -MarquezEndpointChecks $MarquezEndpointChecks
```

- [ ] **Step 4: Implement runtime evidence collection**

Add helper functions:

```powershell
function Get-DevDockerServiceLabels {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    $Lock,
    [Parameter(Mandatory = $true)]
    [string]$Service
  )

  # -a is required for the successfully completed airflow-init one-shot container.
  $containerId = (Invoke-DevDockerCompose -RootPath $RootPath -Lock $Lock -Arguments @('ps', '-aq', $Service) | Select-Object -First 1).Trim()
  if (-not $containerId) {
    throw "container id missing for service $Service"
  }
  $json = (Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{json .Config.Labels}}') | Select-Object -First 1)
  return @{} + ($json | ConvertFrom-Json -AsHashtable)
}

function Get-DevSchedulerLineageChecks {
  param([string]$RootPath, $Lock)
  $expectedPairs = @(
    'AIRFLOW__OPENLINEAGE__TRANSPORT', '{"type": "http", "url": "http://marquez-api:5000", "endpoint": "api/v1/lineage"}',
    'AIRFLOW__OPENLINEAGE__NAMESPACE', 'ask-seoul-dev-airflow',
    'AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE', 'true',
    'AIRFLOW__OPENLINEAGE__DISABLE_SOURCE_CODE', 'true',
    'AIRFLOW__OPENLINEAGE__INCLUDE_FULL_TASK_INFO', 'false',
    'AIRFLOW__OPENLINEAGE__DEBUG_MODE', 'false',
    'ASK_SEOUL_DBT_OPENLINEAGE_ENABLED', 'true',
    'ASK_SEOUL_DBT_OPENLINEAGE_URL', 'http://marquez-api:5000',
    'ASK_SEOUL_DBT_OPENLINEAGE_ENDPOINT', 'api/v1/lineage',
    'ASK_SEOUL_DBT_OPENLINEAGE_NAMESPACE', 'ask-seoul-dev-dbt'
  )
  $script = 'while [ "$#" -gt 0 ]; do key="$1"; expected="$2"; shift 2; if [ "$(printenv "$key")" = "$expected" ]; then printf "%s=true\n" "$key"; else printf "%s=false\n" "$key"; fi; done'
  $lines = Invoke-DevSchedulerCommand -RootPath $RootPath -Lock $Lock -Command (@('sh', '-c', $script, '--') + $expectedPairs)
  $checks = @{}
  foreach ($line in $lines) {
    $name, $value = $line -split '=', 2
    $checks[$name] = ($value -eq 'true')
  }
  return $checks
}

function Get-DevAirflowPools {
  param([string]$RootPath, $Lock)
  $raw = @(Invoke-DevSchedulerCommand -RootPath $RootPath -Lock $Lock -Command @('airflow', 'pools', 'list', '--output', 'json')) -join "`n"
  $arrayStarts = [regex]::Matches($raw, '(?m)^\s*\[')
  if ($arrayStarts.Count -eq 0) {
    throw 'Airflow pools output did not contain a JSON array'
  }
  $json = $raw.Substring($arrayStarts[$arrayStarts.Count - 1].Index).Trim()
  $rows = @($json | ConvertFrom-Json)
  $pools = @{}
  foreach ($row in $rows) {
    if ($row.pool -in @('trino_traffic_heavy', 'trino_weather_heavy', 'trino_heavy')) {
      $pools[[string]$row.pool] = [int]$row.slots
    }
  }
  return $pools
}

function Get-DevMarquezRuntime {
  param([string]$RootPath, $Lock)
  $evidence = @{}
  foreach ($service in 'marquez-db', 'marquez-api', 'marquez-web') {
    $containerId = (Invoke-DevDockerCompose -RootPath $RootPath -Lock $Lock -Arguments @('ps', '-aq', $service) | Select-Object -First 1).Trim()
    $state = ((Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{json .State}}') | Select-Object -First 1) | ConvertFrom-Json -AsHashtable)
    $evidence[$service] = @{
      Status = [string]$state.Status
      Health = if ($state.Health) { [string]$state.Health.Status } else { '' }
      Memory = [int64]((Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{.HostConfig.Memory}}') | Select-Object -First 1).Trim())
      RestartPolicy = [string]((Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{.HostConfig.RestartPolicy.Name}}') | Select-Object -First 1).Trim())
      RestartCount = [int]((Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{.RestartCount}}') | Select-Object -First 1).Trim())
      OOMKilled = [bool]$state.OOMKilled
    }
  }
  return $evidence
}

function Get-DevMarquezEndpointChecks {
  param([string]$RootPath, $Lock)
  $dns = (Invoke-DevSchedulerCommand -RootPath $RootPath -Lock $Lock -Command @('sh', '-c', 'getent hosts marquez-api >/dev/null && printf true || printf false') | Select-Object -First 1).Trim()
  return @{
    Dns = ($dns -eq 'true')
    AdminHttpStatus = [int]((Invoke-DevHarnessExternal -FilePath 'curl' -Arguments @('-sS', '-o', 'NUL', '-w', '%{http_code}', 'http://127.0.0.1:5001/healthcheck') | Select-Object -First 1).Trim())
    MetadataHttpStatus = [int]((Invoke-DevHarnessExternal -FilePath 'curl' -Arguments @('-sS', '-o', 'NUL', '-w', '%{http_code}', 'http://127.0.0.1:5000/api/v1/namespaces') | Select-Object -First 1).Trim())
  }
}
```

In `Get-RunningDeploymentEvidence`, populate:

```powershell
    CurrentLineageOverlaySha256 = Get-DevFileSha256 -Path $Lock.lineage_overlay_path
    ComposeLabels = $composeLabels
    SchedulerLineageChecks = Get-DevSchedulerLineageChecks -RootPath $RootPath -Lock $Lock
    AirflowPools = Get-DevAirflowPools -RootPath $RootPath -Lock $Lock
    MarquezRuntime = Get-DevMarquezRuntime -RootPath $RootPath -Lock $Lock
    MarquezEndpointChecks = Get-DevMarquezEndpointChecks -RootPath $RootPath -Lock $Lock
```

Build `$composeLabels` by looping over `$script:DeploymentComposeLabelServices`, defined as the exact service list used in `New-TestComposeLabels`. `Get-DevDockerServiceLabels` must use `docker compose ps -aq <service>` so the completed `airflow-init` label is included.

- [ ] **Step 5: Update verify-dev-deploy parameter passing and output**

Modify `scripts/verify-dev-deploy.ps1`:

```powershell
Assert-RunningDeployment `
  -Lock $lock `
  -ServiceMounts $evidence.ServiceMounts `
  -RuntimeGitHeads $evidence.RuntimeGitHeads `
  -RequiredDbtProjectExists $evidence.RequiredDbtProjectExists `
  -ServiceHealth $evidence.ServiceHealth `
  -CurrentLineageOverlaySha256 $evidence.CurrentLineageOverlaySha256 `
  -ComposeLabels $evidence.ComposeLabels `
  -SchedulerLineageChecks $evidence.SchedulerLineageChecks `
  -AirflowPools $evidence.AirflowPools `
  -MarquezRuntime $evidence.MarquezRuntime `
  -MarquezEndpointChecks $evidence.MarquezEndpointChecks
```

Append non-secret output:

```powershell
Write-Output "lineage overlay $($lock.lineage_overlay_path)"
Write-Output "lineage overlay fingerprint verified $($evidence.CurrentLineageOverlaySha256)"
foreach ($service in 'marquez-db', 'marquez-api', 'marquez-web') {
  $runtime = $evidence.MarquezRuntime[$service]
  Write-Output "$service status=$($runtime.Status) health=$($runtime.Health) memory=$($runtime.Memory) restartPolicy=$($runtime.RestartPolicy) restartCount=$($runtime.RestartCount) oomKilled=$($runtime.OOMKilled)"
}
Write-Output "marquez dns $($evidence.MarquezEndpointChecks.Dns)"
Write-Output "trino_traffic_heavy $($evidence.AirflowPools['trino_traffic_heavy'])"
Write-Output "trino_weather_heavy $($evidence.AirflowPools['trino_weather_heavy'])"
```

- [ ] **Step 6: Run verifier tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path scripts/tests/DevDeployHarness.Tests.ps1 -Output Detailed"
```

Expected: PASS. Existing tests for mount/SHA verification, mutex, origin/dev literal, and scheduler failure still pass.

- [ ] **Step 7: Commit Task 4**

```powershell
git add scripts/lib/DevDeployHarness.psm1 scripts/verify-dev-deploy.ps1 scripts/tests/DevDeployHarness.Tests.ps1
git commit -m "fix(deploy): verify lineage backend and domain pool runtime evidence"
```

Expected: commit succeeds after explicit user approval for committing.

### Task 5: Stage2 Trino Hard-Concurrency Canary Overlay

**Files:**
- Create: `trino/resource-groups.canary-hard2.json`
- Create: `docker-compose.trino-hard2-canary.yml`
- Modify: `scripts/tests/test_trino_runtime_hardening.py:51-85`
- Modify: `.env.example:50-56`

**Interfaces:**
- Consumes: default `trino/resource-groups.properties` points to `/etc/trino/resource-groups.json`.
- Produces:
  - Stage1 default keeps `trino/resource-groups.json` with `hardConcurrencyLimit=1`.
  - Stage2 canary overlay replaces the mounted resource group JSON and sets query caps, heap headroom, and task concurrency through dedicated `TRINO_CANARY_*` interpolation variables only.

- [ ] **Step 1: Write failing Stage2 canary tests**

Add to `scripts/tests/test_trino_runtime_hardening.py`:

```python
    def test_canary_resource_group_allows_two_running_queries(self):
        resource_groups = ROOT / "trino/resource-groups.canary-hard2.json"
        self.assertTrue(resource_groups.exists(), "canary resource group file must exist")
        data = json.loads(resource_groups.read_text(encoding="utf-8"))
        self.assertEqual(1, len(data["rootGroups"]))
        group = data["rootGroups"][0]
        self.assertEqual("global", group["name"])
        self.assertEqual(2, group["hardConcurrencyLimit"])
        self.assertEqual(100, group["maxQueued"])
        self.assertEqual("80%", group["softMemoryLimit"])
        self.assertEqual([{"user": ".*", "group": "global"}], data["selectors"])

    def test_canary_overlay_is_explicit_and_uses_reduced_query_memory(self):
        overlay = ROOT / "docker-compose.trino-hard2-canary.yml"
        self.assertTrue(overlay.exists(), "canary overlay must exist")
        text = overlay.read_text(encoding="utf-8")
        self.assertIn(
            "./trino/resource-groups.canary-hard2.json:/etc/trino/resource-groups.json:ro",
            text,
        )
        self.assertIn(
            "TRINO_QUERY_MAX_MEMORY_PER_NODE: ${TRINO_CANARY_QUERY_MAX_MEMORY_PER_NODE:-1280MB}",
            text,
        )
        self.assertIn(
            "TRINO_QUERY_MAX_MEMORY: ${TRINO_CANARY_QUERY_MAX_MEMORY:-1280MB}",
            text,
        )
        self.assertIn(
            "TRINO_QUERY_MAX_TOTAL_MEMORY: ${TRINO_CANARY_QUERY_MAX_TOTAL_MEMORY:-2560MB}",
            text,
        )
        self.assertIn(
            "TRINO_MEMORY_HEAP_HEADROOM_PER_NODE: ${TRINO_CANARY_MEMORY_HEAP_HEADROOM_PER_NODE:-2GB}",
            text,
        )
        self.assertIn(
            "TRINO_TASK_CONCURRENCY: ${TRINO_CANARY_TASK_CONCURRENCY:-2}",
            text,
        )
        self.assertNotIn("${TRINO_QUERY_MAX_MEMORY_PER_NODE:-", text)
        self.assertNotIn("${TRINO_QUERY_MAX_MEMORY:-", text)
        self.assertNotIn("${TRINO_QUERY_MAX_TOTAL_MEMORY:-", text)
        self.assertNotIn("${TRINO_MEMORY_HEAP_HEADROOM_PER_NODE:-", text)
        self.assertNotIn("${TRINO_TASK_CONCURRENCY:-", text)
        self.assertNotIn("docker-compose.trino-hard2-canary.yml", self.compose)
```

Update `test_safe_defaults_are_documented` to keep Stage1 defaults unchanged and add documentation fragments:

```python
        canary_docs = {
            "# Stage2 canary only: TRINO_CANARY_QUERY_MAX_MEMORY_PER_NODE=1280MB",
            "# Stage2 canary only: TRINO_CANARY_QUERY_MAX_MEMORY=1280MB",
            "# Stage2 canary only: TRINO_CANARY_QUERY_MAX_TOTAL_MEMORY=2560MB",
            "# Stage2 canary only: TRINO_CANARY_MEMORY_HEAP_HEADROOM_PER_NODE=2GB",
            "# Stage2 canary only: TRINO_CANARY_TASK_CONCURRENCY=2",
        }
        self.assertTrue(canary_docs.issubset(set(self.env_example.splitlines())))
```

- [ ] **Step 2: Run canary tests and verify they fail**

Run:

```powershell
python -m unittest scripts.tests.test_trino_runtime_hardening -v
```

Expected: FAIL because canary JSON/overlay and `.env.example` comments do not exist.

- [ ] **Step 3: Create Stage2 canary resource group file**

Create `trino/resource-groups.canary-hard2.json`:

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 2,
      "maxQueued": 100,
      "schedulingPolicy": "fair",
      "jmxExport": true
    }
  ],
  "selectors": [
    {"user": ".*", "group": "global"}
  ]
}
```

- [ ] **Step 4: Create explicit canary overlay**

Create `docker-compose.trino-hard2-canary.yml`:

```yaml
# Stage2 Trino hard-concurrency canary.
# Use only with an explicit docker compose -f argument after Stage1 fairness is verified.
services:
  trino:
    environment:
      TRINO_QUERY_MAX_MEMORY_PER_NODE: ${TRINO_CANARY_QUERY_MAX_MEMORY_PER_NODE:-1280MB}
      TRINO_QUERY_MAX_MEMORY: ${TRINO_CANARY_QUERY_MAX_MEMORY:-1280MB}
      TRINO_QUERY_MAX_TOTAL_MEMORY: ${TRINO_CANARY_QUERY_MAX_TOTAL_MEMORY:-2560MB}
      TRINO_MEMORY_HEAP_HEADROOM_PER_NODE: ${TRINO_CANARY_MEMORY_HEAP_HEADROOM_PER_NODE:-2GB}
      TRINO_TASK_CONCURRENCY: ${TRINO_CANARY_TASK_CONCURRENCY:-2}
    volumes:
      - ./trino/resource-groups.canary-hard2.json:/etc/trino/resource-groups.json:ro
```

- [ ] **Step 5: Document canary env comments without changing Stage1 defaults**

Append under `.env.example:50-56`:

```dotenv
# Stage2 canary only: TRINO_CANARY_QUERY_MAX_MEMORY_PER_NODE=1280MB
# Stage2 canary only: TRINO_CANARY_QUERY_MAX_MEMORY=1280MB
# Stage2 canary only: TRINO_CANARY_QUERY_MAX_TOTAL_MEMORY=2560MB
# Stage2 canary only: TRINO_CANARY_MEMORY_HEAP_HEADROOM_PER_NODE=2GB
# Stage2 canary only: TRINO_CANARY_TASK_CONCURRENCY=2
```

- [ ] **Step 6: Run Trino hardening tests**

Run:

```powershell
python -m unittest scripts.tests.test_trino_runtime_hardening -v
```

Expected: PASS. Default `trino/resource-groups.json` still asserts `hardConcurrencyLimit=1`; canary file asserts `hardConcurrencyLimit=2`; rendered canary uses `1280MB/1280MB/2560MB`, `2GB` headroom, task concurrency `2`, and no base `TRINO_*` interpolation variable.

- [ ] **Step 7: Commit Task 5**

```powershell
git add trino/resource-groups.canary-hard2.json docker-compose.trino-hard2-canary.yml .env.example scripts/tests/test_trino_runtime_hardening.py
git commit -m "feat(trino): add explicit hard concurrency canary overlay"
```

Expected: commit succeeds after explicit user approval for committing.

### Task 6: Documentation And Operator Commands

**Files:**
- Modify: `docs/traffic-weather-lineage.md`
- Modify: `docs/agent/workflows/revision-locked-dev-deploy.md`
- Modify: `README.md`
- Test: `scripts/tests/DevDeployHarness.Tests.ps1:319-346`
- Test: `scripts/tests/test_traffic_weather_lineage_overlay.py:263-300`

**Interfaces:**
- Consumes: new deploy compose set and Stage2 canary overlay.
- Produces: Korean docs that explain normal deploy, verify evidence, Stage2 canary entry/stop rules, and root/submodule boundary.

- [ ] **Step 1: Write failing docs assertions**

In `scripts/tests/DevDeployHarness.Tests.ps1`, extend the workflow doc test to require:

```powershell
    $workflow | Should Match 'docker-compose\.traffic-weather-lineage\.yml'
    $workflow | Should Match 'marquez-api'
    $workflow | Should Match 'trino_traffic_heavy'
    $workflow | Should Match 'trino_weather_heavy'
    $workflow | Should Match 'docker-compose\.trino-hard2-canary\.yml'
```

In `scripts/tests/test_traffic_weather_lineage_overlay.py`, extend `required_fragments`:

```python
            "Marquez always-on",
            "SEARCH_ENABLED=false",
            "trino_traffic_heavy",
            "trino_weather_heavy",
            "docker-compose.trino-hard2-canary.yml",
            "hardConcurrencyLimit=1",
            "hardConcurrencyLimit=2",
```

- [ ] **Step 2: Run docs tests and verify they fail**

Run:

```powershell
python -m unittest scripts.tests.test_traffic_weather_lineage_overlay.TrafficWeatherLineageOverlayTest.test_korean_guide_documents_usage_and_domain_boundary -v
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path scripts/tests/DevDeployHarness.Tests.ps1 -Output Detailed"
```

Expected: FAIL because docs do not mention always-on Marquez, domain pools, or canary overlay yet.

- [ ] **Step 3: Update `docs/traffic-weather-lineage.md`**

Add a Korean section with these exact command snippets:

```markdown
## local dev deploy 계약

Marquez always-on: `docker-compose.yml`의 `marquez-db`, `marquez-api`, `marquez-web`은 profile 없이 항상 기동한다. `marquez-api`는 `SEARCH_ENABLED=false`로 optional OpenSearch를 사용하지 않고, admin `/healthcheck`가 deployment health 기준이다.

기본 deploy는 다음 3-file compose set을 사용한다.

```powershell
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml -f .runtime/dev/docker-compose.generated.yml config --quiet
pwsh -File scripts/deploy-dev.ps1
pwsh -File scripts/verify-dev-deploy.ps1
```

Stage1 기본값은 `trino/resource-groups.json`의 `hardConcurrencyLimit=1`이다. Stage2 canary는 Stage1 fairness 검증 후에만 다음 overlay를 명시적으로 추가한다.

```powershell
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml -f .runtime/dev/docker-compose.generated.yml -f docker-compose.trino-hard2-canary.yml config --quiet
```

Stage2 canary는 `hardConcurrencyLimit=2`, `TRINO_QUERY_MAX_MEMORY_PER_NODE=1280MB`, `TRINO_QUERY_MAX_MEMORY=1280MB`, `TRINO_QUERY_MAX_TOTAL_MEMORY=2560MB`를 함께 적용한다.
```

Add stop rules:

```markdown
## Stage2 즉시 중단 기준

- Trino restart count 또는 `OOMKilled` 증가
- `OutOfMemoryError`, `Killed`, `EXCEEDED_LOCAL_MEMORY_LIMIT`, cluster OOM 발생
- Trino container memory가 8.0 GiB 이상으로 2회 연속 관측
- Traffic Gold exact reconciliation 실패 또는 Bronze interleave 확인
- Iceberg write conflict 또는 중복 key 발생
- runnable Weather task가 Weather lane에서도 15분 이상 `scheduled` 대기
- resolver batch hotfix 후 Traffic transform이 30분 초과
```

- [ ] **Step 4: Update revision-locked deploy workflow and README**

In `docs/agent/workflows/revision-locked-dev-deploy.md` and `README.md`, replace examples using two compose files:

```powershell
docker compose -f .\docker-compose.yml -f .\.runtime\dev\docker-compose.generated.yml ...
```

with:

```powershell
docker compose -f .\docker-compose.yml -f .\docker-compose.traffic-weather-lineage.yml -f .\.runtime\dev\docker-compose.generated.yml ...
```

Add verification evidence list:

```markdown
- Marquez DB/API/Web 상태: `marquez-db`, `marquez-api`, `marquez-web`
- scheduler DNS: `getent hosts marquez-api`
- lineage env: `ask-seoul-dev-airflow`, `ask-seoul-dev-dbt`, selective enable
- pools: `trino_traffic_heavy=1`, `trino_weather_heavy=1`, `trino_heavy=1`
- compose labels: base compose, Traffic/Weather lineage overlay, generated exact-ref override
```

- [ ] **Step 5: Run docs tests**

Run:

```powershell
python -m unittest scripts.tests.test_traffic_weather_lineage_overlay -v
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path scripts/tests/DevDeployHarness.Tests.ps1 -Output Detailed"
```

Expected: PASS for guide/workflow documentation assertions.

- [ ] **Step 6: Commit Task 6**

```powershell
git add docs/traffic-weather-lineage.md docs/agent/workflows/revision-locked-dev-deploy.md README.md scripts/tests/test_traffic_weather_lineage_overlay.py scripts/tests/DevDeployHarness.Tests.ps1
git commit -m "docs: document lineage hotfix deploy and canary workflow"
```

Expected: commit succeeds after explicit user approval for committing.

### Task 7: Static And Runtime Verification

**Files:**
- Modify: `LessonRun.md` only if executing runtime smoke and recording results.
- No code/config changes in this task.

**Interfaces:**
- Consumes: all previous task outputs.
- Produces: local evidence that static tests, default deploy, verify script, Stage1, and optional Stage2 canary behave as specified.

- [ ] **Step 1: Run full static Python tests**

Run:

```powershell
python -m unittest scripts.tests.test_trino_runtime_hardening scripts.tests.test_traffic_weather_lineage_overlay scripts.tests.test_dbt_openlineage_fail_open_probe -v
```

Expected:

```text
OK
```

If Docker is unavailable, `test_docker_compose_merges_environment_without_global_listener` may skip with `Docker CLI is not installed`; record the skip.

- [ ] **Step 2: Run full Pester tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path scripts/tests/DevDeployHarness.Tests.ps1 -Output Detailed"
```

Expected:

```text
Tests Passed
```

- [ ] **Step 3: Verify WhatIf output is non-secret and includes overlay**

Run:

```powershell
pwsh -File scripts/deploy-dev.ps1 -WhatIf
```

Expected output contains:

```text
WhatIf: requested_ref origin/dev
WhatIf: dags <40-hex-sha> -> <repo>\.runtime\dev\dags
WhatIf: dbt <40-hex-sha> -> <repo>\.runtime\dev\dbt
WhatIf: compose override <repo>\.runtime\dev\docker-compose.generated.yml
WhatIf: lineage overlay <repo>\docker-compose.traffic-weather-lineage.yml
WhatIf: lineage overlay sha256 <64-hex-sha>
```

Expected output does not contain API keys, passwords, tokens, `.env` values, `KMA_SERVICE_KEY`, or `SEOUL_OPEN_API_KEY`.

- [ ] **Step 4: Verify default 3-file compose config**

Run:

```powershell
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml -f .runtime/dev/docker-compose.generated.yml config --quiet
```

Expected: command exits `0` and prints no secret values.

- [ ] **Step 5: Deploy default Stage1 runtime**

Run:

```powershell
pwsh -File scripts/deploy-dev.ps1
```

Expected output contains:

```text
requested_ref origin/dev
dags <40-hex-sha> -> <repo>\.runtime\dev\dags
dbt <40-hex-sha> -> <repo>\.runtime\dev\dbt
deployment lock <repo>\.runtime\dev\deployment-lock.json
compose override <repo>\.runtime\dev\docker-compose.generated.yml
lineage overlay <repo>\docker-compose.traffic-weather-lineage.yml
```

- [ ] **Step 6: Run deployment verifier**

Run:

```powershell
pwsh -File scripts/verify-dev-deploy.ps1
```

Expected output contains:

```text
verified deployment lock <repo>\.runtime\dev\deployment-lock.json
airflow-apiserver healthy
airflow-scheduler healthy
marquez-db healthy
marquez-api healthy
marquez-web running
marquez dns True
trino_traffic_heavy 1
trino_weather_heavy 1
```

- [ ] **Step 7: Verify Marquez event POST manually**

Run:

```powershell
$body = @{
  eventType = "START"
  eventTime = (Get-Date).ToUniversalTime().ToString("o")
  run = @{ runId = [guid]::NewGuid().ToString() }
  job = @{ namespace = "ask-seoul-dev-airflow"; name = "hotfix_verify" }
  producer = "https://github.com/ASAC-DE-bigkk/ASK-Seoul"
  schemaURL = "https://openlineage.io/spec/1-0-5/OpenLineage.json#/definitions/RunEvent"
} | ConvertTo-Json -Depth 8
Invoke-WebRequest -Uri "http://127.0.0.1:5000/api/v1/lineage" -Method Post -ContentType "application/json" -Body $body
```

Expected: HTTP status `201`.

- [ ] **Step 8: Verify Stage2 canary config renders only when explicitly requested**

Run:

```powershell
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml -f .runtime/dev/docker-compose.generated.yml -f docker-compose.trino-hard2-canary.yml config --quiet
```

Expected: command exits `0`.

Run:

```powershell
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml -f .runtime/dev/docker-compose.generated.yml -f docker-compose.trino-hard2-canary.yml config | Select-String -Pattern "resource-groups.canary-hard2.json|1280MB|2560MB"
```

Expected output contains:

```text
resource-groups.canary-hard2.json
1280MB
2560MB
```

- [ ] **Step 9: Start the Stage2 canary explicitly and verify the running Trino guardrail**

Run only after the root, ASAC-DAG #426, and ASAC-DBT #257 hotfix branches have passed their static gates and the exact refs have been mounted by the dev harness:

```powershell
$baseCompose = @(
  '-f', 'docker-compose.yml',
  '-f', 'docker-compose.traffic-weather-lineage.yml',
  '-f', '.runtime/dev/docker-compose.generated.yml'
)
$canaryCompose = $baseCompose + @('-f', 'docker-compose.trino-hard2-canary.yml')

docker compose @canaryCompose up -d --no-deps --force-recreate trino
docker compose @canaryCompose ps trino
docker compose @canaryCompose exec -T trino sh -c "grep -F '\"hardConcurrencyLimit\": 2' /etc/trino/resource-groups.json"
docker compose @canaryCompose exec -T trino sh -c 'test "$TRINO_QUERY_MAX_MEMORY_PER_NODE" = 1280MB && test "$TRINO_QUERY_MAX_MEMORY" = 1280MB && test "$TRINO_QUERY_MAX_TOTAL_MEMORY" = 2560MB && test "$TRINO_MEMORY_HEAP_HEADROOM_PER_NODE" = 2GB && test "$TRINO_TASK_CONCURRENCY" = 2'
```

Expected: Trino is running, the mounted resource group reports `hardConcurrencyLimit=2`, and all five canary memory/concurrency lines match exactly. If any assertion fails, execute Step 11 immediately.

- [ ] **Step 10: Unpause Traffic only after all hotfix gates pass, then observe three complete canary cycles**

First complete ASAC-DAG plan Task 7 Step 7 and verify there is no pre-hotfix active Traffic DagRun; never let the canary unpause resume a mixed-revision run. Then run three sequential manual cycles so each cycle has an unambiguous run id. The loop exits immediately on a failed DAG run, Trino restart, or Trino OOM state; it never prints environment or secret values:

```powershell
$dagId = 'traffic_incident_transform'
docker compose @canaryCompose exec -T airflow-scheduler airflow dags unpause $dagId

for ($cycle = 1; $cycle -le 3; $cycle++) {
  $runId = 'canary__hard2__cycle_{0}__{1}' -f $cycle, (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  docker compose @canaryCompose exec -T airflow-scheduler airflow dags trigger $dagId --run-id $runId

  do {
    Start-Sleep -Seconds 15
    $state = (docker compose @canaryCompose exec -T airflow-scheduler airflow dags state $dagId $runId | Select-Object -Last 1).Trim().ToLowerInvariant()
  } while ($state -notin @('success', 'failed'))

  if ($state -ne 'success') {
    throw "Traffic canary cycle $cycle failed: $runId state=$state"
  }

  $trinoId = (docker compose @canaryCompose ps -q trino | Select-Object -First 1).Trim()
  $trinoState = docker inspect $trinoId --format '{{json .State}}' | ConvertFrom-Json
  $restartCount = [int](docker inspect $trinoId --format '{{.RestartCount}}')
  if ($restartCount -ne 0 -or [bool]$trinoState.OOMKilled) {
    throw "Trino canary guard failed after cycle $cycle`: restartCount=$restartCount oomKilled=$($trinoState.OOMKilled)"
  }

  docker stats --no-stream --format 'trino={{.MemUsage}}' $trinoId
  docker compose @canaryCompose exec -T airflow-scheduler airflow tasks states-for-dag-run $dagId $runId
}
```

For every cycle, record total Traffic duration, resolver duration, `dbt_test_gold` duration/tier, Trino memory, restart/OOM state, and whether any runnable Weather task stayed `scheduled` for 15 minutes. Acceptance requires all three Traffic runs to succeed, no Trino restart/OOM, no Iceberg write conflict or duplicate key, exact Gold reconciliation success, and no Weather starvation. Leave Traffic unpaused only after all three cycles pass; otherwise pause it before rollback.

- [ ] **Step 11: Execute the hard=1 rollback immediately when a Stage2 stop condition fires**

```powershell
docker compose @canaryCompose exec -T airflow-scheduler airflow dags pause traffic_incident_transform
docker compose @baseCompose up -d --no-deps --force-recreate trino
docker compose @baseCompose ps trino
docker compose @baseCompose exec -T trino sh -c "grep -F '\"hardConcurrencyLimit\": 1' /etc/trino/resource-groups.json"
pwsh -File scripts/verify-dev-deploy.ps1
```

Expected: Traffic is paused, Trino is recreated from the default three-file Stage1 compose set, `hardConcurrencyLimit=1` is mounted, and the deployment verifier passes. This rollback removes only the canary overlay; it keeps the Traffic/Weather domain pools and Marquez services.

- [ ] **Step 12: Record runtime evidence if smoke was executed**

Append a Korean entry to `LessonRun.md` with:

```markdown
## 2026-07-18 Traffic/Weather lineage hotfix smoke

- root branch: `fix/38-trino-openlineage-starvation`
- deploy command: `pwsh -File scripts/deploy-dev.ps1`
- compose set: `docker-compose.yml`, `docker-compose.traffic-weather-lineage.yml`, `.runtime/dev/docker-compose.generated.yml`
- DAG run id: `<actual DAG run id>`
- task state/time: `<task id>: <success|failed>, <duration>`
- final row count: `<table>: <count>`
- created object/table: `<R2 object key or Trino table>`
- Marquez POST status: `201`
- Trino restart count: `<count>`
- Trino peak memory: `<observed value>`
- Stage2 canary: `<not run|passed|rolled back with reason>`
```

Use actual runtime values. Do not write secret values.

- [ ] **Step 13: Commit verification record if `LessonRun.md` changed**

```powershell
git add LessonRun.md
git commit -m "docs: record lineage hotfix smoke evidence"
```

Expected: commit succeeds after explicit user approval for committing. Skip this commit if runtime smoke was not executed or `LessonRun.md` was not changed.

## Rollback Procedure

- Keep Traffic/Weather domain lanes. Do not roll back Airflow pools when only Trino Stage2 canary fails.
- To roll back Stage2, stop using `docker-compose.trino-hard2-canary.yml` and redeploy with the default 3-file compose set.
- Confirm default `trino/resource-groups.json` still has `hardConcurrencyLimit=1`.
- If Marquez fails independently, restart only `marquez-db`, `marquez-api`, `marquez-web`. Data tasks should remain fail-open for lineage emission warnings.
- If deployment verification fails because Marquez is absent or unhealthy, treat it as deploy failure, not data task failure.

## Self-Review

- Spec coverage: Marquez always-on/restart/health/SEARCH off/memory caps are covered by Task 1 and Task 4. DevDeployHarness overlay merge+lock+verify is covered by Task 3 and Task 4. Traffic/Weather pool bootstrap is covered by Task 2, with submodule task assignment explicitly handed off. Trino Stage1 hard=1 and Stage2 explicit hard=2 canary config/memory tests are covered by Task 5. Runtime and static verification are covered by Task 7.
- Placeholder scan: no unresolved marker phrases or unbounded generic instructions remain. Snippets, commands, expected outputs, and file paths are explicit.
- Type/signature consistency: PowerShell helper names and evidence keys are consistent across tasks: `Get-DevFileSha256`, `Get-DevComposeFileArguments`, `Assert-DeploymentComposeLabels`, `CurrentLineageOverlaySha256`, `SchedulerLineageChecks`, `AirflowPools`, `MarquezRuntime`, `MarquezEndpointChecks`, and `ComposeLabels`.
- Scope check: this root plan does not modify `dags/` or `dbt/`; it documents the required ASAC-DAG pool assignment as handoff because the user requested root plan only.
