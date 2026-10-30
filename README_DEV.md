# git-rebase-keep-merge（rebuild-neo）

用 `--no-ff` 分段重建 PR 分支的 merge 歷史並重新 merge 到指定 base 上，消除 `--rebase-merges` 產生的虛假合併線。重建結果脫離原始 merge commit（第二父改為 feature tip）。

## 檔案

| 檔案 | 說明 |
|---|---|
| `rebuild-neo.ps1` | 主腳本（UTF-8 with BOM，訊息全英文） |
| `rebuild-neo.bat` | 啟動器（chcp 65001、轉傳 %*、失敗 pause） |
| `README.md` | **面向使用者**的說明（用法／安全機制／落地指令）；本檔（README_DEV.md）為開發紀錄，收尾時更新 |
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

**ps1 最後更新：2026-10-31（本次收尾：新增「重建已落地偵測」與「遠端落後守衛」兩道防護；README 拆分為面向使用者的 README.md + 本開發紀錄）**

已實作：

- 位置參數、`-f`、`-n` dry-run（印出全部指令、唯讀查詢除外一律不執行）、`-RebuiltTag` 選擇性標記
- `rebuild/` 前綴臨時分支；自動偵測遇 `rebuild/<src>-rebuilt` 還原來源名，避免套娃並讓「already exists」守衛生效
- banner 顯示目前分支、臨時分支、patch 目錄、dry-run/tag 模式
- `Invoke-Git` 輔助函式（印指令、`-Query` 總是執行、`-Capture` 回傳輸出）
- `Test-Ancestor` 輔助函式（唯讀、會印出指令）
- 起跑前守衛：merge / cherry-pick / rebase / revert 進行中一律拒絕（屬衝突狀態）；**髒工作樹不再拒絕**（見下方 stash 機制）
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
- **未提交變更／未追蹤檔不再拒絕執行（前次改動）**：已追蹤的未提交變更（含 staged）`git stash push` 保存，主體包進 `try{...}finally{...}` 結束時 `git stash pop --index` 還原（`finally` 在 `exit` 時仍執行、保留退出碼，實測驗證）。變更既**不被拒絕**、也**不進 commit**（write-tree 只寫索引，暫存變更已 stash 離開）、更**不遺失**。finally 的 pop 失敗分兩種成因給對應指引：(a) pop **前**索引就有 unmerged（重建停在衝突中）→ 先修索引再 pop；(b) pop 前索引乾淨、pop 才衝突（stash 與重建改到同幾行）→ 真內容衝突。dry-run 不建立 stash、只印計畫。
- **重建已落地偵測（本次新增）**：temp 分支 `rebuild/<feature>-rebuilt` 存在且為 feature 的祖先（例如已 `checkout -B <feature> <temp>` 落地過）→ 不再重跑「重建的重建」，印說明 exit 0；`-f` 為明確覆蓋（印 WARNING 後照跑，適用 base 已前移需重重建已落地分支的場景）
- **遠端落後守衛（本次新增）**：banner 後、任何變更動作前，best-effort 比對 base / feature 與 upstream（無 upstream 退回 `origin/<名稱>`）— 只 fetch 兩分支實際使用的遠端；**本地嚴格落後（`rev-list --left-right --count` 顯示僅遠端有 commits）→ 拒絕 exit 1** 並附 `git merge --ff-only` 更新指令；領先→提示、分歧→警告（重建本地內容）；無遠端／無 upstream／fetch 失敗／不可比對 → 一律只提示不中斷；比對全用穩定 plumbing（rev-parse / rev-list），不解析訊息文字；dry-run 不 fetch、用上次取得的遠端狀態
- **未追蹤檔碰撞停車機制「遇到時才處理」（前次無差別、本次改為精準交集）**：實測確認 git 對未追蹤檔與 checkout/cherry-pick 碰撞**一律硬拒絕且不看內容是否相同**（同內容也拒、本地檔不銷毀、`stash -u` 還原不可靠）→ 殘留檔（切換/撤銷遺留、先行複製）會直接中斷重建。**停車集 = 未追蹤檔 ∩（base tree 路徑 ∪ `base..feature` 全部提交的 name-only 路徑）** — 即只停「checkout 寫 base 內容」與「重放 cherry-pick/merge/apply 寫範圍內路徑」真正會撞的檔；已枚舉腳本全部寫工作樹命令（checkout/cherry-pick/merge/apply/reset --hard/stash，後兩者只動 tracked）確認交集覆蓋完整，查詢全用穩定格式（porcelain / ls-tree / log --name-only）不解析易變錯誤訊息；**若預測有漏，退化為 git 明確拒絕（不會靜默）**。其餘未追蹤檔全程原地不動（`N other untracked file(s) do not collide - left in place`）。`finally` 歸還規則不變 — 路徑空→靜默歸位；**內容相同→丟停車副本**（無縫）；**內容不同→保留停車副本+警告**（worktree 留重建版，殘留永不混入未來 `git commit -a`，附 `git diff --no-index` 比對指令）。**「內容相同」的判定本次改為忽略空白/行尾/空行格式的等價比較**（`Get-FileEquivalence`：SHA-1 位元組快取路徑 → 不同時回退 `git diff --no-index --quiet --ignore-cr-at-eol --ignore-space-change --ignore-all-space --ignore-blank-lines`，exit 0 = 視為相同）— 解決 Windows 上 CRLF/LF、tab/空白重縮排、空行增減殘留被誤判為衝突的假陽性；三態返回 `Equal / Equivalent / Different`，`Equivalent` 在還原時無縫丟停車副本並附註記、在停車撞位時釋放路徑（不再後綴停車）。**八項邊界已實測**：CRLF/LF、縮排、tab vs 空格、空格數量、多餘空行、**檔案尾換行有無（舊邊界已消除）** 皆視為相同；真內容差異仍判不同。**BOM 有無升級為專屬偵測（本次）**：`Get-FileEquivalence` 第四態 `BomOnly` — 位元組比對發現「僅一側有 UTF-8 BOM、去 BOM 後內容全同」時不自動視為相同（BOM 常是**刻意增加或刪除**），機制維持保守（停車端：保留兩份 `.parkedN` 並註記、還原端：保留停車副本+manifest），但訊息改為專屬 `BOM DIFFERENCE` 通知（含檢查指令與「決定哪側該帶 BOM」指引），取代籠統的 `LEFTOVER CONFLICT`；BOM＋真內容差異仍回籠統訊息（已驗證不誤分流）。二進位仍走位元組精確比較（ignore 旗標不適用於二進位內容）。註：`--ignore-all-space` 語意下**純縮排差異也不再算差異**（前導縮排曾為刻意保留項，依指定旗標改為忽略）。停車撞位（同路徑已有前次停車副本）：等價→釋放路徑、異內容/BOM→唯一後綴 `.parkedN` + manifest `原路徑 => 停車路徑` 映射，兩份都保留。任何停車失敗 → 寫完 manifest 硬退。還原逐條 try/catch、刪除失敗降級 .NET API、計數失實不刪 manifest、manifest 自身不計入殘留掃描 — 皆為實測暴露的孤兒檔 bug 修復。**附帶修正：Content check MISMATCH 現在 exit 1**。dry-run 只印 would-park 計畫、也不再替前次停車執行還原（只提示）。
- **`pause` 全手動路徑實測通過**：用 base 前移夾具湊齊三重條件（patch context 漂移 + `git merge` 衝突 + `apply --3way` 失敗）→ 正確抵達 `Pausing: resolve conflicts...`；重跑時 preflight 守衛正確擋下未解決的 `UU` 狀態

