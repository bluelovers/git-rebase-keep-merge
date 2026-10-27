# git-rebase-keep-merge（rebuild-neo）

用 `--no-ff` 分段重建 PR 分支的 merge 歷史並重新 merge 到指定 base 上，消除 `--rebase-merges` 產生的虛假合併線。重建結果脫離原始 merge commit（第二父改為 feature tip）。

## 檔案

| 檔案 | 說明 |
|---|---|
| `rebuild-neo.ps1` | 主腳本（UTF-8 with BOM，訊息全英文） |
| `rebuild-neo.bat` | 啟動器（chcp 65001、轉傳 %*、失敗 pause） |
| `rebuild-neo-tests/build-mixed-001.ps1` | 夾具分支 `tmp/rebuild-mixed-001` 建構腳本（base=neo） |
| `rebuild-neo-tests/build-mixed-neo-001.ps1` | 夾具分支 `tmp/rebuild-mixed-neo-001` 建構腳本（base=ad607938，含中段合併 neo） |

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

**ps1 最後更新：2026-08-27 10:06（對應 T:\opencode 工作副本）**

已實作：

- 位置參數、`-f`、`-n` dry-run（印出全部指令、唯讀查詢除外一律不執行）、`-RebuiltTag` 選擇性標記
- `rebuild/` 前綴臨時分支；自動偵測遇 `rebuild/<src>-rebuilt` 還原來源名，避免套娃並讓「already exists」守衛生效
- banner 顯示目前分支、臨時分支、patch 目錄、dry-run/tag 模式
- `Invoke-Git` 輔助函式（印指令、`-Query` 總是執行、`-Capture` 回傳輸出）
- `Test-Ancestor` 輔助函式（唯讀，已加入，供後續空合併判斷使用）
- 起跑前守衛：merge / cherry-pick / rebase / revert 進行中一律拒絕；工作樹有已追蹤檔案修改一律拒絕

進行中（已準備輔助函式，主迴圈尚未改）：

- **方案 (b)**：合併目標已是 HEAD 祖先時，改用 `git commit-tree` 建空合併 commit 保留節點 1:1（目前會被靜默丟棄）
- **單親 "Merge" 訊息誤判**：目前 `訊息 -match "^Merge"` 也觸發合併路徑，會把舊歷史變回祖先；應只看 parentCount
- **octopus（3+ 父）**：目前只合併 `$hash^2`，第 3 個以後的父內容遺失
- **patch 缺 `--binary`**：`git diff --output` 需加 `--binary`，否則含二進位檔時 `apply --3way` 必失敗
- **`FeatureBranch == BaseBranch`**：範圍為空卻印 `Rebuild completed!`
- **衝突 fallback 路徑從未被實測過**（三輪實跑全零衝突）：`merge --abort` → `apply --3way` → `commit` 與 `pause` 行為皆未驗證

## 測試案例

夾具分支皆可用 `rebuild-neo-tests\` 下的腳本一鍵重建（`-Force` 覆蓋重建；分支與提交訊息逐字重現 2026-08-27 手動建構的版本）。

| # | 分支 | base | 結構 | 結果 |
|---|---|---|---|---|
| 1 | `tmp/rebuild-merge-test` | neo | 3 個 PR 合併 | PASS（tree、patch-id 相同） |
| 2 | `tmp/rebuild-mixed-001` | neo | 10 節點：5 一般提交與 5 PR 合併交錯，c3/c4 夾擊 processing.py，含連續合併 | PASS：tree `d4017e5f` 相同、patch-id `33ff575e…` 相同、5 原 merge 全脫離、5 feature tip 全為祖先、訊息未加 (Rebuilt)、原分支未動 |
| 3 | `tmp/rebuild-mixed-neo-001` | ad607938 | 17 節點：c1..c8 → **Mneo(#9，帶入 44 檔/498,672 行)** → 5 PR 合併 + c9/c10 夾擊 processing.py → c11 | PASS（tree `93e7b61d` 完全相同、`git diff 來源 重建` 為空、4 個跨版本 cherry-pick 全乾淨）；**發現問題**：Mneo 因 `Already up to date.` 被靜默丟棄（17→16 節點），對應上方「方案 (b)」待辦 |
| 4 | 各分支 dry-run | — | 同上 | PASS：計畫正確、零改動（分支 tip、patch 目錄、工作樹皆未變） |

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
