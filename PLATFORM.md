# PLATFORM.md — the contract the Omarchy communication plugins share

**Status: descriptive.** This documents the status quo as of 2026-09-04, across
`caseonline.omarchy.office365` (mail), `janrenz.omarchy.slack` (slack) and
`janrenz.omarchy.teams` (teams). Where the three disagree, that is recorded as a
divergence rather than smoothed over — a spec that hides drift is worth less
than one that names it.

**This file is a synchronized copy.** It lives in all three plugin repos so each
stays self-contained for an agent reading only that repo. Changing it means
changing all three.

Each plugin's own `SPEC.md` states what it does; `AGENTS.md` states how to
change it. This file is what none of them should have to restate.

---

## 1. Shape

All three are the same machine:

```
  helper (Python, stdlib only)   holds credentials, makes every network call,
        │                        prints exactly one JSON object per invocation
        │  JSON on stdout
        ▼
  Service.qml / Store.qml        owns Processes, the poll timer, and the state
        │                        the UI binds to
        │  properties
        ▼
  Model.js                       pure JS: shaping, grouping, labels, links.
        │                        No Qt types — runnable under plain `node`
        ▼
  QML surfaces                   bar widget, dropdown, window
```

Data flows one way. The only things travelling back toward the network are a
command line and a stdin payload.

### 1.1 Surfaces

Each plugin presents up to three surfaces, declared through `manifest.json`:

| Surface | Entry point | Instances |
|---|---|---|
| Bar widget | `barWidget` | One **per monitor**, times the widget count |
| Dropdown | mounted by the bar widget via a `Loader` | Follows its widget |
| Window | `panel` | **One per plugin** |

The per-monitor multiplication of the bar widget is the single most
consequential fact in this architecture. It is the root cause of duplicate
polling, duplicate notifications, and rate-limit bursts, and each plugin
answers it differently — see §6.

---

## 2. Helper contract

Binding on all three, for every command.

1. **One JSON object on stdout, and nothing else.** No progress output, no
   partial writes, no second object.
2. **Exit 0 even on failure.** A failure is
   `{"ok": false, "error": {"code": "...", "message": "..."}}`, so the UI always
   has something to render. Exit non-zero *only* when the arguments themselves
   were unusable — that is argparse's job, not the command's.
3. **`--account <alias>` on every account-scoped command.** An alias is matched
   against `\A[A-Za-z0-9._-]+\Z`; anything else is `bad_alias`.
4. **`--demo` runs the whole plugin against fixtures.** Every read is answered
   synthetically and **every write returns as if it had happened and sends
   nothing.** This is what makes an automated run safe.
5. **`list`, `remove`, `palette`** exist on all three.
   `palette` returns the active theme's named colours, because the helper is
   where the theme file can be read and QML should not parse it.
6. **Stdlib only.** No pip, nothing vendored. `urllib`, `json`, `email`,
   `imaplib`, `smtplib`, `re` are the whole toolkit. The helper must run on a
   stock Arch box with no plugin-specific setup.

### 2.1 Credentials

- Tokens live under `~/.local/state/omarchy/<plugin>/`, mode **0600** inside a
  **0700** directory.
- Tokens reach the helper on **stdin**. Never argv — any local user can read
  another process's command line. Never `shell.json` — that file is the bar
  layout and is world-readable.
- Only the helper ever touches a token. QML renders the JSON the helper printed
  and holds no credential of any kind.
- **What a person wrote travels the same way.** Message text, search queries,
  reply comments and file paths go over stdin (`--stdin`, reading
  `{"text": …}` / `{"file": …}` / `{"query": …}`). The `--text` / `--comment`
  argv forms remain for driving the helper by hand.

### 2.2 Network posture

- **The UI never fetches anything remote.** Not an avatar, not an inline image,
  not a file. The helper fetches, and the host is checked **before** any token
  is attached.
- **A redirect is part of that check, not an exception to it.** urllib follows a
  redirect by copying the original request's headers — `Authorization` among
  them — onto the new request, comparing no hosts on the way. A check that only
  inspects the URL it was handed is a check a `302` walks straight through. So
  every request goes through a `GuardedRedirects` opener that asks again: the
  token comes off the moment the host changes, a redirect off `https` is
  refused, a redirect off the allowed hosts is refused, and an upload follows
  nothing at all.
- **`urllib.request.urlopen` is called nowhere.** Slack and Teams each assert
  this in their test suite, because one call site slipping back to it undoes
  everything above.

