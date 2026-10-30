# rebuild-neo（`git-rebuild-merges`）

在 Git 中，當我們使用 `git rebase --rebase-merges` 或進行多次 Squash 合併時，有時候會把分支的合併歷史弄亂，產生出看起來怪異、或是跟實際上不符的「假合併線」。

這個工具的目的，就是 一鍵幫你把這些分支的合併歷史「重新整理」乾淨，讓它變成符合實際狀況的乾淨合併節點，同時確保程式碼內容完全正確。

核心特點：
- 安全第一：全程在臨時分支上操作，**絕對不會直接改動你的原分支**。
- 內容自動比對：結束時會自動檢查程式碼（Tree），確保重建後的內容跟原本一模一樣，否則自動放棄。
- **還原真實歷史**：產生的合併節點是乾淨、正確的標準合併。

## 用法

```
rebuild-neo <base> [<feature>] [選項]
```

| 參數 / 選項 | 說明 |
|---|---|
| `<base>` | 必填。重建的目標 base（例如 `neo`） |
| `<feature>` | 選填。要重建的分支；省略時取**目前分支**（不會修改它） |
| `-f` / `-OverwriteTempBranch` | 覆蓋已存在的**臨時分支**（純機械操作，不繞過任何守衛；舊別名 `-Force` 仍可用） |
| `-RedoLanded` | 重新重建**已落地**的分支（覆蓋落地守衛；獨立旗標，不與 `-f` 互相蘊含 — 兩守衛各需明確通過） |
| `-n` / `-DryRun` | 只列出將執行的指令，不做任何變更 |
| `-MaxCommits <n>` | **提交數防護**：first-parent 節點超過 n 個時拒絕執行並告知總數（**預設 10**；`-1` = 不限制，但超過 10 仍會警告並告知數量；提升此值屬危險操作，需明確許可） |
| `-RebuiltTag` | 合併訊息後追加 ` (Rebuilt)`（預設不加） |

> **給 AI agent 的同意提醒**：腳本在「建議你採取危險後續動作」的每處訊息附近（覆蓋臨時分支、重跑已落地重建、用臨時分支替換原始分支）都會附帶一行**情境專屬**的 `AGENT REMINDER: ask the user for explicit permission before <該動作>` —— **agent 必須先取得使用者明確許可，才能執行該動作**；每次只提示當下情境那一條，未經許可不得自行判斷後直接執行。

Windows 下直接執行：

```
rebuild-neo <base> [<feature>] [選項]
```

（即 `rebuild-neo.bat`，內部呼叫 `rebuild-neo.ps1`。）

### `git-rebuild-merges` 別名

把本目錄加入 `PATH` 後，可用 git 子命令形式呼叫（`git-rebuild-merges.bat` 轉發給 `rebuild-neo.bat`，行為完全一致）：

```
git-rebuild-merges <base> [<feature>] [選項]
```

## 安全機制

- **原分支永不變更**：結果只出現在臨時分支上，確認後才由你決定落地或丟棄
- **內容驗證**：結束時比對重建結果與原分支的 tree；不一致會明確報錯並以 exit 1 退出
- **重建已落地偵測**：若上次重建的臨時分支已是目前分支的祖先（已落地過），不再重跑「重建的重建」，直接說明並退出；重跑需明確指定 **`-RedoLanded`**（獨立旗標 — `-f` 只管覆蓋臨時分支，**不會**隱式繞過任何守衛）
- **遠端落後守衛**：起跑前自動 fetch 並比對 base / feature 與各自 upstream（或 `origin/<名稱>`）；**本地嚴格落後遠端即拒絕**（用舊內容重建會產生錯誤結果，訊息附更新指令）；領先／分歧僅提示
- **未提交的變更**：起跑前自動 stash，結束後原樣還原（含 staged / unstaged 狀態）；即使中途失敗也會還原
- **擋路的未追蹤檔案**（與重建會建立／修改的路徑同名，例如切換分支殘留或先行複製的檔案）：自動停放到 `.git/rebuild-neo-leftovers/`，結束時歸還
  - 內容相同（含忽略空白／行尾差異）→ 無縫歸還
  - 內容不同 → 保留你的副本並提示比對方式，不會讓殘留悄悄進入提交
  - BOM 差異 → 專屬提示（BOM 可能是刻意增刪，交由你決定）
