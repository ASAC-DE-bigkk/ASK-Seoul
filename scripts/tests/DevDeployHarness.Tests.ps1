Import-Module (Join-Path $PSScriptRoot '..\lib\DevDeployHarness.psm1') -Force -DisableNameChecking

function Invoke-TestGit {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git -C $RepositoryPath @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $RepositoryPath $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }

  return $output
}

function New-TestGitRepository {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  & git -C $Path init | Out-Null
  & git -C $Path config user.email 'tester@example.com' | Out-Null
  & git -C $Path config user.name 'Harness Tester' | Out-Null

  Set-Content -LiteralPath (Join-Path $Path 'tracked.txt') -Value 'one' -Encoding ASCII
  Invoke-TestGit -RepositoryPath $Path -Arguments @('add', 'tracked.txt') | Out-Null
  Invoke-TestGit -RepositoryPath $Path -Arguments @('commit', '-m', 'first') | Out-Null
  $firstSha = (Invoke-TestGit -RepositoryPath $Path -Arguments @('rev-parse', 'HEAD')).Trim()

  Set-Content -LiteralPath (Join-Path $Path 'tracked.txt') -Value 'two' -Encoding ASCII
  Invoke-TestGit -RepositoryPath $Path -Arguments @('commit', '-am', 'second') | Out-Null
  $secondSha = (Invoke-TestGit -RepositoryPath $Path -Arguments @('rev-parse', 'HEAD')).Trim()

  return @{
    FirstSha = $firstSha
    SecondSha = $secondSha
  }
}

function Get-ServiceBlock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Yaml,

    [Parameter(Mandatory = $true)]
    [string]$Service
  )

  $pattern = "(?ms)^  $([regex]::Escape($Service)):\r?\n(?<block>.*?)(?=^  [A-Za-z0-9_-]+:|^volumes:|\z)"
  $match = [regex]::Match($Yaml, $pattern)
  if (-not $match.Success) {
    throw "service block missing for $Service"
  }

  return $match.Value
}

function Assert-TestThrows {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$ScriptBlock,

    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  $thrown = $null
  try {
    & $ScriptBlock
  }
  catch {
    $thrown = $_
  }

  $thrown | Should Not BeNullOrEmpty
  $thrown.Exception.Message | Should Match $Pattern
}

function New-TestServiceMounts {
  param(
    [Parameter(Mandatory = $true)]
    $Lock
  )

  $mounts = @{}
  foreach ($service in 'airflow-init', 'airflow-apiserver', 'airflow-scheduler', 'airflow-dag-processor', 'airflow-triggerer') {
    $mounts[$service] = @(
      @{ Destination = '/opt/airflow/dags'; Source = $Lock.dags.worktree_path },
      @{ Destination = '/opt/airflow/plugins'; Source = (Join-Path $Lock.dags.worktree_path 'plugins') },
      @{ Destination = '/opt/airflow/dbt'; Source = $Lock.dbt.worktree_path }
    )
  }

  return $mounts
}

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
  param(
    [Parameter(Mandatory = $true)]
    $Lock
  )

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
    ServiceMounts = (New-TestServiceMounts -Lock $Lock)
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

