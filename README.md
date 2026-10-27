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

**ps1 最後更新：2026-08-27（本次收尾：衝突 fallback 實測並修復結構退化）**

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

待辦（未來可參考）：

- **`--binary` 實測**：`git diff --binary` 已加入但尚未用含二進位檔的衝突夾具驗證（需在夾具中放一個兩側都改的二進位檔，確認 `apply --3way` 還原正確）
- 衝突 fallback 的 `pause` 路徑（apply 也失敗、需完全手動解決）仍未實測 — 目前夾具的 patch 都能乾淨套用
- CJK commit 訊息／分支名（`-m` 編碼鏈）、repo 路徑含空格、`commit.gpgsign=true` 與 pre-commit/commit-msg hook、rename／檔案模式變更穿過 merge 與 fallback、重建中斷後重跑的恢復行為

## 測試案例

夾具分支皆可用 `rebuild-neo-tests\` 下的腳本一鍵重建（`-Force` 覆蓋重建；分支與提交訊息逐字重現 2026-08-27 手動建構的版本）。

| # | 分支 | base | 結構 | 結果 |
|---|---|---|---|---|
| 1 | `tmp/rebuild-merge-test` | neo | 3 個 PR 合併 | PASS（tree、patch-id 相同） |
| 2 | `tmp/rebuild-mixed-001` | neo | 10 節點：5 一般提交與 5 PR 合併交錯，c3/c4 夾擊 processing.py，含連續合併 | PASS：tree `d4017e5f` 相同、patch-id `33ff575e…` 相同、5 原 merge 全脫離、5 feature tip 全為祖先、訊息未加 (Rebuilt)、原分支未動 |
| 3 | `tmp/rebuild-mixed-neo-001` | ad607938 | 17 節點：c1..c8 → **Mneo(#9，帶入 44 檔/498,672 行)** → 5 PR 合併 + c9/c10 夾擊 processing.py → c11 | PASS：tree `93e7b61d` 完全相同、`git diff 來源 重建` 為空、4 個跨版本 cherry-pick 全乾淨；方案 (b) 修復後 **17==17 節點 1:1**，Mneo 以空合併 commit 保留、原 Mneo 仍脫離、neo tip 為真第二父 |
| 4 | `tmp/rebuild-edge-001` | neo | 5 節點：一般提交 → 單親 "Merge remote-tracking..." 訊息 → 空提交 → **octopus 合併 3 側支** → 一般提交 | PASS：5==5 節點、tree 相同、訊息逐行相同；單親 Merge 訊息正確走 cherry-pick 且脫離原提交、空提交以 `--allow-empty` 保留、octopus 重放為 MERGE x4 且 3 個側支 tip 全為祖先 |
| 5 | 空範圍守衛 | neo | `neo neo` 與 `neo 0c388f8b`（feature 已含於 base） | PASS：皆印 `Nothing to rebuild`、exit 0 |
| 6 | `tmp/rebuild-conflict-001` | neo | 4 節點：c1 建檔 → merge side-a → **merge side-b（必然衝突，原始史手動解為 AB）** → c2 | PASS：fallback 觸發 2 次（含 replay 時因 cherry-pick 改變 merge-base 導致的 add/add 衝突），`apply --3way` 皆乾淨套用；4==4 節點、tree 相同、解法 `line3-AB` 被完整重現、合併節點保持 MERGE x2、側支 tip 可達、原合併脫離。**實測發現並修復**：原 fallback 以 `add -u`+`commit` 收尾會把合併退化成單親（側支失聯），已改 `write-tree`+`commit-tree` |
| 7 | 各分支 dry-run | — | 同上 | PASS：計畫正確、零改動（分支 tip、patch 目錄、工作樹皆未變） |

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
