Set-StrictMode -Version Latest

$script:AirflowServices = @(
  'airflow-init',
  'airflow-apiserver',
  'airflow-scheduler',
  'airflow-dag-processor',
  'airflow-triggerer'
)

function Normalize-DevHarnessPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Normalize-DevRemoteUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url
  )

  return $Url.Trim().TrimEnd('\', '/').ToLowerInvariant()
}

function Invoke-DevHarnessGit {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  return Invoke-DevHarnessExternal -FilePath 'git' -Arguments (@('-C', $RepositoryPath) + $Arguments)
}

function Get-DevGitModulesUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$ChildName
  )

  $gitmodules = Join-Path $RootPath '.gitmodules'
  if (-not (Test-Path -LiteralPath $gitmodules)) {
    throw ".gitmodules missing at $gitmodules"
  }

  $url = (Invoke-DevHarnessExternal -FilePath 'git' -Arguments @('config', '-f', $gitmodules, '--get', "submodule.$ChildName.url") | Select-Object -First 1).Trim()
  if (-not $url) {
    throw ".gitmodules URL missing for submodule $ChildName"
  }

  return $url
}

function Assert-DevGitTopLevel {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedPath,

    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  $expected = Normalize-DevHarnessPath -Path $ExpectedPath
  if (-not (Test-Path -LiteralPath $expected -PathType Container)) {
    throw "$Label source repository missing at $expected"
  }

  $topLevel = (Invoke-DevHarnessGit -RepositoryPath $Path -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1).Trim()
  $actual = Normalize-DevHarnessPath -Path $topLevel
  if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label source repository at $expected is not an initialized child Git worktree; git top-level resolved to $actual"
  }
}

function Assert-DevSourceRepository {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$ChildName
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
  $childPath = Join-Path $root $ChildName
  Assert-DevGitTopLevel -Path $childPath -ExpectedPath $childPath -Label $ChildName

  $expectedUrl = Get-DevGitModulesUrl -RootPath $root -ChildName $ChildName
  $actualUrl = (Invoke-DevHarnessGit -RepositoryPath $childPath -Arguments @('remote', 'get-url', 'origin') | Select-Object -First 1).Trim()
  if ((Normalize-DevRemoteUrl -Url $actualUrl) -ne (Normalize-DevRemoteUrl -Url $expectedUrl)) {
    throw "$ChildName origin remote does not match .gitmodules: expected $expectedUrl, got $actualUrl"
  }
}

function Invoke-DevHarnessExternal {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    # Native tools frequently use stderr for progress. Preserve it as diagnostic
    # output and determine failure exclusively from the process exit code.
    $ErrorActionPreference = 'Continue'
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($exitCode -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }

  return $output
}

function Resolve-DevRevision {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [ValidateScript({
      if ($_ -ne 'origin/dev') {
        throw 'Resolve-DevRevision only accepts the literal merged dev ref origin/dev.'
      }
      return $true
    })]
    [string]$Ref = 'origin/dev',

    [switch]$SkipFetch
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
  Assert-DevSourceRepository -RootPath $root -ChildName 'dags'
  Assert-DevSourceRepository -RootPath $root -ChildName 'dbt'

  if (-not $SkipFetch) {
    Invoke-DevHarnessGit -RepositoryPath (Join-Path $root 'dags') -Arguments @('fetch', 'origin', 'dev') | Out-Null
    Invoke-DevHarnessGit -RepositoryPath (Join-Path $root 'dbt') -Arguments @('fetch', 'origin', 'dev') | Out-Null
  }

  $dagSha = (Invoke-DevHarnessGit -RepositoryPath (Join-Path $root 'dags') -Arguments @('rev-parse', '--verify', $Ref)).Trim()
  $dbtSha = (Invoke-DevHarnessGit -RepositoryPath (Join-Path $root 'dbt') -Arguments @('rev-parse', '--verify', $Ref)).Trim()

  return [ordered]@{
    requested_ref = $Ref
    dags = $dagSha
    dbt = $dbtSha
  }
}

