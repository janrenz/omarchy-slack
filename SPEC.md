# SPEC.md — Slack for Omarchy

**Status: descriptive.** This records what the plugin does as of version
**0.8.0** (2026-09-04). It is the contract; `AGENTS.md` is how to change it;
`README.md` is for somebody deciding whether to install it. The contract all
three communication plugins share lives in [`PLATFORM.md`](PLATFORM.md) and is
not restated here.

---

## 1. Scope

Slack channels, DMs and threads in the bar and in a window of their own, plus
the channel's canvas.

| | |
|---|---|
| Plugin id | `janrenz.omarchy.slack` |
| Kinds | `bar-widget`, `panel` |
| Entry points | `src/BarWidget.qml`, `src/SlackWindow.qml` |
| `allowMultiple` | **false** — one workspace per install |
| Helper | `src/slack.py` (4324 lines) |
| State | `~/.local/state/omarchy/slack/` |
| Cache | `marks.json`, `threads.json`, `previews.json`, `fetch.lock`, `media/` |

**One workspace per install.** The window is one per plugin and the widget is
`allowMultiple: false`; two workspaces would be two sidebars fighting over one
window.

### 1.1 Authentication

A **user token** from a Slack app the user creates themselves. There is no
device-code flow and no OAuth dance — `login-set` takes the token on stdin.
`create-app` emits an app manifest (and `--dry-run` validates it).

**What the token may do is read back, not assumed.** Every response carries
`x-oauth-scopes`; `remember_scopes` records them and the window says "this token
cannot search" rather than offering a search that 403s. `WANTED_SCOPES` is the
declared set, `CAPABILITIES` maps capability → scope, and `missing_scopes`
reports the shortfall. **New capability ⇒ new scope check.**

---

## 2. The rate limit decides the architecture

**This is the single most important fact about the plugin.** Everything below
follows from it.

Slack allows an app outside its Marketplace **one `conversations.history`
request per minute**, plus a burst of about fifteen. Every app anybody makes for
themselves is such an app. Measured on a real workspace: after a minute of quiet,
six calls five seconds apart returned one success and five refusals.

So the obvious design — a sidebar asking each conversation what was last said in
it — is **impossible here**. Forty conversations would need forty requests, and
forty requests would need forty minutes. (This is exactly the design the Teams
plugin uses, and it is why the two plugins are shaped differently.)

What is **not** limited is search. One `search.messages` for everything since a
date, newest first, returns the last few hundred messages across every
conversation, each with its channel, author, text and timestamp. That is what
forty history requests would have said, in one request, covering the whole
workspace rather than the forty that fitted a budget.

### 2.1 A poll, exactly

1. **Two requests** listing channels and DMs by name.
2. **One search** for everything said in the last `FEED_DAYS` (14) — where every
   preview and every "this is new" comes from.
3. **`conversations.info`** for the conversations whose newest message is newer
   than the read mark already held. Not restricted; measured at ten calls a
   second without a refusal.

Measured: a full poll of a workspace with 42 channels and 403 DMs takes about
**3.5 seconds** and never touches the limit. The sidebar is on screen in about a
fifth of a second, from the last snapshot.

### 2.2 One search, and it means one

`activity_feed` has `FEED_PAGES` (3) available and **stops at the first page that
reaches back past `high_water(seen)`** — the newest message the previous poll
recorded anywhere. Everything older than that is an answer already given: a
message does not change after it is sent, and the preview it produced is in
`previews.json`.

Measured: three searches became one on a real workspace, and every one of the
twelve conversations the deeper pages turned up already had a preview on disk no
older than what those pages knew.

The deeper pages go out on the first poll of a workspace, which has nothing
recorded, and when more than a hundred messages have arrived since the last one —
a laptop back from a day asleep.

**Do not "simplify" this back to a fixed page count, and do not raise
`FEED_PAGES` hoping for better coverage** — the first poll of a workspace still
walks all of them, and that is where coverage comes from.

### 2.3 What is not asked again

| Thing | TTL | Why |
|---|---|---|
| Conversation list | `LIST_TTL` 15 min | Which channels you are in changes about weekly; joining one refreshes it on the spot |
| Presence | `PRESENCE_TTL` 5 min | One request **per person**, so it is a command of its own the window calls once the sidebar is already drawn, and only about people actually being drawn — a dot nobody can see is a request spent on nothing |
| Users | `USER_TTL` 7 days | |
| Channel meta | `CHANNEL_TTL` 6 h | |
| Stars | `STARS_TTL` 10 min | |
| The finished snapshot | `SNAPSHOT_MAX_AGE` 15 min | So a shell that has just started draws the sidebar it had rather than a blank one |
| A transcript | `TRANSCRIPT_TTL` 90 s fallback | See §2.5 |

