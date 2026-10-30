# rebuild-neo

以 `--no-ff` 分段重建分支的合併歷史，重新合併到指定 base 上。適用於 PR 分支因 `--rebase-merges` 或 squash 產生「假合併線」、需要恢復成真實合併節點的場合。

重建結果：

- 合併節點為**真實合併**（第二父指向 feature tip），完全脫離原始 merge commit
- 內容與原分支一致（結束時 tree 驗證，不符以失敗退出）
- **不修改原分支** — 全程在 `rebuild/<分支名>-rebuilt` 臨時分支上工作，由你決定是否落地

## 用法

```
rebuild-neo <base> [<feature>] [選項]
```

| 參數 / 選項 | 說明 |
|---|---|
| `<base>` | 必填。重建的目標 base（例如 `neo`） |
| `<feature>` | 選填。要重建的分支；省略時取**目前分支**（不會修改它） |
| `-f` / `-Force` | 覆蓋已存在的臨時分支 |
| `-n` / `-DryRun` | 只列出將執行的指令，不做任何變更 |
| `-RebuiltTag` | 合併訊息後追加 ` (Rebuilt)`（預設不加） |

Windows 下直接執行：

```
rebuild-neo <base> [<feature>] [選項]
```

（即 `rebuild-neo.bat`，內部呼叫 `rebuild-neo.ps1`。）

## 安全機制

- **原分支永不變更**：結果只出現在臨時分支上，確認後才由你決定落地或丟棄
- **內容驗證**：結束時比對重建結果與原分支的 tree；不一致會明確報錯並以 exit 1 退出
- **重建已落地偵測**：若上次重建的臨時分支已是目前分支的祖先（已落地過），不再重跑「重建的重建」，直接說明並退出（`-f` 可明確覆蓋）
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

```bash
# 結果正確 → 落地（把原分支移動到重建結果）
git checkout -B <feature> rebuild/<feature>-rebuilt
git branch -D rebuild/<feature>-rebuilt

# 結果不要 → 丟棄
git checkout <feature>
git branch -D rebuild/<feature>-rebuilt
```

## 檔案

| 檔案 | 說明 |
|---|---|
| `rebuild-neo.bat` / `rebuild-neo.ps1` | 主腳本 |
| `rebuild-neo-tests/` | 測試分支的一鍵建構腳本 |
| `README_DEV.md` | 開發紀錄：設計決策、實測案例與驗證方法 |
