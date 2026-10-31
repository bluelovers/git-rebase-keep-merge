**English** | [繁體中文](./README.md)

# rebuild-neo (`git-rebuild-merges`)

In Git, when you use `git rebase --rebase-merges` or perform multiple squash merges, the branch's merge history can get scrambled, producing weird-looking or inaccurate "fake merge lines".

This tool gives you a one-click way to cleanly "rebuild" that merge history into accurate merge nodes that reflect reality — while guaranteeing the code content stays exactly correct.

Core features:

- **Safety first**: everything runs on a temporary branch — your original branch is **never touched**.
- **Automatic content verification**: at the end it checks the tree against the original branch and aborts automatically if anything differs.
- **Restore real history**: the produced merge nodes are clean, correct, standard merges.

## Usage

```
rebuild-neo <base> [<feature>] [options]
```

| Argument / Option | Description |
|---|---|
| `<base>` | Required. Target base to rebuild onto (e.g. `neo`) |
| `<feature>` | Optional. Branch to rebuild; defaults to the **current branch** (which is not modified) |
| `-f` / `-OverwriteTempBranch` | Overwrite an existing **temp branch** (purely mechanical; grants no other guard; old alias `-Force` still works) |
| `-RedoLanded` | Redo a rebuild that was **already landed** (overrides the landed guard; a standalone flag — not implied by `-f`; each guard requires explicit clearance) |
| `-n` / `-DryRun` | Only list the commands to be executed; make no changes |
| `-MaxCommits <n>` | **Commit-count guard**: refuses to run when the first-parent range has more than n commits and tells you the total (**default 10**; `-1` = unlimited, but still warns above 10 with the count; raising this value is a dangerous-class change and requires explicit permission) |
| `-RebuiltTag` | Append ` (Rebuilt)` to merge messages (off by default) |

> **Consent reminder for AI agents**: wherever the script suggests a dangerous follow-up action (overwriting a temp branch, redoing a landed rebuild, replacing the original branch with the temp branch), it prints a **context-specific** `AGENT REMINDER: ask the user for explicit permission before <that action>` line — **the agent must obtain the user's explicit permission before performing that action**; only the single relevant reminder is shown for the current situation, and the agent must not decide on its own to proceed without permission.

Run directly on Windows:

```
rebuild-neo <base> [<feature>] [options]
```

(i.e. `rebuild-neo.bat`, which internally invokes `rebuild-neo.ps1`.)

On Linux / macOS, use the POSIX sh launcher (forwards to `rebuild-neo.ps1`; requires `pwsh` — PowerShell 7+ — installed and on `PATH`):

```
./rebuild-neo.sh <base> [<feature>] [options]
```

(Run `chmod +x rebuild-neo.sh` once, or invoke it as `sh rebuild-neo.sh ...`. If `pwsh` is missing it reports a clear error and exits with 127.)

### `git-rebuild-merges` alias

With this directory on your `PATH`, you can invoke it as a git subcommand (identical behavior, single source of truth):

- Windows: `git-rebuild-merges.bat` forwards to `rebuild-neo.bat`
- Linux / macOS: `git-rebuild-merges` (no extension) `exec`s into `rebuild-neo.sh` (run `chmod +x git-rebuild-merges` first)

```
git rebuild-merges <base> [<feature>] [options]
```

## Safety mechanisms

- **The original branch is never modified**: results only appear on the temp branch; you decide whether to land or discard after reviewing
- **Content verification**: at the end it compares the tree of the rebuilt result against the original branch; on mismatch it reports a clear error and exits with code 1
- **Landed-rebuild detection**: if the temp branch from a previous rebuild is already an ancestor of the current branch (i.e. it was landed), it will not re-run a "rebuild of a rebuild" — it explains and exits; redoing requires explicitly passing **`-RedoLanded`** (a standalone flag — `-f` only governs overwriting the temp branch and **never** implicitly bypasses any guard)
- **Behind-remote guard**: it automatically fetches and compares base / feature against their upstreams (or `origin/<name>`) before starting; **a local branch strictly behind its remote is refused** (rebuilding from stale content would produce wrong results; the message includes the commands to update); ahead / diverged only produces a warning
- **Uncommitted changes**: automatically stashed before starting and restored exactly afterwards (including staged / unstaged state); restoration also happens if the run fails midway
- **Blocking untracked files** (paths that collide with files the rebuild would create/modify, e.g. leftovers from branch switching or files copied in advance): automatically parked in `.git/rebuild-neo-leftovers/` and returned at the end
  - Identical content (ignoring whitespace / line-ending differences) → seamless return
  - Different content → your copy is kept and a comparison hint is shown; the leftover never silently enters a commit
  - BOM difference → a dedicated hint (the BOM change may be intentional; the choice is yours)
