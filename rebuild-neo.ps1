param(
    [Parameter(Position = 0)]
    [string]$BaseBranch,
    [Parameter(Position = 1)]
    [string]$FeatureBranch,
    [Alias('f')]
    [switch]$Force,
    [Alias('n')]
    [switch]$DryRun,
    [switch]$RebuiltTag,
    [string]$PatchDir = ".git/rebuild-patches"
)

# Force PowerShell output encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Print every git command before it runs.
# -Query commands are read-only and always executed (dry-run needs their output to build the plan).
# Everything else is skipped entirely under -DryRun, so no repository state ever changes.
function Invoke-Git {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$CommandArgs,
        [switch]$Query,
        [switch]$Capture
    )
    Write-Host ('  $ git ' + ($CommandArgs -join ' ')) -ForegroundColor DarkGray
    if ($Query) {
        return (& git @CommandArgs)
    }
    if ($DryRun) {
        return
    }
    if ($Capture) {
        return (& git @CommandArgs)
    }
    & git @CommandArgs
}

# Read-only check: does '$Child' already contain '$Ancestor'?
# Always executed (safe under -DryRun, changes no state) and printed for the log.
function Test-Ancestor {
    param(
        [Parameter(Mandatory = $true)] [string]$Ancestor,
        [Parameter(Mandatory = $true)] [string]$Child
    )
    Write-Host ('  $ git merge-base --is-ancestor ' + $Ancestor + ' ' + $Child) -ForegroundColor DarkGray
    & git merge-base --is-ancestor $Ancestor $Child 2>$null
    return ($LASTEXITCODE -eq 0)
}

# BaseBranch must be provided explicitly; no default inside the script.
if ([string]::IsNullOrWhiteSpace($BaseBranch)) {
    Write-Host "Error: base branch is required." -ForegroundColor Red
    Write-Host "Usage: .\rebuild-neo.ps1 <base-branch> [<feature-branch>] [-f] [-n] [-RebuiltTag]" -ForegroundColor Yellow
    Write-Host "  <base> [<feature>]  positional args, same style as: git rebase <upstream> [<branch>]" -ForegroundColor Yellow
    Write-Host "  -f / -Force         overwrite an existing temp branch" -ForegroundColor Yellow
    Write-Host "  -n / -DryRun        print every command, execute nothing" -ForegroundColor Yellow
    Write-Host "  -RebuiltTag         append ' (Rebuilt)' to rebuilt merge messages (default: off)" -ForegroundColor Yellow
    exit 1
}

# Must run inside the target repository
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: current directory is not a git repository. cd into the target repo first." -ForegroundColor Red
    exit 1
}

# Refuse to start while a merge / cherry-pick / rebase / revert is already in progress.
# A leftover MERGE_HEAD or CHERRY_PICK_HEAD would make checkout and replay ambiguous.
$InProgress = @()
if (Test-Path (Join-Path (git rev-parse --git-dir) 'MERGE_HEAD'))       { $InProgress += 'merge' }
if (Test-Path (Join-Path (git rev-parse --git-dir) 'CHERRY_PICK_HEAD'))  { $InProgress += 'cherry-pick' }
if (Test-Path (Join-Path (git rev-parse --git-dir) 'rebase-merge'))      { $InProgress += 'rebase' }
if (Test-Path (Join-Path (git rev-parse --git-dir) 'rebase-apply'))      { $InProgress += 'rebase' }
if (Test-Path (Join-Path (git rev-parse --git-dir) 'REVERT_HEAD'))       { $InProgress += 'revert' }
if ($InProgress.Count -gt 0) {
    Write-Host ("Error: a " + ($InProgress -join '/') + " operation is already in progress in this repo.") -ForegroundColor Red
    Write-Host "       Finish or abort it first (e.g. 'git merge --abort', 'git cherry-pick --abort'," -ForegroundColor Red
    Write-Host "       'git rebase --abort', 'git revert --abort') and clear any staged changes, then re-run." -ForegroundColor Red
    exit 1
}

