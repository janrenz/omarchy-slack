#!/usr/bin/env node
// Tests for Model.js - the shaping the window binds to.
//
//   node dev/test-model.js
//
// Model.js is deliberately free of Qt types so it can be run here: the sidebar
// grouping, the message blocks, the link building and the time labels are all
// decisions worth checking without a compositor in the way.

const fs = require("fs")
const path = require("path")

const source = fs
  .readFileSync(path.join(__dirname, "..", "src", "Model.js"), "utf8")
  .replace(".pragma library", "")

const Model = new Function(
  source +
    "; return { accountView, conversationRows, conversationRow, selectableRows, groupMessages, " +
    "whenLabel, dayLabel, subtitleFor, oneLine, plainText, parseJson, linkify, hasLink, " +
    "escapeHtml, usableSpans, safeHref, densityScale, densityNames, sortNames, reactionIsMine, " +
    "presenceColor, presenceLabel, presenceWanted, presenceWantedFromRows, " +
    "switcherRows, searchRows, fileLabel, " +
    "threadLabel, coverageLabel, previewMarkdown, canvasNote }"
)()

let passed = 0
const failures = []

function test(name, body) {
  try {
    body()
    passed++
  } catch (error) {
    failures.push(name + ": " + error.message)
  }
}

function eq(actual, expected, what) {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) throw new Error((what || "") + " expected " + b + " got " + a)
}

function ok(value, what) {
  if (!value) throw new Error(what || "expected truthy")
}

const snapshot = (accounts) => ({ accounts })

const dm = (over) => Object.assign({
  id: "D1", kind: "im", title: "Priya Raman", lastFrom: "Priya Raman",
  lastText: "Can you look at the deploy?", when: "2026-09-01T09:00:00Z",
  ts: "1788252000.0", unread: false, unreadCount: 0, presence: { state: "active" },
  avatar: "", private: false, current: true, topic: ""
}, over || {})

const channel = (over) => Object.assign({
  id: "C1", kind: "channel", title: "#platform", lastFrom: "Tomás",
  lastText: "Rolling back", when: "2026-09-01T08:00:00Z", ts: "1788248400.0",
  unread: false, unreadCount: 0, presence: null, avatar: "", private: false,
  current: true, topic: "Keeping the lights on"
}, over || {})

// ---------------------------------------------------------------- accountView

test("a workspace that answered is a loaded view", () => {
  const view = Model.accountView(snapshot([{ alias: "work", ok: true, team: "Example",
    dms: [dm()], channels: [channel()], unreadCount: 1, post: true, search: false }]), "work")
  ok(view.ok, "ok")
  ok(view.loaded, "loaded")
  eq(view.team, "Example")
  eq(view.canPost, true, "canPost")
  eq(view.canSearch, false, "canSearch")
  eq(view.dms.length, 1)
})

test("a workspace nobody asked about is an empty view rather than a crash", () => {
  const view = Model.accountView(snapshot([{ alias: "other", ok: true }]), "work")
  eq(view.ok, false)
  eq(view.loaded, false)
  eq(view.dms, [])
  eq(view.canPost, false, "capabilities default to off")
})

test("a refusal carries its code so the window can act on it", () => {
  const view = Model.accountView(snapshot([
    { alias: "work", ok: false, error: { code: "auth_required", message: "Not signed in" } }]), "work")
  eq(view.errorCode, "auth_required")
  eq(view.errorMessage, "Not signed in")
})

test("a capability the helper stops reporting quietly switches the feature off", () => {
  const view = Model.accountView(snapshot([{ alias: "work", ok: true }]), "work")
  eq(view.canReact, false)
  eq(view.canMarkRead, false)
})

// ------------------------------------------------------------ conversationRows

const view = Model.accountView(snapshot([{
  alias: "work", ok: true,
  dms: [dm(), dm({ id: "D2", title: "Dana Okafor", unread: true, unreadCount: 3 })],
  channels: [channel(), channel({ id: "C2", title: "#design", lastText: "" })]
}]), "work")