**Divergence.** Slack and Teams have `GuardedRedirects` and the urlopen
assertion. Mail (`graph.py`) does not — see the mail `SPEC.md` §11.

### 2.3 Markup

**A message never chooses its own markup.** Every incoming message is flattened
to plain text by the helper. The only tag any window ever builds is an `<a>`
around text it escaped itself, positioned from a `links` array of
`{start, end, href}` offsets into that text.

Link schemes are `http`, `https`, `mailto` — **and only those, checked three
times**: in the helper, again in `Model.js` where the anchor is written, and once
more in `openUrl` before the browser sees it. All three checks stay.

Two places carry an extra rule:

- **Mail** may render a message's own HTML (Show formatting, `htmlBody`, a
  standing sender rule, or a message with no plain-text part). Everything remote
  is stripped *before* rendering, so nothing in a message can phone home or
  report a read receipt. `Model.legibleBody` additionally drops colour
  declarations that fail a contrast check against the pane, because Outlook and
  Word stamp `color: black` on nearly every span they emit.
- **Slack's canvas editor** is fenced the same three-checkpoint way:
  `canvas_markdown` escapes on the way out and never writes a picture,
  `Model.previewMarkdown` strips any picture or tag before a renderer sees it,
  and links still go through `openUrl`.

---

## 3. Configuration

Settings live in one object per widget instance inside
`~/.config/omarchy/shell.json`, under `bar.layout.<section>[]`, keyed by the
plugin `id`.

- `manifest.json`'s `barWidget.schema` is what the shell's settings panel
  renders. **Adding a setting means adding it there and reading it through
  `setting()`** — one without the other is a setting that either cannot be set
  or has no effect.
- `barWidget.defaults` is what a freshly added widget gets.
- The **window has no settings of its own.** It is one per plugin while a widget
  may be multi-instance, so it reads a widget's entry out of `shell.json`.
- `shell.json` is world-readable. Nothing secret goes in it. `clientId` and
  `authority` are the only identity-adjacent values that belong there, and
  neither is a secret.

### 3.1 Settings all three share

| Key | Type | Meaning |
|---|---|---|
| `account` | string | The alias passed to the helper |
| `icon` | string | Nerd Font glyph for the bar |
| `label` | string | Text shown instead of the icon |
| `refreshIntervalSec` | integer | Poll interval |
| `pausePolling` | boolean | Honour the poll gate (§5) |
| `tintOnUnread` | boolean | Colour the bar icon when something waits |
| `notify` | boolean | Desktop notification on arrival |
| `agentHandover` | boolean | Enable the coding-agent route (§8) |
| `ipcTarget` | string | Names an `IpcHandler` for the **dropdown**; empty for none |

`ipcTarget` **must default to empty.** A multi-instance widget where several
instances register one IPC target is a collision.

**Divergence.** `density` (`compact` / `cosy` / `roomy` / `spacious`, scaling
`0.6 / 1.0 / 1.7 / 2.4`) exists in Slack and Teams and **not** in mail.

---

## 4. Notifications, and the toast as a route back in

Notifications go out through `omarchy-notification-send`.

**A toast survives a shell restart, and that is the point.** Its `--exec`
becomes an `omarchy-exec-argv` hint: the click action rides as *data*, so
omarchy can still run it after the shell that sent it has been replaced —
something a live libnotify action cannot do. Clicking runs:

```
omarchy-shell shell summon <plugin-id> '<json>'
```

and the payload lands in the window's `open()`.

Two traps, and both bite:

- **That sender has no `--` to end its options.** A headline that happens to be
  exactly one of its flags is guarded with a leading space in `asText()`.
- **`-r` needs the id a previous send printed with `-p`.** That is what makes
  several messages in one conversation update a single toast instead of
  stacking a pile of them.

### 4.1 Prime, then announce

The first pass over a conversation or mailbox is **silent**. `Notifier.observe`
records what is already there and announces nothing; only what arrives after
that is announced. Without this, every shell start dumps the entire backlog onto
the desktop.

`observe` is keyed by conversation and timestamp and drops what it has already
said, which makes announcing **idempotent** — and that in turn is what makes it
safe to announce from a snapshot another process earned (§6).

### 4.2 One announcer

Only one Service may announce. The flag is `notifies`, elected in
`BarWidget.qml` from `bar.moduleWidgets(moduleName)[0]`, reading
`bar.moduleSlots` so it **re-elects when a monitor is unplugged**.

It fails **open**: an unresolved election means "yes, speak". The first round is
silent anyway (§4.1), so failing open costs at worst one duplicate on a race,
where failing closed costs silence.

