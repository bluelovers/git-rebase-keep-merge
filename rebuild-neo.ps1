param(
    [Parameter(Position = 0)]
    [string]$BaseBranch,
    [Parameter(Position = 1)]
    [string]$FeatureBranch,
    # Canonical name states exactly what it permits: overwriting the existing TEMP
    # branch. 'f'/'Force' remain aliases so older invocations keep working, but every
    # printed message shows the precise name. This flag is purely mechanical and never
    # implies any other guard's permission (no -or-compounds across flags).
    [Alias('f', 'Force')]
    [switch]$OverwriteTempBranch,
    # Redoing a LANDED rebuild is a separate, conscious decision with its own dedicated
    # flag - one flag per guard, no flag implies another, so a single consent can never
    # silently cover multiple guards.
    [switch]$RedoLanded,
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

# Single source for the consent wording, but ONE context-specific line per situation
# instead of enumerating every risky action every time - the reader gets exactly the
# consent that applies HERE, with no unrelated noise. The caller passes the precise
# action so each call site's message matches the guard that suggested it.
function Write-AgentConsentReminder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )
    Write-Host " AGENT REMINDER: ask the user for explicit permission before $Action." -ForegroundColor DarkYellow
}

# Display width counting East Asian wide characters as 2 columns, so the frame's
# top/bottom rules align even when branch names or subjects contain CJK.
function Get-DisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

# Fixed maximum width for the FRAME BORDERS only - a deliberate CONSTANT (no
# console-width probing, by design). Only the ─ rules are capped so the border itself
# can never wrap; content lines always print in full (evidence is never folded or
# truncated). Raise this one number if all target consoles are known to be wider.
$MaxFrameWidth = 60

# Beautified open-left frame (deliberately NO right border) around DETECTION / EVIDENCE
# blocks. Proof output (hashes, counts, commit lists) must be visually separable from
# ordinary script narration so a reader sees at a glance "these lines come from
# verification". Rules auto-size to the widest line (CJK-aware) but never exceed
# $MaxFrameWidth; content lines always print complete. One definition, one style -
# callers pass the already-assembled lines and their color.
function Write-EvidenceFrame {
    param(
        [Parameter(Mandatory = $true)] [string[]]$Lines,
        [Parameter(Mandatory = $true)] [System.ConsoleColor]$Color
    )
    $maxW = 0
    foreach ($line in $Lines) {
        $w = Get-DisplayWidth $line
        if ($w -gt $maxW) { $maxW = $w }
    }
    $ruleLen = [Math]::Min($maxW + 1, $MaxFrameWidth)
    $rule = '─' * $ruleLen
    Write-Host ('┌' + $rule) -ForegroundColor $Color
    foreach ($line in $Lines) { Write-Host ('│ ' + $line) -ForegroundColor $Color }
    Write-Host ('└' + $rule) -ForegroundColor $Color
}

# Leftover-parking equivalence: is this file the SAME file as that one?
#   'Equal'      - byte-identical (SHA-1 fast path, no subprocess)
#   'Equivalent' - same content once line-ending / whitespace / blank-line formatting is
#                  ignored (Windows artifacts: CRLF vs LF, tabs-vs-spaces re-indent,
#                  editors adding blank lines or a final newline) - hashing alone would
#                  wrongly escalate these to a leftover CONFLICT
#   'BomOnly'    - content identical after stripping a leading UTF-8 BOM from ONE side.
#                  A BOM is often added or removed DELIBERATELY (Windows editors vs
#                  git/text tooling), so it is never auto-equated - call sites keep both
#                  copies and emit a dedicated BOM notification instead of guessing.
#   'Different'  - real content difference
# Fallback: `git diff --no-index --quiet` with (verified empirically, see README):
#   --ignore-cr-at-eol     line endings (CR at EOL)
#   --ignore-space-change  whitespace-amount changes (-b)
#   --ignore-all-space     ANY whitespace difference incl. indentation and tabs vs
#                          spaces (-w; superset of -b and --ignore-space-at-eol)
#   --ignore-blank-lines   added/removed all-blank lines (also covers a missing/extra
#                          final newline, which presents as a blank-line difference)
# exit 0 = equivalent, anything else = different (then BOM-only is checked). Binary
# files are byte-compared (hash path; ignore-flags never apply to binary content).
function Get-FileEquivalence {
    param(
        [Parameter(Mandatory = $true)] [string]$PathA,
        [Parameter(Mandatory = $true)] [string]$PathB
    )
    try {
        if ((Get-FileHash -LiteralPath $PathA -ErrorAction Stop).Hash -eq
            (Get-FileHash -LiteralPath $PathB -ErrorAction Stop).Hash) { return 'Equal' }
    } catch {
        return 'Different'
    }
    Invoke-Git -Query -CommandArgs @('diff', '--no-index', '--quiet', '--ignore-cr-at-eol', '--ignore-space-change', '--ignore-all-space', '--ignore-blank-lines', '--', $PathA, $PathB)
    if ($LASTEXITCODE -eq 0) { return 'Equivalent' }
    # BOM-only detection: a leading UTF-8 BOM is content, not whitespace, so the ignore
    # flags cannot equate it - but it deserves a dedicated message instead of the generic
    # "differs" one (BOM changes are frequently deliberate; never auto-resolved).
    try {
        $bytesA = [System.IO.File]::ReadAllBytes($PathA)
        $bytesB = [System.IO.File]::ReadAllBytes($PathB)
        $hasBomA = ($bytesA.Length -ge 3 -and $bytesA[0] -eq 0xEF -and $bytesA[1] -eq 0xBB -and $bytesA[2] -eq 0xBF)
        $hasBomB = ($bytesB.Length -ge 3 -and $bytesB[0] -eq 0xEF -and $bytesB[1] -eq 0xBB -and $bytesB[2] -eq 0xBF)
        # Exactly one side has a BOM and the byte lengths differ by exactly those 3 bytes.
        if (($hasBomA -xor $hasBomB) -and [Math]::Abs($bytesA.Length - $bytesB.Length) -eq 3) {
            $contentA = $bytesA
            $contentB = $bytesB
            if ($hasBomA) { $contentA = New-Object byte[] ($bytesA.Length - 3); if ($contentA.Length -gt 0) { [System.Array]::Copy($bytesA, 3, $contentA, 0, $contentA.Length) } }
            if ($hasBomB) { $contentB = New-Object byte[] ($bytesB.Length - 3); if ($contentB.Length -gt 0) { [System.Array]::Copy($bytesB, 3, $contentB, 0, $contentB.Length) } }
            $same = ($contentA.Length -eq $contentB.Length)
            if ($same) {
                for ($i = 0; $i -lt $contentA.Length; $i++) {
                    if ($contentA[$i] -ne $contentB[$i]) { $same = $false; break }
                }
            }
            if ($same) { return 'BomOnly' }
        }
    } catch {
        # fall through to 'Different'
    }
    return 'Different'
}