# Refuse to run when tracked files are already modified: replay would mix our changes into the result.
$DirtyTracked = git status --porcelain --untracked-files=no
if ($LASTEXITCODE -eq 0 -and $DirtyTracked) {
    Write-Host "Error: the working tree has modified tracked files:" -ForegroundColor Red
    $DirtyTracked | Select-Object -First 10 | ForEach-Object { Write-Host ("       " + $_) -ForegroundColor Red }
    Write-Host "       Commit or stash them first so the rebuild starts from a clean tree." -ForegroundColor Red
    exit 1
}

# Branch we started on, captured before any checkout, for display purposes.
$StartBranch = git branch --show-current

git rev-parse --verify --quiet "$BaseBranch^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: branch/commit '$BaseBranch' does not exist." -ForegroundColor Red
    exit 1
}

# FeatureBranch is optional: falls back to the current branch.
# This is safe because the script never modifies it; work happens on a temp branch only.
if (-not [string]::IsNullOrWhiteSpace($FeatureBranch)) {
    git rev-parse --verify --quiet "$FeatureBranch^{commit}" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: branch/commit '$FeatureBranch' does not exist." -ForegroundColor Red
        exit 1
    }
    Write-Host "Source branch: $FeatureBranch (specified explicitly)" -ForegroundColor Cyan
} else {
    $CurrentBranch = $StartBranch
    if ([string]::IsNullOrWhiteSpace($CurrentBranch)) {
        Write-Host "Error: detached HEAD, cannot auto-detect source branch. Pass it explicitly: rebuild-neo <base> <feature>" -ForegroundColor Red
        exit 1
    }

    # Re-running while still sitting on a rebuild temp branch: recover the real source
    # name instead of nesting rebuild/rebuild/... so the "already exists" guard can fire.
    if ($CurrentBranch -match '^rebuild/(.+)-rebuilt$') {
        $FeatureBranch = $Matches[1]
        Write-Host "Source branch not specified; current branch is temp '$CurrentBranch'," -ForegroundColor Yellow
        Write-Host "  -> recovering source branch: $FeatureBranch" -ForegroundColor Yellow
    } else {
        $FeatureBranch = $CurrentBranch
        Write-Host "Source branch not specified; auto-detected current branch: $FeatureBranch" -ForegroundColor Yellow
    }

    git rev-parse --verify --quiet "$FeatureBranch^{commit}" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: recovered source branch '$FeatureBranch' no longer exists." -ForegroundColor Red
        Write-Host "       Pass the source branch explicitly: rebuild-neo <base> <feature>" -ForegroundColor Red
        exit 1
    }
}

# Temp branch always lives under the rebuild/ namespace to avoid name collisions.
$NewBranch = "rebuild/$FeatureBranch-rebuilt"

if ($Force) {
    Write-Host "Force mode (-f): existing temp branch '$NewBranch' will be overwritten." -ForegroundColor Magenta
} else {
    git rev-parse --verify --quiet "$NewBranch^{commit}" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Error: temp branch '$NewBranch' already exists." -ForegroundColor Red
        Write-Host "       Re-run with -f to overwrite it, or delete it first." -ForegroundColor Red
        exit 1
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Smart segment rebuild & re-merge flow (UTF-8 safe)" -ForegroundColor Cyan
Write-Host " Base: $BaseBranch | Source: $FeatureBranch" -ForegroundColor Cyan
$StartBranchLabel = if ([string]::IsNullOrWhiteSpace($StartBranch)) { "(detached HEAD)" } else { $StartBranch }
Write-Host " Current branch: $StartBranchLabel" -ForegroundColor Yellow
Write-Host " TEMP branch to work on: $NewBranch" -ForegroundColor Magenta
Write-Host " Patch dir: $PatchDir" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host " Mode: DRY RUN (commands printed only, nothing executed)" -ForegroundColor Magenta
}
if ($RebuiltTag) {
    Write-Host " Rebuilt tag: ' (Rebuilt)' appended to rebuilt merge messages" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Test-Path $PatchDir)) {
    Write-Host ('  $ New-Item -ItemType Directory -Path ' + $PatchDir) -ForegroundColor DarkGray
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $PatchDir | Out-Null
    }
}

# Absolute patch path resolved without requiring the directory to exist (dry-run never creates it).
$absolutePatchPath = if ([System.IO.Path]::IsPathRooted($PatchDir)) {
    [System.IO.Path]::GetFullPath($PatchDir)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PatchDir))
}

