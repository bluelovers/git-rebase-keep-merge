# Recreate test branch tmp/rebuild-manual-001 - the fixture that exercises
# rebuild-neo.ps1's conflict-fallback PAUSE (full-manual) path.
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-manual-001.ps1          # fails if branch already exists
#   .\build-manual-001.ps1 -Force   # delete and rebuild it
#
# Why this reaches `pause` (three conditions must all hold, they do here):
#   1. base moved from ad607938 -> neo, so the merge patch's context has DRIFTED
#      (the side branch changed a line that neo ALSO changed) -> `git apply --index` fails
#   2. `git merge` then CONFLICTS (both sides edited the same PIPELINE_PATHS line)
#   3. `git apply --3way` also cannot apply cleanly (context too far gone)
#   => script pauses: "resolve conflicts ... git add -u ... press any key".
#   Under redirected stdin (e.g. < /dev/null) nothing is resolved, so it stops with a
#   clear error + recovery hint instead. This is the ONLY fixture that reaches `pause`.
#
# Anchor is ad607938 (before neo changed download_configs.py), so rebuilding onto neo
# is what creates the drift/conflict.
#
# Resulting first-parent history (base = ad607938):
#   c1 create manualtest.txt -> merge side (change PIPELINE_PATHS line) -> c2 append
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-manual-001'
$Anchor = 'ad607938'
$Side = 'tmp/manual-side'

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Anchor^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: anchor '$Anchor' not found." -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $Force) { Write-Host "Error: branch '$Branch' already exists. Use -Force to rebuild." -ForegroundColor Red; exit 1 }
    git merge --abort 2>$null | Out-Null
    git checkout -f $Anchor | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 1 }
    foreach ($b in @($Branch, $Side)) {
        git rev-parse --verify --quiet "$b^{commit}" | Out-Null
        if ($LASTEXITCODE -eq 0) { git branch -D $b | Out-Null }
    }
}

git checkout -B $Branch $Anchor
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: safe regular commit on a file the later merge does NOT touch
@('manual-path test') | Set-Content -Path 'manualtest.txt' -Encoding utf8
git add manualtest.txt
git commit -m 'manual: c1 create manualtest.txt'
if ($LASTEXITCODE -ne 0) { exit 1 }

# side branch: edit the SAME line neo later edits (the Qwen entry in PIPELINE_PATHS)
git checkout -b $Side $Anchor
if ($LASTEXITCODE -ne 0) { exit 1 }
# sed: single-line replacement (no python dependency), keeps encoding identical to the source
git config --get core.autocrlf | Out-Null
(Get-Content 'download_configs.py') -replace '^    "Qwen/Qwen-Image-2\.1"$', '    "side/model-A"' | Set-Content -Path 'download_configs.py' -Encoding utf8
Select-String -Path 'download_configs.py' -Pattern 'side/model-A' -Quiet | Out-Null
if (-not $?) { Write-Host 'Error: side edit did not apply - fixture is wrong.' -ForegroundColor Red; exit 1 }
git add download_configs.py
git commit -m 'side: change PIPELINE_PATHS to side/model-A'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git merge --no-ff $Side -m "Merge branch '$Side'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Unexpected conflict on the anchor base - fixture is wrong.' -ForegroundColor Red; exit 1 }

# c2: regular commit after the merge
Add-Content -Path 'manualtest.txt' -Value 'manual c2'
git add manualtest.txt
git commit -m 'manual: c2 append'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Anchor" -ForegroundColor Green
Write-Host " Rebuilding onto 'neo' (a NEWER base) is what triggers the conflict/pause path." -ForegroundColor Yellow
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Anchor..$Branch"
