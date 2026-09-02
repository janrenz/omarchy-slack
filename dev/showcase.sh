#!/usr/bin/env bash
# Generate the showcase images: the real window, drawing invented people.
#
#   dev/showcase.sh [outdir]        # default: the repo root
#
# Nothing of yours ends up in an image, and nothing of yours is touched to make
# one. The Teams plugin photographs its window by installing a demo widget into
# your shell.json, restarting the shell, and putting your configuration back
# afterwards - which works, but means a screenshot run reaches into a live
# desktop. This runs the window offscreen in a Quickshell of its own instead:
# your bar, your shell.json and your session are not involved, and neither is
# any account - `demo` makes slack.py answer every read from its own fixtures
# and refuse every write.
set -euo pipefail
cd "$(dirname "$0")"

OUT="$(cd "${1:-..}" && pwd)"
. ./stage.sh

for tool in qs python3; do
  command -v "$tool" >/dev/null || { echo "showcase: $tool is required" >&2; exit 1; }
done

./run.sh >/dev/null
trap 'pkill -x -f "qs -p $STAGE/shell.qml" 2>/dev/null || true' EXIT
sleep 2

ipc() { qs -p "$STAGE/shell.qml" ipc call dev "$@" >/dev/null; }
shot() { ipc shot "$1"; sleep 0.8; [ -s "$1" ] || { echo "showcase: no image at $1" >&2; exit 1; }; }

# A channel, open, with a thread hanging off the last message - the picture
# that has to say in one glance what this is.
ipc open demo-channel-0
sleep 1
shot "$OUT/showcase-conversation.png"

# The thread itself, because it is the part Slack has that the Teams plugin
# cannot have.
ipc thread
sleep 1
shot "$OUT/showcase-thread.png"
ipc back

# Jumping, which is how anybody who uses Slack actually navigates it.
ipc pane switcher
sleep 1.2
shot "$OUT/showcase-jump.png"
ipc pane none

# The channel's canvas, being written rather than read: the pane has no
# message box, and the page keeps up with the source.
ipc canvas
sleep 1.5
ipc canvasEdit false
sleep 0.8
shot "$OUT/showcase-canvas.png"
ipc canvasEdit false >/dev/null 2>&1 || true
ipc canvas

# The keyboard, since that is the argument for having this at all.
ipc pane help
sleep 0.8
shot "$OUT/showcase-keyboard.png"
ipc pane none

# preview.png is the one name the marketplace looks for in the repository
# root; it is a copy rather than a fifth photograph so the listing card cannot
# drift from the screenshots in the README.
cp "$OUT/showcase-conversation.png" "$OUT/preview.png"

echo "showcase: wrote showcase-*.png and preview.png in $OUT"