**Divergence, and the three plugins are in three states:**

| Plugin | `notifies` | Why |
|---|---|---|
| **Mail** | No election, and none needed | The `Notifier` lives in the singleton `Store.qml`, so exactly one exists per plugin however many bar surfaces there are |
| **Slack** | `notifies: root.primaryInstance`, elected from `bar.moduleWidgets(moduleName)[0]`, re-electing on `bar.moduleSlots` | No singleton, so the election is the only thing stopping one toast per monitor |
| **Teams** | **`notifies: true`, unconditionally** | No singleton *and* no election — see that repo's `GAPS.md` `TEAMS-3` |

Note that `observe`'s idempotence (§4.1) does **not** substitute for the
election. It protects against one Service announcing a snapshot it inherited from
another's poll; it does nothing about two Services each keeping their own
`observe` state, which is what a per-monitor bar surface produces.

---

## 5. The poll gate

`PollGate.qml` decides whether a poll is worth making at all, from idle time,
network reachability and battery state. A poll is also a token refresh, and
spending one on a locked laptop spends it on nobody.

Behaviour when `pausePolling` is on:

- Nothing is asked of the server while the screen has been idle ~5 minutes or
  the machine has no network. A fetch goes out the moment either changes back.
- On battery the interval is **doubled**; in the power-saver profile,
  **tripled**.
- **Anything the user asks for by hand still goes out**, gate or no gate.

**Every default in `PollGate.qml` means "go ahead", and this is not a style
choice.** Measured on this hardware: for the first second or two of a shell's
life UPower has no devices at all, NetworkManager reports `Unknown`
connectivity, and `canCheckConnectivity` is false. A gate that failed closed
would swallow the first fetch after every shell start — the one fetch that fills
an empty panel.

---

## 6. Several Services, one account

`Service.qml` is instantiated by the bar widget *and* by the window, and the bar
is one surface per monitor. A two-monitor desktop with the window open therefore
has three Services, each with its own poll timer, all asking about the same
account — in a burst, which is what an API answers with a 429 rather than
averaging out.

The three plugins are at three different points on this problem, and this is the
sharpest divergence between them:

| Plugin | Approach | State |
|---|---|---|
| **Mail** | `kinds: ["service"]` singleton `Store.qml` — one per plugin, built by the shell. All shared state lives there; per-host view state stays in `Service.qml`. | Solved |
| **Slack** | No singleton. `cmd_fetch` takes a `FetchSlot` — an `flock` on `fetch.lock` in the cache — and whoever finds it taken waits and is handed the snapshot the holder wrote, marked `cached`. | Solved differently, in the helper |
| **Teams** | Neither. Three Services poll three times an interval. | **Open** |

Two consequences of Slack's approach are worth stating because each was a bug on
the way there:

- **Pacing inside the helper is per process.** One helper run cannot see another
  run's requests. Only the lock can.
- **A shared snapshot must not be chased.** Answering `cached: true` by
  re-polling with `maxAge: 0` would not terminate: every answer comes back
  shared and asks for one more. Slack re-polls only when the snapshot it was
  handed is older than a whole interval.

The mail plugin's rule, stated plainly: **do not add a poll outside the store.**
Fetching is keyed by mailbox *and* folder, and requests for one mailbox run one
at a time — a fetch is also a token refresh and Entra rotates refresh tokens, so
two at once risks an avoidable sign-in.

---

## 7. Window IPC contract

```
omarchy-shell shell summon <plugin-id> '<json>'    →  Window.open(payloadJson)
omarchy-shell shell call   <plugin-id> <method> <arg>  →  any method on the window
omarchy-shell shell toggle <plugin-id>             →  the window
```

`open(payloadJson)` hands its payload to `applyPayload(payload)`. Two rules bind
every payload key, present and future:

1. **The shell drains its payload queue in a loop** and delivers to a window
   that is already open. Anything added must **survive arriving twice**.
2. **It must not throw away work in progress** — a draft being typed, a
   half-written reply.

`agentDraft(argJson)` is the same draft route reachable by name through `call`,
and it **returns what it made of the payload** so a caller can tell whether it
landed.

### 7.1 Payload keys

| Plugin | Reveal a message | Draft |
|---|---|---|
| Mail | `account`, `folderId`, `messageId` (+ `instance`, `action`) | `draft` |
| Slack | `conversation`, `thread`, `message` | `draft` |
| Teams | `chat` — or `team` + `channel` — and `message` | `draft` |

**A message in a folder or conversation not yet loaded cannot be revealed at
once.** All three keep the request pending (mail: `pendingMessageId` plus a
`Connections` on the list) and answer it when the fetch lands.