# -B creates the temp branch, or resets it to base when -f is given.
$CheckoutAction = if ($Force) { "-B" } else { "-b" }
Invoke-Git -CommandArgs @('checkout', $CheckoutAction, $NewBranch, $BaseBranch)
if (-not $DryRun -and $LASTEXITCODE -ne 0) {
    Write-Host "Error: cannot create or switch to temp branch $NewBranch" -ForegroundColor Red
    exit 1
}

# --first-parent: replay only mainline nodes (merges stay merges; no double-apply of side-branch commits)
$commits = Invoke-Git -Query -CommandArgs @('log', "$BaseBranch..$FeatureBranch", '--first-parent', '--reverse', '--oneline')

# Nothing to replay: same branch, or the feature is already fully contained in base.
# Don't fall through to a misleading "Rebuild completed!" banner.
if (-not $commits -or @($commits).Count -eq 0) {
    if (Test-Ancestor $FeatureBranch $BaseBranch) {
        Write-Host "Nothing to rebuild: '$FeatureBranch' is already fully contained in '$BaseBranch'." -ForegroundColor Yellow
    } else {
        Write-Host "Nothing to rebuild: '$BaseBranch..$FeatureBranch' has no first-parent commits." -ForegroundColor Yellow
    }
    exit 0
}