Describe 'DevDeployHarness' {
  It 'uses TestDrive for every repository fixture' {
    $forbiddenRoot = 'C:' + [IO.Path]::DirectorySeparatorChar + 'repo'
    (Get-Content -Raw -LiteralPath $PSCommandPath) | Should Not Match ([regex]::Escape($forbiddenRoot))
  }

  It 'writes every Airflow service with the locked DAG and DBT mount' {
    $lock = (New-TestDeploymentLock -Name 'compose-override-mounts').Lock
    $yaml = New-DevComposeOverrideText -Lock $lock

    foreach ($service in 'airflow-init', 'airflow-apiserver', 'airflow-scheduler', 'airflow-dag-processor', 'airflow-triggerer') {
      $block = Get-ServiceBlock -Yaml $yaml -Service $service
      $block | Should Match ([regex]::Escape("${service}:"))
      $block | Should Match ([regex]::Escape("'$($lock.dags.worktree_path):/opt/airflow/dags:ro'"))
      $block | Should Match ([regex]::Escape("'$($lock.dbt.worktree_path):/opt/airflow/dbt'"))
    }
  }

  It 'rejects resolving any ref except literal origin/dev' {
    $fixture = New-TestDeploymentLock -Name 'reject-ref'
    $thrown = $null

    try {
      Resolve-DevRevision -RootPath $fixture.RootPath -Ref 'dev'
    }
    catch {
      $thrown = $_
    }

    $thrown | Should Not BeNullOrEmpty
    $thrown.Exception.Message | Should Match 'origin/dev'
  }

  It 'rejects uninitialized child repositories before fetch or rev-parse' {
    $root = Join-Path $TestDrive 'root-with-empty-children'
    New-Item -ItemType Directory -Path (Join-Path $root 'dags') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'dbt') -Force | Out-Null
    & git -C $root init | Out-Null
    @'
[submodule "dags"]
	path = dags
	url = https://github.com/ASAC-DE-bigkk/ASAC-DAG
[submodule "dbt"]
	path = dbt
	url = https://github.com/ASAC-DE-bigkk/ASAC-DBT
'@ | Set-Content -LiteralPath (Join-Path $root '.gitmodules') -Encoding ASCII

    Assert-TestThrows -Pattern 'dags.*initialized child Git worktree' -ScriptBlock {
      Resolve-DevRevision -RootPath $root
    }
  }

  It 'rejects child origin remotes that differ from .gitmodules' {
    $root = Join-Path $TestDrive 'root-with-remote-mismatch'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    @'
[submodule "dags"]
	path = dags
	url = https://github.com/ASAC-DE-bigkk/ASAC-DAG
[submodule "dbt"]
	path = dbt
	url = https://github.com/ASAC-DE-bigkk/ASAC-DBT
'@ | Set-Content -LiteralPath (Join-Path $root '.gitmodules') -Encoding ASCII
    foreach ($child in 'dags', 'dbt') {
      New-Item -ItemType Directory -Path (Join-Path $root $child) -Force | Out-Null
      & git -C (Join-Path $root $child) init | Out-Null
    }
    & git -C (Join-Path $root 'dags') remote add origin https://github.com/example/wrong-dag | Out-Null
    & git -C (Join-Path $root 'dbt') remote add origin https://github.com/ASAC-DE-bigkk/ASAC-DBT | Out-Null

    Assert-TestThrows -Pattern 'dags.*origin.*does not match .gitmodules' -ScriptBlock {
      Resolve-DevRevision -RootPath $root
    }
  }

  It 'preserves native stderr when a command exits successfully' {
    $module = Get-Module DevDeployHarness

    $output = & $module {
      $ErrorActionPreference = 'Stop'
      Invoke-DevHarnessExternal -FilePath 'cmd.exe' -Arguments @('/c', 'echo fetch-progress 1>&2')
    }

    ($output -join [Environment]::NewLine) | Should Match 'fetch-progress'
  }

  It 'rejects a dirty runtime worktree before compose starts' {
    $thrown = $null
    try {
      Assert-DevRuntimeWorktree -Path 'C:\runtime\dags' -StatusLines @(' M domains/traffic/file.py')
    }
    catch {
      $thrown = $_
    }

    $thrown | Should Not BeNullOrEmpty
    $thrown.Exception.Message | Should Match 'dirty'
  }

  It 'rejects a Docker mount that differs from the lock' {
    $lock = (New-TestDeploymentLock -Name 'wrong-mount').Lock
    $thrown = $null

    try {
      Assert-DeploymentMounts -Lock $lock -Mounts @(@{ Destination = '/opt/airflow/dags'; Source = 'C:\wrong' })
    }
    catch {
      $thrown = $_
    }

    $thrown | Should Not BeNullOrEmpty
    $thrown.Exception.Message | Should Match 'mount'
  }

  It 'advances an existing clean runtime worktree to the requested detached SHA' {
    $repo = Join-Path $TestDrive 'repo-clean'
    $runtime = Join-Path $TestDrive 'runtime-clean'
    $revisions = New-TestGitRepository -Path $repo
    Invoke-TestGit -RepositoryPath $repo -Arguments @('worktree', 'add', '--detach', $runtime, $revisions.FirstSha) | Out-Null

    Ensure-DevRuntimeWorktree -RepositoryPath $repo -WorktreePath $runtime -Sha $revisions.SecondSha | Should Be $runtime

    $actualSha = (Invoke-TestGit -RepositoryPath $runtime -Arguments @('rev-parse', 'HEAD')).Trim()
    $actualSha | Should Be $revisions.SecondSha

    $branch = & git -C $runtime symbolic-ref -q HEAD 2>$null
    $LASTEXITCODE | Should Not Be 0
    $branch | Should BeNullOrEmpty
  }

  It 'fails dirty existing runtime worktrees before advancing the SHA' {
    $repo = Join-Path $TestDrive 'repo-dirty'
    $runtime = Join-Path $TestDrive 'runtime-dirty'
    $revisions = New-TestGitRepository -Path $repo
    Invoke-TestGit -RepositoryPath $repo -Arguments @('worktree', 'add', '--detach', $runtime, $revisions.FirstSha) | Out-Null
    Set-Content -LiteralPath (Join-Path $runtime 'tracked.txt') -Value 'dirty' -Encoding ASCII

    $thrown = $null
    try {
      Ensure-DevRuntimeWorktree -RepositoryPath $repo -WorktreePath $runtime -Sha $revisions.SecondSha
    }
    catch {
      $thrown = $_
    }

    $thrown | Should Not BeNullOrEmpty
    $thrown.Exception.Message | Should Match 'dirty'
    $actualSha = (Invoke-TestGit -RepositoryPath $runtime -Arguments @('rev-parse', 'HEAD')).Trim()
    $actualSha | Should Be $revisions.FirstSha
  }

  It 'deploy-dev.ps1 has no ref parameter and uses literal origin/dev' {
    $script = Get-Command (Join-Path $PSScriptRoot '..\deploy-dev.ps1')
    @($script.Parameters.Keys) | Should Be @('WhatIf')

    $content = Get-Content -Raw -LiteralPath $script.Source
    $content | Should Match '\$revision = Resolve-DevRevision -RootPath \$root -SkipFetch:\$WhatIf'
    $content | Should Match 'WhatIf: requested_ref origin/dev'
    $content | Should Match 'WhatIf: lineage overlay'
    $content | Should Not Match '(?i)\bparam\s*\([^)]*\$(Ref|Branch|Sha|FeatureRef)\b'
    $content | Should Not Match '(?i)Resolve-DevRevision[^\r\n]*-(Ref|Branch|Sha|FeatureRef)\b'
  }

  It 'deploy-dev.ps1 verifies after compose up before reporting success' {
    $script = Get-Command (Join-Path $PSScriptRoot '..\deploy-dev.ps1')
    $content = Get-Content -Raw -LiteralPath $script.Source

    $composeUpIndex = $content.IndexOf("Invoke-DevDockerCompose -RootPath `$root -Lock `$lock -Arguments @('up', '-d', '--build', '--wait', '--force-recreate')")
    $verifyIndex = $content.IndexOf("& (Join-Path `$PSScriptRoot 'verify-dev-deploy.ps1')")
    $successIndex = $content.IndexOf('Write-Output "requested_ref origin/dev"')
    $whatIfReturnIndex = $content.IndexOf('return')

    $composeUpIndex | Should BeGreaterThan -1
    $verifyIndex | Should BeGreaterThan $composeUpIndex
    $successIndex | Should BeGreaterThan $verifyIndex
    $verifyIndex | Should BeGreaterThan $whatIfReturnIndex
  }

  It 'force recreates the stack so every service records the exact compose file set' {
    $script = Get-Item (Join-Path $PSScriptRoot '..\deploy-dev.ps1')
    $content = Get-Content -Raw -LiteralPath $script.FullName

    $content | Should Match "-Arguments @\('up', '-d', '--build', '--wait', '--force-recreate'\)"
    $content | Should Not Match "-Arguments @\('up', '-d', '--build', '--wait'\)"
  }

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

  It 'queries completed airflow-init mounts with docker compose ps --all' {
    $module = Get-Module DevDeployHarness
    $source = Get-Content -Raw -LiteralPath $module.Path

    $source | Should Match 'Get-DevDockerServiceMounts[\s\S]*?Arguments @\(''ps'', ''-aq'', \$Service\)'
  }

  It 'verifies runtime SHA on the host instead of container Git metadata' {
    $module = Get-Module DevDeployHarness
    $source = Get-Content -Raw -LiteralPath $module.Path

    $source | Should Match 'Invoke-DevHarnessGit -RepositoryPath \$Lock\.dags\.worktree_path -Arguments @\(''rev-parse'', ''HEAD''\)'
    $source | Should Match 'Invoke-DevHarnessGit -RepositoryPath \$Lock\.dbt\.worktree_path -Arguments @\(''rev-parse'', ''HEAD''\)'
    $source | Should Not Match "Invoke-DevSchedulerCommand[\s\S]*?@\('git', '-C', '/opt/airflow/dags'"
  }

  It 'rejects a second deployment mutex and removes the lock file after release' {
    $root = Join-Path $TestDrive 'mutex-root'
    $first = New-DevDeploymentMutex -RootPath $root
    $lockPath = Join-Path $root '.runtime\dev\deploy.lock'

    Test-Path -LiteralPath $lockPath | Should Be $true
    Assert-TestThrows -Pattern 'deployment already in progress' -ScriptBlock {
      New-DevDeploymentMutex -RootPath $root
    }

    Close-DevDeploymentMutex -Mutex $first
    Test-Path -LiteralPath $lockPath | Should Be $false
  }

  It 'documents deploy-dev as origin/dev entry point and deploy.sh as main-based path' {
    $readme = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\README.md')

    $readme | Should Match 'deploy-dev\.ps1'
    $readme | Should Match 'origin/dev'
    $readme | Should Match 'deploy\.sh[\s\S]*main'
    $readme | Should Match 'Marquez always-on'
    $readme | Should Match 'docker-compose\.traffic-weather-lineage\.yml'
    $readme | Should Match 'trino_traffic_heavy=1'
    $readme | Should Match 'trino_weather_heavy=1'
    $readme | Should Match 'docker-compose\.trino-hard2-canary\.yml'
    $readme | Should Not Match '--profile lineage'
    $readme | Should Not Match 'docker compose -f \.\\docker-compose\.yml -f \.\\\.runtime\\dev\\docker-compose\.generated\.yml'
  }

  It 'documents revision-locked dev deploy guardrails and diagnosis evidence' {
    $workflow = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\docs\agent\workflows\revision-locked-dev-deploy.md')

    $workflow | Should Match 'deploy-dev\.ps1` accepts only literal `origin/dev`'
    $workflow | Should Match 'It has no feature-ref, branch-name, arbitrary-ref, or SHA input mode'
    $workflow | Should Match 'deployment-lock\.json'
    $workflow | Should Match 'lineage_overlay_sha256'
    $workflow | Should Match 'compose_files'
    $workflow | Should Match 'docker-compose\.yml[\s\S]*docker-compose\.traffic-weather-lineage\.yml[\s\S]*docker-compose\.generated\.yml'
    $workflow | Should Match 'airflow-init[\s\S]*airflow-apiserver[\s\S]*airflow-scheduler[\s\S]*airflow-dag-processor[\s\S]*airflow-triggerer'
    $workflow | Should Match 'source root `dags/` and `dbt/` paths are fetch sources only'
    $workflow | Should Match 'must not run checkout, reset, merge, clean, or worktree mutation commands in those source root paths'
    $workflow | Should Match 'Failure diagnosis'
    $workflow | Should Match 'docker compose[\s\S]*ps'
    $workflow | Should Match 'docker inspect[\s\S]*Mounts'
    $workflow | Should Match 'Logs must be inspected locally and redacted before terminal capture, recording, or sharing'
    $workflow | Should Match '\$logSecretPattern'
    $workflow | Should Match 'Where-Object \{ \$_ -notmatch \$logSecretPattern \}'
    $workflow | Should Match 'ForEach-Object[\s\S]*\[REDACTED\]'
    $workflow | Should Not Match '(?m)^docker compose[^\r\n]* logs --tail 200 airflow-'
    $workflow | Should Match 'git -C \.\\.runtime\\dev\\dags rev-parse HEAD'
    $workflow | Should Match 'git -C \.\\.runtime\\dev\\dbt rev-parse HEAD'
    $workflow | Should Match '/opt/airflow/dbt/domains/traffic_weather/dbt_project\.yml'
    $workflow | Should Match 'Secrets and `.env` values must never be output, copied into reports, written to LessonRun, or included in issue/PR bodies'
    $workflow | Should Match 'Marquez always-on'
    $workflow | Should Match 'marquez-api'
    $workflow | Should Match 'DNS'
    $workflow | Should Match 'compose labels'
    $workflow | Should Match 'trino_traffic_heavy=1'
    $workflow | Should Match 'trino_weather_heavy=1'
    $workflow | Should Match 'hardConcurrencyLimit=1'
    $workflow | Should Match 'docker-compose\.trino-hard2-canary\.yml'
    $workflow | Should Match 'hardConcurrencyLimit=2'
    $workflow | Should Match 'restart/OOM/memory error'
    $workflow | Should Match 'Iceberg conflict/duplicate'
    $workflow | Should Match 'Weather scheduled > 15m'
    $workflow | Should Match 'Traffic > 30m'
    $workflow | Should Not Match '--profile lineage'
    $workflow | Should Not Match 'docker compose -f \.\\docker-compose\.yml -f \.\\\.runtime\\dev\\docker-compose\.generated\.yml'
  }

  It 'verify-dev-deploy.ps1 has no public parameters and rejects unexpected arguments' {
    $script = Get-Command (Join-Path $PSScriptRoot '..\verify-dev-deploy.ps1')
    $script.Parameters.Keys | Should BeNullOrEmpty

    $output = & powershell.exe -NoProfile -File $script.Source unexpected 2>&1
    $LASTEXITCODE | Should Not Be 0
    ($output -join [Environment]::NewLine) | Should Match 'accepts no arguments'
    ($output -join [Environment]::NewLine) | Should Not Match 'deployment lock missing'
    (Get-Content -Raw -LiteralPath $script.Source) | Should Match 'RuntimeGitHeads \$evidence\.RuntimeGitHeads'
  }

  It 'rejects a runtime DAG SHA that differs from the lock' {
    $fixture = New-TestDeploymentLock -Name 'runtime-dag-sha'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.RuntimeGitHeads.dags = ('c' * 40)

    Assert-TestThrows -Pattern 'DAG.*SHA.*mismatch' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a runtime DBT SHA that differs from the lock' {
    $fixture = New-TestDeploymentLock -Name 'runtime-dbt-sha'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.RuntimeGitHeads.dbt = ('d' * 40)

    Assert-TestThrows -Pattern 'DBT.*SHA.*mismatch' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a running deployment with a missing required dbt project' {
    $fixture = New-TestDeploymentLock -Name 'missing-dbt-project'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.RequiredDbtProjectExists = $false

    Assert-TestThrows -Pattern 'dbt project.*missing' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a running deployment with a missing service mount set' {
    $fixture = New-TestDeploymentLock -Name 'missing-service-mounts'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.ServiceMounts.Remove('airflow-triggerer')

    Assert-TestThrows -Pattern 'mounts missing.*airflow-triggerer' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a running deployment with a bad service mount path' {
    $fixture = New-TestDeploymentLock -Name 'bad-service-mount'
    $lock = $fixture.Lock
    $assertArgs = New-TestRunningDeploymentArgs -Lock $lock
    $assertArgs.ServiceMounts['airflow-scheduler'] = @(
      @{ Destination = '/opt/airflow/dags'; Source = 'C:\wrong-dags' },
      @{ Destination = '/opt/airflow/plugins'; Source = (Join-Path $lock.dags.worktree_path 'plugins') },
      @{ Destination = '/opt/airflow/dbt'; Source = $lock.dbt.worktree_path }
    )

    Assert-TestThrows -Pattern 'mount mismatch.*/opt/airflow/dags' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects missing apiserver health evidence' {
    $fixture = New-TestDeploymentLock -Name 'missing-apiserver-health'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.ServiceHealth.Remove('airflow-apiserver')

    Assert-TestThrows -Pattern 'health missing.*airflow-apiserver' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects unhealthy scheduler health evidence' {
    $fixture = New-TestDeploymentLock -Name 'unhealthy-scheduler'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.ServiceHealth['airflow-scheduler'] = 'starting'

    Assert-TestThrows -Pattern 'airflow-scheduler.*not healthy.*starting' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a changed current lineage overlay fingerprint' {
    $fixture = New-TestDeploymentLock -Name 'overlay-drift'
    $lock = $fixture.Lock
    Set-Content -LiteralPath $lock.lineage_overlay_path -Value 'services: { changed: {} }' -Encoding UTF8
    $assertArgs = New-TestRunningDeploymentArgs -Lock $lock
    $assertArgs.CurrentLineageOverlaySha256 = Get-DevFileSha256 -Path $lock.lineage_overlay_path

    Assert-TestThrows -Pattern 'lineage overlay sha256 mismatch' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects reordered compose config file labels' {
    $fixture = New-TestDeploymentLock -Name 'labels-reordered'
    $lock = $fixture.Lock
    $assertArgs = New-TestRunningDeploymentArgs -Lock $lock
    $assertArgs.ComposeLabels['airflow-scheduler']['com.docker.compose.project.config_files'] = @(
      $lock.compose_files[1], $lock.compose_files[0], $lock.compose_files[2]
    ) -join ','

    Assert-TestThrows -Pattern 'compose file set mismatch.*airflow-scheduler.*index 0' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a false scheduler lineage boolean without retaining raw env' {
    $fixture = New-TestDeploymentLock -Name 'scheduler-check'
    $lock = $fixture.Lock
    $assertArgs = New-TestRunningDeploymentArgs -Lock $lock
    $assertArgs.SchedulerLineageChecks['AIRFLOW__OPENLINEAGE__NAMESPACE'] = $false

    Assert-TestThrows -Pattern 'scheduler lineage check failed.*AIRFLOW__OPENLINEAGE__NAMESPACE' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a missing Weather pool slot' {
    $fixture = New-TestDeploymentLock -Name 'pool-slot'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.AirflowPools['trino_weather_heavy'] = 0

    Assert-TestThrows -Pattern 'Airflow pool.*trino_weather_heavy.*expected 1.*got 0' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'rejects a wrong Marquez memory cap restart policy count or OOM state' {
    $fixture = New-TestDeploymentLock -Name 'marquez-runtime'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.MarquezRuntime['marquez-api'].Memory = 0L
    $assertArgs.MarquezRuntime['marquez-api'].RestartPolicy = 'no'
    $assertArgs.MarquezRuntime['marquez-api'].RestartCount = 1
    $assertArgs.MarquezRuntime['marquez-api'].OOMKilled = $true

    Assert-TestThrows -Pattern 'Marquez marquez-api memory expected 1610612736 bytes, got 0' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'uses the native curl executable for Marquez endpoint checks on Windows PowerShell' {
    $module = Get-Module DevDeployHarness
    $source = Get-Content -Raw -LiteralPath $module.Path

    $source | Should Match "Invoke-DevHarnessExternal -FilePath 'curl\.exe'"
    $source | Should Not Match "Invoke-DevHarnessExternal -FilePath 'curl'"
  }

  It 'passes every mandatory evidence argument for legacy SHA assertions' {
    $fixture = New-TestDeploymentLock -Name 'legacy-dag-sha'
    $assertArgs = New-TestRunningDeploymentArgs -Lock $fixture.Lock
    $assertArgs.RuntimeGitHeads.dags = ('c' * 40)

    Assert-TestThrows -Pattern 'DAG.*SHA.*mismatch' -ScriptBlock {
      Assert-RunningDeployment @assertArgs
    }
  }

  It 'preserves scheduler command failures while probing the required dbt project' {
    $fixture = New-TestDeploymentLock -Name 'scheduler-command-failure'
    $lock = $fixture.Lock

    Mock Invoke-DevDockerCompose {
      param(
        [string]$RootPath,
        $Lock,
        [string[]]$Arguments
      )

      if (($Arguments -join ' ') -match 'test -f') {
        throw 'docker compose exec failed: scheduler not running'
      }

      switch -Regex ($Arguments -join ' ') {
        'ps -aq airflow-' { return 'container-id' }
        default { throw "unexpected docker compose call: $($Arguments -join ' ')" }
      }
    } -ModuleName DevDeployHarness

    Mock Invoke-DevHarnessGit {
      param([string]$RepositoryPath, [string[]]$Arguments)
      if (($Arguments -join ' ') -eq 'status --porcelain') { return @() }
      if (($Arguments -join ' ') -eq 'rev-parse HEAD') {
        if ($RepositoryPath -eq $lock.dags.worktree_path) { return $lock.dags.sha }
        if ($RepositoryPath -eq $lock.dbt.worktree_path) { return $lock.dbt.sha }
      }
      throw "unexpected git call: $RepositoryPath $($Arguments -join ' ')"
    } -ModuleName DevDeployHarness

    Mock Invoke-DevHarnessExternal {
      param(
        [string]$FilePath,
        [string[]]$Arguments
      )

      switch -Regex ($Arguments -join ' ') {
        'json \.Mounts' {
          return ConvertTo-Json @(
            @{ Destination = '/opt/airflow/dags'; Source = $lock.dags.worktree_path },
            @{ Destination = '/opt/airflow/plugins'; Source = (Join-Path $lock.dags.worktree_path 'plugins') },
            @{ Destination = '/opt/airflow/dbt'; Source = $lock.dbt.worktree_path }
          )
        }
        'State\.Health' { return 'healthy' }
        default { throw "unexpected docker call: $($Arguments -join ' ')" }
      }
    } -ModuleName DevDeployHarness

    Assert-TestThrows -Pattern 'scheduler not running' -ScriptBlock {
      Get-RunningDeploymentEvidence -RootPath $fixture.RootPath -Lock $lock
    }
  }
}