# BaseBranch must be provided explicitly; no default inside the script.
if ([string]::IsNullOrWhiteSpace($BaseBranch)) {
    Write-Host "Error: base branch is required." -ForegroundColor Red
    Write-Host "Usage: .\rebuild-neo.ps1 <base-branch> [<feature-branch>] [-f] [-n] [-RebuiltTag] [-RedoLanded]" -ForegroundColor Yellow
    Write-Host "  <base> [<feature>]  positional args, same style as: git rebase <upstream> [<branch>]" -ForegroundColor Yellow
    Write-Host "  -f / -OverwriteTempBranch  overwrite an existing temp branch (mechanical only;" -ForegroundColor Yellow
    Write-Host "                      grants no other guard, never implies -RedoLanded)" -ForegroundColor Yellow
    Write-Host "  -n / -DryRun        print every command, execute nothing" -ForegroundColor Yellow
    Write-Host "  -RebuiltTag         append ' (Rebuilt)' to rebuilt merge messages (default: off)" -ForegroundColor Yellow
    Write-Host "  -RedoLanded         redo a rebuild that was already landed (distinct from -f;" -ForegroundColor Yellow
    Write-Host "                      -f alone never bypasses the landed guard)" -ForegroundColor Yellow
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

# Uncommitted TRACKED changes and untracked files do NOT block the rebuild: they are
# stashed just before the replay (untracked files are never staged by cherry-pick/merge/
# write-tree, so they can't enter the result) and restored in `finally` - so they are
# neither committed into the rebuilt history nor lost. See the stash block before checkout.
# A merge/cherry-pick already in progress above still aborts: that is a conflict state.

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

# A previous rebuild that was already LANDED: the temp branch tip is an ancestor of the
# feature branch itself (e.g. after 'git checkout -B <feature> rebuild/<feature>-rebuilt').
# Re-running would only rebuild the already-rebuilt history - pointless. -f is the
# explicit escape hatch for intentional rebuilds of a landed branch (e.g. base moved on).
git rev-parse --verify --quiet "$NewBranch^{commit}" | Out-Null
$tempExists = ($LASTEXITCODE -eq 0)
if ($tempExists -and (Test-Ancestor $NewBranch $FeatureBranch)) {
    # Evidence lines make the claim self-verifying (hashes + counts) so no follow-up
    # commands are needed to check the guard's facts.
    $tempTip = (git rev-parse --short=8 $NewBranch 2>$null)
    $featTip = (git rev-parse --short=8 $FeatureBranch 2>$null)
    $beyond  = (git rev-list --count "$NewBranch..$FeatureBranch" 2>$null)
    if ($RedoLanded) {
        Write-Host " WARNING: the previous rebuild was already LANDED into '$FeatureBranch'" -ForegroundColor Yellow
        Write-Host "          ($NewBranch @$tempTip is an ancestor of $FeatureBranch @$featTip," -ForegroundColor Yellow
        Write-Host "           $beyond commit(s) beyond the landed tip)." -ForegroundColor Yellow
        Write-Host "          -RedoLanded rebuilds the LANDED history (temp branch will be overwritten)." -ForegroundColor Yellow
    } else {
        Write-Host "Nothing to do: the previous rebuild has already been landed into '$FeatureBranch'." -ForegroundColor Yellow
        $landedEvidence = @("evidence: $NewBranch (@$tempTip) is an ancestor of '$FeatureBranch' (@$featTip)")
        if ("$beyond" -eq '0') { $landedEvidence += "  -> '$FeatureBranch' points exactly at the landed tip" }
        else { $landedEvidence += "  -> '$FeatureBranch' is $beyond commit(s) beyond the landed tip" }
        $landedEvidence += "  (rebuilding again would only rebuild the already-rebuilt history)."
        Write-EvidenceFrame -Lines $landedEvidence -Color Yellow
        Write-Host "  To redo anyway: the landed guard AND the temp-overwrite guard must each be" -ForegroundColor Yellow
        Write-Host "    passed explicitly:  -RedoLanded -OverwriteTempBranch" -ForegroundColor Yellow
        Write-Host "    (a plain -f alone is never enough here), or delete the temp branch first:" -ForegroundColor Yellow
        Write-Host "    git branch -D $NewBranch" -ForegroundColor Yellow
        Write-AgentConsentReminder -Action "redoing an already-landed rebuild (-RedoLanded -OverwriteTempBranch)"
        exit 0
    }
}

# Owns exactly ONE permission: overwriting the temp branch (-OverwriteTempBranch).
# It never consults -RedoLanded (the landed guard above already got its own consent).
if (-not $OverwriteTempBranch) {
    if ($tempExists) {
        Write-Host "Error: temp branch '$NewBranch' already exists." -ForegroundColor Red
        if ($RedoLanded) {
            Write-Host "       A -RedoLanded run also overwrites it: re-run with both flags," -ForegroundColor Red
            Write-Host "         -RedoLanded -OverwriteTempBranch (-f), or delete it first: git branch -D $NewBranch" -ForegroundColor Red
        } else {
            Write-Host "       Re-run with -OverwriteTempBranch (-f) to overwrite it, or delete it first." -ForegroundColor Red
        }
        Write-AgentConsentReminder -Action "overwriting the existing temp branch (-OverwriteTempBranch / -f)"
        exit 1
    }
}
if ($OverwriteTempBranch -and $tempExists) {
    Write-Host " Overwrite mode: existing temp branch '$NewBranch' will be overwritten." -ForegroundColor Magenta
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

# ===== Remote vs local awareness (best effort, never fatal on infrastructure issues) =====
# Fetches exactly the remotes used by the two branches' upstreams and reports each branch
# against its upstream (or origin/<name> fallback):
#   local strictly BEHIND  -> refuse (a stale rebuild would silently produce wrong work)
#   local ahead            -> informational
#   diverged               -> warn; rebuilds the LOCAL content
# No remote / no upstream / fetch failure -> report and continue; comparisons always use
# STABLE git plumbing (rev-parse / rev-list --left-right --count), never message text.
$branchPairs = @(@('base', $BaseBranch), @('feature', $FeatureBranch))
$upstreamMap = @{}
$remotesNeeded = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($pair in $branchPairs) {
    $bname = $pair[1]
    if ($upstreamMap.ContainsKey($bname)) { continue }
    # upstream of the branch, else the origin/<name> fallback
    git rev-parse --abbrev-ref "$bname@{upstream}" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $up = (git rev-parse --abbrev-ref "$bname@{upstream}" 2>$null | Select-Object -First 1)
        if ("$up") { $upstreamMap[$bname] = "$up".Trim(); [void]$remotesNeeded.Add(("$up".Trim() -split '/')[0]) }
    } else {
        git rev-parse --verify --quiet "refs/remotes/origin/$bname" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $upstreamMap[$bname] = "origin/$bname"; [void]$remotesNeeded.Add('origin') }
    }
}
if ($upstreamMap.Count -eq 0) {
    Write-Host " Remote check: no upstream/origin tracking for base or feature - skipped." -ForegroundColor DarkGray
} else {
    if (-not $DryRun) {
        foreach ($r in $remotesNeeded) {
            Write-Host " Remote check: git fetch $r (updating remote-tracking refs)..." -ForegroundColor DarkGray
            $fetchOut = git fetch --quiet $r 2>&1
            if ($LASTEXITCODE -ne 0) {
                # Embed the actual failure reason (network? auth? moved URL?) instead of
                # guessing - saves a manual ls-remote/fetch round-trip.
                $cause = ("$($fetchOut | Select-Object -First 1)").Trim()
                if ($cause.Length -gt 120) { $cause = $cause.Substring(0, 120) + '...' }
                if (-not $cause) { $cause = "(no error output; exit code $LASTEXITCODE)" }
                Write-Host " Warning: 'git fetch $r' failed - comparing against its LAST fetched state." -ForegroundColor Yellow
                Write-Host "   cause: $cause" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host " Remote check: dry run - no fetch; comparing against the last fetched state." -ForegroundColor DarkGray
    }
    foreach ($pair in $branchPairs) {
        $label = $pair[0]
        $bname = $pair[1]
        if (-not $upstreamMap.ContainsKey($bname)) {
            Write-Host ("   " + $label + " '" + $bname + "': no upstream tracking - comparison skipped") -ForegroundColor DarkGray
            continue
        }
        $up = $upstreamMap[$bname]
        $counts = git rev-list --left-right --count "$bname...$up" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $counts) {
            Write-Host ("   " + $label + " '" + $bname + "' vs " + $up + ": not comparable - skipped") -ForegroundColor DarkGray
            continue
        }
        $parts = ("$counts".Trim()) -split '\s+'
        $localOnly = [int]$parts[0]
        $remoteOnly = [int]$parts[1]
        $localTip = (git rev-parse --short=8 $bname 2>$null)
        $remoteTip = (git rev-parse --short=8 $up 2>$null)
        if ($localOnly -eq 0 -and $remoteOnly -eq 0) {
            Write-Host ("   " + $label + " '" + $bname + "' vs " + $up + ": up to date (both @$localTip)") -ForegroundColor DarkGray
        } elseif ($remoteOnly -gt 0 -and $localOnly -eq 0) {
            # Evidence embedded: both tips, the exact count, and the missing commits
            # themselves - the message is self-verifying, no follow-up commands needed.
            Write-Host ("Error: local " + $label + " branch '" + $bname + "' is BEHIND " + $up + " by $remoteOnly commit(s).") -ForegroundColor Red
            $frameLines = @(("evidence: local @$localTip (0 unpushed) vs remote @$remoteTip ($remoteOnly unpulled):"))
            $frameLines += @(git log --oneline --no-decorate "$bname..$up" 2>$null | Select-Object -First 5 | ForEach-Object { "  $_" })
            if ($remoteOnly -gt 5) {
                $frameLines += ("  ... and " + ($remoteOnly - 5) + " more (git log --oneline $bname..$up)")
            }
            Write-EvidenceFrame -Lines $frameLines -Color Red
            Write-Host ("       Rebuilding now would use stale content. Update first, then re-run:") -ForegroundColor Red
            Write-Host ("         git checkout $bname; git merge --ff-only $up") -ForegroundColor Yellow
            exit 1
        } elseif ($localOnly -gt 0 -and $remoteOnly -eq 0) {
            Write-Host ("   " + $label + " '" + $bname + "' vs " + $up + ": ahead by $localOnly commit(s) (unpushed local work; local @$localTip / remote @$remoteTip)") -ForegroundColor DarkGray
        } else {
            Write-Host ("   " + $label + " '" + $bname + "' vs " + $up + ": DIVERGED (local +$localOnly / remote +$remoteOnly) - rebuilding the LOCAL content") -ForegroundColor Yellow
            Write-EvidenceFrame -Lines @("evidence: local @$localTip ($localOnly not pushed) / remote @$remoteTip ($remoteOnly not pulled)") -Color Yellow
        }
    }
}

# Stash uncommitted TRACKED changes so they can neither leak into the replay
# (write-tree commits the INDEX - a staged file would be swept into a merge commit)
# nor be destroyed (checkout / the drift path's reset --hard). Untracked files are
# PARKED separately just before checkout (see inside the try below): git refuses any
# checkout/cherry-pick that would overwrite an untracked path - even when the local
# bytes are IDENTICAL to the committed ones (verified experimentally) - so leftovers
# must be moved out of the worktree or the rebuild is rejected outright. The stash is
# popped again in `finally`, so even an early `exit` cannot strand your changes.
$Stashed = $false
$TrackedChanges = Invoke-Git -Query -CommandArgs @('status', '--porcelain', '--untracked-files=no')
if ($TrackedChanges) {
    Write-Host " Uncommitted tracked changes detected - they will be stashed first:" -ForegroundColor Yellow
    $TrackedChanges | Select-Object -First 10 | ForEach-Object { Write-Host ("       " + $_) -ForegroundColor DarkGray }
    Invoke-Git -CommandArgs @('stash', 'push', '-m', 'rebuild-neo auto-stash')
    if ($DryRun) {
        Write-Host "  -> (dry run) would stash the changes above, then pop them again at the end." -ForegroundColor DarkGray
    } elseif ($LASTEXITCODE -eq 0) {
        $Stashed = $true
        Write-Host "  -> Changes stashed (safe in git stash); popped again at the end." -ForegroundColor DarkYellow
    } else {
        Write-Host "Warning: could not stash the changes - continuing anyway; a later step may fail." -ForegroundColor Yellow
    }
}

try {

# ===== Park untracked files =====
# git hard-refuses ANY checkout/cherry-pick that would write over an untracked path -
# even when the local bytes are IDENTICAL to the committed ones (verified experimentally;
# git does not compare content, it just refuses and leaves the file untouched). Such
# leftovers (from branch switches/aborts, manual copies) would otherwise abort the rebuild
# with a misleading error. Park ALL status-visible untracked files outside the worktree for
# the duration of the rebuild - zero collision risk, no prediction needed - and return them
# in `finally` under content rules:
#   - rebuild left the path free        -> moved back silently (original untracked state)
#   - path rebuilt with IDENTICAL bytes -> parked copy dropped (seamless no-op)
#   - path rebuilt with DIFFERENT bytes -> parked copy KEPT + warning; the worktree keeps
#     the committed version so a leftover can never sneak into a later `git commit -a`
# The manifest doubles as crash recovery: a killed run leaves it behind and the next run
# both warns and re-attempts the restore.
$leftoverDir = Join-Path (git rev-parse --git-dir) 'rebuild-neo-leftovers'
$manifestPath = Join-Path $leftoverDir 'manifest.txt'
$oldParked = @()
if (Test-Path $manifestPath) {
    $oldParked = @([System.IO.File]::ReadAllLines($manifestPath) | Where-Object { $_ })
    if ($oldParked.Count -gt 0) {
        Write-Host " NOTE: $($oldParked.Count) untracked file(s) are still parked from a previous (interrupted) run:" -ForegroundColor Yellow
        $oldParked | Select-Object -First 10 | ForEach-Object { Write-Host ("       " + $_) -ForegroundColor Yellow }
        Write-Host "       They will be re-attempted for restore when this run finishes." -ForegroundColor Yellow
    }
}

# Encounter-based parking: ONLY untracked files the rebuild would actually WRITE get
# parked; everything else (docs/, keys, configs, ...) is never touched. A path collides
# when it exists untracked AND is written by one of exactly two sources:
#   (a) the checkout of base  -> any path in base's tree (git refuses even identical
#       bytes - verified experimentally; a '??' path is not in the index, so checkout
#       must create it),
#   (b) the replay            -> cherry-pick/merge/apply write exactly the paths changed
#       by commits in base..feature; reset --hard only rewrites tracked-at-HEAD paths,
#       which all originate from those two sets; stash push/pop never touch untracked.
# All sources are queried in STABLE git formats (porcelain / ls-tree / log --name-only)
# - no parsing of human-readable error messages, no locale dependence. If this
# prediction were ever incomplete, behaviour degrades to git's clear refusal (never
# silently) - the restore machinery below is identical for any parked set.
$untrackedPaths = @()
foreach ($line in (git -c core.quotepath=false status --porcelain --untracked-files=all)) {
    # porcelain v1: '^?? path' lines are untracked (expanded to real files with -uall)
    if ("$line" -match '^\?\? (.+)$') {
        $rel = $Matches[1]
        if ($rel.StartsWith('"')) { $rel = $rel.Trim('"').Replace('\"', '"') }
        $untrackedPaths += $rel
    }
}
$collisionPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($p in (git ls-tree -r --name-only $BaseBranch)) { if ("$p") { [void]$collisionPaths.Add("$p") } }
foreach ($p in (git log --name-only --format= "$BaseBranch..$FeatureBranch")) { if ("$p") { [void]$collisionPaths.Add("$p") } }
$untrackedList = @($untrackedPaths | Where-Object { $collisionPaths.Contains($_) })
$leftAlone = $untrackedPaths.Count - $untrackedList.Count
if ($untrackedList.Count -gt 0) {
    Write-Host " Untracked files that WOULD collide with the rebuild - parking them for the run:" -ForegroundColor Yellow
    $untrackedList | Select-Object -First 10 | ForEach-Object { Write-Host ("       " + $_) -ForegroundColor DarkGray }
    if ($untrackedList.Count -gt 10) { Write-Host ("       ... and " + ($untrackedList.Count - 10) + " more") -ForegroundColor DarkGray }
    if ($leftAlone -gt 0) { Write-Host ("       ($leftAlone other untracked file(s) do not collide - left in place)") -ForegroundColor DarkGray }
    if ($DryRun) {
        Write-Host "  -> (dry run) would park the files above under $leftoverDir and return them at the end." -ForegroundColor DarkGray
    } else {
        New-Item -ItemType Directory -Force -Path $leftoverDir | Out-Null
        $manifestLines = @($oldParked)
        $parkFailures = @()
        foreach ($rel in $untrackedList) {
            $src = Join-Path (Get-Location).Path $rel
            $dst = Join-Path $leftoverDir $rel
            $relTrim = $rel.TrimEnd('/')   # 'docs/' -> 'docs' for suffix math
            if (Test-Path -LiteralPath $dst) {
                # A parked copy for this path already exists (previous run kept it, or a
                # previous suffix parked here). Never lose either copy:
                #   equivalent content -> the parked copy already holds it; free the path.
                #   different content  -> park under a unique suffix and record the mapping.
                $dstIsDir = (Get-Item -LiteralPath $dst) -is [System.IO.Directory]
                $srcIsDir = (Get-Item -LiteralPath $src) -is [System.IO.Directory]
                $eq = 'Different'
                if (-not $dstIsDir -and -not $srcIsDir) {
                    $eq = Get-FileEquivalence $src $dst
                }
                if ($eq -eq 'Equal' -or $eq -eq 'Equivalent') {
                    Write-Host ('  $ Remove-Item "' + $rel + '"  # equivalent copy already parked') -ForegroundColor DarkGray
                    if ($eq -eq 'Equivalent') {
                        Write-Host "       (equal ignoring whitespace/line-endings/blank lines; parked copy kept)" -ForegroundColor DarkGray
                    }
                    try {
                        Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction Stop
                        if ($manifestLines -notcontains $rel) { $manifestLines += $rel }
                        continue
                    } catch {
                        $parkFailures += $rel
                        Write-Host ("Warning: could not free '" + $rel + "': " + $_.Exception.Message) -ForegroundColor Yellow
                        continue
                    }
                }
                if ($eq -eq 'BomOnly') {
                    # BOM differences are frequently deliberate - never auto-resolved;
                    # keep BOTH copies (suffix-parked below) and say so explicitly.
                    Write-Host ("       (differs only by a UTF-8 BOM - kept both copies; BOM changes can be deliberate)") -ForegroundColor DarkGray
                }
                $n = 2
                do {
                    $suffixRel = $relTrim + '.parked' + $n
                    $suffixDst = Join-Path $leftoverDir $suffixRel
                    $n++
                } while (Test-Path -LiteralPath $suffixDst)
                Write-Host ('  $ Move-Item "' + $rel + '" -> "' + $suffixDst + '"  # path already parked (kept both copies)') -ForegroundColor DarkGray
                try {
                    $suffixParent = Split-Path $suffixDst -Parent
                    if ($suffixParent) { New-Item -ItemType Directory -Force -Path $suffixParent | Out-Null }
                    Move-Item -LiteralPath $src -Destination $suffixDst -ErrorAction Stop
                    $manifestLines += ($rel + ' => ' + $suffixRel)
                } catch {
                    $parkFailures += $rel
                    Write-Host ("Warning: could not park '" + $rel + "': " + $_.Exception.Message) -ForegroundColor Yellow
                }
            } else {
                $dstParent = Split-Path $dst -Parent
                if ($dstParent) { New-Item -ItemType Directory -Force -Path $dstParent | Out-Null }
                Write-Host ('  $ Move-Item "' + $rel + '" -> "' + $dst + '"') -ForegroundColor DarkGray
                try {
                    Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
                    $manifestLines += $rel
                } catch {
                    $parkFailures += $rel
                    Write-Host ("Warning: could not park '" + $rel + "' (in use?): " + $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        }
        $manifestLines = @($manifestLines | Where-Object { $_ } | Select-Object -Unique)
        if ($manifestLines.Count -gt 0) {
            Set-Content -Path $manifestPath -Value $manifestLines -Encoding UTF8
        }
        if ($parkFailures.Count -gt 0) {
            # A file we could not park stays in the worktree, where git will hard-refuse
            # the replay (or, worse, abort commits one by one and silently corrupt the
            # result). Fail fast BEFORE any checkout instead.
            Write-Host "Error: could not park these untracked file(s) - the rebuild would corrupt or be rejected:" -ForegroundColor Red
            $parkFailures | ForEach-Object { Write-Host ("       " + $_) -ForegroundColor Red }
            Write-Host "       Close/free them (file locks?) and re-run. Everything already parked was restored below." -ForegroundColor Red
            exit 1
        }
    }
} elseif ($leftAlone -gt 0) {
    Write-Host " $leftAlone untracked file(s) present, none collide with the rebuild - left in place." -ForegroundColor DarkGray
}

# -B creates the temp branch, or resets it to base when -f is given.
# State-driven, not flag-driven: the guards above already decided WHETHER overwriting is
# permitted (-OverwriteTempBranch / -RedoLanded each settled their own guard), so here we
# only read what exists: -B when the temp branch is present (overwrite/reset it), else -b.
# No -or compound of flags anywhere.
$CheckoutAction = if ($tempExists) { "-B" } else { "-b" }
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
        $fTip = (git rev-parse --short=8 $FeatureBranch 2>$null)
        $bTip = (git rev-parse --short=8 $BaseBranch 2>$null)
        Write-Host "Nothing to rebuild: '$FeatureBranch' is already fully contained in '$BaseBranch'." -ForegroundColor Yellow
        Write-EvidenceFrame -Lines @("evidence: '$FeatureBranch' (@$fTip) is an ancestor of '$BaseBranch' (@$bTip).") -Color Yellow
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

        # An EMPTY patch means the original merge was content-neutral: its tree equalled its
        # first parent's (e.g. a rename/rename conflict resolved by hand to drop everything the
        # side branch added). Replaying such a node must ALSO be content-neutral. `git merge`
        # would recompute a different merge-base and could auto-merge to a DIFFERENT tree
        # (e.g. keeping a rename the original hand-deleted), silently diverging - and the
        # empty patch can't be applied as a fallback either. So short-circuit: build the merge
        # node directly with commit-tree, using the CURRENT tree (no content change) and every
        # side parent. Deterministic, no divergence possible.
        if (-not $DryRun -and (Get-Item $targetPatchFile).Length -eq 0) {
            Write-Host "  -> Empty patch: original merge was content-neutral. Building the merge node without re-merging content." -ForegroundColor Yellow
            $curTree = (Invoke-Git -Query -CommandArgs @('rev-parse', 'HEAD^{tree}')) -join ''
            $ctArgs = @('commit-tree', "$curTree".Trim(), '-p', 'HEAD')
            foreach ($t in $sideParents) { $ctArgs += @('-p', $t) }
            $ctArgs += @('-m', $commitMessage)
            $newCommit = Invoke-Git -Capture -CommandArgs $ctArgs
            if ($LASTEXITCODE -ne 0 -or "$newCommit" -notmatch '^[0-9a-f]{7,40}$') {
                Write-Host "  -> Error: commit-tree failed for content-neutral merge of $hash" -ForegroundColor Red
                exit 1
            }
            $newCommit = "$newCommit".Trim()
            Invoke-Git -CommandArgs @('reset', '--hard', $newCommit)
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  -> Error: failed to attach the content-neutral merge commit $newCommit" -ForegroundColor Red
                exit 1
            }
            Write-Host "  -> Content-neutral merge node created: $($newCommit.Substring(0,8)) (side parents kept, content untouched)" -ForegroundColor Green
            continue
        }

        # ===== Merge node replay =====
        # Strategy: PATCH-FIRST, merge as fallback.
        #
        # The first-parent patch (diff P1..M) IS the merge's content contribution relative to
        # its mainline parent - the authoritative definition of what the merge added. Applying
        # it with `git apply --index` (strict context) is the most faithful replay and is the
        # ONLY way to reproduce renames: because cherry-picking the mainline rewrites commit
        # hashes, `git merge` computes a merge-base that predates the renamed file, fails to
        # detect the rename, and silently keeps BOTH the old and new paths (content divergence
        # that never triggers the conflict fallback). When the patch context has drifted
        # (e.g. rebuilding onto a NEWER base, like the Mneo layout), `git apply` fails cleanly
        # and we fall back to a real `git merge`, which can still 3-way against the new base.
        if ($DryRun) {
            Invoke-Git -CommandArgs @('apply', '--index', $targetPatchFile)
            Write-Host "  -> (dry run) would try 'git apply --index' first; on drift fall back to 'git merge --no-ff'," -ForegroundColor DarkGray
            Write-Host "     and on merge conflict to 'git apply --3way'. Nothing executed." -ForegroundColor DarkGray
            continue
        }

        $mergedClean = $false   # true only when a real `git merge` produced its own commit
        $appliedOK   = $false

        # --- Primary: faithful patch replay (handles renames) ---
        Invoke-Git -CommandArgs @('apply', '--index', $targetPatchFile)
        if ($LASTEXITCODE -eq 0) {
            $appliedOK = $true
            Write-Host "  -> Patch applied cleanly (faithful first-parent replay)." -ForegroundColor Green
        } else {
            # Context drifted. `git apply` is all-or-nothing, but reset anyway so the merge
            # below always starts from a clean tree regardless of git version behaviour.
            Write-Host "  -> Patch context drifted (base moved?); falling back to git merge --no-ff..." -ForegroundColor Yellow
            Invoke-Git -CommandArgs @('reset', '--hard', 'HEAD')
            Invoke-Git -CommandArgs (@('merge', '--no-ff') + $sideParents + @('-m', $commitMessage))
            if ($LASTEXITCODE -eq 0) {
                $mergedClean = $true
                Write-Host "  -> Merge completed cleanly, no conflicts." -ForegroundColor Green
            } else {
                Write-Host "  -> Conflict detected! Falling back to 3-way patch application..." -ForegroundColor Yellow
                Invoke-Git -CommandArgs @('merge', '--abort')
                Invoke-Git -CommandArgs @('apply', '--3way', '--index', $targetPatchFile)
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  -> Patch could not apply cleanly. Pausing: resolve conflicts in the working tree," -ForegroundColor Red
                    Write-Host "  ->    stage the result with 'git add -u', then press any key to continue..." -ForegroundColor Red
                    pause
                } else {
                    Write-Host "  -> Patch applied successfully (3-way)." -ForegroundColor Green
                }
            }
        }

        # If the content came from a patch (primary apply OR 3-way fallback), it is staged but
        # uncommitted: finish it as a real merge commit via write-tree + commit-tree so the node
        # keeps its merge structure and every side parent stays reachable. A clean `git merge`
        # already created its own commit, so we skip finishing in that case. A plain `git commit`
        # here would silently degrade the merge into a single-parent commit.
        if (-not $mergedClean) {
            $mergedTree = Invoke-Git -Capture -CommandArgs @('write-tree')
            if ($LASTEXITCODE -ne 0 -or "$mergedTree" -notmatch '^[0-9a-f]{7,40}$') {
                # Most common cause: the conflict-fallback `pause` was passed without resolving
                # and staging first (e.g. auto-run with redirected stdin), leaving unmerged paths.
                $unmerged = git diff --name-only --diff-filter=U
                if ($unmerged) {
                    Write-Host "  -> Error: conflicts are still unresolved (these paths are unmerged):" -ForegroundColor Red
                    $unmerged | ForEach-Object { Write-Host ("       " + $_) -ForegroundColor Red }
                    Write-Host "       Resolve each file, then run: git add -u" -ForegroundColor Yellow
                    Write-Host "       (in a live terminal the script pauses here so you can do that before it continues)" -ForegroundColor Yellow
                } else {
                    Write-Host "  -> Error: git write-tree failed - index is not in a committable state." -ForegroundColor Red
                    Write-Host "       Check: git status   (then git add the resolved files and re-run)" -ForegroundColor Yellow
                }
                Write-Host "  -> The rebuild STOPPED mid-way on this temp branch. To abandon and retry:" -ForegroundColor Cyan
                Write-Host "       git reset --hard HEAD   # discard partial work, then re-run with -f" -ForegroundColor Cyan
                exit 1
            }
            $ctArgs = @('commit-tree', "$mergedTree".Trim(), '-p', 'HEAD')
            foreach ($t in $sideParents) { $ctArgs += @('-p', $t) }
            $ctArgs += @('-m', $commitMessage)
            $newCommit = Invoke-Git -Capture -CommandArgs $ctArgs
            if ($LASTEXITCODE -ne 0 -or "$newCommit" -notmatch '^[0-9a-f]{7,40}$') {
                Write-Host "  -> Error: commit-tree failed while finishing the patch-applied merge." -ForegroundColor Red
                exit 1
            }
            $newCommit = "$newCommit".Trim()
            Invoke-Git -CommandArgs @('reset', '--hard', $newCommit)
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  -> Error: failed to attach the merge commit $newCommit" -ForegroundColor Red
                exit 1
            }
            Write-Host "  -> Merge node created: $($newCommit.Substring(0,8)) (structure preserved, side parents kept)" -ForegroundColor Green
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
        # A wrong result must not exit 0 - automation would treat it as success.
        Write-Host " Exiting with failure (the rebuild above must NOT be landed as-is)." -ForegroundColor Red
        exit 1
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
Write-AgentConsentReminder -Action "replacing '$FeatureBranch' with the rebuilt temp branch (git checkout -B ...)"
Write-Host ""
Write-Host " To discard the rebuild instead:" -ForegroundColor Cyan
Write-Host "   git checkout $FeatureBranch" -ForegroundColor White
Write-Host "   git branch -D $NewBranch" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green
} finally {
    # Restore uncommitted tracked changes stashed before the replay. This runs on normal
    # completion AND on every early `exit` (verified: PowerShell executes `finally` on exit).
    # --index re-stages what was staged, so staged-vs-unstaged state is preserved.
    if ($Stashed) {
        Write-Host ""
        # Decide the failure cause BEFORE popping: a failed `stash pop` leaves its OWN
        # unmerged paths behind, so checking after the pop cannot tell (a) from (b).
        #   (a) index ALREADY unmerged before the pop => the rebuild itself stopped mid-
        #       conflict; pop would fail to even write the index. Skip it, fix that first.
        #   (b) index clean before the pop => attempt it; if it then fails, the stash
        #       genuinely conflicts with the rebuilt content.
        $preUnmerged = git diff --name-only --diff-filter=U
        if ($preUnmerged) {
            Write-Host "Your changes could not be restored yet: the rebuild STOPPED with" -ForegroundColor Red
            Write-Host "unresolved conflicts, and the index must be clean before the stash pops:" -ForegroundColor Red
            $preUnmerged | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
            Write-Host "Resolve those (or 'git reset --hard HEAD' to abandon this temp branch), then:" -ForegroundColor Yellow
            Write-Host "  git stash list        # your changes are SAFE here ('rebuild-neo auto-stash')" -ForegroundColor Yellow
            Write-Host "  git stash pop --index # restore them after the index is clean" -ForegroundColor Yellow
        } else {
            Invoke-Git -CommandArgs @('stash', 'pop', '--index')
            if ($DryRun) {
                Write-Host "  -> (dry run) stash was not created; nothing to pop." -ForegroundColor DarkGray
            } elseif ($LASTEXITCODE -ne 0) {
                Write-Host "Could not restore your stashed changes automatically: they CONFLICT with the" -ForegroundColor Red
                Write-Host "rebuilt content (the rebuild changed lines you had also edited). Your changes" -ForegroundColor Red
                Write-Host "are SAFE in the stash:" -ForegroundColor Red
                Write-Host "  git stash list         # find 'rebuild-neo auto-stash'" -ForegroundColor Yellow
                Write-Host "  git stash pop --index  # retry once you've inspected/resolved" -ForegroundColor Yellow
            } else {
                Write-Host "Your uncommitted changes were restored (staged state preserved)." -ForegroundColor Green
            }
        }
    }

    # Return parked untracked files under the content rules (see the park block for the
    # full rationale). The manifest is the source of truth, so entries from a previously
    # KILLED run are re-attempted here too (self-healing).
    if ($DryRun -and (Test-Path $manifestPath)) {
        Write-Host ""
        Write-Host " (dry run) parked file(s) from a previous run exist under $leftoverDir;" -ForegroundColor DarkGray
        Write-Host "           a real run would restore them. Nothing executed now." -ForegroundColor DarkGray
    } elseif (Test-Path $manifestPath) {
        Write-Host ""
        $entries = @([System.IO.File]::ReadAllLines($manifestPath) | Where-Object { $_ })
        $returned = 0
        $identicalDropped = 0
        $normalizedDropped = 0
        $unresolved = @()
        foreach ($lineSpec in $entries) {
          try {
            # Manifest line: '<originalRelPath>' or '<originalRelPath> => <parkedRelPath>'
            # (the arrow form is used when a path was parked under a unique suffix because
            # the plain location already held a previous leftover).
            $origRel = $lineSpec
            $parkedRel = $lineSpec
            if ($lineSpec -match '^(.+?) => (.+)$') {
                $origRel = $Matches[1]
                $parkedRel = $Matches[2]
            }
            $src = Join-Path $leftoverDir $parkedRel      # parked copy
            $dst = Join-Path (Get-Location).Path $origRel  # worktree location
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if (-not (Test-Path -LiteralPath $dst)) {
                $dstParent = Split-Path $dst -Parent
                if ($dstParent) { New-Item -ItemType Directory -Force -Path $dstParent | Out-Null }
                Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
                $returned++
                continue
            }
            # Path exists again - decide by content.
            $srcIsDir = (Get-Item -LiteralPath $src) -is [System.IO.Directory]
            $dstIsDir = (Get-Item -LiteralPath $dst) -is [System.IO.Directory]
            if ($srcIsDir -or $dstIsDir) {
                $unresolved += $lineSpec
                Write-Host ("LEFTOVER CONFLICT: '" + $origRel + "' exists in the rebuild AND was parked as a leftover (directory).") -ForegroundColor Red
                Write-Host ("  parked copy: " + $src) -ForegroundColor Yellow
                continue
            }
            $eq = Get-FileEquivalence $src $dst
            if ($eq -eq 'Equal' -or $eq -eq 'Equivalent') {
                # Equivalent content (byte-identical OR equal modulo whitespace/line-endings):
                # the rebuilt file IS the leftover - drop the parked copy.
                # Removal failures must NOT be counted as success, or the manifest would be
                # deleted while the file stays parked (orphaned with no tracking). PS5.1's
                # Remove-Item -Force is known to throw NullReferenceException on some paths;
                # fall back to the .NET API before giving up.
                $droppedOk = $false
                try {
                    Remove-Item -LiteralPath $src -Force -ErrorAction Stop
                    $droppedOk = $true
                } catch {
                    try {
                        if ((Get-Item -LiteralPath $src) -is [System.IO.Directory]) {
                            [System.IO.Directory]::Delete($src, $true)
                        } else {
                            [System.IO.File]::Delete($src)
                        }
                        $droppedOk = $true
                    } catch {
                        $droppedOk = $false
                    }
                }
                if ($droppedOk) {
                    if ($eq -eq 'Equivalent') {
                        $normalizedDropped++
                        Write-Host (" note: '" + $origRel + "' differs only in whitespace/line-endings/blank lines -") -ForegroundColor DarkGray
                        Write-Host ("       treated as the same file; parked copy dropped, rebuilt version kept.") -ForegroundColor DarkGray
                    } else {
                        $identicalDropped++
                    }
                } else {
                    $unresolved += $lineSpec
                    Write-Host ("Warning: could not delete identical parked copy '" + $origRel + "'; kept for retry.") -ForegroundColor Yellow
                }
            } else {
                $unresolved += $lineSpec
                if ($eq -eq 'BomOnly') {
                    # Content is identical except a leading UTF-8 BOM on one side.
                    # Deliberately NOT auto-resolved (BOM is often added/removed on
                    # purpose) - notify precisely instead of the generic "differs".
                    Write-Host ("BOM DIFFERENCE: '" + $origRel + "' differs ONLY by a leading UTF-8 BOM (present in one copy, absent in the other).") -ForegroundColor Red
                    Write-Host ("  BOM is often added or removed DELIBERATELY (Windows editors vs git/text tooling) - not auto-resolved.") -ForegroundColor Yellow
                    Write-Host ("  worktree keeps the REBUILT version; your leftover is parked at:") -ForegroundColor Yellow
                    Write-Host ("    " + $src) -ForegroundColor Yellow
                    Write-Host ("  Inspect:  git diff --no-index `"" + $src + "`" `"" + $dst + "`"") -ForegroundColor Yellow
                    Write-Host ("  Decide: keep whichever side should carry the BOM (copy the parked file over, or strip/add its BOM).") -ForegroundColor Yellow
                } else {
                    Write-Host ("LEFTOVER CONFLICT: '" + $origRel + "' differs from the rebuilt file at the same path.") -ForegroundColor Red
                    Write-Host ("  worktree keeps the REBUILT version; your leftover is parked at:") -ForegroundColor Yellow
                    Write-Host ("    " + $src) -ForegroundColor Yellow
                    Write-Host ("  Compare:  git diff --no-index `"" + $src + "`" `"" + $dst + "`"") -ForegroundColor Yellow
                    Write-Host ("  To use your leftover, copy it over (it becomes an uncommitted change);") -ForegroundColor Yellow
                    Write-Host ("  otherwise delete the parked copy when you're done.") -ForegroundColor Yellow
                }
            }
          } catch {
            # One entry must never abort (or silently skip) the rest - keep it tracked.
            $unresolved += $lineSpec
            Write-Host ("Warning: error while returning '" + $lineSpec + "': " + $_.Exception.Message) -ForegroundColor Yellow
          }
        }
        # Summary + manifest bookkeeping
        $notes = @()
        if ($returned -gt 0) { $notes += "$returned returned unchanged" }
        if ($identicalDropped -gt 0) { $notes += "$identicalDropped identical leftover(s) dropped (rebuilt file kept)" }
        if ($normalizedDropped -gt 0) { $notes += "$normalizedDropped leftover(s) dropped as equal ignoring whitespace/line-endings/blank lines" }
        if ($notes.Count -gt 0) {
            Write-Host ("Untracked leftovers: " + ($notes -join '; ') + ".") -ForegroundColor Green
        }
        # Manifest bookkeeping - never drop tracking while anything stays parked:
        # a manifest deleted over leftover files would orphan them invisibly.
        if ($unresolved.Count -eq 0) {
            # Exclude the manifest file itself - it lives inside leftoverDir and would
            # otherwise be counted as a phantom residual (self-perpetuating forever).
            $manifestFull = [System.IO.Path]::GetFullPath($manifestPath)
            $residuals = @(Get-ChildItem -LiteralPath $leftoverDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $manifestFull })
            if ($residuals.Count -eq 0) {
                Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
                if (-not (Get-ChildItem -LiteralPath $leftoverDir -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $leftoverDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                $rootLen = (Resolve-Path -LiteralPath $leftoverDir).Path.Length
                $residualLines = @($residuals | ForEach-Object {
                    ($_.FullName.Substring($rootLen).TrimStart('\', '/')) -replace '\\', '/'
                } | Select-Object -Unique)
                Set-Content -Path $manifestPath -Value $residualLines -Encoding UTF8
                Write-Host "Warning: $($residualLines.Count) parked file(s) could not be resolved this run;" -ForegroundColor Yellow
                Write-Host "         manifest kept so the next run re-attempts their restore." -ForegroundColor Yellow
            }
        } else {
            Set-Content -Path $manifestPath -Value $unresolved -Encoding UTF8
        }
    }
}
