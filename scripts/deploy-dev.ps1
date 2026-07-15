param(
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\DevDeployHarness.psm1') -Force -DisableNameChecking

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
$revision = Resolve-DevRevision -RootPath $root -SkipFetch:$WhatIf
$lock = New-DeploymentLock -RootPath $root -DagSha $revision.dags -DbtSha $revision.dbt

if ($WhatIf) {
  Write-Output "WhatIf: requested_ref origin/dev"
  Write-Output "WhatIf: dags $($lock.dags.sha) -> $($lock.dags.worktree_path)"
  Write-Output "WhatIf: dbt $($lock.dbt.sha) -> $($lock.dbt.worktree_path)"
  Write-Output "WhatIf: compose override $($lock.compose_override_path)"
  return
}

$mutex = $null
try {
  $mutex = New-DevDeploymentMutex -RootPath $root

  Ensure-DevRuntimeWorktree -RepositoryPath (Join-Path $root 'dags') -WorktreePath $lock.dags.worktree_path -Sha $lock.dags.sha | Out-Null
  Ensure-DevRuntimeWorktree -RepositoryPath (Join-Path $root 'dbt') -WorktreePath $lock.dbt.worktree_path -Sha $lock.dbt.sha | Out-Null
  Write-DeploymentLockAtomically -Lock $lock | Out-Null
  Write-DevComposeOverride -Lock $lock | Out-Null

  Invoke-DevDockerCompose -RootPath $root -Lock $lock -Arguments @('config', '--quiet') | Out-Null
  Invoke-DevDockerCompose -RootPath $root -Lock $lock -Arguments @('up', '-d', '--build') | Out-Null
  & (Join-Path $PSScriptRoot 'verify-dev-deploy.ps1') | Out-Null

  Write-Output "requested_ref origin/dev"
  Write-Output "dags $($lock.dags.sha) -> $($lock.dags.worktree_path)"
  Write-Output "dbt $($lock.dbt.sha) -> $($lock.dbt.worktree_path)"
  Write-Output "deployment lock $($lock.deployment_lock_path)"
  Write-Output "compose override $($lock.compose_override_path)"
}
finally {
  if ($null -ne $mutex) {
    Close-DevDeploymentMutex -Mutex $mutex
  }
}
