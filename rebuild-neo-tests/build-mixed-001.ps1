# Recreate test branch tmp/rebuild-mixed-001 (regular commits interleaved with PR merges).
# This is a scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-mixed-001.ps1          # fails if branch already exists
#   .\build-mixed-001.ps1 -Force   # delete and rebuild it
#
# Resulting first-parent history (base = neo):
#   c1 regular -> merge pr/sort-ckp-001 -> c2 regular -> merge pr/extra_networks-001
#   -> c3 regular (processing.py) -> merge idle -> c4 regular (processing.py)
#   -> merge ckp -> merge pt-bat -> c5 regular
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-mixed-001'
$Base = 'neo'

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

foreach ($b in @($Base, 'pr/sort-ckp-001', 'pr/extra_networks-001', 'bluelovers/pr/idle-001', 'bluelovers/pr/ckp-001', 'bluelovers/pr/pt-bat-001')) {
    git rev-parse --verify --quiet "$b^{commit}" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "Error: required branch '$b' not found." -ForegroundColor Red; exit 1 }
}

git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $Force) { Write-Host "Error: branch '$Branch' already exists. Use -Force to rebuild." -ForegroundColor Red; exit 1 }
    Write-Host "Rebuilding: deleting existing '$Branch'" -ForegroundColor Yellow
    git checkout $Base
    if ($LASTEXITCODE -ne 0) { exit 1 }
    git branch -D $Branch
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

git checkout -b $Branch $Base
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: marker file, before any merge
@(
    'rebuild mixed-history test file'
    'c1: regular commit BEFORE the first merge'
) | Set-Content -Path 'rebuild-mixed-test.txt' -Encoding utf8
git add rebuild-mixed-test.txt
git commit -m 'mixed-test: c1 regular commit before first merge'
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff pr/sort-ckp-001 -m "Merge branch 'pr/sort-ckp-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge pr/sort-ckp-001 - resolve manually.' -ForegroundColor Red; exit 1 }

# c2: regular commit between merge1 and merge2
Add-Content -Path 'rebuild-mixed-test.txt' -Value 'c2: regular commit BETWEEN merge1 and merge2'
git add rebuild-mixed-test.txt
git commit -m 'mixed-test: c2 regular commit between merges'
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff pr/extra_networks-001 -m "Merge branch 'pr/extra_networks-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge pr/extra_networks-001 - resolve manually.' -ForegroundColor Red; exit 1 }

# c3: touches processing.py, which later merges also touch
Add-Content -Path 'modules/processing.py' -Value '' -NoNewline
Add-Content -Path 'modules/processing.py' -Value '# rebuild-mixed-test: c3 regular commit BEFORE the idle merge'
git add modules/processing.py
git commit -m 'mixed-test: c3 regular commit touching a file that later merges also touch'
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff bluelovers/pr/idle-001 -m "Merge branch 'bluelovers/pr/idle-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge idle-001 - resolve manually.' -ForegroundColor Red; exit 1 }

# c4: touches processing.py again, between two merges that touch it
Add-Content -Path 'modules/processing.py' -Value '' -NoNewline
Add-Content -Path 'modules/processing.py' -Value '# rebuild-mixed-test: c4 regular commit AFTER idle merge, BEFORE ckp merge'
git add modules/processing.py
git commit -m 'mixed-test: c4 regular commit between two merges that touch the same file'
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff bluelovers/pr/ckp-001 -m "Merge branch 'bluelovers/pr/ckp-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge ckp-001 - resolve manually.' -ForegroundColor Red; exit 1 }

git merge --no-ff bluelovers/pr/pt-bat-001 -m "Merge branch 'bluelovers/pr/pt-bat-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge pt-bat-001 - resolve manually.' -ForegroundColor Red; exit 1 }

# c5: regular commit after the final merge
Add-Content -Path 'rebuild-mixed-test.txt' -Value 'c5: regular commit AFTER the last merge'
git add rebuild-mixed-test.txt
git commit -m 'mixed-test: c5 regular commit after final merge'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Base" -ForegroundColor Green
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Base..$Branch"
