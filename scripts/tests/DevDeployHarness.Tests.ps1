Import-Module (Join-Path $PSScriptRoot '..\lib\DevDeployHarness.psm1') -Force -DisableNameChecking

Describe 'DevDeployHarness' {
  It 'writes every Airflow service with the locked DAG and DBT mount' {
    $lock = New-DeploymentLock -RootPath 'C:\repo' -DagSha ('a' * 40) -DbtSha ('b' * 40)
    $yaml = New-DevComposeOverrideText -Lock $lock

    foreach ($service in 'airflow-init', 'airflow-apiserver', 'airflow-scheduler', 'airflow-dag-processor', 'airflow-triggerer') {
      $yaml | Should Match "${service}:`n"
    }
    $yaml | Should Match ([regex]::Escape($lock.dags.worktree_path))
    $yaml | Should Match ([regex]::Escape($lock.dbt.worktree_path))
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
    $lock = New-DeploymentLock -RootPath 'C:\repo' -DagSha ('a' * 40) -DbtSha ('b' * 40)
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
}
