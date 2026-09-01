# AGENTS.md

An Omarchy shell plugin: Slack channels, DMs and threads in the bar and in a
window of their own. Quickshell/QML on top of one Python helper. Read
`README.md` for what it does and how it is installed — this file is about
changing it.

## Orientation, in one pass

```
manifest.json          schemaVersion 1. kinds, entryPoints, and the settings
                       schema the shell's settings panel renders. Adding a
                       setting means adding it here AND reading it through
                       `setting()`.
src/slack.py           The helper. Holds the token, makes every network call,
                       prints one JSON object per invocation. Stdlib only.
src/emoji.py           :shortcode: -> character, for the helper's flattening.
src/config.py          Shared paths and the token store the helper reads.
src/Model.js           Pure JS: shaping, grouping, labels, link building. No Qt
                       types, so `node dev/test-model.js` can run it.
src/Service.qml        Owns the Processes that run slack.py, the poll timer,
                       and the state the UI binds to.
src/BarWidget.qml      The bar icon. Opens the window; there is no dropdown.
src/SlackWindow.qml    The window. Sidebar, transcript, message box. ~2k lines.
src/Notifier.qml       notify-send, with the prime-then-announce rule.
src/SettingsForm.qml   The settings UI shown inside the shell's settings panel.
src/QuickSwitcher.qml  `n` / `Ctrl-k`. src/SearchPane.qml is Slack search.
src/ImageViewer.qml    A picture from the transcript, with save-as.
```

Data flows one way: `slack.py` → JSON → `Service.qml` → `Model.js` → the window.
Nothing goes back the other way except a command line and a stdin payload.

## Invariants. Breaking one of these is a security bug, not a regression

1. **The token never reaches QML.** It lives in `~/.local/state/omarchy/slack/`,
   mode 600, and is passed to `slack.py` on **stdin** — never in argv (anyone on
   the machine can read another process's command line) and never in
   `shell.json` (world-readable).
2. **The window never fetches anything remote.** Avatars, images and files are
   fetched by the helper, checked against Slack's own hosts first, and the token
   is attached for `files.slack.com` alone. An `<img src="https://evil/">` in a
   message must not be able to collect a token or report a read receipt.
3. **A message never chooses its own markup.** `slack.py` flattens mrkdwn to
   text. The only tag the window ever builds is an `<a>` around text it escaped
   itself, from an offset into that text. `http`, `https`, `mailto` only —
   checked in `slack.py`, again in `Model.js` where the anchor is written, and
   once more in `openUrl` before `xdg-open` sees it. Keep all three.
4. **Stdlib only.** No pip, nothing vendored. `python3 src/slack.py` must run on
   a stock Arch box.
5. **Every helper command prints one JSON object** and exits 0 even on failure —
   `{"ok": false, "error": {...}}` — so the window always has something to
   render. Exit non-zero only when the arguments themselves were unusable.
6. **What the token may do is read back, not assumed.** Every response carries
   `x-oauth-scopes`; the window says "this token cannot search" rather than
   offering a search that 403s. New capability ⇒ new scope check.
7. **No symlinks anywhere in this repo.** `omarchy plugin validate` refuses a
   plugin folder that contains one. That is why the dev harness is assembled
   outside the repo — see below.
8. **Colors and spacing come from `qs.Commons`** (`Color`, `Style`, `Border`).
   No hardcoded hex, no hardcoded pixel gaps; use `Style.space()` and the
   density scale so the window follows the theme's font size.

## The dev loop

```bash
node   dev/test-model.js                    # the shaping the window binds to
python3 dev/test-slack.py                   # parsing, permission, host checks
python3 src/slack.py fetch --account work --demo   # synthetic data, no sign-in
python3 src/slack.py create-app --dry-run   # is the app manifest still valid?

dev/run.sh                                  # the real window, offscreen
dev/shot.sh /tmp/slack.png [demo-im-0]      # photograph what it is drawing
dev/showcase.sh                             # regenerate the README images
```

`dev/link.sh` assembles a Quickshell config folder in `$XDG_RUNTIME_DIR/omarchy-slack-dev`
and symlinks the sources into it. It has to: Quickshell only imports modules
from inside its own config folder, so `Commons/` and `Ui/` from
`/usr/share/omarchy/shell/` must sit beside a `shell.qml` — and the repo itself
may not contain symlinks (invariant 7). Editing a link edits the real file.

`--demo` runs through the whole plugin: every read is answered from fixtures in
`slack.py`, every write returns as if it had happened and posts nothing. That is
what makes an automated run safe.

**Installed-copy edits need a real restart.** `omarchy-shell shell reloadConfig`
and `rescanPlugins` both return ok without re-reading plugin QML or a widget's
entry in `shell.json`. Run `omarchy-restart-shell` and confirm the PID moved
(`pgrep -af 'quickshell -n'`). A surviving PID also proves the QML parsed — a
fatal QML error makes it exit instead.

## Things that will surprise you

- **`Service.qml` is instantiated more than once.** `BarWidget.qml` has one and
  `SlackWindow.qml` has another, and the bar is one surface *per monitor* — so a
  two-monitor desktop with the window open polls the workspace three times an
  interval. The mail plugin solved the same problem by moving the data into a
  `kinds: ["service"]` singleton (`Store.qml`); this plugin has not yet. Bear it
  in mind before adding another poll.
- **Slack's rate limits are the design constraint**, not an annoyance. Previews
  for the whole workspace cost *one* search per poll, because non-Marketplace
  apps get roughly one `conversations.history` a minute plus a burst of fifteen.
  Read the "How it knows what is new" section of the README before adding any
  per-conversation request.
- **Lists are `Repeater`s inside `ScrollView`s**, including the transcript. Every
  row is instantiated. `ListView` with `reuseItems` is the fix if a long
  conversation gets slow — the mail plugin's `MailList.qml` carries a comment on
  exactly this trade-off.
- **The window is a `FloatingWindow`** — a real Hyprland toplevel, tiled like
  anything else. It has no app id of its own, so its `title` is the only handle
  a Hyprland window rule has on it.
- **`omarchy-shell shell summon janrenz.omarchy.slack '<json>'`** delivers that
  JSON to `SlackWindow.open(payloadJson)`, which currently ignores it. Same for
  `omarchy-shell shell call <id> <method> <arg>`, which routes to any method on
  the loaded window.

## House style

Comments and prose explain **why**, never what — look at the header of
`Service.qml` or `dev/link.sh` for the register. Full sentences. A comment that
restates the line below it does not survive review. The README is written for a
person deciding whether to install this, and says plainly what the plugin does
not do.

Keep the work inside the window. When something cannot be finished here, that is
the bug — not a reason to hand the user off to a browser.