function New-DeploymentLock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$DagSha,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$DbtSha
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
  $runtime = Join-Path $root '.runtime\dev'

  return [ordered]@{
    schema_version = 1
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
    compose_override_path = (Join-Path $runtime 'docker-compose.generated.yml')
    required_dbt_project = '/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml'
  }
}

function New-DevDeploymentMutex {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
  $runtime = Join-Path $root '.runtime\dev'
  if (-not (Test-Path -LiteralPath $runtime)) {
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
  }

  $lockPath = Join-Path $runtime 'deploy.lock'
  try {
    $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $writer = [System.Text.UTF8Encoding]::new($false)
    $bytes = $writer.GetBytes("pid=$PID$([Environment]::NewLine)created_at_utc=$([DateTime]::UtcNow.ToString('o'))$([Environment]::NewLine)")
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
  }
  catch [System.IO.IOException] {
    throw "deployment already in progress; lock exists at $lockPath"
  }

  return [pscustomobject]@{
    LockPath = $lockPath
    Stream = $stream
  }
}

function Close-DevDeploymentMutex {
  param(
    [Parameter(Mandatory = $true)]
    $Mutex
  )

  if ($Mutex.Stream) {
    $Mutex.Stream.Dispose()
  }

  if ($Mutex.LockPath -and (Test-Path -LiteralPath $Mutex.LockPath)) {
    Remove-Item -LiteralPath $Mutex.LockPath -Force
  }
}

function Ensure-DevRuntimeWorktree {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [string]$WorktreePath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$Sha
  )

  $repository = Normalize-DevHarnessPath -Path $RepositoryPath
  $worktree = Normalize-DevHarnessPath -Path $WorktreePath
  Assert-DevGitTopLevel -Path $repository -ExpectedPath $repository -Label 'runtime source'

  $parent = Split-Path -Parent $worktree
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  if (-not (Test-Path -LiteralPath $worktree)) {
    Invoke-DevHarnessGit -RepositoryPath $repository -Arguments @('worktree', 'add', '--detach', $worktree, $Sha) | Out-Null
  }
  else {
    Assert-DevRuntimeWorktree -Path $worktree
    Invoke-DevHarnessGit -RepositoryPath $worktree -Arguments @('checkout', '--detach', $Sha) | Out-Null
    $actualSha = (Invoke-DevHarnessGit -RepositoryPath $worktree -Arguments @('rev-parse', 'HEAD')).Trim()
    if ($actualSha -ne $Sha) {
      throw "runtime worktree revision mismatch at ${worktree}: expected $Sha, got $actualSha"
    }
  }

  Assert-DevRuntimeWorktree -Path $worktree
  return $worktree
}

function Format-DevComposeVolume {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [string]$Mode
  )

  $value = "${Source}:${Destination}"
  if ($Mode) {
    $value = "${value}:$Mode"
  }

  return $value.Replace("'", "''")
}

function New-DevComposeOverrideText {
  param(
    [Parameter(Mandatory = $true)]
    $Lock
  )

  $dagPath = $Lock.dags.worktree_path
  $pluginPath = Join-Path $dagPath 'plugins'
  $dbtPath = $Lock.dbt.worktree_path
  $serviceText = foreach ($service in $script:AirflowServices) {
    @"
  ${service}:
    volumes: !override
      - '$(Format-DevComposeVolume -Source $dagPath -Destination '/opt/airflow/dags' -Mode 'ro')'
      - '$(Format-DevComposeVolume -Source $pluginPath -Destination '/opt/airflow/plugins' -Mode 'ro')'
      - '$(Format-DevComposeVolume -Source $dbtPath -Destination '/opt/airflow/dbt')'
      - 'airflow_logs:/opt/airflow/logs'
"@
  }

  return @"
services:
$($serviceText -join [Environment]::NewLine)

volumes:
  airflow_logs:
"@
}

function Write-DevComposeOverride {
  param(
    [Parameter(Mandatory = $true)]
    $Lock
  )

  $path = $Lock.compose_override_path
  $directory = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  New-DevComposeOverrideText -Lock $Lock | Set-Content -LiteralPath $path -Encoding UTF8
  return $path
}

