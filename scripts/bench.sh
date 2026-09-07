#!/bin/zsh
# Run the built-in benchmark (app must be installed). Prints per-stage timings.
set -uo pipefail
LOG="$HOME/Library/Logs/Vunu/vunu.log"
open -a /Applications/Vunu.app --args --benchmark
echo "benchmark requested; results appear in Settings → Models → Benchmark and below:"
sleep 2
tail -n 0 -f "$LOG" | grep --line-buffered -E "\[bench\]" &
TAILPID=$!
sleep 40
kill $TAILPID 2>/dev/null
