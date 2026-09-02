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
                       Caches beside the token: marks.json (channel read
                       marks), threads.json (thread read marks, local only).
src/emoji.py           :shortcode: -> character, for the helper's flattening.
src/config.py          Shared paths and the token store the helper reads.
src/Model.js           Pure JS: shaping, grouping, labels, link building. No Qt
                       types, so `node dev/test-model.js` can run it.
src/Service.qml        Owns the Processes that run slack.py, the poll timer,
                       and the state the UI binds to.
src/BarWidget.qml      The bar icon. Opens the window; there is no dropdown.
src/SlackWindow.qml    The window. Sidebar, transcript, message box, and the
                       canvas pane - which has no message box, and has the
                       Markdown editor instead. ~2k lines.
                       Also the file chooser and the window-wide DropArea, which
                       both end at sendFile() - the one place a file:// URL
                       becomes a path.
src/Notifier.qml       omarchy-notification-send, the prime-then-announce rule,
                       and the click that opens the conversation.
src/PollGate.qml       Whether it is worth polling at all: idle, network, battery.
src/handover.sh        Builds the prompt that hands a conversation to the
                       user's coding agent and execs omarchy-agent. Runnable by
                       hand; --print shows the prompt and launches nothing.
skills/omarchy-slack/  What that agent is pointed at: the helper's commands, and
                       how to hand a draft back instead of posting it.
src/SettingsForm.qml   The settings UI shown inside the shell's settings panel.
src/QuickSwitcher.qml  `n` / `Ctrl-k`. src/SearchPane.qml is Slack search.
                       The `directory` command it runs is also what the message
                       box's @-completion uses, with its own query and its own
                       Process - see Service's mention section.
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
   message must not be able to collect a token or report a read receipt. The
   same rule runs the other way for the one request that *sends*: an upload URL
   comes back from `files.getUploadURLExternal`, and `UPLOAD_HOSTS` is checked
   before any of the user's file leaves - an API response is a better source
   than a message, but it is still somebody else naming where our data goes, and
   no token is attached there because that URL carries its own.
3. **A message never chooses its own markup.** This is about messages coming
   *in*. The one thing that goes the other way is `escape_outgoing`: a message
   being sent is escaped so a stray `<` cannot become somebody else's link, and
   then exactly two shapes are restored - `<@U…>` and the three `<!here>`-style
   broadcasts - because a mention *is* that form on the wire and the composer
   completes into it. The pattern is deliberately tight and carries no `|label`
   part, which is Slack's to write. Widening it means widening what a person's
   own typing can turn into.

   Incoming: `slack.py` flattens mrkdwn to text. The only tag the window ever
   builds is an `<a>` around text it escaped
   itself, from an offset into that text. `http`, `https`, `mailto` only —
   checked in `slack.py`, again in `Model.js` where the anchor is written, and
   once more in `openUrl` before `xdg-open` sees it. Keep all three.

   The canvas editor's page pane is the one exception, and it is fenced the
   same way: `canvas_markdown` escapes every character that would be markup on
   the way out and never writes a picture, `Model.previewMarkdown` takes out
   any picture and any tag that is there anyway before a renderer sees the
   string, and a link still goes through `openUrl`. Three checkpoints again.
   Rendering a canvas *anywhere else* means adding a fourth, not skipping
   these.
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