### 7.2 `toggle` reaches the window, never the dropdown

The shell decides where `summon` / `toggle` / `hide` go from the manifest's
`kinds`, and `isBarWidgetPanelPlugin()` returns false for anything that is
*also* a `panel` kind. All three are both, so `toggle <plugin-id>` **always
means the window and can never reach the dropdown.** The widget's
`opened`/`open`/`close` shape exists for the bar's own click-away and popout
coordination, not for that route.

A keybinding onto the dropdown therefore needs the panel's own `IpcHandler`,
which is what `ipcTarget` names.

---

## 8. The coding-agent handover

`src/handover.sh` builds a prompt and execs `omarchy-agent`. It is runnable by
hand, and `--print` shows the prompt and launches nothing.

**No message text leaves the window.** The agent is told which account and which
message, and reads it through the same helper the window uses —
`skills/omarchy-<plugin>/SKILL.md` is what it is pointed at.

The skill carries two standing rules for the agent:

1. **It does not send.** Reading is the agent's to do; anything other people
   will see is the user's decision each time. The agent drafts into the window
   (via `draft` / `agentDraft`) and the user presses send. It sends directly only
   when that specific message is the user telling it to.
2. **Read `ok` before trusting the rest.** `auth_required` means only the user
   can fix it, from the window.

**`agentHandover` is one setting away from not existing**, and it gates all four
of: the `a` key, the button, the help entry, and the **inbound** draft. A feature
that reaches somebody's mail or somebody else's messages has to be refusable, so
check the gate rather than assuming it.

`agentArgv()` is deliberately split out of `askAgent()` so the handover can be
exercised without an agent actually starting.

---

## 9. UI conventions

- **Colours and spacing come from `qs.Commons`** (`Color`, `Style`, `Border`).
  No hardcoded hex, no hardcoded pixel gaps. Use `Style.space()` and — in Slack
  and Teams — the density scale, so the window follows the theme's font size.
- **The window is a `FloatingWindow`** — a real Hyprland toplevel, tiled like
  anything else. It has **no app id of its own**, so its `title` is the only
  handle a Hyprland window rule has on it.
- **The dropdown fetches nothing.** It binds to the Service the bar icon already
  owns, so opening it costs no request.
- **The dropdown offers every action the window does** and performs none of the
  hard ones. A pane that silently has five fewer buttons than the same pane
  elsewhere is a difference nobody can explain. Mail's `Panel.qml` sets
  `canCompose`/`canMove`/`canAgent` like the window plus `actsHere: false`,
  which puts "opens the window on it" in those tooltips; the buttons call
  `handOff`, which summons the window with an `action` the window runs once its
  fetch lands.
- **Capability is read back, never assumed.** The UI says "this token cannot
  search" rather than offering a search that 403s. A new capability means a new
  capability check.

### 9.1 Keymap

Shared across all three:

| Key | Meaning |
|---|---|
| `j` / `k` | Down / up in whatever has focus |
| `h` / `l` | Out a step / in a step |
| `Enter` | Open, and follow it in |
| `Esc` | Back one step, ending at closing the window |
| `Page up`/`down`, `Ctrl-d`/`Ctrl-u`, `Ctrl-f`/`Ctrl-b` | Screen, half screen, screen |
| `g` / `G` | Top / bottom |
| `a` | Hand to the coding agent (gated on `agentHandover`) |
| `r` | Refresh / reload |
| `u` | Show only unread |
| `?` | The key help; `Esc` closes it |

Slack and Teams additionally share `Tab`/`i` (straight to the message box),
`e` or `+` (react), `1`–`n` (pick that reaction), `s`/`o` (in a picture: save /
open elsewhere), `Shift+Enter` (send), and `,` (settings).

### 9.2 Lists

**Divergence, and a measured one.** Slack and Teams draw every list — the
transcript included — as a `Repeater` inside a `ScrollView`. Every row is
instantiated, and **every row is rebuilt whenever the array is replaced**. A
`ListView` over a plain JS array recreates *all* of its delegates when the array
changes, so `reuseItems` alone buys nothing.

Making a long conversation cheap needs a model that diffs, and there are two,
neither free:

- `Quickshell.ScriptModel` (`values` plus `objectProp: "id"`) diffs for you but
  exposes only `modelData` — every `required property string foo` in the delegate
  becomes `modelData.foo`, and a delegate that outlives its row during a remove
  transition then reads through a null, so the last non-null row has to be kept.