### 2.4 `FetchSlot` — several Services, one poll

`cmd_fetch` takes a **`FetchSlot`**: an `flock` on `fetch.lock` in the cache.
Whoever gets it does the work; whoever finds it taken waits (up to `FETCH_WAIT`,
25 s) and is handed the snapshot the holder wrote, marked `cached`.

So the count of Services no longer sets the count of polls, and it holds for the
window and for a manual refresh too — which a QML singleton would not have
covered. Two monitors cost what one does, and three do too.

Three consequences, each of which was a bug on the way here:

- **The pacing in `Slack` is per instance, and every helper run is its own
  process.** It cannot see another process's requests. Only the lock can.
- **Announcing may not be gated on a snapshot being freshly earned.** It was, and
  once a Service could inherit somebody else's poll that meant a message
  announced by nobody at all. `Notifier.observe` is keyed by conversation and ts
  and drops what it has already said, so announcing from a shared snapshot is
  **idempotent** — which is what makes it safe to do unconditionally.
- **A shared snapshot must not be chased.** `Service.qml` used to answer
  `cached: true` by immediately re-polling with `maxAge: 0`, which is how the
  window became the third poller. Now that the helper hands back what another
  process's poll wrote, chasing **would not even terminate**: every answer would
  come back shared and ask for one more. It re-polls only when the snapshot it
  was given is older than a whole interval, which is the bootstrap case it was
  written for.

### 2.5 A transcript is kept, and `seen` says whether it is still good

`conversations.history` is spent on exactly one thing: **a conversation you open
that has changed since you last read it.** The transcript last read is kept on
disk, and whether it is current is answerable for free — the poll already
remembers the newest thing its search saw in every conversation.

**The trap is in which two values get compared.** `seen` comes from
`search.messages`, which returns thread replies; `conversations.history` returns
only top-level messages. So a channel whose last word was a reply in a thread has
a `seen` permanently ahead of anything its own transcript can end on. Comparing
them as *positions* made that channel look stale on every open and the cache
never hit once — measured on a real workspace.

What they can be trusted to agree about is **change**: a transcript written while
`seen` was X is current while `seen` is still X. Which also fixes the guarantee in
one sentence: **a transcript is as current as the sidebar's previews are.**

Be clear about which half of the problem this solves. Reading a conversation for
the first time still costs a request, and four never-opened channels opened
inside a minute still hit the limit. What goes away is every *re*-read — going
back to the one you just left, closing and reopening the window, coming out of a
thread into its channel, reopening the same channel after each poll. That is most
of what browsing Slack actually is.

**Anything that changes a conversation must call `drop_transcript`.** `send`,
`upload` and `react` all do. It takes **every** record for the conversation,
threads included: a reply moves the parent's count in the channel, and a reaction
is given by a ts that says nothing about which of the two views it is in. The
reload behind those three also passes `--fresh`, because it is looking for
something Slack has just been told that no search has run to confirm.

---

## 3. Helper command surface

`python3 src/slack.py <command> --account <alias> [...]`.

### 3.1 Account

| Command | Arguments |
|---|---|
| `login-set` | `--account`; reads `{"token": "xoxp-…"}` on **stdin** |
| `login-status` | `--account` |
| `create-app` | `--name`, `--dry-run` |
| `list`, `remove`, `palette`, `reactions` | — |

`login-set` refuses before writing anything: `no_token` if stdin carried none,
`bad_token` if it does not begin `xox`, `login_failed` if `auth.test` says no,
and `token_unusable` if `token_problem` finds the scopes cannot work. **Nothing
is written in that last case** — a token that cannot work is not a sign-in, and
storing it would leave the window claiming to be signed in to a workspace it
cannot read.

### 3.2 Reading

