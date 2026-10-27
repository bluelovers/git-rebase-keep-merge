# Recreate test branch tmp/rebuild-cjk-001 (CJK messages / filenames / branch names).
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-cjk-001.ps1          # fails if branch already exists
#   .\build-cjk-001.ps1 -Force   # delete and rebuild it
#
# Covers: CJK commit messages (cherry-pick -m path and merge -m path),
# CJK filenames/content, and a side branch whose NAME contains CJK.
#
# Resulting first-parent history (base = neo):
#   c1 (CJK msg, CJK file) -> merge tmp/中文側支-001 -> c2 (CJK msg)
#   -> merge tmp/cjk-side-2 (CJK msg)
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-cjk-001'
$Base = 'neo'
$SideCJK = 'tmp/中文側支-001'
$SideMix = 'tmp/cjk-side-2'

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Base^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: base '$Base' not found." -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $Force) { Write-Host "Error: branch '$Branch' already exists. Use -Force to rebuild." -ForegroundColor Red; exit 1 }
    git checkout $Base
    if ($LASTEXITCODE -ne 0) { exit 1 }
    foreach ($b in @($Branch, $SideCJK, $SideMix)) {
        git rev-parse --verify --quiet "$b^{commit}" | Out-Null
        if ($LASTEXITCODE -eq 0) { git branch -D $b | Out-Null }
    }
}

git checkout -b $Branch $Base
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: CJK message + CJK filename + CJK content
@('第一行', '第二行', '第三行') | Set-Content -Path '中文檔案.txt' -Encoding utf8
git add '中文檔案.txt'
git commit -m '中文測試：c1 建立中文檔名與中文內容'
if ($LASTEXITCODE -ne 0) { exit 1 }

# side branch with CJK name and CJK message
git checkout -b $SideCJK $Base
if ($LASTEXITCODE -ne 0) { exit 1 }
@('側支內容 A') | Set-Content -Path '側支檔案.txt' -Encoding utf8
git add '側支檔案.txt'
git commit -m '側支：加入側支檔案（中文訊息）'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git merge --no-ff $SideCJK -m "合併分支 '$SideCJK'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge CJK side - resolve manually.' -ForegroundColor Red; exit 1 }

# c2: CJK message, append to the CJK file
Add-Content -Path '中文檔案.txt' -Value '第四行'
git add '中文檔案.txt'
git commit -m '中文測試：c2 追加中文檔案'
if ($LASTEXITCODE -ne 0) { exit 1 }

# second side branch: ASCII name, CJK message (mixed naming coverage)
git checkout -b $SideMix $Base
if ($LASTEXITCODE -ne 0) { exit 1 }
@('側支內容 B') | Set-Content -Path '側支檔案2.txt' -Encoding utf8
git add '側支檔案2.txt'
git commit -m '側支二：另一個中文訊息提交'
if ($LASTEXITCODE -ne 0) { exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }
git merge --no-ff $SideMix -m "合併分支 '$SideMix'"
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at merge side-2 - resolve manually.' -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Base" -ForegroundColor Green
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Base..$Branch"
