#!/bin/sh
# Polls this repo's HEAD and runs `flutter analyze` + `flutter test --coverage`
# whenever it changes -- no matter who made the commit (you, from this
# Terminal, or Claude, via the device bridge). Start it once in a Terminal
# tab with a real `flutter` on PATH and leave it running:
#
#   ./scripts/watch-and-test.sh &
#
# Output overwrites .flutter-ci.log (gitignored) at the repo root each run.
# Stop it with `kill %1` (or Ctrl-C if run in the foreground) or by closing
# the tab.
set -eu

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
cd "$REPO_ROOT"
LOG="$REPO_ROOT/.flutter-ci.log"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH -- run this from a Terminal where 'flutter doctor' works." >&2
  exit 1
fi

echo "Watching $REPO_ROOT for new commits (checking every 5s). Logging to $LOG."

last=""
while true; do
  cur="$(git rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
    last="$cur"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) -- new commit $cur, running local CI..."
    {
      echo "=== spliit2go local CI: $(date -u +%Y-%m-%dT%H:%M:%SZ) commit $cur ($(git log -1 --format=%s)) ==="
      echo "--- flutter analyze ---"
      flutter analyze
      analyze_status=$?
      echo "--- flutter analyze exit: $analyze_status ---"
      echo "--- flutter test --coverage ---"
      flutter test --coverage
      test_status=$?
      echo "--- flutter test exit: $test_status ---"
      if command -v lcov >/dev/null 2>&1 && [ -f coverage/lcov.info ]; then
        echo "--- coverage summary ---"
        lcov --summary coverage/lcov.info
      fi
      echo "=== done: $(date -u +%Y-%m-%dT%H:%M:%SZ) -- analyze:$analyze_status test:$test_status ==="
    } > "$LOG" 2>&1
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) -- done, see $LOG"
  fi
  sleep 5
done
