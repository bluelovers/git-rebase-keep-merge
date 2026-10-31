#!/usr/bin/env sh
# ============================================================
# rebuild-neo launcher (POSIX sh)
# Forwards all arguments to rebuild-neo.ps1 via pwsh
# (PowerShell 7+; the executable is `pwsh` on Linux/macOS).
#
# Usage: rebuild-neo.sh <base-branch> [<feature-branch>] [選項]
#   same options as rebuild-neo.ps1 / rebuild-neo.bat
#
# Runs in the CURRENT directory: cd into the target repo first.
# ============================================================

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if ! command -v pwsh >/dev/null 2>&1; then
    echo "rebuild-neo: PowerShell 7 ('pwsh') not found on PATH." >&2
    echo "Install it first: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux" >&2
    exit 127
fi

pwsh -NoProfile -File "$SCRIPT_DIR/rebuild-neo.ps1" "$@"
rc=$?

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "[launcher] rebuild-neo failed with exit code $rc."
    # Interactive shells only: prompt so a double-clicked / manually
    # run terminal window stays open; scripts and CI must not hang.
    if [ -t 0 ]; then
        printf "Press Enter to continue..."
        read -r _
    fi
fi

exit "$rc"