test("each section gets a heading, and only when it has rows", () => {
  const rows = Model.conversationRows(view, {})
  eq(rows[0].kind, "heading")
  eq(rows[0].title, "Direct messages")
  eq(rows.filter(r => r.kind === "heading").map(r => r.title),
     ["Direct messages", "Channels"])
  eq(rows.filter(r => r.kind === "conversation").length, 4)
})

test("direct messages lead, because a DM is a tap on the shoulder", () => {
  const rows = Model.conversationRows(view, {}).filter(r => r.kind === "conversation")
  eq(rows[0].title, "Priya Raman")
  eq(rows[2].title, "#platform")
})

test("unread-only keeps what is waiting and says so when nothing is", () => {
  const rows = Model.conversationRows(view, { unreadOnly: true })
  eq(rows.filter(r => r.kind === "conversation").map(r => r.title), ["Dana Okafor"])

  const quiet = Model.conversationRows(Model.accountView(snapshot([
    { alias: "work", ok: true, dms: [dm()], channels: [] }]), "work"), { unreadOnly: true })
  eq(quiet.length, 1)
  eq(quiet[0].kind, "note")
  eq(quiet[0].title, "Nothing unread")
})

// A DM the helper padded the section out with has no date on it: nothing has
// been said in it lately. Those fold behind one row.
const quietDm = (id, title) => dm({ id, title, when: "", ts: "", lastText: "" })

const folding = (dms, options) => Model.conversationRows(Model.accountView(snapshot([
  { alias: "work", ok: true, dms, channels: [] }]), "work"), options || {})

test("direct messages with nothing said in them lately fold behind one row", () => {
  const rows = folding([dm(), quietDm("D8", "Yuki Tanaka"), quietDm("D9", "Ana Beltrán")])
  eq(rows.filter(r => r.kind === "conversation").map(r => r.title), ["Priya Raman"])
  const more = rows.filter(r => r.kind === "more")
  eq(more.length, 1)
  eq(more[0].title, "Show 2 more")
  eq(more[0].expanded, false)
})

test("unfolding shows every one of them, and offers the way back", () => {
  const rows = folding([dm(), quietDm("D8", "Yuki Tanaka")], { showAllDms: true })
  eq(rows.filter(r => r.kind === "conversation").map(r => r.title),
     ["Priya Raman", "Yuki Tanaka"])
  eq(rows.filter(r => r.kind === "more")[0].title, "Show fewer")
})

test("unread is never folded away, dated or not", () => {
  // A date is not what makes a direct message matter.
  const rows = folding([dm(), dm({ id: "D8", title: "Dana Okafor", when: "", ts: "",
                                   unread: true, unreadCount: 2 })])
  eq(rows.filter(r => r.kind === "conversation").map(r => r.title),
     ["Priya Raman", "Dana Okafor"])
  eq(rows.filter(r => r.kind === "more").length, 0)
})

test("a section that is nothing but quiet ones is left alone", () => {
  // "Show 12 more" over an empty section says less than the twelve names do.
  const rows = folding([quietDm("D8", "Yuki Tanaka"), quietDm("D9", "Ana Beltrán")])
  eq(rows.filter(r => r.kind === "conversation").length, 2)
  eq(rows.filter(r => r.kind === "more").length, 0)
})

test("asking for a subset already is asking for all of it", () => {
  // A filter and the unread toggle are somebody naming what they want; folding
  // half of the answer away is the opposite of answering.
  const dms = [dm(), quietDm("D8", "Yuki Tanaka")]
  eq(folding(dms, { filter: "yuki" }).filter(r => r.kind === "more").length, 0)
  eq(folding(dms, { filter: "yuki" }).filter(r => r.kind === "conversation")
       .map(r => r.title), ["Yuki Tanaka"])
  eq(folding(dms, { unreadOnly: true }).filter(r => r.kind === "more").length, 0)
})

test("the fold is something the cursor can land on and press Return on", () => {
  const rows = folding([dm(), quietDm("D8", "Yuki Tanaka")])
  const landable = Model.selectableRows(rows)
  eq(landable.map(i => rows[i].kind), ["conversation", "more"])
})