- **狀態守衛**：merge / cherry-pick / rebase / revert 進行中、或工作樹有未解決衝突時拒絕起跑
- **既有守衛**：feature 已完全包含於 base（無事可做）時直接退出

## 執行後

腳本結束時停在臨時分支上，並印出兩條路徑的指令：

> **共用提醒（給 AI agent）**：下面的 `git checkout -B <feature> rebuild/<feature>-rebuilt` 屬於**用臨時分支覆寫原始分支**的行為，`git branch -D` 屬於刪除行為。**AI agent 必須先取得使用者的明確許可後才可以執行**；使用者未明確同意前，只做到「停在臨時分支、報告結果」為止。

```bash
# 結果正確 → 落地（把原分支移動到重建結果）
git checkout -B <feature> rebuild/<feature>-rebuilt
git branch -D rebuild/<feature>-rebuilt

# 結果不要 → 丟棄
git checkout <feature>
git branch -D rebuild/<feature>-rebuilt
```

## 為什麼需要這個腳本？（FAQ）

### 什麼是「真」合併線？

一般用 `git merge` 把功能分支併入主幹時，Git 會產生一個**合併結點（Merge Commit）**，它有兩個「父親」（Parents）：

- **第一父（First Parent）**：指向主幹（例如 `main` 或 `neo`）
- **第二父（Second Parent）**：指向功能分支的頂端（Feature Tip）

這條線的語意是：「這一天，我們把某個功能完整地併入了主幹。」

### 「假合併線」是怎麼來的？

當 PR 分支很長、包含多個子分支、或過程中多次 `rebase` / `squash` 時，為了保留分支結構，常會用 `git rebase --rebase-merges`（或由工具自動處理）。但這類歷史重寫操作在重新播放（Replay）提交時，往往只是「模擬」出一個合併結點的長相：

- 圖形上看起來像合併線（有分支交會）
- 但血統（Parent 指標）可能已名存實亡——第二父指向錯亂、或只是被 squash 壓成的單向直線
- 後續 `git log --graph` 圖形詭異，`bisect` 定位錯提交、`cherry-pick` 撿錯補丁等操作都可能引發意想不到的災難

### 這個腳本在做什麼？

不做 `--rebase-merges` 那種半自動的模擬，而是**砍掉重練**：

1. 讀取原本的分支歷史
2. 用最保險的 `--no-ff`（No Fast-Forward）方式，分段重新做一次**真實合併**
3. 確保產生的合併結點是正統的——第二父乖乖指向功能分支頂端，完全脫離原始 merge commit
4. 最後比對程式碼內容（Tree），重建後與原分支一模一樣才算成功；不一樣就直接失敗退出，保護專案不被亂改

### 為什麼不直接用 `git rebase --rebase-merges` 就好？

`--rebase-merges` 的目標是「保留分支線的形狀」，不是「恢復真實合併語意」；重寫後的合併節點第二父通常不再指向原本的 feature tip，血統與實際程式碼演進脫節。本腳本則明確保證：合併節點的第二父指向原 feature tip，且 tree 與原分支完全一致。

### 重建會動到我的原分支嗎？

不會。全程在 `rebuild/<分支名>-rebuilt` 臨時分支上工作，原分支一個 commit 都不動；重建結果確認無誤後，由你自己決定落地（`git checkout -B`）或丟棄。

### 重建後的 commit hash 一定變嗎？

會變。合併結點被重建為新的 commit，hash 必然不同（這正是「脫離原始 merge commit」的含意）；但**程式碼內容（tree）不變**，結束時會自動驗證。

## 檔案

| 檔案 | 說明 |
|---|---|
| `rebuild-neo.bat` / `rebuild-neo.ps1` | 主腳本 |
| `git-rebuild-merges.bat` | git 子命令別名啟動器（轉發給 `rebuild-neo.bat`） |
| `rebuild-neo-tests/` | 測試分支的一鍵建構腳本 |
| `README_DEV.md` | 開發紀錄：設計決策、實測案例與驗證方法 |
