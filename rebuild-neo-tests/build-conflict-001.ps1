# Recreate test branch tmp/rebuild-conflict-001 (a guaranteed merge conflict).
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-conflict-001.ps1          # fails if branch already exists
#   .\build-conflict-001.ps1 -Force   # delete and rebuild it
#
# Design: side A and side B change the SAME line. The original merge of B is
# conflict-resolved by hand (A -> AB). During rebuild the same conflict must
# reappear, and the script's fallback (merge --abort -> git apply --3way ->
# add -u -> commit) must reproduce the original resolution exactly, so the
# rebuilt tree stays identical to the source tree.
#
# Resulting first-parent history (base = neo):
#   c1 create conflict-test.txt -> merge side-a (clean)
#   -> merge side-b (CONFLICT, resolved AB) -> c2 regular
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-conflict-001'
$Base = 'neo'
$SideA = 'tmp/conflict-side-a'
$SideB = 'tmp/conflict-side-b'
$File = 'conflict-test.txt'
# The contested line, and the resolution used when the merge conflicts.
$Line3 = 'line3'
$ResolvedLine3 = 'line3-AB'

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Base^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: base '$Base' not found." -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $Force) { Write-Host "Error: branch '$Branch' already exists. Use -Force to rebuild." -ForegroundColor Red; exit 1 }
    git checkout $Base
    if ($LASTEXITCODE -ne 0) { exit 1 }
    foreach ($b in @($Branch, $SideA, $SideB)) {
        git rev-parse --verify --quiet "$b^{commit}" | Out-Null
        if ($LASTEXITCODE -eq 0) { git branch -D $b | Out-Null }
    }
}

git checkout -b $Branch $Base
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: the file both sides will contend over
@('line1', 'line2', $Line3, 'line4', 'line5') | Set-Content -Path $File -Encoding utf8
git add $File
git commit -m 'conflict: c1 create conflict-test.txt'
if ($LASTEXITCODE -ne 0) { exit 1 }
$C1 = git rev-parse HEAD

# side A: changes line3 -> line3-A
git checkout -b $SideA $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
(Get-Content $File) -replace [regex]::Escape($Line3), 'line3-A' | Set-Content -Path $File -Encoding utf8
git add $File
git commit -m 'side-a: change the contested line to A'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git merge --no-ff $SideA -m "Merge branch '$SideA'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Unexpected conflict at merge side-a.' -ForegroundColor Red; exit 1 }

# side B: branches from c1 (NOT from the A merge) and changes the SAME line -> B
git checkout -b $SideB $C1
if ($LASTEXITCODE -ne 0) { exit 1 }
(Get-Content $File) -replace [regex]::Escape($Line3), 'line3-B' | Set-Content -Path $File -Encoding utf8
git add $File
git commit -m 'side-b: change the contested line to B'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
# This merge conflicts by design; resolve it by hand exactly once.
git merge --no-ff $SideB -m "Merge branch '$SideB'"
if ($LASTEXITCODE -eq 0) { Write-Host 'Expected a conflict at merge side-b but got a clean merge - fixture is wrong.' -ForegroundColor Red; exit 1 }
Write-Host 'Conflict at merge side-b (expected) - resolving by hand.' -ForegroundColor Yellow
# Full rewrite: drop the conflict markers and keep ONE resolved value.
# (A blind line-replace would leave the <<<<<<< / >>>>>>> markers in place.)
@('line1', 'line2', $ResolvedLine3, 'line4', 'line5') | Set-Content -Path $File -Encoding utf8
git add $File
git commit -m "Merge branch '$SideB'"
if ($LASTEXITCODE -ne 0) { exit 1 }

# c2: regular commit after the conflicted merge
Add-Content -Path $File -Value 'c2 marker line'
git add $File
git commit -m 'conflict: c2 regular commit after the resolved merge'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Base (one hand-resolved conflict inside)" -ForegroundColor Green
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Base..$Branch"