test("what is not in the payload at all is only said once the fold is open", () => {
  const view = Model.accountView(snapshot([{ alias: "work", ok: true, hiddenDms: 5,
    dms: [dm(), quietDm("D8", "Yuki Tanaka")], channels: [] }]), "work")
  // Two "there is more" lines under each other makes neither of them mean
  // anything, so the fold speaks first and the note waits its turn.
  eq(Model.conversationRows(view, {}).filter(r => r.kind === "note").length, 0)
  eq(Model.conversationRows(view, { showAllDms: true })
       .filter(r => r.kind === "note")[0].title, "and 5 older direct messages")

  // With nothing to fold, it is said the way it always was.
  const dated = Model.accountView(snapshot([{ alias: "work", ok: true, hiddenDms: 5,
    dms: [dm()], channels: [] }]), "work")
  eq(Model.conversationRows(dated, {}).filter(r => r.kind === "note")[0].title,
     "and 5 older direct messages")
})

test("the filter looks at what was said as well as who said it", () => {
  eq(Model.conversationRows(view, { filter: "design" })
       .filter(r => r.kind === "conversation").map(r => r.title), ["#design"])
  eq(Model.conversationRows(view, { filter: "rolling" })
       .filter(r => r.kind === "conversation").map(r => r.title), ["#platform"])
  eq(Model.conversationRows(view, { filter: "nothing here" })[0].title, "Nothing matches")
})

test("a channel with nothing said in it falls back to its topic", () => {
  eq(Model.conversationRow(channel({ lastText: "" })).subtitle, "Keeping the lights on")
})

test("a direct message does not repeat the name it is already titled with", () => {
  eq(Model.conversationRow(dm()).subtitle, "Can you look at the deploy?")
  eq(Model.conversationRow(channel()).subtitle, "Tomás: Rolling back")
})

test("only conversations can be landed on", () => {
  const rows = Model.conversationRows(view, {})
  const landable = Model.selectableRows(rows)
  ok(landable.every(i => rows[i].kind === "conversation"), "no headings under the cursor")
  eq(landable.length, 4)
})

test("nothing is said about coverage while the search is working", () => {
  // A row without a preview means nothing was said in it lately, not that the
  // plugin ran out of budget - so there is nothing to apologise for.
  const fine = Model.accountView(snapshot([{ alias: "work", ok: true, feed: true,
    covered: 23, total: 445 }]), "work")
  eq(Model.coverageLabel(fine), "")
})

test("a search that is not available is said plainly", () => {
  const blind = Model.accountView(snapshot([{ alias: "work", ok: true, feed: false }]), "work")
  ok(Model.coverageLabel(blind).indexOf("no search access") >= 0, "says what is missing")
  eq(Model.coverageLabel(Model.accountView(snapshot([]), "work")), "", "nothing loaded, nothing said")
})

test("the direct messages left out of the sidebar are counted in a row of their own", () => {
  const many = Model.accountView(snapshot([{ alias: "work", ok: true,
    dms: [dm()], channels: [channel()], hiddenDms: 373 }]), "work")
  const rows = Model.conversationRows(many, {})
  const note = rows.filter(r => r.kind === "note")
  eq(note.length, 1)
  eq(note[0].title, "and 373 older direct messages")
  ok(note[0].subtitle.indexOf("press n") >= 0, "says where they are")
  // Not while filtering: the count belongs to the whole list, not the filter.
  eq(Model.conversationRows(many, { filter: "priya" }).filter(r => r.kind === "note").length, 0)
  eq(Model.conversationRows(many, { unreadOnly: true }).filter(r => r.key === "note:more-dms").length, 0)
})

test("one left over is one, not ones", () => {
  const one = Model.accountView(snapshot([{ alias: "work", ok: true,
    dms: [dm()], channels: [], hiddenDms: 1 }]), "work")
  eq(Model.conversationRows(one, {}).filter(r => r.kind === "note")[0].title,
     "and 1 older direct message")
})