foreach ($c in $commits) {
    $parts = $c -split ' ', 2
    $hash = $parts[0]
    $msg = $parts[1]
    # '(Rebuilt)' marker is opt-in via -RebuiltTag; the message stays verbatim by default.
    $commitMessage = if ($RebuiltTag) { "$msg (Rebuilt)" } else { $msg }

    $parentLine = (Invoke-Git -Query -CommandArgs @('rev-list', '--parents', '-n', '1', $hash)) -join ' '
    $parentCount = $parentLine.Split(' ').Length - 1

    # A merge node is a commit with 2+ parents. The commit MESSAGE is never used as a
    # signal: a single-parent commit whose subject starts with "Merge" (squash-style
    # messages, "Merge remote-tracking branch ..." squashes) must stay on the
    # cherry-pick path, otherwise merging it would drag the old history back in as an
    # ancestor - exactly what this tool exists to prevent.
    if ($parentCount -gt 1) {
        Write-Host "`n[Merge commit detected] $hash - $msg" -ForegroundColor Yellow

        # Side parents ^2..^N (octopus merges have 3+ parents; all must be replayed or
        # their content is silently lost).
        $sideParents = @()
        for ($i = 2; $i -le $parentCount; $i++) { $sideParents += "$hash^$i" }

        # Case (b): every side parent is already contained in HEAD (e.g. the merge target
        # is the base branch itself, or was brought in by an earlier replayed merge).
        # `git merge --no-ff` would answer "Already up to date." and create NO commit,
        # silently dropping the node. Force an empty merge commit with commit-tree so the
        # rebuilt history keeps a 1:1 node mapping; content stays unchanged.
        $allContained = $false
        if (-not $DryRun) {
            $allContained = $true
            foreach ($t in $sideParents) {
                if (-not (Test-Ancestor $t 'HEAD')) { $allContained = $false; break }
            }
        }

        if ($allContained) {
            Write-Host "  -> All merge targets already contained in HEAD; forcing an EMPTY merge commit (node preserved, content unchanged)." -ForegroundColor Yellow
            $ctArgs = @('commit-tree', 'HEAD^{tree}', '-p', 'HEAD')
            foreach ($t in $sideParents) { $ctArgs += @('-p', $t) }
            $ctArgs += @('-m', $commitMessage)
            $newCommit = Invoke-Git -Capture -CommandArgs $ctArgs
            if ($LASTEXITCODE -ne 0 -or "$newCommit" -notmatch '^[0-9a-f]{7,40}$') {
                Write-Host "  -> Error: commit-tree failed for empty merge of $hash" -ForegroundColor Red
                exit 1
            }
            $newCommit = "$newCommit".Trim()
            # Tree is identical to HEAD's tree, so --hard moves the branch without touching content.
            Invoke-Git -CommandArgs @('reset', '--hard', $newCommit)
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  -> Error: failed to attach the empty merge commit $newCommit" -ForegroundColor Red
                exit 1
            }
            Write-Host "  -> Empty merge commit created: $($newCommit.Substring(0,8))" -ForegroundColor Green
            continue
        }

        $patchPath = "$PatchDir/merge-$hash.patch"
        $targetPatchFile = "$absolutePatchPath/merge-$hash.patch"

        # --binary: embed binary payloads, otherwise `git apply --3way` in the conflict
        # fallback cannot restore binary files touched by the merge.
        # git writes the patch file directly: no shell redirection, no caret escaping, no encoding corruption
        Invoke-Git -CommandArgs @('diff', '--binary', "--output=$targetPatchFile", "$hash^", $hash)
        if ($DryRun) {
            Write-Host "  -> (dry run) would extract patch to: $patchPath" -ForegroundColor DarkGray
        } elseif ($LASTEXITCODE -ne 0) {
            Write-Host "  -> Error: failed to extract patch for $hash" -ForegroundColor Red
            exit 1
        } else {
            Write-Host "  -> Patch extracted safely: $patchPath" -ForegroundColor DarkYellow
        }

        Write-Host "  -> Re-running git merge --no-ff (feature tip(s), detached from original merges)..." -ForegroundColor Yellow
        # Replay every side parent in one merge command: keeps the node an octopus merge
        # (1:1 node mapping) and nothing is lost. If any pair conflicts, git aborts the
        # whole octopus and the patch fallback below recovers the content.
        Invoke-Git -CommandArgs (@('merge', '--no-ff') + $sideParents + @('-m', $commitMessage))

        if ($DryRun) {
            Write-Host "  -> (dry run) command printed above, not executed." -ForegroundColor DarkGray
        } elseif ($LASTEXITCODE -ne 0) {
            Write-Host "  -> Conflict detected! Falling back to patch application..." -ForegroundColor Yellow

            Invoke-Git -CommandArgs @('merge', '--abort')
            Invoke-Git -CommandArgs @('apply', '--3way', '--index', $targetPatchFile)
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  -> Patch could not apply cleanly. Pausing: resolve conflicts in the working tree," -ForegroundColor Red
                Write-Host "  ->    stage the result with 'git add -u', then press any key to continue..." -ForegroundColor Red
                pause
            } else {
                Write-Host "  -> Patch applied successfully! Finishing as a real merge commit..." -ForegroundColor Green
            }

            # Finish with write-tree + commit-tree (NOT a plain `git commit`): the node keeps
            # its merge structure - HEAD plus every side parent - so the side tips stay
            # reachable and the rebuilt node mapping stays 1:1. A plain commit here would
            # silently degrade the merge into a single-parent commit.
            $mergedTree = Invoke-Git -Capture -CommandArgs @('write-tree')
            if ($LASTEXITCODE -ne 0 -or "$mergedTree" -notmatch '^[0-9a-f]{7,40}$') {
                Write-Host "  -> Error: git write-tree failed - index not in a committable state." -ForegroundColor Red
                exit 1
            }
            $ctArgs = @('commit-tree', "$mergedTree".Trim(), '-p', 'HEAD')
            foreach ($t in $sideParents) { $ctArgs += @('-p', $t) }
            $ctArgs += @('-m', $commitMessage)
            $newCommit = Invoke-Git -Capture -CommandArgs $ctArgs
            if ($LASTEXITCODE -ne 0 -or "$newCommit" -notmatch '^[0-9a-f]{7,40}$') {
                Write-Host "  -> Error: commit-tree failed while finishing the fallback merge." -ForegroundColor Red
                exit 1
            }
            $newCommit = "$newCommit".Trim()
            Invoke-Git -CommandArgs @('reset', '--hard', $newCommit)
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  -> Error: failed to attach the fallback merge commit $newCommit" -ForegroundColor Red
                exit 1
            }
            Write-Host "  -> Fallback merge commit created: $($newCommit.Substring(0,8)) (structure preserved)" -ForegroundColor Green
        } else {
            Write-Host "  -> Merge completed cleanly, no conflicts." -ForegroundColor Green
        }

    } else {
        Write-Host "`n[Regular commit] $hash - $msg" -ForegroundColor Cyan
        # An empty commit (no file changes vs its parent) makes plain cherry-pick fail with
        # "The previous cherry-pick is now empty"; replay it explicitly as an empty commit
        # so the node mapping stays 1:1.
        $isEmpty = $false
        if (-not $DryRun) {
            Invoke-Git -Query -CommandArgs @('diff', '--quiet', "$hash^", $hash)
            $isEmpty = ($LASTEXITCODE -eq 0)
        }
        if ($isEmpty) {
            Write-Host "  -> Empty commit detected; replaying with --allow-empty." -ForegroundColor DarkGray
            Invoke-Git -CommandArgs @('cherry-pick', '--allow-empty', $hash)
        } else {
            Invoke-Git -CommandArgs @('cherry-pick', $hash)
        }

        if ($DryRun) {
            Write-Host "  -> (dry run) command printed above, not executed." -ForegroundColor DarkGray
        } elseif ($LASTEXITCODE -ne 0) {
            Write-Host "  -> Cherry-pick conflict! Resolve conflicts, run 'git cherry-pick --continue', and press any key to continue..." -ForegroundColor Red
            pause
        }
    }
}