function Write-DeploymentLockAtomically {
  param(
    [Parameter(Mandatory = $true)]
    $Lock
  )

  $path = $Lock.deployment_lock_path
  $directory = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  $tempPath = "$path.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
  $Lock | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
  Move-Item -LiteralPath $tempPath -Destination $path -Force
  return $path
}

function Read-DeploymentLock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
  $path = Join-Path $root '.runtime\dev\deployment-lock.json'
  if (-not (Test-Path -LiteralPath $path)) {
    throw "deployment lock missing at $path"
  }

  return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Assert-DevRuntimeWorktree {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string[]]$StatusLines
  )

  if ($PSBoundParameters.ContainsKey('StatusLines')) {
    $lines = $StatusLines
  }
  else {
    $lines = Invoke-DevHarnessGit -RepositoryPath $Path -Arguments @('status', '--porcelain')
  }

  $dirtyLines = @($lines | Where-Object { $_ })
  if ($dirtyLines.Count -gt 0) {
    throw "runtime worktree is dirty at $Path`: $($dirtyLines -join '; ')"
  }
}

function Assert-DeploymentMounts {
  param(
    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [object[]]$Mounts
  )

  $expected = @{
    '/opt/airflow/dags' = (Normalize-DevHarnessPath -Path $Lock.dags.worktree_path)
    '/opt/airflow/plugins' = (Normalize-DevHarnessPath -Path (Join-Path $Lock.dags.worktree_path 'plugins'))
    '/opt/airflow/dbt' = (Normalize-DevHarnessPath -Path $Lock.dbt.worktree_path)
  }

  foreach ($destination in $expected.Keys) {
    $mount = @($Mounts | Where-Object { $_.Destination -eq $destination } | Select-Object -First 1)
    if ($mount.Count -eq 0) {
      throw "deployment mount missing for $destination"
    }

    $actualSource = Normalize-DevHarnessPath -Path $mount[0].Source
    if (-not [string]::Equals($actualSource, $expected[$destination], [StringComparison]::OrdinalIgnoreCase)) {
      throw "deployment mount mismatch for $destination`: expected $($expected[$destination]), got $actualSource"
    }
  }
}

function Assert-RunningDeployment {
  param(
    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [hashtable]$ServiceMounts,

    [Parameter(Mandatory = $true)]
    [hashtable]$RuntimeGitHeads,

    [Parameter(Mandatory = $true)]
    [bool]$RequiredDbtProjectExists,

    [Parameter(Mandatory = $true)]
    [hashtable]$ServiceHealth
  )

  foreach ($service in $script:AirflowServices) {
    if (-not $ServiceMounts.ContainsKey($service)) {
      throw "deployment mounts missing for service $service"
    }

    Assert-DeploymentMounts -Lock $Lock -Mounts $ServiceMounts[$service]
  }

  if (-not $RuntimeGitHeads.ContainsKey('dags')) {
    throw 'DAG runtime SHA missing from running deployment evidence'
  }

  if ($RuntimeGitHeads['dags'] -ne $Lock.dags.sha) {
    throw "DAG runtime SHA mismatch: expected $($Lock.dags.sha), got $($RuntimeGitHeads['dags'])"
  }

  if (-not $RuntimeGitHeads.ContainsKey('dbt')) {
    throw 'DBT runtime SHA missing from running deployment evidence'
  }

  if ($RuntimeGitHeads['dbt'] -ne $Lock.dbt.sha) {
    throw "DBT runtime SHA mismatch: expected $($Lock.dbt.sha), got $($RuntimeGitHeads['dbt'])"
  }

  if (-not $RequiredDbtProjectExists) {
    throw "required dbt project missing: $($Lock.required_dbt_project)"
  }

  foreach ($service in 'airflow-apiserver', 'airflow-scheduler') {
    if (-not $ServiceHealth.ContainsKey($service)) {
      throw "service health missing for $service"
    }

    if ($ServiceHealth[$service] -ne 'healthy') {
      throw "service $service is not healthy: $($ServiceHealth[$service])"
    }
  }
}