test("presence arrives separately and is keyed by the person", () => {
  const dmRow = dm({ withUserId: "U9", presence: null })
  const withDot = Model.conversationRow(dmRow, { U9: { state: "active" } })
  eq(withDot.presence, "active")
  eq(withDot.userId, "U9")
  // Nothing heard yet is nothing drawn, rather than a wrong dot.
  eq(Model.conversationRow(dmRow, {}).presence, "")
  // And what the snapshot itself carried still counts.
  eq(Model.conversationRow(dm({ withUserId: "U9", presence: { state: "away" } }), null).presence,
     "away")
})

test("only the people the sidebar draws are asked about", () => {
  const many = Model.accountView(snapshot([{ alias: "work", ok: true, channels: [],
    dms: [dm({ id: "D1", withUserId: "U1" }), dm({ id: "D2", withUserId: "U2" }),
          dm({ id: "D3", withUserId: "" }), dm({ id: "D4", withUserId: "U1" })] }]), "work")
  // Deduplicated, group DMs skipped, and capped - it is one request each.
  eq(Model.presenceWanted(many, 20), ["U1", "U2"])
  eq(Model.presenceWanted(many, 1), ["U1"])
  eq(Model.presenceWanted(null, 20), [])
})

test("and only the ones the fold left on screen", () => {
  // presenceWanted walks the snapshot, which carries up to thirty direct
  // messages; the sidebar folds the quiet ones away behind one row. Asking
  // about somebody whose dot is not drawn is a request spent on nothing.
  const rows = folding([dm({ withUserId: "U1" }),
                        quietDm("D8", "Yuki Tanaka"),
                        quietDm("D9", "Ana Beltrán")])
  eq(Model.presenceWantedFromRows(rows, 20), ["U1"])
  // Unfolded, they are on screen and worth a dot each.
  const open = folding([dm({ withUserId: "U1" }),
                        dm({ id: "D8", title: "Yuki Tanaka", withUserId: "U8",
                             when: "", ts: "", lastText: "" })], { showAllDms: true })
  eq(Model.presenceWantedFromRows(open, 20), ["U1", "U8"])
  // Headings and the fold row are rows too, and nobody is behind them.
  eq(Model.presenceWantedFromRows([{ kind: "heading" }, { kind: "more" }], 20), [])
  eq(Model.presenceWantedFromRows(null, 20), [])
})

// ---------------------------------------------------------------- switcher

const directory = {
  people: [{ id: "U9", name: "Yuki Tanaka", handle: "yuki", title: "Design" }],
  channels: [
    { id: "C1", name: "platform", member: true, topic: "Keeping the lights on" },
    { id: "C9", name: "incidents", member: false, topic: "When something is on fire" }
  ]
}

test("what you are already in comes first and opens", () => {
  const rows = Model.switcherRows("", view, directory, 12)
  eq(rows[0].action, "open")
  eq(rows[0].title, "Priya Raman")
})

test("a channel you are in is not offered twice", () => {
  const rows = Model.switcherRows("platform", view, directory, 12)
  eq(rows.map(r => r.title), ["#platform"])
})

test("a channel you are not in offers to join, and says so", () => {
  const rows = Model.switcherRows("incid", view, directory, 12)
  eq(rows.length, 1)
  eq(rows[0].action, "join")
  ok(rows[0].subtitle.indexOf("Enter joins it") >= 0, "says what Enter does")
})

test("a person becomes a direct message", () => {
  const rows = Model.switcherRows("yuki", view, directory, 12)
  eq(rows[0].action, "dm")
  eq(rows[0].userId, "U9")
})

test("a leading # or @ is not part of what was typed", () => {
  eq(Model.switcherRows("#incid", view, directory, 12)[0].title, "#incidents")
  eq(Model.switcherRows("@yuki", view, directory, 12)[0].action, "dm")
})

test("the switcher stops at the limit it was given", () => {
  eq(Model.switcherRows("", view, directory, 2).length, 2)
})

