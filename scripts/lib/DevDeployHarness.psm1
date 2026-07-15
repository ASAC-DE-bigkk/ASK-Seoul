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

function Invoke-DevHarnessGit {
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

function Resolve-DevRevision {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [string]$Ref = 'origin/dev'
  )

  $root = Normalize-DevHarnessPath -Path $RootPath
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
    compose_override_path = (Join-Path $runtime 'docker-compose.generated.yml')
    required_dbt_project = '/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml'
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
  $parent = Split-Path -Parent $worktree
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  if (-not (Test-Path -LiteralPath $worktree)) {
    Invoke-DevHarnessGit -RepositoryPath $repository -Arguments @('worktree', 'add', '--detach', $worktree, $Sha) | Out-Null
  }
  else {
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

Export-ModuleMember -Function @(
  'Resolve-DevRevision',
  'Ensure-DevRuntimeWorktree',
  'New-DeploymentLock',
  'New-DevComposeOverrideText',
  'Write-DevComposeOverride',
  'Assert-DevRuntimeWorktree',
  'Assert-DeploymentMounts'
)
