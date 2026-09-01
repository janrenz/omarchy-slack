#!/usr/bin/env bash
# Assemble a Quickshell config folder outside the repo.
#
# Quickshell only imports modules from inside its own config folder, so the
# plugin's sources and the shell's Commons/Ui have to sit beside a shell.qml.
# Omarchy refuses a plugin folder containing any symlink - one could point a
# plugin that has landed in the trusted directory at anything on disk - so that
# folder is built somewhere else and links back in.
set -euo pipefail
cd "$(dirname "$0")"
repo="$(cd .. && pwd)"

. ./stage.sh
rm -rf "$STAGE"; mkdir -p "$STAGE"

ln -sfn /usr/share/omarchy/shell/Commons "$STAGE/Commons"
ln -sfn /usr/share/omarchy/shell/Ui "$STAGE/Ui"
# The Python helpers too: without slack.py beside the QML the harness cannot
# run a fetch at all, so --demo data never arrives and the window renders empty
# for no visible reason.
for f in "$repo"/src/*.qml "$repo"/src/Model.js "$repo"/src/*.py "$repo"/src/*.sh; do
  ln -sfn "$f" "$STAGE/$(basename "$f")"
done
ln -sfn "$(pwd)/shell.qml" "$STAGE/shell.qml"
echo "$STAGE"
