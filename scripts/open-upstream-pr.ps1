#requires -Version 5.1
<#
.SYNOPSIS
Push a feat/* branch to origin and open or find its upstream PR.
.EXAMPLE
.\scripts\open-upstream-pr.ps1 -Title 'feat: describe the change' -Body 'Summary and tests'
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Title,
    [ValidateNotNullOrEmpty()][string]$Body,
    [ValidateNotNullOrEmpty()][string]$BodyFile,
    [switch]$Draft,
    [switch]$Fill,
    [switch]$FillFirst,
    [switch]$FillVerbose
)

$originalLocation = Get-Location
try {
    . "$PSScriptRoot/git-common.ps1"
    if ($Body -and $BodyFile) { throw 'Use either -Body or -BodyFile, not both.' }
    $fillCount = [int]$Fill.IsPresent + [int]$FillFirst.IsPresent + [int]$FillVerbose.IsPresent
    if ($fillCount -gt 1) { throw 'Choose only one fill option.' }
    if ($BodyFile) { $BodyFile = (Resolve-Path -LiteralPath $BodyFile).Path }
    $prArgs = @()
    if ($Title) { $prArgs += @('--title', $Title) }
    if ($Body) { $prArgs += @('--body', $Body) }
    if ($BodyFile) { $prArgs += @('--body-file', $BodyFile) }
    if ($Draft) { $prArgs += '--draft' }
    if ($Fill) { $prArgs += '--fill' }
    if ($FillFirst) { $prArgs += '--fill-first' }
    if ($FillVerbose) { $prArgs += '--fill-verbose' }
    if ($prArgs.Count -eq 0) { $prArgs = @('--fill') }
    Initialize-Repo
    Require-Command gh
    Assert-CleanTree
    $branch = Get-CurrentBranch
    $mineBranch = if ($env:MINE_BRANCH) { $env:MINE_BRANCH } else { 'nagaozen' }
    if ($branch -cnotmatch '^feat/.+' -or $branch -ceq $BaseBranch -or $branch -ceq $mineBranch) {
        throw 'Upstream PRs must come from feat/*, never main or the integration branch.'
    }
    Invoke-Native gh @('auth', 'status', '--hostname', 'github.com') | Out-Null
    Invoke-Native git @('fetch', '--no-tags', 'upstream', "+refs/heads/${BaseBranch}:refs/remotes/upstream/$BaseBranch")
    $base = "refs/remotes/upstream/$BaseBranch"
    Invoke-Native git @('merge-base', $base, 'HEAD') | Out-Null
    $count = Get-NativeText git @('rev-list', '--count', "$base..HEAD")
    if ([long]$count -eq 0) { throw 'No feature commits to propose.' }
    & git diff --quiet "$base...HEAD"
    if ($LASTEXITCODE -eq 0) { throw 'No file changes to propose.' }
    if ($LASTEXITCODE -ne 1) { throw "git diff failed (exit $LASTEXITCODE)." }
    Write-Host 'Proposed commits (start upstream-bound features from origin/main, not nagaozen):'
    Invoke-Native git @('log', '--oneline', "$base..HEAD")
    if (-not (Test-Ancestor $base HEAD)) {
        Write-Warning "Branch does not contain latest upstream/$BaseBranch; GitHub will check mergeability."
    }
    $head = "$(($ForkRepo -split '/')[0]):$branch"
    $json = Get-NativeText gh @('pr', 'list', '--repo', $UpstreamRepo, '--base', $BaseBranch,
        '--head', $head, '--state', 'open', '--json', 'url')
    $existing = @($json | ConvertFrom-Json)
    Invoke-Native git @('push', '--set-upstream', 'origin', "HEAD:refs/heads/$branch")
    if ($existing.Count -gt 0) {
        Write-Host "`nUpdated existing PR: $($existing[0].url)"
    }
    else {
        Invoke-Native gh (@('pr', 'create', '--repo', $UpstreamRepo, '--base', $BaseBranch, '--head', $head) + $prArgs)
    }
}
catch {
    [Console]::Error.WriteLine('Error: ' + $_.Exception.Message)
    exit 1
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
}