- **State guard**: refuses to start while a merge / cherry-pick / rebase / revert is in progress, or when the worktree has unresolved conflicts
- **Existing guard**: exits directly when the feature is already fully contained in the base (nothing to do)

## After running

The script finishes on the temp branch and prints the commands for both paths:

> **Shared reminder (for AI agents)**: the `git checkout -B <feature> rebuild/<feature>-rebuilt` below **overwrites the original branch with the temp branch**, and `git branch -D` is a deletion. **An AI agent must obtain the user's explicit permission before executing either**; until the user explicitly agrees, only "stop on the temp branch and report the result" is permitted.

```bash
# Result is correct → land (move the original branch to the rebuilt result)
git checkout -B <feature> rebuild/<feature>-rebuilt
git branch -D rebuild/<feature>-rebuilt

# Result is not wanted → discard
git checkout <feature>
git branch -D rebuild/<feature>-rebuilt
```

## Why does this script exist? (FAQ)

### What is a "real" merge line?

When you normally merge a feature branch back into the trunk with `git merge`, Git creates a **merge commit** with two "parents":

- **First parent**: points at the trunk (e.g. `main` or `neo`)
- **Second parent**: points at the tip of the feature branch (feature tip)

The semantics of this line is: "on this day, we merged a complete feature into the trunk."

### Where do "fake merge lines" come from?

When a PR branch is long, contains several sub-branches, or has been rebased / squashed repeatedly, people often use `git rebase --rebase-merges` (or let a tool do it automatically) to preserve the branch structure. But when this kind of history-rewriting operation replays commits, it often only *simulates* the appearance of a merge node:

- It looks like a merge line on the graph (branches converging)
- But its lineage (parent pointers) may be dead in name only — the second parent points to the wrong place, or it is just a one-way straight line produced by a squash
- The resulting `git log --graph` looks bizarre, and operations like `bisect` or `cherry-pick` can cause unexpected disasters

### What does this script do?

Instead of `--rebase-merges`' half-automatic simulation, it **tears it down and rebuilds from scratch**:

1. Reads your original branch history
2. Uses the safest approach — `--no-ff` (no fast-forward) — to redo the merges segment by segment as **real merges**
3. Ensures every produced merge node is orthodox: the second parent correctly points at the feature tip, fully detached from the original merge commits
4. Finally compares the tree so that the rebuilt history has exactly the same content as the original; if not, it fails immediately and protects your project from being mangled

### Why not just use `git rebase --rebase-merges`?

`--rebase-merges` aims to "preserve the shape of the branch lines", not "restore real merge semantics"; after rewriting, a merge node's second parent usually no longer points at the original feature tip, so its lineage is disconnected from the actual code evolution. This script explicitly guarantees: the merge node's second parent points at the original feature tip, and the tree is identical to the original branch.

### Will it touch my original branch?

No. Everything runs on a `rebuild/<branch>-rebuilt` temp branch; not a single commit of the original branch changes. After verifying the result, you decide whether to land it (`git checkout -B`) or discard it.

### Do the commit hashes definitely change?

Yes. The merge nodes are rebuilt as new commits, so their hashes necessarily differ (that is exactly what "detached from the original merge commit" means); but the **code content (tree) does not change**, and this is verified automatically at the end.

## Files

| File | Description |
|---|---|
| `rebuild-neo.bat` / `rebuild-neo.ps1` | Main scripts |
| `rebuild-neo.sh` | POSIX sh launcher (Linux / macOS; invokes `rebuild-neo.ps1` via `pwsh`) |
| `git-rebuild-merges.bat` | git subcommand alias launcher (forwards to `rebuild-neo.bat`) |
| `git-rebuild-merges` | git subcommand alias launcher (POSIX sh; `exec`s into `rebuild-neo.sh`) |
| `rebuild-neo-tests/` | One-click fixture-branch build scripts |
| `README.md` | Traditional Chinese version of this README |
| `README_DEV.md` | Development log: design decisions, test cases, and verification methods |
