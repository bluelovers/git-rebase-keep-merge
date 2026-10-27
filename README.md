# git-rebase-keep-merge（rebuild-neo）

用 `--no-ff` 分段重建 PR 分支的 merge 歷史並重新 merge 到指定 base 上，消除 `--rebase-merges` 產生的虛假合併線。重建結果脫離原始 merge commit（第二父改為 feature tip）。

## 檔案

| 檔案 | 說明 |
|---|---|
| `rebuild-neo.ps1` | 主腳本（UTF-8 with BOM，訊息全英文） |
| `rebuild-neo.bat` | 啟動器（chcp 65001、轉傳 %*、失敗 pause） |
| `rebuild-neo-tests/build-mixed-001.ps1` | 夾具分支 `tmp/rebuild-mixed-001` 建構腳本（base=neo） |
| `rebuild-neo-tests/build-mixed-neo-001.ps1` | 夾具分支 `tmp/rebuild-mixed-neo-001` 建構腳本（base=ad607938，含中段合併 neo） |
| `rebuild-neo-tests/build-edge-001.ps1` | 夾具分支 `tmp/rebuild-edge-001` 建構腳本（單親 Merge 訊息、空提交、octopus） |
| `rebuild-neo-tests/build-conflict-001.ps1` | 夾具分支 `tmp/rebuild-conflict-001` 建構腳本（必然衝突，含手動解決步驟） |
| `rebuild-neo-tests/build-cjk-001.ps1` | 夾具分支 `tmp/rebuild-cjk-001` 建構腳本（CJK 訊息／檔名／分支名） |
| `rebuild-neo-tests/build-rename-001.ps1` | 夾具分支 `tmp/rebuild-rename-001` 建構腳本（純改名 + rename/rename 衝突，記錄已知限制） |
| `rebuild-neo-tests/build-mixedrename-001.ps1` | 夾具分支 `tmp/rebuild-mixedrename-001` 建構腳本（rename + 內容改動在同一合併） |
| `rebuild-neo-tests/build-manual-001.ps1` | 夾具分支 `tmp/rebuild-manual-001` 建構腳本（base 前移造成 context 漂移，唯一能觸發 `pause` 全手動路徑的夾具） |
| `rebuild-neo-tests/build-binary-001.ps1` | 夾具分支 `tmp/rebuild-binary-001` 建構腳本（fallback 帶二進位 payload，驗證 `--binary`） |

## 工作流程

