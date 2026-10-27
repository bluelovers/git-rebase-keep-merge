# Recreate test branch tmp/rebuild-binary-001 - the fixture that verifies
# rebuild-neo.ps1's --binary handling in the conflict fallback (apply --3way).
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-binary-001.ps1          # fails if branch already exists
#   .\build-binary-001.ps1 -Force   # delete and rebuild it
#
# Design (same drift pattern as build-manual-001, plus a binary file):
#   - Anchor ad607938, commit A = bintest.txt + rebuildpayload.dat (binary v1, NUL bytes
#     so git classifies it as binary). Main does NOT touch download_configs.py.
#   - Side bumps the binary to v2 AND changes the PIPELINE_PATHS line that neo LATER changes.
#   - Original merge onto the anchor is CLEAN (main never edited that line).
#   - Rebuilding onto neo causes context drift on that line -> apply --index fails ->
#     git merge conflicts -> apply --3way runs with a patch that carries BOTH a text hunk
#     and a GIT binary patch payload. Verified: apply --3way restores the binary cleanly
#     ("Applied patch to 'rebuildpayload.dat' cleanly") even though the text file conflicts.
#
# Resulting first-parent history (base = ad607938):
#   c1 create bintest + binary v1 -> c2 append -> merge side (binary v2 + line change)
#   -> c3 append
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-binary-001'
$Anchor = 'ad607938'
$Side = 'tmp/binside'
$BinFile = 'rebuildpayload.dat'

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

# Write a file git classifies as BINARY (embedded NUL bytes). .gitignore excludes *.bin,
# so this fixture uses a .dat name; -f guards against any ignore rule.
function Write-BinaryPayload([string]$Tag) {
    # 'BIN' + NULs + tag + NULs + 'END' => guaranteed NULs => git binary detection fires
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("BIN`0`1`2PAYLOAD_$Tag`0`0END")
    [System.IO.File]::WriteAllBytes((Join-Path (Get-Location).Path $BinFile), $bytes)
}

git checkout -B $Branch $Anchor
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: text file + binary v1 (commit A, the fork point for the side branch)
@('binary-fallback test') | Set-Content -Path 'bintest.txt' -Encoding utf8
Write-BinaryPayload 'v1'
git add -f bintest.txt $BinFile
git commit -m 'binary: c1 create bintest.txt + binary v1'
if ($LASTEXITCODE -ne 0) { exit 1 }
$A = (git rev-parse HEAD).Trim()

# side: bump binary to v2 AND change the PIPELINE line that neo later changes
git checkout -b $Side $A
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-BinaryPayload 'v2'
(Get-Content 'download_configs.py') -replace '^    "Qwen/Qwen-Image-2\.1"$', '    "side/model-A"' | Set-Content -Path 'download_configs.py' -Encoding utf8
git add -f $BinFile download_configs.py
git commit -m 'bin-side: binary v2 + change PIPELINE line'
if ($LASTEXITCODE -ne 0) { exit 1 }

# main: does NOT touch download_configs.py; append bintest then merge side (clean on anchor)
git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
Add-Content -Path 'bintest.txt' -Value 'binary: c2 append'
git add bintest.txt
git commit -m 'binary: c2 append bintest'
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff $Side -m "Merge branch '$Side'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Unexpected conflict on the anchor base - fixture is wrong.' -ForegroundColor Red; exit 1 }

# c3: regular commit after the merge
Add-Content -Path 'bintest.txt' -Value 'binary: c3 append after merge'
git add bintest.txt
git commit -m 'binary: c3 append after merge'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Anchor" -ForegroundColor Green
Write-Host " Rebuilding onto 'neo' triggers context drift -> fallback -> apply --3way with binary payload." -ForegroundColor Yellow
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Anchor..$Branch"