function Invoke-DevDockerCompose {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
  $composeArgs = @('-f', (Join-Path $root 'docker-compose.yml'), '-f', $Lock.compose_override_path) + $Arguments
  Push-Location -LiteralPath $root
  try {
    return Invoke-DevHarnessExternal -FilePath 'docker' -Arguments (@('compose') + $composeArgs)
  }
  finally {
    Pop-Location
  }
}

function Get-DevDockerServiceMounts {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [string]$Service
  )

  $containerId = (Invoke-DevDockerCompose -RootPath $RootPath -Lock $Lock -Arguments @('ps', '-aq', $Service) | Select-Object -First 1).Trim()
  if (-not $containerId) {
    throw "container id missing for service $Service"
  }

  $json = (Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{json .Mounts}}') | Select-Object -First 1)
  return @($json | ConvertFrom-Json)
}

function Get-DevDockerServiceHealth {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [string]$Service
  )

  $containerId = (Invoke-DevDockerCompose -RootPath $RootPath -Lock $Lock -Arguments @('ps', '-q', $Service) | Select-Object -First 1).Trim()
  if (-not $containerId) {
    throw "container id missing for service $Service"
  }

  return (Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}') | Select-Object -First 1).Trim()
}

function Invoke-DevSchedulerCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    $Lock,

    [Parameter(Mandatory = $true)]
    [string[]]$Command
  )

  return Invoke-DevDockerCompose -RootPath $RootPath -Lock $Lock -Arguments (@('exec', '-T', 'airflow-scheduler') + $Command)
}

function Get-RunningDeploymentEvidence {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    $Lock
  )

  $serviceMounts = @{}
  foreach ($service in $script:AirflowServices) {
    $serviceMounts[$service] = Get-DevDockerServiceMounts -RootPath $RootPath -Lock $Lock -Service $service
  }

  Assert-DevRuntimeWorktree -Path $Lock.dags.worktree_path
  Assert-DevRuntimeWorktree -Path $Lock.dbt.worktree_path
  $dagHead = (Invoke-DevHarnessGit -RepositoryPath $Lock.dags.worktree_path -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
  $dbtHead = (Invoke-DevHarnessGit -RepositoryPath $Lock.dbt.worktree_path -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()

  $projectEvidence = (Invoke-DevSchedulerCommand -RootPath $RootPath -Lock $Lock -Command @(
      'sh',
      '-c',
      'if test -f "$1"; then printf exists; else printf missing; fi',
      '--',
      $Lock.required_dbt_project
    ) | Select-Object -First 1).Trim()

  if ($projectEvidence -eq 'exists') {
    $projectExists = $true
  }
  elseif ($projectEvidence -eq 'missing') {
    $projectExists = $false
  }
  else {
    throw "unexpected required dbt project probe result: $projectEvidence"
  }

  return @{
    ServiceMounts = $serviceMounts
    RuntimeGitHeads = @{ dags = $dagHead; dbt = $dbtHead }
    RequiredDbtProjectExists = $projectExists
    ServiceHealth = @{
      'airflow-apiserver' = Get-DevDockerServiceHealth -RootPath $RootPath -Lock $Lock -Service 'airflow-apiserver'
      'airflow-scheduler' = Get-DevDockerServiceHealth -RootPath $RootPath -Lock $Lock -Service 'airflow-scheduler'
    }
  }
}

Export-ModuleMember -Function @(
  'Resolve-DevRevision',
  'Ensure-DevRuntimeWorktree',
  'New-DeploymentLock',
  'New-DevDeploymentMutex',
  'Close-DevDeploymentMutex',
  'New-DevComposeOverrideText',
  'Write-DevComposeOverride',
  'Write-DeploymentLockAtomically',
  'Read-DeploymentLock',
  'Assert-DevRuntimeWorktree',
  'Assert-DeploymentMounts',
  'Assert-RunningDeployment',
  'Invoke-DevDockerCompose',
  'Get-RunningDeploymentEvidence'
)
