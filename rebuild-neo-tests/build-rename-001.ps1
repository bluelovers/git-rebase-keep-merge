# Recreate test branch tmp/rebuild-rename-001 (rename / rename-rename edge cases).
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-rename-001.ps1          # fails if branch already exists
#   .\build-rename-001.ps1 -Force   # delete and rebuild it
#
# KNOWN LIMITATION this fixture documents: side-b renames the SAME file to a
# DIFFERENT name, so the original merge is a rename/rename CONFLICT that is
# resolved by hand (keep moved.txt, drop other-name.txt -> net content change 0,
# so the extracted patch is empty). During rebuild the replayed merge-base can
# differ and the merge auto-merges CLEANLY (git keeps other-name.txt), so the
# fallback never fires and the hand-resolved deletion is lost -> trees diverge.
# rebuild-neo.ps1 now prints a "Content check: MISMATCH" banner for this case.
#
# Resulting first-parent history (base = neo):
#   c1 create target.txt+other.txt -> merge side-a (rename -> moved.txt)
#   -> merge side-b (rename/rename CONFLICT, hand-resolved) -> c2 append
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-rename-001'
$Base = 'neo'
$SideA = 'tmp/rename-side-a'
$SideB = 'tmp/rename-side-b'

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Base^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: base '$Base' not found." -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $Force) { Write-Host "Error: branch '$Branch' already exists. Use -Force to rebuild." -ForegroundColor Red; exit 1 }
    # Clear any half-finished merge before switching away.
    git merge --abort 2>$null | Out-Null
    git checkout -f $Base | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 1 }
    foreach ($b in @($Branch, $SideA, $SideB)) {
        git rev-parse --verify --quiet "$b^{commit}" | Out-Null
        if ($LASTEXITCODE -eq 0) { git branch -D $b | Out-Null }
    }
}

git checkout -B $Branch $Base
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: the file that will be renamed twice, plus a bystander file
@('target line1', 'target line2', 'target line3', 'target line4') | Set-Content -Path 'target.txt' -Encoding utf8
@('other file') | Set-Content -Path 'other.txt' -Encoding utf8
git add target.txt other.txt
git commit -m 'rename-test: c1 create target.txt and other.txt'
if ($LASTEXITCODE -ne 0) { exit 1 }

# side-a: pure rename target.txt -> moved.txt (no content change)
git checkout -b $SideA $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git mv target.txt moved.txt
git commit -m 'side-a: rename target.txt to moved.txt'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git merge --no-ff $SideA -m "Merge branch '$SideA'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Unexpected conflict at merge side-a.' -ForegroundColor Red; exit 1 }

# side-b: branches from c1 (BEFORE the rename) and renames the SAME file to a
# DIFFERENT name -> rename/rename conflict when merged.
$C1 = git rev-parse "$Branch~1"
git checkout -b $SideB $C1
if ($LASTEXITCODE -ne 0) { exit 1 }
git mv target.txt other-name.txt
git commit -m 'side-b: rename target.txt to other-name.txt (different target)'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git merge --no-ff $SideB -m "Merge branch '$SideB'"
if ($LASTEXITCODE -eq 0) { Write-Host 'Expected a rename/rename conflict at merge side-b but got a clean merge - fixture is wrong.' -ForegroundColor Red; exit 1 }
Write-Host 'rename/rename conflict at merge side-b (expected) - resolving by hand.' -ForegroundColor Yellow
# Resolution: keep moved.txt (side-a name); drop the losing rename target and the
# (already-renamed) source path. Net content change vs first parent is ZERO.
git add moved.txt
git rm -q -f other-name.txt target.txt
git commit -m "Merge branch '$SideB'"
if ($LASTEXITCODE -ne 0) { exit 1 }

# c2: regular commit appending to the renamed file
Add-Content -Path 'moved.txt' -Value 'target line5'
git add moved.txt
git commit -m 'rename-test: c2 append to the renamed file'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Base (one hand-resolved rename/rename conflict inside)" -ForegroundColor Green
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Base..$Branch"
