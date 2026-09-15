#requires -Version 5.1
<#
.SYNOPSIS
Mirror upstream main and merge upstream into local/origin nagaozen.
.EXAMPLE
.\scripts\update-from-upstream.ps1 -AllowLocalCommits
#>
[CmdletBinding()]
param([switch]$AllowLocalCommits)

$originalLocation = Get-Location
try {
    . "$PSScriptRoot/git-common.ps1"
    $mineBranch = if ($env:MINE_BRANCH) { $env:MINE_BRANCH } else { 'nagaozen' }
    Initialize-Repo
    Assert-CleanTree
    Invoke-Native git @('check-ref-format', "refs/heads/$mineBranch") | Out-Null
    if ($mineBranch -ceq $BaseBranch) { throw 'MINE_BRANCH must differ from BASE_BRANCH.' }
    if ((Get-CurrentBranch) -cne $mineBranch) { throw "Switch to $mineBranch first." }

    Invoke-Native git @('fetch', '--no-tags', 'upstream', "+refs/heads/${BaseBranch}:refs/remotes/upstream/$BaseBranch")
    Invoke-Native git @('fetch', '--no-tags', 'origin',
        "+refs/heads/${BaseBranch}:refs/remotes/origin/$BaseBranch",
        "+refs/heads/${mineBranch}:refs/remotes/origin/$mineBranch")
    $target = Get-NativeText git @('rev-parse', "refs/remotes/upstream/$BaseBranch")
    $forkTip = Get-NativeText git @('rev-parse', "refs/remotes/origin/$BaseBranch")
    $mineTip = Get-NativeText git @('rev-parse', "refs/remotes/origin/$mineBranch")
    if (-not (Test-Ancestor $forkTip $target)) {
        throw "origin/$BaseBranch is not an upstream mirror. Complete the one-time migration; nothing was pushed."
    }
    $behind = Test-Ancestor HEAD $mineTip
    if (-not $behind) {
        if (-not (Test-Ancestor $mineTip HEAD)) {
            throw "Local and origin/$mineBranch diverged. Reconcile manually; nothing was pushed."
        }
        Write-Host 'Unpublished local commits:'
        Invoke-Native git @('log', '--oneline', "$mineTip..HEAD")
        if (-not $AllowLocalCommits) {
            throw 'Review these commits, then rerun with -AllowLocalCommits to publish them.'
        }
    }
    Invoke-Native git @('merge-base', 'HEAD', $target) | Out-Null
    if ($behind) { Invoke-Native git @('merge', '--ff-only', $mineTip) }
    & git merge --no-edit $target
    if ($LASTEXITCODE -ne 0) {
        throw 'Upstream merge failed; nothing was pushed. Resolve conflicts, stage specific paths, and git commit (or git merge --abort). Then rerun with -AllowLocalCommits.'
    }
    $localTip = Get-NativeText git @('rev-parse', 'HEAD')
    # Atomically update both remote refs; never force-push.
    Invoke-Native git @('push', '--atomic', 'origin',
        "${target}:refs/heads/$BaseBranch", "${localTip}:refs/heads/$mineBranch")
    Invoke-Native git @('branch', "--set-upstream-to=origin/$mineBranch", $mineBranch)
    foreach ($pair in @(@($BaseBranch, $target), @($mineBranch, $localTip))) {
        $remote = Get-NativeText git @('ls-remote', '--exit-code', 'origin', "refs/heads/$($pair[0])")
        if (($remote -split '\s+')[0] -ne $pair[1]) { throw 'Remote changed during verification.' }
    }
    Write-Host "`nMirrored origin/$BaseBranch; synchronized local and origin/$mineBranch at $localTip."
}
catch {
    [Console]::Error.WriteLine('Error: ' + $_.Exception.Message)
    exit 1
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
}
