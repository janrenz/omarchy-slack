# Where the harness's Quickshell config folder is assembled. Sourced, not run.
#
# Every script here rm -rf's this folder and kills the harness by matching a
# command line that contains this path, so it has to be a place nobody else can
# write to or get to first: $XDG_RUNTIME_DIR is per-user and mode 0700, /tmp is
# neither. With no runtime dir there is no safe default, so refuse rather than
# fall back to a predictable path in shared temp.
if [ -n "${SLACK_DEV_STAGE:-}" ]; then
  STAGE="$SLACK_DEV_STAGE"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STAGE="$XDG_RUNTIME_DIR/omarchy-slack-dev"
else
  echo "dev: no XDG_RUNTIME_DIR - set SLACK_DEV_STAGE to a directory only you can write" >&2
  exit 1
fi
