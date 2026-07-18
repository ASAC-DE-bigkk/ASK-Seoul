Set-StrictMode -Version Latest

$script:TrafficWeatherLineageOverlay = 'docker-compose.traffic-weather-lineage.yml'

$script:AirflowServices = @(
  'airflow-init',
  'airflow-apiserver',
  'airflow-scheduler',
  'airflow-dag-processor',
  'airflow-triggerer'
)

$script:DeploymentComposeLabelServices = @(
  'postgres',
  'marquez-db',
  'marquez-api',
  'marquez-web',
  'trino',
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
    [hashtable]$ServiceHealth,

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

  Assert-CurrentLineageOverlayFingerprint -Lock $Lock -CurrentLineageOverlaySha256 $CurrentLineageOverlaySha256
  Assert-DeploymentComposeLabels -Lock $Lock -ComposeLabels $ComposeLabels
  Assert-SchedulerLineageChecks -SchedulerLineageChecks $SchedulerLineageChecks
  Assert-AirflowPools -AirflowPools $AirflowPools
  Assert-MarquezDeploymentRuntime -MarquezRuntime $MarquezRuntime -MarquezEndpointChecks $MarquezEndpointChecks
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
  $composeArgs = (Get-DevComposeFileArguments -RootPath $root -Lock $Lock) + $Arguments
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
  $object = $json | ConvertFrom-Json
  $labels = @{}
  foreach ($property in $object.PSObject.Properties) {
    $labels[$property.Name] = $property.Value
  }
  return $labels
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
    if (-not $containerId) {
      throw "container id missing for service $service"
    }

    $state = (Invoke-DevHarnessExternal -FilePath 'docker' -Arguments @('inspect', $containerId, '--format', '{{json .State}}') | Select-Object -First 1) | ConvertFrom-Json
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
    # Windows PowerShell defines `curl` as an Invoke-WebRequest alias. Pin the
    # native executable so curl flags and exit codes retain their CLI meaning.
    AdminHttpStatus = [int]((Invoke-DevHarnessExternal -FilePath 'curl.exe' -Arguments @('-sS', '-o', 'NUL', '-w', '%{http_code}', 'http://127.0.0.1:5001/healthcheck') | Select-Object -First 1).Trim())
    MetadataHttpStatus = [int]((Invoke-DevHarnessExternal -FilePath 'curl.exe' -Arguments @('-sS', '-o', 'NUL', '-w', '%{http_code}', 'http://127.0.0.1:5000/api/v1/namespaces') | Select-Object -First 1).Trim())
  }
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

  $composeLabels = @{}
  foreach ($service in $script:DeploymentComposeLabelServices) {
    $composeLabels[$service] = Get-DevDockerServiceLabels -RootPath $RootPath -Lock $Lock -Service $service
  }

  return @{
    ServiceMounts = $serviceMounts
    RuntimeGitHeads = @{ dags = $dagHead; dbt = $dbtHead }
    RequiredDbtProjectExists = $projectExists
    ServiceHealth = @{
      'airflow-apiserver' = Get-DevDockerServiceHealth -RootPath $RootPath -Lock $Lock -Service 'airflow-apiserver'
      'airflow-scheduler' = Get-DevDockerServiceHealth -RootPath $RootPath -Lock $Lock -Service 'airflow-scheduler'
    }
    CurrentLineageOverlaySha256 = Get-DevFileSha256 -Path $Lock.lineage_overlay_path
    ComposeLabels = $composeLabels
    SchedulerLineageChecks = Get-DevSchedulerLineageChecks -RootPath $RootPath -Lock $Lock
    AirflowPools = Get-DevAirflowPools -RootPath $RootPath -Lock $Lock
    MarquezRuntime = Get-DevMarquezRuntime -RootPath $RootPath -Lock $Lock
    MarquezEndpointChecks = Get-DevMarquezEndpointChecks -RootPath $RootPath -Lock $Lock
  }
}

Export-ModuleMember -Function @(
  'Resolve-DevRevision',
  'Ensure-DevRuntimeWorktree',
  'Get-DevFileSha256',
  'Get-DevComposeFileArguments',
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