// ---------------------------------------------------------------- search

test("a search result knows which conversation to open", () => {
  const rows = Model.searchRows([{ channel: "C1", channelName: "#platform", kind: "channel",
    from: "Tomás", text: "Rolling back  the release", ts: "1.1", when: "2026-09-01T08:00:00Z" }])
  eq(rows[0].channel, "C1")
  eq(rows[0].ts, "1.1")
  eq(rows[0].text, "Rolling back the release")
})

// ---------------------------------------------------------------- links

test("a message cannot bring its own markup", () => {
  const html = Model.linkify("<b>not bold</b> & <script>x</script>", "", [])
  ok(html.indexOf("<b>") === -1, "no tags survive")
  ok(html.indexOf("&lt;b&gt;") >= 0, "they are shown as the words they were")
  ok(html.indexOf("&amp;") >= 0, "and so is the ampersand")
})

test("a span is drawn where the helper said it was", () => {
  const html = Model.linkify("put it in the release notes", "#89b4fa",
    [{ href: "https://example.com/notes", start: 10, end: 27 }])
  ok(html.indexOf('href="https://example.com/notes"') >= 0, "the address")
  ok(html.indexOf(">the release notes<") >= 0, "the words")
  ok(html.indexOf("#89b4fa") >= 0, "tinted from the theme")
})

test("a span pointing somewhere unrunnable is left as words", () => {
  const html = Model.linkify("click me", "", [{ href: "javascript:alert(1)", start: 0, end: 8 }])
  eq(html, "click me")
  eq(Model.safeHref("data:text/html,x"), "")
  eq(Model.safeHref("mailto:a@example.com"), "mailto:a@example.com")
})

test("spans that overlap or point outside the text are dropped", () => {
  const spans = Model.usableSpans("0123456789", [
    { href: "https://a.example", start: 0, end: 5 },
    { href: "https://b.example", start: 3, end: 8 },
    { href: "https://c.example", start: 8, end: 99 },
    { href: "https://d.example", start: -1, end: 2 }
  ])
  eq(spans.length, 1)
  eq(spans[0].href, "https://a.example")
})

test("an address typed out in full still becomes a link", () => {
  ok(Model.hasLink("see https://example.com/x", []), "found")
  const html = Model.linkify("see https://example.com/x.", "", [])
  ok(html.indexOf('href="https://example.com/x"') >= 0, "without the full stop")
  ok(html.indexOf("x.</a>") === -1, "the sentence is not part of the address")
})

test("a line with nothing to link says so, so it can stay plain text", () => {
  eq(Model.hasLink("just words", []), false)
})

// ---------------------------------------------------------------- transcript

const t = (over) => Object.assign({
  id: "1", ts: "1", from: "Priya", fromId: "U1", text: "one",
  when: "2026-09-01T09:00:00Z", reactions: [], images: [], files: [], links: [],
  replyCount: 0, threadTs: "", parent: false, system: false
}, over || {})

const now = new Date("2026-09-01T12:00:00Z")

test("one person talking twice is one block", () => {
  const groups = Model.groupMessages([t(), t({ id: "2", ts: "2", text: "two" })], "me", now)
  eq(groups.length, 1)
  eq(groups[0].lines.length, 2)
})

test("somebody else answering starts a new one", () => {
  const groups = Model.groupMessages(
    [t(), t({ id: "2", fromId: "U2", from: "Dana" })], "me", now)
  eq(groups.length, 2)
  eq(groups[1].from, "Dana")
})

test("your own words are marked as yours", () => {
  const groups = Model.groupMessages([t({ fromId: "me" })], "me", now)
  eq(groups[0].mine, true)
})

test("a day boundary breaks a block even mid-conversation", () => {
  const groups = Model.groupMessages([
    t({ when: "2026-08-31T20:00:00Z" }),
    t({ id: "2", when: "2026-09-01T09:00:00Z" })
  ], "me", now)
  eq(groups.length, 2)
  eq(groups[0].day, "Yesterday")
  eq(groups[1].day, "Today")
})

