# GAPS.md — Slack for Omarchy

**Companion to [`SPEC.md`](SPEC.md).** That file says what the plugin does; this
one says what it does not do *that it arguably should*, and where the spec has no
answer at all.

Written 2026-09-04 against version 0.8.0. Every finding carries the evidence it
was drawn from, so it can be re-checked rather than believed.

## How to read this

| | |
|---|---|
| **Gap** | Behaviour or a contract that is missing, and whose absence is not a stated decision |
| **Divergence** | Something two of the three plugins do and this one does not |
| **Unspecified** | Code decides it; no document says what the decision should be |

**Severity is about consequence, not effort.** `high` means it can lose data,
leak a credential, or break a stated invariant. `medium` means a user meets it.
`low` means a maintainer meets it.

## What is *not* in here

`README.md` → *What it does not do* lists **deliberate non-goals**, and they stay
that way: no live updates, nothing quieter than a fortnight getting a preview,
an unread count that is counted low rather than high, muted channels not muted,
workspace emoji staying as their names, no huddles or calls or workflows, one
workspace per install, a canvas written whole or not at all. `SPEC.md` §13
records them. **Do not re-raise them as findings.**

Nor is the rate limit a gap. It is the design constraint the whole plugin is
shaped around (`SPEC.md` §2), and the shape is the right one.

---

## SLACK-1 — The lock shares the fetch but not the read state · `medium` · Gap

`FetchSlot` (`SPEC.md` §2.4) solved duplicate polling, and solved it better than
a QML singleton would have — it covers the window and a manual refresh too. **It
does not share UI state, and one piece of UI state needs sharing.**

Marking a conversation read in the window ends at
`Service.qml:947` `markReadProc.onExited`, which calls `root.refresh()` — its
**own** Service. The bar widget's Service is a different instance and is told
nothing. It picks the change up when its own timer next fires and the helper
hands it the newer snapshot.

So: **after the window marks a conversation read, the bar icon can keep showing
it unread for up to one `refreshIntervalSec` — 120 seconds by default.**

This is precisely the bug the mail plugin's `Store.qml` was created to fix. Its
`AGENTS.md` records the same symptom in the same words: the several Services
*"polled one mailbox two or three times over and left the bar showing a message
unread after the window marked it read."* Mail's store therefore holds an
**optimistic read/flagged/deleted overlay** keyed by owner (`overrideOwner`,
`setOverride`, `pruneOwnedOverrides`) so both hosts agree at once.

Stated as by-construction rather than confirmed, because it needs two surfaces to
observe. **To test it:** two monitors, or the window plus one bar, on an interval
long enough to see — set `refreshIntervalSec` to 600, mark a conversation read in
the window, watch the bar's unread count.

**What the spec should say:** whether an optimistic overlay belongs in this
plugin too, and if so where it lives given there is no singleton to hold it — a
cache file the helper reads back, or a shared `Quickshell.Singleton`, or the
`service` kind after all. `PLATFORM.md` §6 presents the lock and the singleton as
two solutions to one problem; they are actually solutions to two, and only mail
has both.

---

## SLACK-2 — Lists are `Repeater`s; mail's diffing model was never ported · `medium` · Divergence

`AGENTS.md` states it plainly and then does not act on it:

> **`MailList.qml` is a `ListView` on purpose**, and the comment at the top says
> why a `Repeater` over a plain array was worse. The Slack and Teams plugins have
> not made that change yet; if you are porting UI between them, port this too.

Every list here — the transcript included — is a `Repeater` inside a
`ScrollView`. Every row is instantiated, and every row is rebuilt whenever the
array is replaced. That second half is measured, not assumed: a `ListView` over a
plain JS array recreates *all* of its delegates when the array changes, so
`reuseItems` alone buys nothing.

Mail solved it with a hand-diffed `ListModel`, deliberately choosing that over
`Quickshell.ScriptModel` — the trade is written up in `PLATFORM.md` §9.2.

The cost lands on the two things this plugin is best at: a long transcript, and a
sidebar of 403 DMs.

**What the spec should say:** which model the transcript uses, and why. The
analysis is already done and written down in two repos; what is missing is the
decision.

---

## SLACK-3 — `demo` is load-bearing and unspecified · `medium` · Unspecified · shared: `PLAT-3`

`Service.qml:31` reads `setting("demo", false)`, and `demo` is what makes every
write a no-op — `enqueueMark` returns early on it, `send` appends `--demo`,
`upload` and `react` likewise. It appears in **no** manifest schema in any of the
three plugins:

```
caseonline.omarchy.office365/manifest.json   occurrences of "demo": 0
janrenz.omarchy.slack/manifest.json          occurrences of "demo": 0
janrenz.omarchy.teams/manifest.json          occurrences of "demo": 0
```

So it cannot be set from the settings panel, is not documented as a setting, and
escapes the rule in `PLATFORM.md` §3 that adding a setting means adding it to the
manifest *and* reading it through `setting()`. `demoOpen` is in the same
position.

The mail plugin has already been bitten by exactly this: a harness whose fixture
alias was a real signed-in mailbox pressed Send and made a real API request, and
only a malformed id stopped it.

**What the spec should say:** either `demo` is a real setting with a schema entry
saying plainly what it disables, or it is a harness-only override read from
somewhere that is not the widget's settings — and the choice is stated.

