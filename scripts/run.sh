#!/bin/zsh
# Kill any running Vunu, launch the installed build, tail the log.
set -uo pipefail
pkill -x Vunu 2>/dev/null || true
sleep 0.4
LOG="$HOME/Library/Logs/Vunu/vunu.log"
mkdir -p "$(dirname "$LOG")"; touch "$LOG"
open -a /Applications/Vunu.app --args "${@}"
echo "launched. tailing $LOG (ctrl-c to stop)"
tail -n 30 -f "$LOG"
