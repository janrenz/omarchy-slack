#!/usr/bin/env bash
# (Re)start the harness, rendered offscreen.
#
# Offscreen means no window on anyone's screen: the harness cannot be occluded
# by another window, cannot be sent to a workspace nobody is looking at, and
# cannot land on top of what someone else is doing. It draws its own
# screenshots - see shot.sh.
#
# It is restarted rather than hot-reloaded because Quickshell's reload popup
# needs a real window, and failing to open it leaves IPC refusing queries.
set -euo pipefail
cd "$(dirname "$0")"

STAGE="$(./link.sh)"
# -x, so this matches the harness and not the shell that is running this
# script - a bare -f pattern also matches any command line that mentions it,
# which includes the one asking for a screenshot.
pkill -x -f "qs -p $STAGE/shell.qml" 2>/dev/null || true
sleep 0.5

QT_QPA_PLATFORM=offscreen qs -p "$STAGE/shell.qml" >"$STAGE/harness.log" 2>&1 &

for _ in $(seq 1 60); do
  sleep 0.2
  if qs -p "$STAGE/shell.qml" ipc show >/dev/null 2>&1; then
    echo "harness up - dev/shot.sh out.png"
    exit 0
  fi
done
echo "harness did not come up; see $STAGE/harness.log" >&2
tail -30 "$STAGE/harness.log" >&2
exit 1
