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
  -RuntimeGitHeads $evidence.RuntimeGitHeads `
  -RequiredDbtProjectExists $evidence.RequiredDbtProjectExists `
  -ServiceHealth $evidence.ServiceHealth `
  -CurrentLineageOverlaySha256 $evidence.CurrentLineageOverlaySha256 `
  -ComposeLabels $evidence.ComposeLabels `
  -SchedulerLineageChecks $evidence.SchedulerLineageChecks `
  -AirflowPools $evidence.AirflowPools `
  -MarquezRuntime $evidence.MarquezRuntime `
  -MarquezEndpointChecks $evidence.MarquezEndpointChecks

Write-Output "verified deployment lock $($lock.deployment_lock_path)"
Write-Output "dags $($lock.dags.sha)"
Write-Output "dbt $($lock.dbt.sha)"
Write-Output "required dbt project $($lock.required_dbt_project)"
Write-Output "airflow-apiserver $($evidence.ServiceHealth['airflow-apiserver'])"
Write-Output "airflow-scheduler $($evidence.ServiceHealth['airflow-scheduler'])"
Write-Output "lineage overlay $($lock.lineage_overlay_path)"
Write-Output "lineage overlay fingerprint verified $($evidence.CurrentLineageOverlaySha256)"
foreach ($service in 'marquez-db', 'marquez-api', 'marquez-web') {
  $runtime = $evidence.MarquezRuntime[$service]
  Write-Output "$service status=$($runtime.Status) health=$($runtime.Health) memory=$($runtime.Memory) restartPolicy=$($runtime.RestartPolicy) restartCount=$($runtime.RestartCount) oomKilled=$($runtime.OOMKilled)"
}
Write-Output "marquez dns $($evidence.MarquezEndpointChecks.Dns)"
Write-Output "trino_traffic_heavy $($evidence.AirflowPools['trino_traffic_heavy'])"
Write-Output "trino_weather_heavy $($evidence.AirflowPools['trino_weather_heavy'])"
