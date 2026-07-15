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

Describe 'DevDeployHarness' {
  It 'writes every Airflow service with the locked DAG and DBT mount' {
    $lock = New-DeploymentLock -RootPath 'C:\repo' -DagSha ('a' * 40) -DbtSha ('b' * 40)
    $yaml = New-DevComposeOverrideText -Lock $lock

    foreach ($service in 'airflow-init', 'airflow-apiserver', 'airflow-scheduler', 'airflow-dag-processor', 'airflow-triggerer') {
      $block = Get-ServiceBlock -Yaml $yaml -Service $service
      $block | Should Match ([regex]::Escape("${service}:"))
      $block | Should Match ([regex]::Escape("'$($lock.dags.worktree_path):/opt/airflow/dags:ro'"))
      $block | Should Match ([regex]::Escape("'$($lock.dbt.worktree_path):/opt/airflow/dbt'"))
    }
  }

  It 'rejects resolving any ref except literal origin/dev' {
    $thrown = $null

    try {
      Resolve-DevRevision -RootPath 'C:\repo' -Ref 'dev'
    }
    catch {
      $thrown = $_
    }

    $thrown | Should Not BeNullOrEmpty
    $thrown.Exception.Message | Should Match 'origin/dev'
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
}
