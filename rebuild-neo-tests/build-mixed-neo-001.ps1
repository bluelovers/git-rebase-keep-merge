# Recreate test branch tmp/rebuild-mixed-neo-001
# (interleaved history + a mid-stream merge of a stage of neo itself).
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-mixed-neo-001.ps1          # fails if branch already exists
#   .\build-mixed-neo-001.ps1 -Force   # delete and rebuild it
#
# Anchor is ad607938 (13 commits before neo tip), so the mid-stream
# "Merge branch 'neo'" brings in the full 44-file delta.
# 5 PR merges all come AFTER the neo merge, otherwise they would drag in
# ad607938..0c388f8b early and shrink the neo merge's content.
#
# Resulting first-parent history (base = ad607938):
#   c1..c8 regular -> Merge neo -> merge sort-ckp -> merge extra_networks
#   -> c9 (processing.py) -> merge idle -> c10 (processing.py) -> merge ckp
#   -> merge pt-bat -> c11 regular
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-mixed-neo-001'
$Base = 'ad607938'

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

foreach ($b in @($Base, 'neo', 'pr/sort-ckp-001', 'pr/extra_networks-001', 'bluelovers/pr/idle-001', 'bluelovers/pr/ckp-001', 'bluelovers/pr/pt-bat-001')) {
    git rev-parse --verify --quiet "$b^{commit}" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "Error: required branch/commit '$b' not found." -ForegroundColor Red; exit 1 }
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
    'rebuild mixed-history + mid-merge-of-base test file'
    'c1: regular commit BEFORE the first merge'
) | Set-Content -Path 'rebuild-mixed-test.txt' -Encoding utf8
git add rebuild-mixed-test.txt
git commit -m 'mixed-neo: c1 create marker file (before any merge)'
if ($LASTEXITCODE -ne 0) { exit 1 }

# c2/c5: README.md appends (README differs between anchor and neo -> cross-version cherry-pick)
Add-Content -Path 'README.md' -Value 'c2 marker line'
git add README.md
git commit -m 'mixed-neo: c2 append README.md (cross-version: README differs anchor->neo)'
if ($LASTEXITCODE -ne 0) { exit 1 }

# c3/c7: requirements.txt appends (also cross-version)
Add-Content -Path 'requirements.txt' -Value '# mixed-neo c3 marker'
git add requirements.txt
git commit -m 'mixed-neo: c3 append requirements.txt (cross-version)'
if ($LASTEXITCODE -ne 0) { exit 1 }

# c4: marker file append
Add-Content -Path 'rebuild-mixed-test.txt' -Value 'c4 marker line'
git add rebuild-mixed-test.txt
git commit -m 'mixed-neo: c4 append marker file'
if ($LASTEXITCODE -ne 0) { exit 1 }

Add-Content -Path 'README.md' -Value 'c5 marker line'
git add README.md
git commit -m 'mixed-neo: c5 append README.md again (cross-version)'
if ($LASTEXITCODE -ne 0) { exit 1 }

# c6: processing.py append (processing.py is unchanged across ad607938..neo,
# so c6/c9/c10 interleave behaves identically on source side and rebuilt side)
Add-Content -Path 'modules/processing.py' -Value '' -NoNewline
Add-Content -Path 'modules/processing.py' -Value '# mixed-neo c6 processing.py marker'
git add modules/processing.py
git commit -m 'mixed-neo: c6 append modules/processing.py'
if ($LASTEXITCODE -ne 0) { exit 1 }

Add-Content -Path 'requirements.txt' -Value '# mixed-neo c7 marker'
git add requirements.txt
git commit -m 'mixed-neo: c7 append requirements.txt (cross-version)'
if ($LASTEXITCODE -ne 0) { exit 1 }

Add-Content -Path 'rebuild-mixed-test.txt' -Value 'c8 marker line'
git add rebuild-mixed-test.txt
git commit -m 'mixed-neo: c8 append marker file'
if ($LASTEXITCODE -ne 0) { exit 1 }

# Mneo: mid-stream merge of the current stage of neo (node #9 of 17, dead center)
git merge neo -m "Merge branch 'neo'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge neo - resolve manually.' -ForegroundColor Red; exit 1 }

# All 5 PR merges go after Mneo, so Mneo carries the full 44-file delta.
git merge --no-ff pr/sort-ckp-001 -m "Merge branch 'pr/sort-ckp-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge pr/sort-ckp-001 - resolve manually.' -ForegroundColor Red; exit 1 }

git merge --no-ff pr/extra_networks-001 -m "Merge branch 'pr/extra_networks-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge pr/extra_networks-001 - resolve manually.' -ForegroundColor Red; exit 1 }

# c9: processing.py right before the idle merge
Add-Content -Path 'modules/processing.py' -Value '' -NoNewline
Add-Content -Path 'modules/processing.py' -Value '# mixed-neo c9 processing.py marker'
git add modules/processing.py
git commit -m 'mixed-neo: c9 append processing.py right before the idle merge'
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff bluelovers/pr/idle-001 -m "Merge branch 'bluelovers/pr/idle-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge idle-001 - resolve manually.' -ForegroundColor Red; exit 1 }

# c10: processing.py right before the ckp merge
Add-Content -Path 'modules/processing.py' -Value '' -NoNewline
Add-Content -Path 'modules/processing.py' -Value '# mixed-neo c10 processing.py marker'
git add modules/processing.py
git commit -m 'mixed-neo: c10 append processing.py right before the ckp merge'
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff bluelovers/pr/ckp-001 -m "Merge branch 'bluelovers/pr/ckp-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge ckp-001 - resolve manually.' -ForegroundColor Red; exit 1 }

git merge --no-ff bluelovers/pr/pt-bat-001 -m "Merge branch 'bluelovers/pr/pt-bat-001'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge pt-bat-001 - resolve manually.' -ForegroundColor Red; exit 1 }

# c11: regular commit after the final merge
Add-Content -Path 'rebuild-mixed-test.txt' -Value 'c11 marker line'
git add rebuild-mixed-test.txt
git commit -m 'mixed-neo: c11 regular commit after the final merge'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Base" -ForegroundColor Green
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Base..$Branch"
