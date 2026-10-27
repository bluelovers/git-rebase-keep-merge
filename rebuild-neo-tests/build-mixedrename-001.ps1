# Recreate test branch tmp/rebuild-mixedrename-001
# (rename AND content change inside one merge).
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-mixedrename-001.ps1          # fails if branch already exists
#   .\build-mixedrename-001.ps1 -Force   # delete and rebuild it
#
# Verifies the patch-first replay handles a merge whose first-parent patch is a
# RENAME WITH a content hunk (similarity < 100%). Pure renames (build-rename-001)
# and content-only merges were already covered; this is the combined case.
#
# Resulting first-parent history (base = neo):
#   c1 create mixfile.txt -> merge side (rename mixfile.txt -> mixfile-renamed.txt
#   AND change line3 in the same commit) -> c2 add tail.txt
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-mixedrename-001'
$Base = 'neo'
$Side = 'tmp/mixrename-side'

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Base^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: base '$Base' not found." -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $Force) { Write-Host "Error: branch '$Branch' already exists. Use -Force to rebuild." -ForegroundColor Red; exit 1 }
    git merge --abort 2>$null | Out-Null
    git checkout -f $Base | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 1 }
    foreach ($b in @($Branch, $Side)) {
        git rev-parse --verify --quiet "$b^{commit}" | Out-Null
        if ($LASTEXITCODE -eq 0) { git branch -D $b | Out-Null }
    }
}

git checkout -B $Branch $Base
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: the file that will be renamed AND modified on the side branch
@('line1', 'line2', 'line3', 'line4', 'line5') | Set-Content -Path 'mixfile.txt' -Encoding utf8
git add mixfile.txt
git commit -m 'mixed-rename: c1 create mixfile.txt'
if ($LASTEXITCODE -ne 0) { exit 1 }

# side branch: rename the file AND change a line in the SAME commit
git checkout -b $Side $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git mv mixfile.txt mixfile-renamed.txt
@('line1', 'line2', 'line3-CHANGED', 'line4', 'line5') | Set-Content -Path 'mixfile-renamed.txt' -Encoding utf8
git add mixfile-renamed.txt
git commit -m 'side: rename mixfile.txt and change line3 in one commit'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git merge --no-ff $Side -m "Merge branch '$Side'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Unexpected conflict at merge side.' -ForegroundColor Red; exit 1 }

# c2: regular commit after the merge
@('mixed-rename c2') | Set-Content -Path 'tail.txt' -Encoding utf8
git add tail.txt
git commit -m 'mixed-rename: c2 add tail.txt'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Base" -ForegroundColor Green
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Base..$Branch"
