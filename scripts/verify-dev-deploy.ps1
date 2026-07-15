Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($args.Count -gt 0) {
  throw "verify-dev-deploy.ps1 accepts no arguments; unexpected arguments: $($args -join ', ')"
}

Import-Module (Join-Path $PSScriptRoot 'lib\DevDeployHarness.psm1') -Force -DisableNameChecking

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
$lock = Read-DeploymentLock -RootPath $root
$evidence = Get-RunningDeploymentEvidence -RootPath $root -Lock $lock

Assert-RunningDeployment `
  -Lock $lock `
  -ServiceMounts $evidence.ServiceMounts `
  -ContainerGitHeads $evidence.ContainerGitHeads `
  -RequiredDbtProjectExists $evidence.RequiredDbtProjectExists `
  -ServiceHealth $evidence.ServiceHealth

Write-Output "verified deployment lock $($lock.deployment_lock_path)"
Write-Output "dags $($lock.dags.sha)"
Write-Output "dbt $($lock.dbt.sha)"
Write-Output "required dbt project $($lock.required_dbt_project)"
Write-Output "airflow-apiserver $($evidence.ServiceHealth['airflow-apiserver'])"
Write-Output "airflow-scheduler $($evidence.ServiceHealth['airflow-scheduler'])"
