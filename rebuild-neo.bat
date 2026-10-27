@echo off
setlocal

rem ============================================================
rem rebuild-neo launcher
rem Forwards all arguments to rebuild-neo.ps1 (UTF-8 safe).
rem
rem Usage: rebuild-neo <base-branch> [<feature-branch>] [-f] [-n] [-RebuiltTag]
rem   positional args follow git rebase style: git rebase <upstream> [<branch>]
rem   -f          overwrite an existing rebuild/ temp branch
rem   -n          dry run: print every command, execute nothing
rem   -RebuiltTag append ' (Rebuilt)' to rebuilt merge messages (default: off)
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