| Command | Arguments | Notes |
|---|---|---|
| `fetch` | `--account` (repeatable), `--conversations`, `--sort {recent,name}`, `--avatars`/`--no-avatars`, `--presence`/`--no-presence`, `--fresh`, `--max-age`, `--demo` | The poll (§2.1) |
| `messages` | `--channel`, `--thread`, `--around`, `--top`, `--avatars`, `--fresh`, `--demo` | A transcript, or one thread's replies |
| `canvas` | `--channel`, `--file`, `--demo` | The channel's canvas |
| `search` | `--query`, `--top`, `--demo` | Needs the search scope |
| `directory` | `--query`, `--demo` | Also what the composer's `@`-completion uses |
| `presence` | `--user` (repeatable), `--demo` | |
| `image` | `--url` | Slack-hosted only |

### 3.3 Writing

| Command | Arguments |
|---|---|
| `send` | `--channel`, `--thread`, `--broadcast`, `--text` \| **`--stdin`**, `--demo` |
| `upload` | `--channel`, `--thread`, `--file` \| **`--stdin`**, `--comment`, `--title`, `--demo` |
| `react` | `--channel`, `--ts`, `--emoji`, `--remove`, `--demo` |
| `mark` | `--channel`, `--ts`, `--demo` |
| `thread-read` | `--channel`, `--ts`, `--upto`, `--demo` |
| `open-dm` | `--user` (repeatable), `--demo` |
| `join` | `--channel`, `--demo` |
| `canvas-edit` | `--channel`, `--file`, `--operation`, `--markdown` \| **`--stdin`**, `--base`, `--demo` |

---

## 4. Behavioural contracts worth stating as spec

### 4.1 Escaping on the way out, and the two shapes restored

`escape_outgoing` escapes a message being sent so a stray `<` cannot become
somebody else's link, and then restores **exactly two shapes**: `<@U…>` and the
three `<!here>`-style broadcasts — because a mention *is* that form on the wire
and the composer completes into it.

The pattern is deliberately tight and carries **no `|label` part**, which is
Slack's to write. **Widening it means widening what a person's own typing can
turn into.**

### 4.2 Threads

- **A thread's unread mark comes free with the transcript, and only for the open
  channel.** `message_row` forwards `subscribed`, `lastRead`, `latestReplyTs` and
  the `threadUnread` it computes from them. Slack sends those on a thread parent
  for a thread the user follows, and sends **no unread count at all** — hence
  `threadLabel(count, unread)` saying "new" rather than a number.
  Extending this to sidebar marks would mean one `conversations.history` per
  channel per poll, which §2 rules out.
- **Reading a thread is marked locally, because Slack has no method for it.**
  `thread-read` writes `threads.json` and `apply_thread_marks` reads it back; by
  construction it can only **clear** a mark, never invent one. **If you add a way
  to see a thread, mark it read there too**, or the chip keeps saying "new" about
  something just read.
- **A thread reply does not bump its channel.** Slack counts threads apart from
  channels and so does this: `conversations.history` does not return a reply
  unless the sender ticked "also send to channel". The sidebar's unread mark is
  about the channel; the thread chips inside it are about the threads.

### 4.3 Marking read

Opening a conversation marks it read in Slack itself, so the count clears in
every client — **up to the newest message the search found**, which includes
replies inside a thread. The transcript is the channel timeline and a thread
reply is not in it, so marking read up to the last line on screen would leave
those rows lit with nothing left to read. **The read mark goes to whichever is
newer, and only ever moves forward**, so nothing already read comes back.

### 4.4 Sending a file is three requests, and only the third shares it

1. `files.getUploadURLExternal` reserves an id and a URL.
2. The bytes go to that URL as `multipart/form-data` with one part named `file`
   — which is what Slack's own example posts, and **that endpoint answers in
   plain text, not JSON**.
3. `files.completeUploadExternal` puts it in a conversation.

**A failure at the third step leaves the file on Slack's side and in no
conversation**, which is why that one reports `upload_incomplete` rather than a
plain failure.

**One file per call, on purpose:** three requests each against a rate limit, and a
dropped folder of forty is not something to discover halfway through.

`UPLOAD_HOSTS` is checked before any of the user's file leaves. An API response is
a better source than a message, **but it is still somebody else naming where our
data goes** — and no token is attached there, because that URL carries its own.
The upload follows no redirects at all.

**A path is resolved once.** `read_upload` opens the file and asks the descriptor
everything after that; asking the name three times — `isfile`, `getsize`, `open`
— is three chances for it to mean a different file. The open is `O_NONBLOCK`
because it now happens first: a FIFO nobody is writing to would otherwise hang a
helper the window is waiting on.

### 4.5 A canvas is saved whole, which is why so little of this is optional