- **正式版本**：本 repo（每個任務收尾同步 + 記錄版本）
- **工作副本**：`T:\opencode\`（執行中、未定稿的修改先放這裡）

## 用法

```
rebuild-neo <base-branch> [<feature-branch>] [-f] [-n] [-RebuiltTag]
```

- 位置參數風格同 `git rebase <upstream> [<branch>]`；feature 省略時自動取目前分支（不修改它，只在 `rebuild/` 前綴臨時分支上工作）
- `-f / -Force`：覆蓋已存在的臨時分支
- `-n / -DryRun`：只印出每支指令、不執行任何操作
- `-RebuiltTag`：merge 訊息後追加 ` (Rebuilt)`（預設不加）
- 所有建立 patch 之後的步驟都會先印出 `$ git ...` 指令再執行

## 版本狀態

**ps1 最後更新：2026-08-27（本次收尾：--binary 實測通過，無 ps1 改動）**

已實作：

- 位置參數、`-f`、`-n` dry-run（印出全部指令、唯讀查詢除外一律不執行）、`-RebuiltTag` 選擇性標記
- `rebuild/` 前綴臨時分支；自動偵測遇 `rebuild/<src>-rebuilt` 還原來源名，避免套娃並讓「already exists」守衛生效
- banner 顯示目前分支、臨時分支、patch 目錄、dry-run/tag 模式
- `Invoke-Git` 輔助函式（印指令、`-Query` 總是執行、`-Capture` 回傳輸出）
- `Test-Ancestor` 輔助函式（唯讀、會印出指令）
- 起跑前守衛：merge / cherry-pick / rebase / revert 進行中一律拒絕；工作樹有已追蹤檔案修改一律拒絕
- **merge 判定只看 parentCount**：單親但訊息以 "Merge" 開頭的提交走 cherry-pick，不會把舊歷史拖回祖先
- **方案 (b) 空合併**：所有 side parent 已含於 HEAD 時，`git commit-tree HEAD^{tree} -p HEAD -p <targets>` + `reset --hard` 建空合併 commit，節點 1:1 保留（Mneo 類案例不再被靜默丟棄）
- **octopus（3+ 父）**：`git merge --no-ff ^2 ^3 ...` 一次合併全部 side parent，保持 1:1 節點且內容不遺失
- **patch 加 `--binary`**：衝突 fallback 的 `git apply --3way` 能還原二進位檔
- **空範圍守衛**：base==feature 或 feature 已含於 base 時印 `Nothing to rebuild` 並 exit 0，不再誤印 completed
- **空提交**：cherry-pick 前用 `git diff --quiet` 偵測，空提交自動加 `--allow-empty`
- **衝突 fallback 收尾改為真合併結構**（本次實測發現原 `add -u` + `commit` 會把合併節點退化成單親 commit、側支 tip 失聯）：現為 `write-tree` + `commit-tree -p HEAD -p <targets>` + `reset --hard`，節點保持 MERGE 且側支 tip 可達；`apply --3way` 失敗時暫停，提示手動解決並 `git add -u` 後繼續，同一段 commit-tree 邏輯收尾
- **CJK 驗證通過**：中文 commit 訊息（cherry-pick 與 merge 兩條路徑）、中文檔名與內容、含 CJK 的側支分支名（`tmp/中文側支-001`）全部完整保留，subjects 逐位元相同
- **內容安全網**（本次新增）：replay 用 `git merge` 重新自動合併，**不保證重現原始手動解決的衝突**（patch fallback 只在 replay 衝突時觸發；若 replay 乾淨卻與原史不同 → 靜默腐蝕）。當 base 是 feature 的祖先時（可證明 tree 應完全相符），結尾比對 `rev-parse <feature>^{tree}` vs `<temp>^{tree}`，不符就印紅字 MISMATCH 與檢查指令；異基底重建（base 已前移）自動略過
- **patch-first 重放（本次改動，修復 rename 內容分歧）**：合併節點改為先 `git apply --index` 套用第一父 patch（`diff P1..M`，即該合併對主線的內容貢獻定義、context 最嚴格）；只有 context 過期（跨版本，如 Mneo 佈局）才退回 `git merge --no-ff`，merge 衝突再走 `apply --3way`。**根因**：主線 cherry-pick 改了 hash → `git merge` 的 `merge-base(重放主線, 側支)` 退回更早祖先、無從偵測 rename → 靜默 add/add 把新舊路徑都留下且不觸發 fallback → 分歧；`git apply` 用第一父 blob 當基準能正確重現 rename。空 patch（內容中立合併，如 rename/rename 手動解）則直接 `commit-tree` 建節點、不碰內容

- **preflight 守衛後的衝突復原指引（本次新增）**：`pause` 後若未解決（非互動／stdin 重導向下立即返回），`write-tree` 失敗改為偵測 unmerged 路徑並印出明確復原步驟（列出未合併檔 → `git add -u` → `git reset --hard HEAD` 捨棄重跑），不再只印技術性 `index not in a committable state`
- **`pause` 全手動路徑實測通過**：用 base 前移夾具湊齊三重條件（patch context 漂移 + `git merge` 衝突 + `apply --3way` 失敗）→ 正確抵達 `Pausing: resolve conflicts...`；重跑時 preflight 守衛正確擋下未解決的 `UU` 狀態

已知限制：

- 目前無已知會產生錯誤內容的案例（rename 已修）。內容安全網仍保留作為防線：若未來任何 replay 產生與原史不同的 tree 會主動警告

待辦（未來可參考）：

- ~~`--binary` 實測~~（已驗證，見案例 14 `tmp/rebuild-binary-001`）
- ~~衝突 fallback 的 `pause` 路徑~~（已實測，見案例 11 `tmp/rebuild-manual-001`）
- ~~patch-first 對「rename + 同時內容也改動」的組合尚未有專屬夾具~~（已驗證，見案例 8）
- ~~preflight 守衛（髒工作樹／進行中操作）~~（已實測，見案例 10）
- rebase / revert 進行中守衛未單獨實測（與 merge/cherry-pick 同源 `Test-Path` 機制）
- ~~repo 路徑含空格~~（以含空格 `-PatchDir` 驗證，見案例 12；repo 本身路徑含空格未測 — `D:\sd-forge` 無空格）
- `commit.gpgsign=true` 與 pre-commit/commit-msg hook
- `pause` 在**真實互動終端**下的行為（目前用 `< /dev/null` 驗證會立即返回並給復原指引；真人按鍵前後的 staging 流程未逐格驗證）

## 測試案例

夾具分支皆可用 `rebuild-neo-tests\` 下的腳本一鍵重建（`-Force` 覆蓋重建；分支與提交訊息逐字重現 2026-08-27 手動建構的版本）。

| # | 分支 | base | 結構 | 結果 |
|---|---|---|---|---|
| 1 | `tmp/rebuild-merge-test` | neo | 3 個 PR 合併 | PASS（tree、patch-id 相同） |
| 2 | `tmp/rebuild-mixed-001` | neo | 10 節點：5 一般提交與 5 PR 合併交錯，c3/c4 夾擊 processing.py，含連續合併 | PASS：tree `d4017e5f` 相同、patch-id `33ff575e…` 相同、5 原 merge 全脫離、5 feature tip 全為祖先、訊息未加 (Rebuilt)、原分支未動 |
| 3 | `tmp/rebuild-mixed-neo-001` | ad607938 | 17 節點：c1..c8 → **Mneo(#9，帶入 44 檔/498,672 行)** → 5 PR 合併 + c9/c10 夾擊 processing.py → c11 | PASS：tree `93e7b61d` 完全相同、`git diff 來源 重建` 為空、4 個跨版本 cherry-pick 全乾淨；方案 (b) 修復後 **17==17 節點 1:1**，Mneo 以空合併 commit 保留、原 Mneo 仍脫離、neo tip 為真第二父 |
| 4 | `tmp/rebuild-edge-001` | neo | 5 節點：一般提交 → 單親 "Merge remote-tracking..." 訊息 → 空提交 → **octopus 合併 3 側支** → 一般提交 | PASS：5==5 節點、tree 相同、訊息逐行相同；單親 Merge 訊息正確走 cherry-pick 且脫離原提交、空提交以 `--allow-empty` 保留、octopus 重放為 MERGE x4 且 3 個側支 tip 全為祖先 |
| 5 | `tmp/rebuild-conflict-001` | neo | 4 節點：c1 建檔 → merge side-a → **merge side-b（必然衝突，原始史手動解為 AB）** → c2 | PASS：fallback 觸發 2 次（含 replay 時因 cherry-pick 改變 merge-base 導致的 add/add 衝突），`apply --3way` 皆乾淨套用；4==4 節點、tree 相同、解法 `line3-AB` 被完整重現、合併節點保持 MERGE x2、側支 tip 可達、原合併脫離。**實測發現並修復**：原 fallback 以 `add -u`+`commit` 收尾會把合併退化成單親（側支失聯），已改 `write-tree`+`commit-tree` |
| 6 | `tmp/rebuild-cjk-001` | neo | 4 節點：CJK 訊息/檔名/內容 → 合併 **CJK 分支名** `tmp/中文側支-001` → CJK 追加 → 合併 `tmp/cjk-side-2` | PASS：CJK commit 訊息（cherry-pick 與 merge 兩路徑）、中文檔名、中文內容、CJK 側支分支名全保留；subjects 逐位元相同、tree 相同、側支 tip 可達、原合併脫離 |
| 7 | `tmp/rebuild-rename-001` | neo | 4 節點：c1 → merge side-a（純改名 → moved.txt）→ **merge side-b（rename/rename 衝突，手動保留 moved.txt）** → c2 | PASS（patch-first 修復後）：4==4 節點、tree 完全相同 `4111f4cb`、側支 tip 可達、原合併脫離。side-a 走 `git apply --index` 正確重現 rename（不再被 merge-base 斷裂破壞）；side-b 空 patch 走內容中立 `commit-tree`、不碰內容 |
| 8 | `tmp/rebuild-mixedrename-001` | neo | 3 節點：c1 建檔 → **merge side（rename + 改內容在同一提交，63% similarity 帶 hunk 的 rename patch）** → c2 | PASS：3==3 節點、tree 完全相同、rename 與內容改動都保留（`mixfile-renamed.txt` 且 line3-CHANGED）、側支 tip 可達、原合併脫離。確認 patch-first 的 `git apply --index` 能處理「rename 且帶內容 hunk」的 patch |
| 9 | 空範圍守衛 | neo | `neo neo` 與 `neo 0c388f8b`（feature 已含於 base） | PASS：皆印 `Nothing to rebuild`、exit 0 |
| 10 | preflight 守衛 | neo | ①髒已追蹤檔（`M webui.py`）②進行中 merge（`.git/MERGE_HEAD` 殘留）③進行中 cherry-pick（`CHERRY_PICK_HEAD` 殘留） | PASS：三種情形皆正確拒絕、印出明確原因與復原提示、exit 1，未動任何分支。（rebase/revert 守衛同源 `Test-Path` 機制，未單獨實測） |
| 11 | `tmp/rebuild-manual-001` | ad607938→**neo** | 3 節點：c1 → merge side（改 PIPELINE_PATHS 同一行）→ c2；重建到**較新的** neo 觸發三重條件 | PASS：三條件全中（`apply --index` context drifted → `git merge` 衝突 → `apply --3way` 失敗 → **Pausing** 正確抵達）。非互動下 write-tree 失敗 → 改進後訊息列出 unmerged 檔 + `git add -u` + `git reset --hard HEAD` 復原指引；重跑 preflight 守衛正確擋下 `UU` 狀態 |
| 12 | 路徑含空格 | neo | `-PatchDir '.git/rebuild patches'`（含空格目錄）對 `tmp/rebuild-conflict-001` 乾跑+實跑 | PASS：`git diff --output=<含空格路徑>` 正確寫入、`git apply --index <含空格路徑>` 正確套用、tree 完全相符；dry-run 正確印出含空格路徑且不建立目錄。證明 PowerShell 陣列 splatting 把含空格路徑當單一參數傳給 git |
| 13 | 各分支 dry-run | — | 同上 | PASS：計畫正確、零改動（分支 tip、patch 目錄、工作樹皆未變） |
| 14 | `tmp/rebuild-binary-001` | ad607938→**neo** | 4 節點：c1 建文字+二進位 v1 → c2 → **merge side（二進位 v2 + 改 PIPELINE 同一行）** → c3；重建到較新的 neo 觸發 drift→fallback | PASS：`git diff --binary` 產生含 `GIT binary patch` payload 的 patch；`apply --3way` 對二進位回 `Applied patch 'rebuildpayload.dat' cleanly`（文字檔才是 `with conflicts`）、工作目錄還原 v2；finish（write-tree+commit-tree）保留暫存二進位（blob `032c6bee`=v2）。`Pausing` 由文字衝突觸發，與二進位無關 |

夾具設計要點：

- 一般提交刻意交錯在合併前／合併間／合併後，並夾擊之後合併也會改的檔案
- 錨點前移（`ad607938`，距 neo 13 commits）以放大中段合併範圍；**5 個 PR 合併全排在 Mneo 之後**，否則 PR 會提前帶入 `ad607938..0c388f8b`，Mneo 只剩 10 檔殘餘
- `processing.py` / `sd_models.py` 在 `ad607938..neo` 全程未變，保證交錯操作兩侧行為一致
- `README.md` / `requirements.txt` 檔首有 hunk 但檔尾安全 → 一般提交可跨版本 append（真的吃到範圍壓力）

## 驗證方法

- **黃金標準（同基底）**：tree hash 相同（`git rev-parse <br>^{tree}`）＋ `git patch-id` 相同（`git diff <base> <br> | git patch-id`）
- **黃金標準（基底不同，如 Mneo 佈局）**：tree 身分相同 ＋ `git diff <source> <rebuilt>` 為空（兩側 patch-id 因範圍不同本來就不同，不可用）
- **結構**：`git log --first-parent --reverse --format='%h|%p|%s'` 逐一比對節點型別與順序
- **脫離原始 merge**：`git merge-base --is-ancestor <原merge> <rebuilt>` 必須為 false
- **合併為真結構**：每個 feature tip 皆須為 rebuilt 的祖先
- **訊息**：first-parent subjects 逐行 diff（預設應完全相同）
- **原分支未動**：重建前後 `git rev-parse <source>` 相同
