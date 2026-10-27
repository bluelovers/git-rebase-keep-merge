# Recreate test branch tmp/rebuild-edge-001 (edge cases).
# Scripted copy of the manual steps used on 2026-10-27.
#
# Usage (run inside D:\sd-forge):
#   .\build-edge-001.ps1          # fails if branch already exists
#   .\build-edge-001.ps1 -Force   # delete and rebuild it
#
# Covers: single-parent commit with a Merge-style message (squash-style),
# empty regular commits, and an octopus merge (3 side branches in one node).
#
# Resulting first-parent history (base = neo):
#   c1 regular -> "Merge remote-tracking..." (single parent!) -> empty commit
#   -> octopus merge of 3 branches -> c2 regular
param([switch]$Force)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Branch = 'tmp/rebuild-edge-001'
$Base = 'neo'
$Sides = @('tmp/edge-side-a', 'tmp/edge-side-b', 'tmp/edge-side-c')

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Error: not inside a git repo. cd into D:\sd-forge first.' -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Base^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: base '$Base' not found." -ForegroundColor Red; exit 1 }

git rev-parse --verify --quiet "$Branch^{commit}" | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $Force) { Write-Host "Error: branch '$Branch' already exists. Use -Force to rebuild." -ForegroundColor Red; exit 1 }
    git checkout $Base
    if ($LASTEXITCODE -ne 0) { exit 1 }
    foreach ($b in @($Branch) + $Sides) {
        git rev-parse --verify --quiet "$b^{commit}" | Out-Null
        if ($LASTEXITCODE -eq 0) { git branch -D $b | Out-Null }
    }
}

git checkout -b $Branch $Base
if ($LASTEXITCODE -ne 0) { exit 1 }

# c1: ordinary regular commit
'edge line' | Set-Content -Path 'edge-test.txt' -Encoding utf8
git add edge-test.txt
git commit -m 'edge: regular commit'
if ($LASTEXITCODE -ne 0) { exit 1 }

# Single-parent commit whose message starts with "Merge" (squash-style).
# Must be replayed via cherry-pick; merging it would drag old history back in.
git commit --allow-empty -m "Merge remote-tracking branch 'origin/something'"
if ($LASTEXITCODE -ne 0) { exit 1 }

# Empty regular commit (no file changes): needs cherry-pick --allow-empty.
git commit --allow-empty -m 'edge: empty commit'
if ($LASTEXITCODE -ne 0) { exit 1 }

# Three side branches, then one octopus merge node combining all of them.
$letters = @{ 'tmp/edge-side-a' = 'a'; 'tmp/edge-side-b' = 'b'; 'tmp/edge-side-c' = 'c' }
foreach ($s in $Sides) {
    git checkout -b $s $Base
    if ($LASTEXITCODE -ne 0) { exit 1 }
    $letters[$s] | Set-Content -Path ("edge-{0}.txt" -f $letters[$s]) -Encoding utf8
    git add ("edge-{0}.txt" -f $letters[$s])
    git commit -m ("side {0}" -f $letters[$s])
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
git checkout $Branch
if ($LASTEXITCODE -ne 0) { exit 1 }

git merge --no-ff @($Sides) -m 'edge: octopus merge of three branches'
if ($LASTEXITCODE -ne 0) { Write-Host 'Conflict at octopus merge - resolve manually.' -ForegroundColor Red; exit 1 }

# c2: regular commit after the octopus
Add-Content -Path 'edge-test.txt' -Value 'edge final'
git add edge-test.txt
git commit -m 'edge: regular commit after octopus'
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host "Done: $Branch built on $Base" -ForegroundColor Green
Write-Host 'First-parent history:'
git log --first-parent --reverse --oneline "$Base..$Branch"