if ($DryRun) {
    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host " DRY RUN finished - no command was executed." -ForegroundColor Magenta
    Write-Host " Repository untouched; current branch is still: $StartBranchLabel" -ForegroundColor Magenta
    Write-Host " Re-run without -DryRun to perform the rebuild." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Magenta
    exit 0
}

# Final safety net: replaying a merge re-runs git's auto-merge, which is NOT guaranteed to
# reproduce a hand-resolved conflict from the original history (the patch fallback only
# fires when the replay conflicts; if the replay auto-merges cleanly to a DIFFERENT result,
# content silently diverges). When base is a strict ancestor of the feature branch, replaying
# base..feature onto base must reproduce the source tree exactly - so verify it and shout if
# not. When base is NOT an ancestor (base moved ahead of where the feature forked), the trees
# may legitimately differ, so we skip the check.
$srcTree = $null
$rebuiltTree = $null
if (Test-Ancestor $BaseBranch $FeatureBranch) {
    $srcTree = (Invoke-Git -Query -CommandArgs @('rev-parse', "$FeatureBranch^{tree}")) -join ''
    $rebuiltTree = (Invoke-Git -Query -CommandArgs @('rev-parse', "$NewBranch^{tree}")) -join ''
    Write-Host ""
    if ($srcTree -eq $rebuiltTree) {
        Write-Host " Content check: rebuilt tree matches source tree exactly ($($srcTree.Substring(0,8)))." -ForegroundColor Green
    } else {
        Write-Host " Content check: MISMATCH - rebuilt tree differs from source tree!" -ForegroundColor Red
        Write-Host "   source  $srcTree" -ForegroundColor Red
        Write-Host "   rebuilt $rebuiltTree" -ForegroundColor Red
        Write-Host "   A merge replayed to a different result than the original (likely a" -ForegroundColor Red
        Write-Host "   hand-resolved conflict). Inspect: git diff $FeatureBranch $NewBranch" -ForegroundColor Red
    }
} else {
    Write-Host ""
    Write-Host " Content check skipped: '$BaseBranch' is not an ancestor of '$FeatureBranch'," -ForegroundColor DarkGray
    Write-Host " so the rebuilt and source trees are allowed to differ (base moved ahead)." -ForegroundColor DarkGray
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Rebuild completed!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Yellow
Write-Host " NOTE: you are still on the TEMP branch: $NewBranch" -ForegroundColor Yellow
Write-Host " The original branch '$FeatureBranch' was NOT modified." -ForegroundColor Yellow
Write-Host ""
Write-Host " If the rebuilt result is correct, make it permanent:" -ForegroundColor Cyan
Write-Host "   git checkout -B $FeatureBranch $NewBranch" -ForegroundColor White
Write-Host " (this moves '$FeatureBranch' to the rebuilt tip and switches to it;" -ForegroundColor DarkGray
Write-Host "  then delete the temp branch: git branch -D $NewBranch)" -ForegroundColor DarkGray
Write-Host ""
Write-Host " To discard the rebuild instead:" -ForegroundColor Cyan
Write-Host "   git checkout $FeatureBranch" -ForegroundColor White
Write-Host "   git branch -D $NewBranch" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green