`canvases.edit` takes **one change per call** — two in the array is a refusal —
and a `replace` with no `section_id` is the whole document. Nothing the window
drew remembers which section it came from, so **whole is the only shape it can
offer.**

Everything careful around it follows:

- The **digest** the helper sends with the Markdown comes back with the save and
  is checked against Slack's current version first (`canvas_changed`).
- A canvas whose Markdown came back **short** (too long to read) or **lossy** (a
  picture, an embed) is never offered the replacing editor at all — only the box
  that appends.
- Slack keeps the canvas title as a heading of its own and **puts it back on every
  full replace**, so `drop_markdown_title` takes it out of what is sent. Without
  that, a canvas gains a copy of its own name with every save.

The editor's page pane is the one place markup is rendered, and it is fenced the
three-checkpoint way described in `PLATFORM.md` §2.3. **Rendering a canvas
anywhere else means adding a fourth checkpoint, not skipping these.**

### 4.6 A summon applies its payload before the settings exist

`open()` starts `config.py` and applies the payload **without waiting for it**,
so a deep link — a clicked toast, a row in the dropdown — reaches `openById`
while `alias` is still `""`.

Two separate things ate it:

- `fetchMessages` asked the helper for a transcript against a nameless workspace
  (`bad_alias`) and nothing re-asked. → **`messagesQueued`**
- `onAliasChanged` treated `"" → "work"` as a change of workspace and called
  `closeConversation()`. → **`lastAlias`**

The second is the one that wastes an afternoon, because what the window shows is
"Pick a conversation" — a link that looks like it was never followed, with no
error anywhere.

**Test this cold.** The whole class is invisible once the window is up, and the
dev harness hides it twice over, because it assigns settings a second time (the
real bar entry, then the fixtures) and that *is* a genuine workspace switch. A
variant that neuters `fixtures()` and opens a real conversation from
`Component.onCompleted` is what reproduces it.

---

## 5. State model

**No singleton.** `Service.qml` (1537 lines) is instantiated by `BarWidget.qml`
and by `SlackWindow.qml`, and the bar is one surface per monitor. Coordination is
in the helper, via `FetchSlot` (§2.4), not in QML.

Service owns: the snapshot, the open conversation and its transcript, thread
state, the canvas and its draft, the composer draft, the quick switcher and its
directory lookups, mention completion, search results, presence, the mark-read
queue, and the sign-in state machine.

`unreadOnly` is fixed **on the bar's Service** so the dropdown filters through
`Model.conversationRows`' existing argument rather than a second copy of it —
which is also why opening the dropdown costs no request.

---

## 6. Settings

| Key | Type | Default | Range / options |
|---|---|---|---|
| `account` | string | — | Workspace alias |
| `conversations` | integer | 40 | 5–120. Read-state checks per poll |
| `sort` | string | `recent` | `recent`, `name` |
| `density` | string | `cosy` | `compact`, `cosy`, `roomy`, `spacious` |
| `avatars` | boolean | true | |
| `presence` | boolean | true | |
| `refreshIntervalSec` | integer | 120 | 30–3600 |
| `pausePolling` | boolean | true | |
| `icon` | string | `󰒱` | |
| `label` | string | `""` | |
| `ipcTarget` | string | `""` | Names the **dropdown's** IpcHandler |
| `tintOnUnread` | boolean | true | |
| `showCount` | boolean | false | |
| `notify` | boolean | true | |
| `agentHandover` | boolean | true | |

`demo` and `demoOpen` exist for the harness and the showcase only.

### 6.1 Live configuration on this machine

```json
{ "id": "janrenz.omarchy.slack", "account": "work", "showCount": false }
```

---

## 7. Data shapes

### 7.1 Conversation row (`conversation_row`)

```
id, kind (im|mpim|channel), name, title, private, withUserId,
topic, purpose, quiet, member, updated, priority,
lastFrom, lastText, when, ts, unread, unreadCount,
presence, avatar, current, starred
```

- `updated` is **not** the last message — a channel here reads 2024 and had a
  message this morning — so it is a tiebreaker and never a claim.
- `priority` is Slack's own relevance score, and **only IMs carry one**.
- `current` says whether the row was given a preview and an unread mark *this
  poll*. A row that was not is still perfectly openable; it just costs a request
  nobody has spent yet, and **says so rather than claiming to have nothing new in
  it**.
- `starred` is filled in by `fetch_account`, since it is one answer for the whole
  workspace rather than something on each conversation.

### 7.2 Message row (`message_row`)