test("the day is written once and not on every block of it", () => {
  const groups = Model.groupMessages([
    t({ when: "2026-09-01T09:00:00Z" }),
    t({ id: "2", fromId: "U2", when: "2026-09-01T09:05:00Z" })
  ], "me", now)
  eq(groups[0].day, "Today")
  eq(groups[1].day, "")
})

test("a system line never joins the block above it", () => {
  const groups = Model.groupMessages(
    [t(), t({ id: "2", system: true, text: "@Dana joined the channel" })], "me", now)
  eq(groups.length, 2)
  eq(groups[1].system, true)
})

test("a thread's replies are carried on the line they hang off", () => {
  const groups = Model.groupMessages([t({ replyCount: 4, threadTs: "1", parent: true })], "me", now)
  eq(groups[0].lines[0].replyCount, 4)
  eq(groups[0].lines[0].threadTs, "1")
})

test("replies are counted in words", () => {
  eq(Model.threadLabel(0), "")
  eq(Model.threadLabel(1), "1 reply")
  eq(Model.threadLabel(4), "4 replies")
})

test("a thread with something new in it says so, without inventing a number", () => {
  eq(Model.threadLabel(4, true), "4 replies · new")
  eq(Model.threadLabel(1, true), "1 reply · new")
  // Unread is meaningless without replies, and false must read as read.
  eq(Model.threadLabel(0, true), "")
  eq(Model.threadLabel(4, false), "4 replies")
  eq(Model.threadLabel(4, "yes"), "4 replies")
})

test("the transcript carries a thread's unread mark to the chip", () => {
  const groups = Model.groupMessages([
    t({ id: "1", ts: "1", replyCount: 3, threadTs: "1", parent: true, threadUnread: true }),
    t({ id: "2", ts: "2", fromId: "U2", from: "Ana", replyCount: 2, threadTs: "2", parent: true })
  ], "me", now)
  const lines = groups.reduce((all, group) => all.concat(group.lines), [])
  eq(lines[0].threadUnread, true)
  // Absent means read, not undefined: the chip binds straight to this.
  eq(lines[1].threadUnread, false)
})

test("a file says what it is and how big", () => {
  eq(Model.fileLabel({ kind: "PDF", size: 0 }), "PDF")
  eq(Model.fileLabel({ kind: "PDF", size: 900 }), "PDF · 900 B")
  eq(Model.fileLabel({ kind: "PDF", size: 2048 }), "PDF · 2 kB")
  eq(Model.fileLabel({ kind: "PNG", size: 5 * 1024 * 1024 }), "PNG · 5 MB")
})

// ---------------------------------------------------------------- time

test("a timestamp says as much as it needs to", () => {
  const today = new Date("2026-09-01T12:00:00Z")
  eq(Model.whenLabel("2026-09-01T09:05:00Z", today), Model.whenLabel("2026-09-01T09:05:00Z", today))
  ok(/^\d\d:\d\d$/.test(Model.whenLabel("2026-09-01T09:05:00Z", today)), "today is a clock")
  ok(/^[A-Z][a-z]{2} \d\d:\d\d$/.test(Model.whenLabel("2026-08-28T09:05:00Z", today)),
     "this week is a weekday")
  ok(/^\d+ [A-Z][a-z]{2}$/.test(Model.whenLabel("2026-03-03T09:05:00Z", today)),
     "older is a date")
  eq(Model.whenLabel("", today), "")
  eq(Model.whenLabel("not a date", today), "")
})

test("a day divider says today, yesterday, or which day it was", () => {
  const today = new Date("2026-09-01T12:00:00Z")
  eq(Model.dayLabel("2026-09-01T09:00:00Z", today), "Today")
  eq(Model.dayLabel("2026-08-31T09:00:00Z", today), "Yesterday")
  eq(Model.dayLabel("2026-08-28T09:00:00Z", today), "Friday")
  ok(Model.dayLabel("2026-03-03T09:00:00Z", today).indexOf("Mar") > 0, "older carries the date")
})