---

## SLACK-4 — Thread read marks are per-machine, and nothing says so · `low` · Unspecified

`SPEC.md` §4.2 records that reading a thread is marked locally because Slack has
no method for it: `thread-read` writes `threads.json` in the cache and
`apply_thread_marks` reads it back.

**What follows from that is not written down anywhere the user can see it:** the
mark lives on this machine only. A thread read here still shows "new" on another
machine running the same plugin, and the `remove` command — which forgets *"a
workspace and everything cached about it"* — silently discards every thread mark
with it.

`README.md` → *Which threads are unread* explains the mechanism. It does not say
the marks are local, or that they are lost on sign-out.

**What the spec should say:** thread marks are per-machine and per-install, they
are lost by `remove`, and there is no route to sync them because Slack exposes
none. That is a fine answer; it is just not on the page.

---

## SLACK-5 — A `.bak` file sits inside `src/` and `.gitignore` does not cover it · `low` · Gap

```
$ git status --porcelain
 M src/SlackWindow.qml
?? src/SlackWindow.qml.bak.1788421173

$ cat .gitignore
*.log
__pycache__/
*.pyc
```

`src/SlackWindow.qml.bak.1788421173` is 2921 lines of a previous
`SlackWindow.qml` sitting in the directory `manifest.json` points its entry
points at. It is untracked, so it will not be published by accident — but
`omarchy plugin validate` inspects the plugin *folder*, and an installed copy is
the folder, not the git tree.

Mail's `.gitignore` is `__pycache__/` and `*.pyc` only, and mail has the same
timestamped-backup habit visible across `~/.config/hypr`.

**What the spec should say:** `*.bak*` is ignored, and backups do not live under
`src/`. A one-line fix, listed because the alternative is finding it in a
published tarball.

---

## PLAT-1 — Shared components are copies, and they have drifted · `medium` · Divergence

Line-counts of `diff` output between the three repos' copies of the same file:

| File | slack↔teams | mail↔slack | mail↔teams |
|---|---|---|---|
| `src/config.py` | **2** | 219 | 219 |
| `src/SelectableText.qml` | **2** | 14 | 14 |
| `src/ImageViewer.qml` | **4** | n/a | n/a |
| `src/Notifier.qml` | 12 | 20 | 10 |
| `src/PollGate.qml` | 14 | 4 | 10 |
| `src/LabeledField.qml` | 7 | 28 | 21 |
| `src/handover.sh` | 54 | — | — |
| `src/Model.js` (first 190 lines) | 48 | — | — |

`config.py` differs from Teams' copy by **exactly one line** across 151 — the
default `--plugin-id`. `SelectableText.qml` by two. `ImageViewer.qml` by four.

`Model.js`'s first ~190 lines are the same helpers in both — `parseJson`,
`oneLine`, `plainText`, `escapeHtml`, `safeHref`, `anchor`, `linkify`,
`usableSpans`, `autoLinked`, `densityScale` — with 48 lines of drift. Most is
comment wording. Some is real: `reactionIsMine` keys on `name` here and on
`emoji` in Teams, because the two APIs name the field differently.

That last one is the shape of the risk. **A shared function with a
plugin-specific key is a function that looks portable and is not**, and nothing
marks it.

**No mechanism and no document says which copy is canonical.** The redirect
guard, the poll gate and the link builder each have to be fixed three times by
somebody who knows all three repos have them.

**What the spec should say:** either a canonical source and a sync step in the
release ritual, or an explicit decision that these are forks and drift is
accepted. `PLATFORM.md` describes the shared contract without saying who owns the
shared code.

---

## PLAT-2 — Three answers to the several-Services problem, and no platform decision · `medium` · Unspecified

`PLATFORM.md` §6 records the state: mail uses a `kinds: ["service"]` singleton,
this plugin uses an `flock` in the helper, Teams uses neither.

All three are defensible, and **this plugin's `AGENTS.md` contains the best
argument in the set** — the lock *"holds for the window and for a manual refresh
too, which a QML singleton would not have covered"*, and *"the count of services
no longer sets the count of polls."* That is a real case that the singleton is
the weaker answer.

It has never been written down as a platform choice, and see `SLACK-1`: the two
approaches are not solutions to one problem but to two, and only mail has both.

**What the spec should say:** which is the platform's answer for a fourth plugin,
what the other is for, and that a plugin needing shared *UI* state needs
something the lock does not give it.

---

## Summary

| ID | Severity | Class | One line |
|---|---|---|---|
| SLACK-1 | medium | Gap | The bar can show unread for up to 120s after the window marked it read |
| SLACK-2 | medium | Divergence | Lists are `Repeater`s; mail's diffing model was never ported |
| SLACK-3 | medium | Unspecified | `demo` makes every write a no-op and is in no manifest |
| SLACK-4 | low | Unspecified | Thread marks are per-machine and lost by `remove`; unsaid |
| SLACK-5 | low | Gap | A 2921-line `.bak` inside `src/`, uncovered by `.gitignore` |
| PLAT-1 | medium | Divergence | Shared components are copies with silent drift; no canonical source |
| PLAT-2 | medium | Unspecified | Three answers to the several-Services problem, no platform decision |
