#requires -Version 5.1
<#
.SYNOPSIS
One-time migration. Run without -Apply to see the plan.
.DESCRIPTION
Preserves local main in a backup ref and uncommitted/untracked work in a stash.
Carries ONLY the named workflow scripts to a clean nagaozen checkout. Other
local work remains in the backup/stash for selective recovery. Does not touch
upstream or feature branches. An exact lease protects the one-time main rewrite.
#>
[CmdletBinding()]
param([switch]$Apply)

$originalLocation = Get-Location
$snapshot = $null
try {
    . "$PSScriptRoot/git-common.ps1"
    if ($BaseBranch -cne 'main' -or ($env:MINE_BRANCH -and $env:MINE_BRANCH -cne 'nagaozen')) {
        throw 'This one-time migration supports main and nagaozen only.'
    }
    Initialize-Repo
    if ((Get-CurrentBranch) -cne 'main') { throw 'Run migration from local main. For an interrupted migration, inspect backups and reconcile manually.' }
    Invoke-Native git @('fetch', '--no-tags', 'upstream', '+refs/heads/main:refs/remotes/upstream/main')
    Invoke-Native git @('fetch', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main',
        '+refs/heads/nagaozen:refs/remotes/origin/nagaozen')
    $oldLocal = Get-NativeText git @('rev-parse', 'refs/heads/main')
    $oldRemote = Get-NativeText git @('rev-parse', 'refs/remotes/origin/main')
    $mine = Get-NativeText git @('rev-parse', 'refs/remotes/origin/nagaozen')
    $target = Get-NativeText git @('rev-parse', 'refs/remotes/upstream/main')
    & git show-ref --verify --quiet refs/heads/nagaozen
    if ($LASTEXITCODE -eq 0) { throw 'Local nagaozen already exists. Stop and inspect it; this script will not overwrite it.' }
    if ($LASTEXITCODE -ne 1) { throw 'Could not check local branch existence.' }
    if (-not (Test-Ancestor $oldRemote $mine)) {
        throw 'origin/nagaozen must preserve all of the current origin/main history before migration.'
    }
    Invoke-Native git @('merge-base', $mine, $target) | Out-Null
    Write-Host "Local main backup: $oldLocal"
    Write-Host "Remote main backup: $oldRemote"
    Write-Host "Clean nagaozen base: $mine"
    Write-Host "New main mirror: $target"
    Write-Host 'Only scripts/ workflow files will be carried over. Other local-only changes stay in backups/stash.'
    Write-Host 'The final atomic push backs up remote main, updates nagaozen, and realigns main using an exact lease.'
    if (-not $Apply) {
        Write-Host 'No branches or working files changed. Review the plan, then rerun with -Apply.'
        return
    }
    Invoke-Native git @('var', 'GIT_AUTHOR_IDENT') | Out-Null
    Invoke-Native git @('var', 'GIT_COMMITTER_IDENT') | Out-Null
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $localBackup = "backup/local-main-$stamp"
    $remoteBackup = "backup/origin-main-$stamp"
    # Copy reviewed working versions before stashing/switching, outside the repo.
    $snapshot = Join-Path ([System.IO.Path]::GetTempPath()) "sandbox-workflow-$stamp"
    New-Item -ItemType Directory -Path $snapshot | Out-Null
    $files = @('git-common.sh', 'git-common.ps1', 'update-from-upstream.sh',
        'update-from-upstream.ps1', 'open-upstream-pr.sh', 'open-upstream-pr.ps1',
        'migrate-to-nagaozen.ps1', 'README.md')
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $snapshot $file)
    }
    Invoke-Native git @('branch', $localBackup, $oldLocal)
    Invoke-Native git @('branch', $remoteBackup, $oldRemote)
    Write-Host "Preserved local history: $localBackup"
    $status = Get-NativeText git @('status', '--porcelain', '--untracked-files=normal')
    if ($status) {
        Invoke-Native git @('stash', 'push', '--include-untracked', '-m', "before-nagaozen-$stamp")
        $stashId = Get-NativeText git @('rev-parse', 'refs/stash')
        Write-Host "Preserved uncommitted work in stash $stashId (not automatically reapplied)."
    }
    Assert-CleanTree
    Invoke-Native git @('switch', '--create', 'nagaozen', '--track', 'origin/nagaozen')
    $root = Get-NativeText git @('rev-parse', '--show-toplevel')
    $scripts = Join-Path $root 'scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $snapshot $file) -Destination (Join-Path $scripts $file) -Force
    }
    $ignore = Join-Path $root '.gitignore'
    $text = [System.IO.File]::ReadAllText($ignore)
    $text = $text.TrimEnd() + "`n`n# Local diagnostic/build artifacts`n/.pnpm-store/`n/tmp/`n/.fugu_history/`n"
    [System.IO.File]::WriteAllText($ignore, $text, (New-Object System.Text.UTF8Encoding($false)))
    $paths = @('.gitignore') + @($files | ForEach-Object { "scripts/$_" })
    Invoke-Native git (@('add', '--') + $paths)
    & git diff --cached --quiet
    $diffCode = $LASTEXITCODE
    if ($diffCode -eq 1) {
        Invoke-Native git @('commit', '-m', 'chore: adopt upstream mirror and nagaozen integration workflow')
    }
    elseif ($diffCode -ne 0) { throw 'Could not inspect staged changes.' }
    & git merge --no-edit $target
    if ($LASTEXITCODE -ne 0) {
        throw 'Upstream merge failed. Nothing was pushed; backups remain. Resolve or abort the merge on nagaozen. Do not rerun migration blindly.'
    }
    Assert-CleanTree
    $newMine = Get-NativeText git @('rev-parse', 'HEAD')
    # Only main gets a force-with-lease override. The nagaozen update is normal.
    Invoke-Native git @('push', '--atomic', "--force-with-lease=refs/heads/main:$oldRemote", 'origin',
        "${oldRemote}:refs/heads/$remoteBackup", "${target}:refs/heads/main", "${newMine}:refs/heads/nagaozen")
    foreach ($pair in @(@('main', $target), @('nagaozen', $newMine), @($remoteBackup, $oldRemote))) {
        $remote = Get-NativeText git @('ls-remote', '--exit-code', 'origin', "refs/heads/$($pair[0])")
        if (($remote -split '\s+')[0] -ne $pair[1]) { throw 'Remote verification mismatch. Inspect branches before proceeding.' }
    }
    # main is not checked out now. Git refuses this if it is checked out elsewhere.
    if ((Get-NativeText git @('rev-parse', 'refs/heads/main')) -ne $oldLocal) {
        throw 'Local main changed during migration; leaving it untouched.'
    }
    Invoke-Native git @('branch', '--force', 'main', $target)
    Invoke-Native git @('branch', '--set-upstream-to=origin/main', 'main')
    Invoke-Native git @('branch', '--set-upstream-to=origin/nagaozen', 'nagaozen')
    Write-Host 'Migration verified. Current branch: nagaozen. Local/origin main mirror the fetched upstream snapshot.'
    Write-Host 'Keep backups and any stash until you have reviewed all local-only work. Never merge the diagnostic backup wholesale.'
}
catch {
    [Console]::Error.WriteLine('Error: ' + $_.Exception.Message)
    if ($snapshot) { [Console]::Error.WriteLine("Script snapshot retained at $snapshot") }
    exit 1
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
}