- A `ListModel` with the diff written by hand.

**Mail chose the second, deliberately** — `MailList.qml`, and the comment at the
top of it says why a `Repeater` over a plain array was worse. Slack and Teams
have not made that change. If you are porting UI between them, port this too.

---

## 10. Development contract

Every repo carries the same harness shape:

```bash
node    dev/test-model.js          # the shaping the UI binds to
python3 dev/test-<plugin>.py       # parsing, transports, permission, host checks
python3 src/<helper>.py fetch --account work --demo
dev/run.sh                         # the real UI, offscreen
dev/shot.sh /tmp/out.png           # photograph what it is drawing
dev/showcase.sh                    # regenerate the README images
```

- **`dev/link.sh` assembles the harness outside the repo**, in
  `$XDG_RUNTIME_DIR/omarchy-<plugin>-dev`, and symlinks the sources into it. It
  has to: Quickshell only imports modules from inside its own config folder, so
  `Commons/` and `Ui/` from `/usr/share/omarchy/shell/` must sit beside a
  `shell.qml` — and **no symlink may exist anywhere in the repo**, because
  `omarchy plugin validate` refuses a plugin folder containing one.
- **Those links point back into the repo, so writing to the stage writes to the
  repo.** A scratch harness saved as `$STAGE/shell.qml` goes straight through the
  symlink and overwrites `dev/shell.qml`. Give a throwaway one any other name.
- **A syntax check across the repo**, not on `$PATH`:
  `/usr/lib/qt6/bin/qmlformat src/*.qml >/dev/null` — silence means they all
  parse. A bare `qmlformat` is "command not found", and inside a loop with
  `|| echo FAIL` that reads as every file being broken.
- **`dev/run.sh` never touches your `shell.json`**, which is what makes it safe
  to run while you are using the real thing. `dev/showcase.sh` does swap it, and
  puts it back on the way out including on failure or Ctrl-C.
- **`ipc call dev state`** prints what the Service thinks is going on, and is the
  first thing to ask when the UI comes up empty.
- **The harness applies fixture settings from `onSettingsLoadedChanged` through a
  `Qt.callLater`, and both halves matter.** The window sets `settingsLoaded`
  *before* assigning the settings it just read from the bar layout, so fixtures
  applied inline are overwritten one line later — and a plain timer racing that
  read wins only *most* of the time, which is how a harness ends up quietly
  showing your real account instead of the fixtures.

### 10.1 Installed-copy edits need a real restart

`omarchy-shell shell reloadConfig` and `rescanPlugins` **both return ok without
re-reading plugin QML** or a widget's entry in `shell.json`. Run
`omarchy-restart-shell` and confirm the PID moved
(`pgrep -af 'quickshell -n'`).

A surviving PID also proves the QML parsed — a fatal QML error makes it exit
instead.

### 10.2 What no linter catches

- **A name that resolves to nothing is not a parse error.** It throws when the
  binding runs. **A binding sees its own object, the root of its own file, and
  the ids in that file — and nothing else:** a property declared on an unnamed
  object in between is not in scope, however directly it encloses the binding.
  Unqualified, it throws once per binding into the shell's log and leaves
  whatever depended on it undrawn. Reading the log is the only way this
  announces itself:

  ```bash
  journalctl --user -t omarchy-shell -n 200 --no-pager | grep -i "$PWD"
  ```

- **QML takes one handler per signal per file.** Adding `onSomethingChanged:`
  beside an existing one does not chain them; it is the same property assigned
  twice and the file will not load at all — reported as
  `Type X unavailable / Property value set multiple times`, whose first line
  names whatever tried to *use* the broken file rather than the two lines that
  disagree. Neither `qmlformat` nor `qmllint` says a word about it.

- **The offscreen harness runs the software scene graph**, so a shader path is
  invisible to every screenshot in these repos. `QT_QPA_PLATFORM=offscreen`
  forces it whatever `QSG_RHI_BACKEND` says. A `ClippingRectangle` cannot be
  photographed here at all, and one drew *no picture* on real hardware for a
  whole release while every shot in the repo looked right. Test a shader path in
  a real shell, not in the harness.

---

## 11. House style

Comments and prose explain **why**, never what. Full sentences. A comment that
restates the line below it does not survive review. State plainly what would
otherwise only live in the git log, including the uncomfortable parts.

The README is written for a person deciding whether to install the plugin, and
says plainly what it **does not** do.

**Keep the work inside the app.** When something cannot be finished here, that
is the bug — not a reason to hand the user off to Outlook, a browser, or the
Teams web app.