// ---------------------------------------------------------------- odds and ends

test("presence is drawn in the theme's colours or not at all", () => {
  eq(Model.presenceColor("active", { green: "#a6e3a1" }), "#a6e3a1")
  eq(Model.presenceColor("away", { muted: "#6c7086" }), "#6c7086")
  eq(Model.presenceColor("active", {}), "", "no palette, no dot")
  eq(Model.presenceColor("", { green: "#a6e3a1" }), "")
  eq(Model.presenceLabel("active"), "Active")
})

test("a reaction chip knows which way it toggles", () => {
  const reactions = [{ name: "+1", count: 2, mine: true }, { name: "eyes", count: 1, mine: false }]
  eq(Model.reactionIsMine(reactions, "+1"), true)
  eq(Model.reactionIsMine(reactions, "eyes"), false)
  eq(Model.reactionIsMine(reactions, "tada"), false, "one nobody has given")
  eq(Model.reactionIsMine(null, "+1"), false)
})

test("spacing is a multiplier over the theme's own", () => {
  eq(Model.densityScale("cosy"), 1.0)
  ok(Model.densityScale("compact") < 1, "compact is tighter")
  ok(Model.densityScale("spacious") > 1, "spacious is airier")
  eq(Model.densityScale("nonsense"), 1.0, "an unknown name is cosy")
  eq(Model.densityNames().length, 4)
  eq(Model.sortNames(), ["recent", "name"])
})

test("a tooltip cannot be handed something Qt would read as markup", () => {
  eq(Model.plainText("<img src=x onerror=y>"), "img src=x onerror=y>")
  eq(Model.plainText(null), "")
})

test("broken JSON is a fallback and not an exception", () => {
  eq(Model.parseJson("{not json", null), null)
  eq(Model.parseJson('{"a":1}', null), { a: 1 })
  eq(Model.parseJson("null", "fallback"), "fallback")
})

test("one line stays one line", () => {
  eq(Model.oneLine("  a\n  b  "), "a b")
  eq(Model.oneLine("abcdef", 4), "abc…")
})

test("a canvas preview draws no picture, whoever asked for one", () => {
  // The one Markdown construct that reaches the network by itself, and the
  // reason a canvas does not get to choose what a renderer fetches.
  eq(Model.previewMarkdown("before ![shot](https://evil.example/x.png) after"),
     "before shot after")
  eq(Model.previewMarkdown("![](https://evil.example/x.png)"), "")
  eq(Model.previewMarkdown("a <img src=\"https://evil.example/y.png\"> b"), "a  b")
})

test("a mention becomes the person, and keeps its id when nobody knows them", () => {
  eq(Model.previewMarkdown("Ask ![](@U0123ABC) today", { U0123ABC: "Ada Lovelace" }),
     "Ask @Ada Lovelace today")
  eq(Model.previewMarkdown("Ask ![](@U0123ABC)"), "Ask @U0123ABC")
})

test("the formatting a canvas came with is left alone", () => {
  const source = "# Rota\n\n- **Ada**\n- Grace\n\n[runbook](https://example.com/x)"
  eq(Model.previewMarkdown(source), source)
})

test("a canvas says why it cannot be rewritten here", () => {
  eq(Model.canvasNote(null), "")
  eq(Model.canvasNote({ canWrite: true, markdown: "- Ada", lossy: [] }), "")
  ok(Model.canvasNote({ canWrite: false, markdown: "- Ada", lossy: [] })
       .indexOf("canvases:write") !== -1)
  ok(Model.canvasNote({ canWrite: true, markdown: "- Ada", lossy: ["a picture"] })
       .indexOf("a picture") !== -1)
  ok(Model.canvasNote({ canWrite: true, markdown: "x", truncated: true, lossy: [] })
       .indexOf("longer than") !== -1)
})

// ----------------------------------------------------------------

if (failures.length > 0) {
  console.error(failures.length + " failed:")
  failures.forEach((line) => console.error("  " + line))
  process.exit(1)
}
console.log(passed + " passed")