```
id, ts, from, fromId, avatar, when, text, links[],
edited, system, mine, images[], files[], reactions[],
threadTs, replyCount, replyUsers, latestReply,
subscribed, lastRead, latestReplyTs, threadUnread,
parent, pinned
```

`links` is **where the links are, rather than the links themselves** — the
transcript builds its anchors out of escaped text, so nothing a sender wrote can
arrive already being markup.

`threadUnread` is a **fact, not a count**: there is no unread count anywhere in
the payload. Verified against a real workspace — parents come back with
`subscribed`/`last_read`/`latest_reply` and never with an `unread_count`.

---

## 8. UI surfaces

### 8.1 Bar widget (`BarWidget.qml`, 188 lines)

Left click toggles the dropdown, **right click summons the window**, middle click
refreshes. Elects `notifies` from `bar.moduleWidgets(moduleName)[0]`.

### 8.2 Dropdown (`BarPanel.qml`, 371 lines)

What is waiting, and nothing else. Every row is a way into the window. Binds to
the bar's Service with `unreadOnly` on it, so **opening it fetches nothing**.

### 8.3 Window (`SlackWindow.qml`, 2972 lines)

Sidebar, transcript, message box, and the canvas pane — which has **no message
box** and has the Markdown editor instead. Also the file chooser and the
window-wide `DropArea`, which both end at `sendFile()` — the one place a `file://`
URL becomes a path.

Sub-surfaces: `QuickSwitcher.qml` (`n` / `Ctrl-k`), `SearchPane.qml` (Slack
search), `ImageViewer.qml` (a picture with save-as), `ReactionBar.qml`,
`SettingsForm.qml`, `KeyHelp.qml`.

**`MessageImage.qml` no longer uses a `ClippingRectangle`.** One drew *no
picture* on real hardware for a whole release while every screenshot in the repo
looked right — see `PLATFORM.md` §10.2.

### 8.4 Keymap

Beyond the shared set in `PLATFORM.md` §9.1:

| Key | |
|---|---|
| `t` | Open the thread on the message under the cursor |
| `1`–`9` | Pick that reaction, or take yours back |
| `@` | In the message box: start a mention; Tab or Enter completes |
| `n` / `Ctrl-k` | Jump to any channel or person |
| `/` | Search every message |
| `f` | Filter the conversations already listed |
| `m` | Mark this conversation read |
| `c` | Read this channel's canvas, and go back again |
| `e` | In a canvas: write in it |

---

## 9. Window IPC

`SlackWindow.open(payloadJson)` → `applyPayload`:

| Key | Meaning |
|---|---|
| `conversation` | reveal this conversation |
| `thread` | …and this thread inside it |
| `message` | …and this message |
| `draft` | put an agent's answer in the message box, **unsent** |

`agentDraft` is the same route by name, and returns what it made of the payload.

Harness routes for exercising the handover without an agent starting:

```bash
qs -p $STAGE/shell.qml ipc call dev handover        # the argv a handover would run
qs -p $STAGE/shell.qml ipc call dev draft '{...}'   # a draft coming back
qs -p $STAGE/shell.qml ipc call dev handovers false
qs -p $STAGE/shell.qml ipc call dev texts agent     # is that row on screen at all?
qs -p $STAGE/shell.qml ipc call dev state
```

---

## 10. Limits and caps

| Constant | Value |
|---|---|
| `CONVERSATION_CAP` | 120 |
| `CHANNEL_LIST_CAP` / `DM_LIST_CAP` | 300 / 800 |
| `DM_ROWS` | 30 |
| `LIST_CAP` | 400 |
| `MESSAGE_CAP` | 60 |
| `DIRECTORY_CAP` | 2000 |
| `PRESENCE_CAP` | 20 |
| `MAX_RESPONSE_BYTES` | 8 MB |
| `WORKERS` | 6 |
| `FEED_DAYS` / `FEED_PAGES` / `FEED_COUNT` | 14 / 3 / 100 |
| `STARS_CAP` | 400 |
| `CANVAS_CAP` / `CANVAS_TEXT_CAP` | 200 KB / 40 000 |
| `UPLOAD_CAP` | 25 MB |
| `IMAGE_CAP` | 12 MB |
| `SNAPSHOT_MAX_AGE` / `FETCH_WAIT` | 15 min / 25 s |
| `TRANSCRIPT_TTL` / `RENDER_VERSION` | 90 s / 2 |

