@echo off
setlocal

rem ============================================================
rem git-rebuild-merges alias launcher (git subcommand style)
rem Forwards all arguments to rebuild-neo.bat - the canonical
rem launcher - so there is a single source of behavior.
rem
rem Usage: git-rebuild-merges <base-branch> [<feature-branch>] [選項]
rem        (requires this directory on PATH; same options as rebuild-neo)
rem
rem Runs in the CURRENT directory: cd into the target repo first.
rem ============================================================

call "%~dp0rebuild-neo.bat" %*
set "RC=%ERRORLEVEL%"

endlocal & exit /b %RC%
