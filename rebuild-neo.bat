@echo off
setlocal

rem ============================================================
rem rebuild-neo launcher
rem Forwards all arguments to rebuild-neo.ps1 (UTF-8 safe).
rem
rem Usage: rebuild-neo <base-branch> [<feature-branch>] [-f] [-n] [-RebuiltTag] [-RedoLanded] [-MaxCommits <n>]
rem   positional args follow git rebase style: git rebase <upstream> [<branch>]
rem   -f / -OverwriteTempBranch  overwrite an existing temp branch (mechanical only;
rem                grants no other guard, never implies -RedoLanded)
rem   -n           dry run: print every command, execute nothing
rem   -RebuiltTag  append ' (Rebuilt)' to rebuilt merge messages (default: off)
rem   -RedoLanded  redo a rebuild that was already landed (distinct from -f;
rem                -f alone never bypasses the landed guard)
rem   -MaxCommits <n>  refuse when the range has more than n first-parent commits
rem                (default 10; -1 = unlimited but warns above 10)
rem
rem Runs in the CURRENT directory: cd into the target repo first.
rem ============================================================

rem UTF-8 console so git/PowerShell output is not mangled
chcp 65001 >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rebuild-neo.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [launcher] rebuild-neo failed with exit code %RC%.
    pause
)

endlocal & exit /b %RC%