qs -p $STAGE/shell.qml ipc call dev handover      # the argv a handover would run
qs -p $STAGE/shell.qml ipc call dev draft '{...}' # a draft coming back
qs -p $STAGE/shell.qml ipc call dev handovers false
qs -p $STAGE/shell.qml ipc call dev texts agent    # is that row on screen at all?
```

A syntax check across the whole repo, which is worth having before a commit and
is not on `$PATH`:

```bash
/usr/lib/qt6/bin/qmlformat src/*.qml >/dev/null   # silence means they all parse
```

A bare `qmlformat` is "command not found", and inside a loop with `|| echo FAIL`
that reads as every file being broken - which is a confusing way to learn that
nothing is wrong. It catches what a running shell does not: a file that parses
but is never imported by the harness.

The three above are how the agent handover is exercised without an agent
actually starting: `agentArgv()` is split out of `askAgent()` for exactly that.

`dev/link.sh` assembles a Quickshell config folder in `$XDG_RUNTIME_DIR/omarchy-slack-dev`
and symlinks the sources into it. It has to: Quickshell only imports modules
from inside its own config folder, so `Commons/` and `Ui/` from
`/usr/share/omarchy/shell/` must sit beside a `shell.qml` — and the repo itself
may not contain symlinks (invariant 7). Editing a link edits the real file.

**Those links point back into the repo, so writing to the stage writes to the
repo.** A scratch harness saved as `$STAGE/shell.qml` goes straight through the
symlink and overwrites `dev/shell.qml`. Give a throwaway one any other name.

`qs -p $STAGE/shell.qml ipc call dev state` prints what the service thinks is
going on, which is the first thing to ask when the window comes up empty.

The harness applies its fixture settings from `onSettingsLoadedChanged`, through
a `Qt.callLater`, and both halves of that matter. The window sets
`settingsLoaded` *before* it assigns the settings it just read from the bar
layout, so fixtures applied inline are overwritten one line later — and the
600ms timer this used to be won that race only *most* of the time, which is how
a harness ends up quietly showing your real workspace instead of the fixtures.

`--demo` runs through the whole plugin: every read is answered from fixtures in
`slack.py`, every write returns as if it had happened and posts nothing. That is
what makes an automated run safe.

**Installed-copy edits need a real restart.** `omarchy-shell shell reloadConfig`
and `rescanPlugins` both return ok without re-reading plugin QML or a widget's
entry in `shell.json`. Run `omarchy-restart-shell` and confirm the PID moved
(`pgrep -af 'quickshell -n'`). A surviving PID also proves the QML parsed — a
fatal QML error makes it exit instead.

## Things that will surprise you

- **The offscreen harness runs the software scene graph, so a shader path is
  invisible to every screenshot in this repo.** `QT_QPA_PLATFORM=offscreen`
  forces it whatever `QSG_RHI_BACKEND` says, and `GraphicsInfo.api ===
  GraphicsInfo.Software` is what `Avatar.qml` and `MessageImage.qml` branch on.
  A `ClippingRectangle` - a ShaderEffect over a ShaderEffectSource - therefore
  cannot be photographed here at all, and one drew *no picture* on real
  hardware for a whole release while every shot in the repo looked right.
  `MessageImage.qml` no longer uses one. If you reach for one, test it in a real
  shell (`omarchy-restart-shell`, then look), not in the harness.
- **A toast is a route back in, and it survives a shell restart.** Notifications
  go out through `omarchy-notification-send`, whose `--exec` becomes the
  `omarchy-exec-argv` hint: the click action rides as *data*, so omarchy can
  still run it after the shell that sent it has been restarted, which a live
  libnotify action cannot. Clicking runs `omarchy-shell shell summon <id>
  '<json>'` and the payload lands in the window's `open()`. Two traps: that
  sender has no `--` to end its options, so a headline that is exactly one of
  its flags is guarded with a leading space in `asText()`; and `-r` needs the id
  a previous send printed with `-p`, which is what makes several messages in one
  conversation update one toast instead of stacking.
- **The poll gate's signals arrive late.** For the first second or two of a
  shell's life UPower has no devices, NetworkManager reports `Unknown`
  connectivity and `canCheckConnectivity` is false - measured, on this machine.
  Every default in `PollGate.qml` therefore means "go ahead": a gate that failed
  closed would swallow the first fetch after every shell start, which is the one
  that fills an empty panel.
- **`Service.qml` is instantiated more than once, and the helper is what makes
  that safe.** `BarWidget.qml` has one and `SlackWindow.qml` has another, and
  the bar is one surface *per monitor* — so a two-monitor desktop with the
  window open used to poll the workspace three times an interval, in a burst,
  which is what Slack answers with a 429 rather than averaging out. The data
  has *not* moved into a `kinds: ["service"]` singleton the way the mail
  plugin's did (`Store.qml`); instead `cmd_fetch` takes a `FetchSlot` — an
  flock on `fetch.lock` in the cache — and whoever finds it taken waits and is
  handed the snapshot the holder wrote, marked `cached`. So the count of
  services no longer sets the count of polls, and it holds for the window and
  for a manual refresh too, which a QML singleton would not have covered.
  Three things follow, and each one was a bug on the way here:
  - **The pacing in `Slack` is per instance, and every helper run is its own
    process.** It cannot see another process's requests. Only the lock can.
  - **Announcing may not be gated on a snapshot being freshly earned.** It was,
    and once a service could inherit somebody else's poll that meant a message
    announced by nobody at all. `Notifier.observe` is keyed by conversation and
    ts and drops what it has already said, so announcing from a shared snapshot
    is idempotent — which is what makes it safe to do unconditionally.
  - **Only one service may announce, and `notifies` is how.** It is elected in
    `BarWidget.qml` from `bar.moduleWidgets(moduleName)[0]`, reading
    `bar.moduleSlots` so that it re-elects when a monitor is unplugged. Before
    that election every copy of the widget announced: two monitors, two toasts
    per message, each with its own replace-id so they stacked instead of
    updating. It fails *open* — an unresolved election means "yes, speak" —
    because the Notifier's first round through a workspace is silent anyway and
    the lock keeps the duplicate poll off the wire.
- **A shared snapshot must not be chased.** `Service.qml` used to answer
  `cached: true` by immediately re-polling with `maxAge: 0`, which is how the
  window became the third poller. Now that the helper hands back what another
  process's poll wrote, chasing would not even terminate: every answer would
  come back shared and ask for one more. It re-polls only when the snapshot it
  was given is older than a whole interval, which is the bootstrap case it was
  written for.
- **A thread's unread mark comes free with the transcript, and only for the
  open channel.** `message_row` forwards `subscribed`, `lastRead`,
  `latestReplyTs` and the `threadUnread` it computes from them; Slack sends
  those on a thread parent for a thread the user follows, and sends no unread
  *count* at all - hence `threadLabel(count, unread)` saying "new" rather than a
  number. Extending it to sidebar marks means one `conversations.history` per
  channel per poll, which the rate limit rules out.
- **Reading a thread is marked locally, because Slack has no method for it.**
  `thread-read` writes `threads.json` in the cache and `apply_thread_marks`
  reads it back; by construction it can only clear a mark, never invent one. If
  you add a way to see a thread, mark it read there too, or the chip will keep
  saying "new" about something the user just read.
- **A canvas is saved whole, which is why so little of this is optional.**
  `canvases.edit` takes one change per call - two in the array is a refusal -
  and a `replace` with no `section_id` is the whole document. Nothing the
  window drew remembers which section it came from, so whole is the only
  shape it can offer. Everything careful around it follows: the digest the
  helper sends with the Markdown comes back with the save and is checked
  against Slack's current version first, and a canvas whose Markdown came back
  short (too long to read) or lossy (a picture, an embed) is never offered the
  replacing editor at all. Slack also keeps the canvas title as a heading of
  its own and puts it back on every full replace, so `drop_markdown_title`
  takes it out of what is sent - without that a canvas gains a copy of its own
  name with every save.
- **Sending a file is three requests, and only the third shares it.**
  `files.getUploadURLExternal` reserves an id and a URL, the bytes go to that
  URL as `multipart/form-data` with one part named `file` (which is what Slack's
  own example posts, and that endpoint answers in plain text, not JSON), and
  `files.completeUploadExternal` is what puts it in a conversation. A failure at
  the third step leaves the file on Slack's side and in no conversation, which
  is why that one reports `upload_incomplete` rather than a plain failure. One
  file per call on purpose: three requests each against a rate limit, and a
  dropped folder of forty is not something to discover halfway through.
- **Slack's rate limits are the design constraint**, not an annoyance. Previews
  for the whole workspace cost *one* search per poll, because non-Marketplace
  apps get roughly one `conversations.history` a minute plus a burst of fifteen.
  Read the "How it knows what is new" section of the README before adding any
  per-conversation request.
- **One search, and it means one.** `activity_feed` has three pages available
  and stops at the first that reaches back past `high_water(seen)` — the newest
  message the previous poll recorded anywhere. Everything older than that is an
  answer already given: a message does not change after it is sent and the
  preview it produced is in `previews.json`. Measured: three searches became
  one on a real workspace, and every one of the twelve conversations the deeper
  pages turned up already had a preview on disk that was no older than what
  those pages knew. Do not "simplify" this back to a fixed page count — and do
  not raise `FEED_PAGES` in the hope of better coverage either, because the
  first poll of a workspace still walks all of them and that is where coverage
  comes from.
- **A transcript is kept, and `seen` is what says whether it is still good.**
  See the "a transcript, remembered" section of `slack.py`. The trap is in
  which two values get compared: `seen` comes from `search.messages`, which
  returns thread replies, and `conversations.history` returns only top-level
  messages — so a channel whose last word was a reply in a thread has a `seen`
  permanently ahead of anything its own transcript can end on. Comparing them
  as positions made that channel look stale on every open and the cache never
  hit once, measured on a real workspace. What they can be trusted to agree
  about is *change*: a transcript written while `seen` was X is current while
  `seen` is still X. Which also fixes the guarantee in one sentence — a
  transcript is as current as the sidebar's previews are.
- **Anything that changes a conversation must call `drop_transcript`.** `send`,
  `upload` and `react` do. It takes every record for the conversation, threads
  included: a reply moves the parent's count in the channel, and a reaction is
  given by a ts that says nothing about which of the two views it is in. The
  reload behind those three also passes `--fresh`, because it is looking for
  something Slack has just been told that no search has run to confirm.
- **Lists are `Repeater`s inside `ScrollView`s**, including the transcript. Every
  row is instantiated, and every row is rebuilt whenever the array is replaced.
  That second half is measured, not assumed: a `ListView` over a plain JS array
  recreates *all* of its delegates when the array changes, so `reuseItems` on its
  own buys nothing. Making a long conversation cheap needs a model that diffs,
  and there are two, neither free. `Quickshell.ScriptModel` (`values` plus
  `objectProp: "id"`) diffs for you but exposes only `modelData` — every
  `required property string foo` in the delegate becomes `modelData.foo`, and a
  delegate that outlives its row during a remove transition then reads through a
  null, so the last non-null row has to be kept. Or the mail plugin's way: a
  `ListModel` with the diff written by hand (`MailList.qml`), which keeps the
  role-named delegate properties. Mail chose the second deliberately.
- **The window is a `FloatingWindow`** — a real Hyprland toplevel, tiled like
  anything else. It has no app id of its own, so its `title` is the only handle
  a Hyprland window rule has on it.
- **`omarchy-shell shell summon janrenz.omarchy.slack '<json>'`** delivers that
  JSON to `SlackWindow.open(payloadJson)`, which hands it to `applyPayload`:
  `conversation`/`thread`/`message` reveal a message (what a clicked
  notification passes), `draft` puts an agent's answer in the message box
  unsent. The shell drains its payload queue in a loop and delivers to a window
  that is already open, so anything added there has to survive arriving twice
  and must not throw away a draft being typed. `omarchy-shell shell call <id>
  <method> <arg>` routes to any method on the loaded window - `agentDraft` is
  the same draft route, and returns what it made of the payload.
- **The coding-agent handover is one setting away from not existing.**
  `agentHandover` gates the `a` key, the button, the help entry and the inbound
  draft. A feature that reaches other people's messages has to be refusable, so
  check the gate rather than assuming it.

## House style

Comments and prose explain **why**, never what — look at the header of
`Service.qml` or `dev/link.sh` for the register. Full sentences. A comment that
restates the line below it does not survive review. The README is written for a
person deciding whether to install this, and says plainly what the plugin does
not do.

Keep the work inside the window. When something cannot be finished here, that is
the bug — not a reason to hand the user off to a browser.
