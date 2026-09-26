# Slack on GNOME

Notes for building a GNOME version, written on the Omarchy machine so the work can start
on the GNOME one without starting from zero. **Nothing here is built yet.**

## Why it does not simply run there

GNOME is Wayland too, but that is not the question. Omarchy's bar is a
Quickshell `PanelWindow`, and a panel needs the **`wlr-layer-shell`** protocol:
the one that lets a client say "I am a bar, pin me to the top edge, reserve my
height, keep me above everything". Hyprland, Sway, KDE and COSMIC implement it.
**Mutter does not**, and has declined to for years
([mutter#973](https://gitlab.gnome.org/GNOME/mutter/-/issues/973),
[gnome-shell#1141](https://gitlab.gnome.org/GNOME/gnome-shell/-/issues/1141)).
On GNOME only the shell draws the top bar, and anything that wants a place in
it is a **GNOME Shell extension** — GJS and St, not QML.

A Quickshell `FloatingWindow`, on the other hand, is an ordinary xdg toplevel,
and runs on GNOME like any other window.

## What carries over unchanged

Most of it — the architecture in `PLATFORM.md` §1 already has the seam in the
right place:

- **`src/slack.py`** — Python stdlib only, one JSON object per call
  (`PLATFORM.md` §2). Sign-in, tokens, every network call. It has no idea what
  desktop it is on, and should stay that way.
- **`src/Model.js`** — `.pragma library`, no Qt types, already runs under plain
  `node`. A GNOME extension can load the same file (a thin wrapper for the
  pragma and an `export`), so labels, grouping and unread logic are not
  written twice.
- **The window** (`src/SlackWindow.qml` and everything under it) — a `FloatingWindow`,
  so it runs under Quickshell on GNOME, given the few things below.

## What has to be replaced

| Omarchy / Hyprland | Where | GNOME |
|---|---|---|
| `qs.Commons`, `qs.Ui` | every QML file; `dev/link.sh` symlinks them from `/usr/share/omarchy/shell/`, which does not exist there | A small `Commons` of our own with the handful of tokens actually used (`Style.font/spacing/space/cornerRadius`, `Color.foreground/background/accent/urgent`), fed from `org.gnome.desktop.interface` `color-scheme` and `accent-color` |
| The `palette` helper command | reads the Omarchy theme file | Fall back to the GNOME values above when there is no Omarchy theme |
| `Hyprland.toplevels`, `Hyprland.dispatch` | `SlackWindow.qml` — find and focus the existing window | Not needed: a single window process raises itself when asked over IPC. GNOME gives no client a way to focus another's window, so do not try |
| `omarchy-shell shell summon/toggle/call` | `Service.qml`, handover, bar → window | The standalone window's own Quickshell IPC (`qs -p … ipc call`) |
| `omarchy-notification-send` | `Notifier.qml` | `notify-send` / `org.freedesktop.Notifications`; click actions work, but the hint Omarchy uses (`omarchy-exec-argv`) does not exist |
| `omarchy-agent` (`src/handover.sh`) | agent handover | Open a terminal with `claude` in it, or leave the feature off on GNOME |
| `SUPER+G` / the Omarchy menu | keybinding | A GNOME custom keybinding (`gsettings … custom-keybindings`) and a `.desktop` entry |
| **Bar widget + dropdown** | `BarWidget.qml`, `BarPanel.qml` | **A GNOME Shell extension** — the only part that is a rewrite |

Slack specifics:

- **Sign-in comes back over `omarchy-slack://`**: `slack.py` writes
  `omarchy-slack-auth.desktop` and registers it as the handler, `src/authcb`
  delivers the callback. That is plain XDG and works on GNOME unchanged.
  The scheme string itself is in the **redirect URLs of the Slack app this
  plugin ships** — do not rename it without changing that app first, or every
  sign-in breaks.

## Proposed shape

```
gnome/
  extension/<uuid>/   metadata.json, extension.js — icon in the top bar, tint on
                      unread, a PopupMenu of what is waiting; runs the helper
                      through Gio.Subprocess, a row launches the window at that
                      conversation
  app/                shell.qml hosting the real window, Commons/, a .desktop
                      entry, install.sh
```

Two things get simpler rather than harder: GNOME has one top bar, so the
per-monitor multiplication of the bar widget (`PLATFORM.md` §1.1, §6) does not
happen, and one extension instance is the obvious single poller.

Everything keeps living in this repo, on `dev`, so a helper fix found on GNOME
lands for Omarchy too.

## Check first, on the GNOME machine

- `gnome-shell --version` — the extension API moved to ES modules in 45 and
  keeps shifting; target the version that is there, and say so in `metadata.json`.
- Is Quickshell available? AUR on Arch; on Fedora/Ubuntu it has to be built.
- `python3` — the helpers need nothing beyond the standard library.

## Naming — an open question, deliberately not decided yet

Once this runs on GNOME too, "omarchy" in the name is no longer the whole
truth. Renaming is still left until a GNOME build actually exists, because the
name lives in more places than the repo, and not all of them are cheap:

- **The GitHub repo** — cheap. GitHub redirects the old URL, clones keep working.
- **The plugin id** (`manifest.json` `id`) — expensive. A marketplace listing
  and every user's entry in `~/.config/omarchy/shell.json` are keyed on it.
  Keep it; it only ever means something to Omarchy anyway.
- **State and cache paths** (`~/.local/state/omarchy/…`, `~/.cache/omarchy/…`)
  — a rename signs everybody out unless the old path is migrated.
- **Anything registered elsewhere** — redirect schemes, app registrations,
  `User-Agent` strings — see the specifics above.

The likely answer: rename the repo (and the README's headline) when the GNOME
part lands, keep the plugin id, and give the GNOME extension its own uuid.
