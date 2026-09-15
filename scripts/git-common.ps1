# Shared helpers for Windows PowerShell 5.1 and PowerShell 7.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# We check native exit codes explicitly, including expected nonzero results.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$UpstreamRepo = 'agent-infra/sandbox'
$ForkRepo = 'nagaozen/sandbox'
$BaseBranch = if ($env:BASE_BRANCH) { $env:BASE_BRANCH } else { 'main' }

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed (exit $LASTEXITCODE)."
    }
}

function Get-NativeText {
    param([string]$Command, [string[]]$Arguments)
    $lines = @(Invoke-Native $Command $Arguments)
    return ($lines -join "`n").Trim()
}

function Test-RepoUrl {
    param([string]$Url, [string]$Repo)
    return $Url -cin @(
        "https://github.com/$Repo", "https://github.com/$Repo.git",
        "git@github.com:$Repo", "git@github.com:$Repo.git",
        "ssh://git@github.com/$Repo", "ssh://git@github.com/$Repo.git"
    )
}

function Assert-Remote {
    param([string]$Remote, [string]$Repo)
    $url = Get-NativeText git @('remote', 'get-url', $Remote)
    if (-not (Test-RepoUrl $url $Repo)) {
        throw "Remote '$Remote' must point to github.com/$Repo; found $url"
    }
    $pushUrls = @(Invoke-Native git @('remote', 'get-url', '--push', '--all', $Remote))
    foreach ($url in $pushUrls) {
        if (-not (Test-RepoUrl $url $Repo)) {
            throw "Unexpected push URL for '${Remote}': $url"
        }
    }
}

function Initialize-Repo {
    Require-Command git
    $root = Get-NativeText git @('rev-parse', '--show-toplevel')
    Set-Location -LiteralPath $root
    Invoke-Native git @('check-ref-format', "refs/heads/$BaseBranch") | Out-Null
    Assert-Remote upstream $UpstreamRepo
    Assert-Remote origin $ForkRepo
    foreach ($state in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply')) {
        $path = Get-NativeText git @('rev-parse', '--git-path', $state)
        if (Test-Path -LiteralPath $path) {
            throw "Finish or abort the current Git operation ($state) first."
        }
    }
}

function Assert-CleanTree {
    $status = Get-NativeText git @('status', '--porcelain', '--untracked-files=normal')
    if ($status) {
        throw 'Working tree is not clean. Commit or stash your changes (including untracked files) first.'
    }
}

function Get-CurrentBranch {
    $branch = & git symbolic-ref --quiet --short HEAD
    if ($LASTEXITCODE -ne 0) {
        throw 'Detached HEAD: switch to a local branch first.'
    }
    return $branch
}

function Test-Ancestor {
    param([string]$Ancestor, [string]$Descendant)
    & git merge-base --is-ancestor $Ancestor $Descendant
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($LASTEXITCODE -eq 1) { return $false }
    throw "git merge-base failed (exit $LASTEXITCODE)."
}
