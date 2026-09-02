---
name: omarchy-slack
description: Read and answer a Slack conversation through the Omarchy Slack plugin's own helper, and put a draft reply back into its window instead of posting it. Use when handed a workspace alias and a conversation id by the plugin's handover, or when asked about a Slack channel, DM or thread on this machine.
---

# Slack, through the Omarchy plugin

The plugin is a Quickshell window on top of one Python helper. The helper holds
the token and makes every network call; you drive the helper. There is no other
Slack access on this machine and no browser session to fall back on.

    HELPER=~/.config/omarchy/plugins/janrenz.omarchy.slack/src/slack.py

Every command needs `--account <alias>` — the workspace name from the widget's
settings, e.g. `work`. `python3 $HELPER list` names the ones that are set up.

## Two rules

1. **You do not post.** Reading is yours to do; anything that other people will
   see — a message, a reaction, a read receipt — is the user's decision each
   time. Draft an answer into the window (below) and let them press send. Post
   directly only when this specific message is the user telling you to.
2. **Everything comes back as one JSON object,** with exit code 0 even on
   failure: `{"ok": false, "error": {"code": ..., "message": ...}}`. Read
   `ok` before you trust the rest. `"code": "auth_required"` means the token is
   gone and only the user can fix it, from the window.

## Reading

    python3 $HELPER messages  --account work --channel C0123 --top 40
    python3 $HELPER messages  --account work --channel C0123 --thread 1712345.0002
    python3 $HELPER fetch     --account work --conversations 40 --sort recent
    python3 $HELPER search    --account work --query "in:#design deploy" --top 20
    python3 $HELPER directory --account work --query "renz"
    python3 $HELPER presence  --account work --user U0123
    python3 $HELPER canvas    --account work --channel C0123

`messages` is the transcript the user is looking at: newest last, each row with
`ts`, the author, the text already flattened out of Slack's mrkdwn, reactions
and thread counts. `--thread <parent ts>` gives one thread's replies instead —
if the handover named an open thread, that is what is on screen. It also says
`canvasFileId` when the channel keeps a canvas.

`canvas` is that document, as text with its links as offsets into it — the
charter or runbook pinned to the top of a channel, which is often where the
convention a message is arguing about is actually written down. `--file <id>`
skips the lookup when `messages` already named one, and an answer with
`"canvas": null` means the channel keeps none.

`fetch` is the sidebar: which conversations exist, what is unread. It is served
from a cache the window keeps warm, so it is cheap; `--fresh` forces the
request and is rarely what you want.

Slack's rate limits are tight for a personal app — roughly one
`conversations.history` a minute plus a small burst. Read one conversation, not
twenty, and prefer `search` over walking channels.

## Handing a draft back to the window

This is the point of the handover. The window opens if it is closed, the text
lands in the message box, focused, unsent:

    omarchy-shell shell summon janrenz.omarchy.slack \
      '{"draft":{"channel":"C0123","text":"Ich schaue morgen früh drauf."}}'

Optional `"thread"` with a parent `ts` puts the draft in that thread's reply
box. The reply is written into the conversation you name, so pass the channel
the handover gave you.

It prints `ok`, or `unknown` when the plugin is not loaded, is disabled, or has
its "Hand a conversation to your coding agent" setting switched off — that
setting also refuses drafts, deliberately. Say so rather than posting instead.

Write the draft in the language of the conversation. Keep it as short as the
thing being answered.

## Only when asked

    printf '%s' '{"text":"..."}' | python3 $HELPER send --account work --channel C0123 --stdin
    python3 $HELPER react     --account work --channel C0123 --ts 1712345.0002 --emoji thumbsup
    python3 $HELPER mark-read --account work --channel C0123 --ts 1712345.0002

`send` takes the text on **stdin**, never in `--text`: anyone on this machine
can read another process's command line. Add `--thread <ts>` to reply in a
thread, `--broadcast` to have that reply also show in the channel.

A file goes with the same rule - the path and the comment on stdin:

    printf '%s' '{"file":"~/Downloads/plan.pdf","comment":"..."}' \
      | python3 $HELPER upload --account work --channel C0123 --stdin

Sending a file needs `files:write`; `login-status` says whether the token has
it. This is the one write where the user has usually already told you the path,
so read the path back to them before you send it - a wrong file in a channel
cannot be taken back.

`--demo` on any command answers from fixtures and posts nothing. It is the safe
way to check a command's shape when you are unsure.

What the token may actually do is reported by `login-status --account work` and
by the `capabilities` in a `fetch`. A token without `search:read` cannot search;
say that rather than retrying.