### 10.1 Host allowlists

| Constant | Hosts |
|---|---|
| `TOKEN_HOSTS` | `files.slack.com` — **the only host a token is attached for** |
| `UPLOAD_HOSTS` | `files.slack.com`, refusing redirects |
| `IMAGE_HOSTS` | `files.slack.com`, `avatars.slack-edge.com`, `a.slack-edge.com`, … |
| `API_OPENER` | `slack.com` |

An avatar CDN does not need the token and does not get it.

---

## 11. Error codes

`auth_required`, `bad_alias`, `bad_canvas_host`, `bad_image_host`,
`bad_reaction`, `bad_redirect`, `bad_token`, `bad_upload_host`,
`canvas_changed`, `canvas_edit_failed`, `canvas_failed`, `create_failed`,
`empty`, `empty_file`, `empty_query`, `image_failed`, `image_too_large`,
`join_failed`, `list_failed`, `login_failed`, `manifest_rejected`,
`mark_read_failed`, `mark_read_permission_required`, `messages_failed`,
`no_base`, `no_canvas`, `no_file`, `no_palette`, `no_token`, `not_a_canvas`,
`not_an_image`, `not_editable`, `open_failed`, `permission_required`,
`rate_limited`, `react_failed`, `response_too_large`, `search_failed`,
`send_failed`, `token_expired`, `token_unusable`, `too_large`, `too_long`,
`unreadable`, `upload_failed`, `upload_incomplete`, `wrong_token`

`PLAIN_ENGLISH` maps Slack's own codes to sentences; `friendly()` and
`scope_error()` are the two entry points. **`rate_limited` is a first-class
outcome**, not an exception — the window says so in those words rather than
showing an empty transcript.

---

## 12. Security invariants

Verbatim from `AGENTS.md`. `PLATFORM.md` §2 carries 1, 4, 5, 7 and 8 in shared
form.

1. The token never reaches QML — `~/.local/state/omarchy/slack/`, mode 600, on
   stdin.
2. **The window never fetches anything remote.** Avatars, images and files are
   fetched by the helper, checked against Slack's own hosts first, and the token
   is attached for `files.slack.com` alone. **The same rule runs the other way for
   the one request that sends** (§4.4). A redirect is part of that check, not an
   exception to it; `urllib.request.urlopen` is called nowhere and **a test
   asserts that**.
3. A message never chooses its own markup — incoming *and*, via
   `escape_outgoing`, outgoing (§4.1). The canvas editor is the one exception and
   is fenced with three checkpoints of its own.
4. Stdlib only. `python3 src/slack.py` must run on a stock Arch box.
5. Every helper command prints one JSON object and exits 0 even on failure.
6. **What the token may do is read back, not assumed.**
7. No symlinks anywhere in the repo.
8. Colours and spacing come from `qs.Commons`; use `Style.space()` and the
   density scale.

---

## 13. Known non-goals

Recorded because they are decisions, not omissions. Full prose in `README.md` →
*What it does not do*.

- **No live updates.** Live Slack means a websocket held open for the session,
  and a desktop shell has no business running one.
- **Nothing quieter than a fortnight gets a preview** unless seen in an earlier
  poll. Its row shows the channel topic instead.
- **An unread count is counted out of the search**, so a conversation with more
  waiting than the window holds is counted **low rather than high**.
- **Muted channels are not muted.** Slack keeps mutes in a preference the Web API
  does not publish.
- **A workspace's own emoji stay as their names.** `:blob-wave:` is a picture that
  lives in that workspace and there is no character for it, so the name is what a
  reader gets — which is what a terminal client would show and is at least honest
  about what was sent.
- **No huddles, calls, workflows, or editing what you sent.**
- **Canvases attached to a *message*** rather than to the channel are still
  Slack's job.

---

## 14. Development

Per `PLATFORM.md` §10, plus:

```bash
node    dev/test-model.js                          # 694 lines
python3 dev/test-slack.py                          # 2245 lines
python3 src/slack.py fetch --account work --demo
python3 src/slack.py create-app --dry-run          # is the manifest still valid?
dev/run.sh ; dev/shot.sh /tmp/slack.png [demo-im-0] ; dev/showcase.sh
```

Stage: `$XDG_RUNTIME_DIR/omarchy-slack-dev`.

`--demo` runs through the whole plugin: every read is answered from fixtures in
`slack.py`, **every write returns as if it had happened and posts nothing.** That
is what makes an automated run safe.
