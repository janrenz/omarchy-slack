#!/usr/bin/env bash
# Photograph what the harness is drawing.
#
#   dev/shot.sh out.png                     # as it is
#   dev/shot.sh out.png demo-im-0           # opening that conversation first
set -euo pipefail
cd "$(dirname "$0")"
. ./stage.sh
OUT="$(realpath -m "${1:-/tmp/slack.png}")"

if [ $# -ge 2 ]; then
  qs -p "$STAGE/shell.qml" ipc call dev open "$2"
  sleep 0.6
fi
qs -p "$STAGE/shell.qml" ipc call dev shot "$OUT"
sleep 0.6
[ -s "$OUT" ] && echo "$OUT" || { echo "no image written; see $STAGE/harness.log" >&2; exit 1; }