已知限制：

- 目前無已知會產生錯誤內容的案例（rename 已修）。內容安全網仍保留作為防線：若未來任何 replay 產生與原史不同的 tree 會主動警告，**且現在會 exit 1**（不再謊報成功）
- **被 .gitignore 忽略的檔案不停車**（停車只掃 status 可見的 `??`）：若某忽略檔恰與「base 才追蹤」的路徑碰撞，git 的行為未驗證 — 本輪需求（切換殘留／先行複製的未追蹤檔）已完整覆蓋，忽略檔屬另一類，尚未實測

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
| 10 | preflight 守衛 | neo | ①進行中 merge（`.git/MERGE_HEAD` 殘留）②進行中 cherry-pick（`CHERRY_PICK_HEAD` 殘留） | PASS：兩種皆正確拒絕、印出明確原因與復原提示、exit 1，未動任何分支。（rebase/revert 守衛同源 `Test-Path` 機制，未單獨實測。**髒工作樹已改為不再拒絕**，見案例 15） |
| 11 | `tmp/rebuild-manual-001` | ad607938→**neo** | 3 節點：c1 → merge side（改 PIPELINE_PATHS 同一行）→ c2；重建到**較新的** neo 觸發三重條件 | PASS：三條件全中（`apply --index` context drifted → `git merge` 衝突 → `apply --3way` 失敗 → **Pausing** 正確抵達）。非互動下 write-tree 失敗 → 改進後訊息列出 unmerged 檔 + `git add -u` + `git reset --hard HEAD` 復原指引；重跑 preflight 守衛正確擋下 `UU` 狀態 |
| 12 | 路徑含空格 | neo | `-PatchDir '.git/rebuild patches'`（含空格目錄）對 `tmp/rebuild-conflict-001` 乾跑+實跑 | PASS：`git diff --output=<含空格路徑>` 正確寫入、`git apply --index <含空格路徑>` 正確套用、tree 完全相符；dry-run 正確印出含空格路徑且不建立目錄。證明 PowerShell 陣列 splatting 把含空格路徑當單一參數傳給 git |
| 13 | 各分支 dry-run | — | 同上 | PASS：計畫正確、零改動（分支 tip、patch 目錄、工作樹皆未變） |
| 14 | `tmp/rebuild-binary-001` | ad607938→**neo** | 4 節點：c1 建文字+二進位 v1 → c2 → **merge side（二進位 v2 + 改 PIPELINE 同一行）** → c3；重建到較新的 neo 觸發 drift→fallback | PASS：`git diff --binary` 產生含 `GIT binary patch` payload 的 patch；`apply --3way` 對二進位回 `Applied patch 'rebuildpayload.dat' cleanly`（文字檔才是 `with conflicts`）、工作目錄還原 v2；finish（write-tree+commit-tree）保留暫存二進位（blob `032c6bee`=v2）。`Pausing` 由文字衝突觸發，與二進位無關 |
| 15 | 未提交變更／未追蹤檔 | neo | staged（`M  LICENSE`）+ unstaged（` M launch.py`）+ 未追蹤檔，對 `mixed-001` 實跑 | PASS：不拒絕、EXIT=0、`stash push → 重建 → stash pop --index` 全流程；`git log -S` 兩個標記查無 → **變更未進任何 commit**；還原後 staged 保持 staged、unstaged 保持 unstaged；未追蹤檔存在且未動；tree 仍與 source 完全相同 |
| 16 | stash 失敗分支 | neo | (a) `manual-001` 讓重建停在自身衝突 (b) 改 `processing.py` 尾端與重建同區 → pop 衝突 | PASS：(a) exit 1、pop 前偵測索引有 unmerged → 訊息「rebuild STOPPED」+ 先修索引再 pop、stash 保留；(b) 重建成功、索引乾淨、pop 衝突 → 訊息「CONFLICT with rebuilt content」、stash 保留。**修正前** (b) 被誤判成 (a)（pop 自身留 unmerged），改為 **pop 前**檢查索引後正確分流 |
| 17 | dry-run + 髒工作樹 | neo | staged + unstaged 變更下乾跑 | PASS：不建立 stash（只印 would stash 計畫）、EXIT=0、變更完整保留 |
| 18 | git 行為基準實測 | — | T1/T2：cherry-pick 建路徑時本地已有未追蹤檔（同內容 vs 異內容）；T3：checkout 同情境；T4：`stash -u` pop 在路徑變已追蹤時 | **基準確認**（決定停車設計的依據）：git 對碰撞**一律硬拒絕、不比對內容**（同內容照樣 `would be overwritten` → fatal）、本地檔不銷毀；`stash -u` pop 即使用戶相同也**整體失敗**（stash 保留）→ `stash -u` 方案出局 |
| 19 | 殘留檔停車（重建創建路徑） | neo | 殘留檔在 `mixed-001` c1 創建的路徑、內容不同；(b) 同內容版本 | PASS：(a) EXIT=0（此前 git 必拒）、worktree 留重建版、殘留停車保存、`git log -S` 證明**未進 commit**、tree 相同、`LEFTOVER CONFLICT` 含停車位置+`git diff --no-index` 指引；(b) 同內容 → 無縫丟停車副本（目錄清空） |
| 20 | 停車污染重跑 + 殘留自癒 | neo | (a) 前次停車副本仍在時同路徑建異內容檔重跑；(b) `manual-001` 失敗路徑（exit 1）+ 前次未解停車條目 | PASS：(a) 唯一後綴 `.parked2` 停車+映射、兩份殘留都保存、tree IDENTICAL（**修復前**：停車失敗→cherry-pick 被拒→pause 靜默跳過→c1..c5 全丟、tree MISMATCH 卻 exit 0 謊報）；(b) exit 1 下 finally 歸還本次停車、前次條目自動重試（manifest 保留） |
| 21 | checkout 碰撞殘留（舊分支起跑） | ad607938→neo | 停在舊錨點分支，殘留在「neo 才新增」的路徑（`moss_image.py`） | PASS：EXIT=0（T3 基準證明原生 checkout 必拒）、停車→重建→歸還流程完整、`LEFTOVER CONFLICT` 指引、manifest 保留未解條目。**實測暴露並修復 4 個 bug**：Remove-Item NullRef 仍計入成功→孤兒檔、manifest 刪除未驗目錄空、殘留掃描把 manifest 自身算入（自我循環）、逐條異常跳過其餘條目 → 全改真實計數+try/catch+刪除降級 .NET API+安全網掃描 |
| 22 | dry-run + 殘留檔 | neo | 有未追蹤殘留乾跑 | PASS：只印 `would park` 計畫、檔案未移動、leftovers 目錄未建、exit 0 |
| 23 | 全夾具回歸（停車機制後） | neo | 7 夾具（mixed/Mneo/conflict/CJK/edge/rename/mixedrename） | PASS：全部 exit=0 且 `Content check matches exactly`（停車/還原不影響任何既有行為） |
| 24 | 遇到時才處理（交集停車） | neo | (A)只有不碰撞的未追蹤檔 (B)殘留在會碰撞路徑＋共存不碰撞檔 (C)舊分支+base tree 路徑殘留 (D)乾跑 | PASS：(A) 10 檔全不碰撞 → **零移動、leftovers 目錄不建**、訊息 `none collide - left in place`；(B) **僅** `rebuild-mixed-test.txt` 停車、其餘 10 檔原地（外科式）、LEFTOVER CONFLICT+tree 相同；(C) **僅** `moss_image.py`（base tree 集）、EXIT=0（T3 基準原生必拒）、tree 相同；(D) 只印 would-park、檔案未動。**＋7 夾具回歸全綠 exit=0** |
| 25 | CRLF/LF 等價判斷 | neo | (E1) CRLF 殘留 vs LF 提交檔（同內容僅行尾異）(E2) 真內容差異 (E3) 污染重跑+EOL 變體 (E4) 相同二進位殘留 | PASS：(E1) **零衝突警告**、`dropped as equal ignoring whitespace/line-endings`+註記、停車副本丟棄、tree 相同（此前必誤判衝突）；(E2) CONFLICT 仍正常、停車+manifest 保留；(E3) `equivalent copy already parked` → **釋放路徑、.parked2 建立數=0**（此前會後綴停車），還原端真差異仍 CONFLICT；(E4) 相同二進位走 SHA-1 快取 → 丟停車副本、tree 相同。**＋7 夾具回歸全綠** |
| 26 | 等價旗標擴充（`-b`/`-w`/blank-lines） | — | 8 項邊界直測（git diff 層）＋ E5 複合工件殘留（CRLF+重縮排+多餘空行+缺尾換行）實跑 | **8 項邊界**：CRLF/LF、縮排、tab vs 空格、空格數量、多餘空行、**缺檔案尾換行**（舊邊界被旗標組覆蓋消除）→ 全 equivalent；真內容 → different；**BOM 有無 → different（唯一剩餘邊界）**。E5 實跑：複合工件變體 → `dropped as equal ignoring whitespace/line-endings/blank lines`、零 CONFLICT、tree 相同。**＋7 夾具回歸全綠 exit=0** |
| 27 | BOM 專屬偵測（`BomOnly`） | neo | (T1) BOM-only 殘留（終版內容+BOM vs 無 BOM 提交檔）(T2) 停車撞位 BOM 變體 (負例) BOM+真內容差異 | PASS：(T1) **專屬 `BOM DIFFERENCE` 通知**（含檢查指令與「決定哪側帶 BOM」指引）、籠統訊息 0 次、停車+manifest 保留、tree 相同（不自動視為相同 — BOM 常為刻意增刪）；(T2) 停車端註記 `kept both copies; BOM changes can be deliberate` + `.parked2` 雙份保留 → 還原端 BOM 條目保留+plain 條目判相同丟棄、manifest 只留 BOM 條目；負例 BOM+真差異 → 回籠統 `LEFTOVER CONFLICT`（不誤分流）。**＋7 夾具回歸全綠 exit=0** |
| 28 | 重建已落地偵測 | 克隆倉庫 | (a) 建 temp → 落地（`checkout -B <feature> <temp>`）→ 重跑 (b) 同上加 `-f` | PASS：(a) exit 0、`Nothing to do: ... already been landed`、零重放工作；(b) `-f` → `WARNING: ... already LANDED ... -f will rebuild the LANDED history` 後照跑完成（tree 仍相符）。落地守衛在 temp-exists 守衛之前給出更精確的說明 |
| 29 | 遠端落後守衛 | 真實倉庫（非破壞性）＋克隆 | 真實：本地 `neo` 落後 `origin/neo` 8 commits（使用者倉庫真實狀態）；克隆：up-to-date 情境 | PASS（真實）：`git fetch origin` → `Error: local base branch 'neo' is BEHIND origin/neo by 8 commit(s)` + 更新指令、**exit 1 且零改動**（stash/checkout 均未觸碰 — HEAD 仍為使用者分支、未提交修改原封）；PASS（克隆）：`base 'neo' vs origin/neo: up to date` → 正常重建。領先/分歧共用同一 `rev-list --left-right --count` plumbing（已審閱，未個別造模擬遠端 — 依指示不強迫重現） |

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
