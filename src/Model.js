.pragma library

// Shaping only: no Qt types, no network, nothing that needs a running shell.
// Kept that way so the sidebar ordering, the message grouping and the link
// building can be run under node, the way the Teams and Office 365 plugins
// test theirs.

function parseJson(raw, fallback) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return parsed === null ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

function oneLine(text, maxLength) {
  var flat = String(text || "").replace(/\s+/g, " ").trim()
  if (maxLength && flat.length > maxLength) return flat.substring(0, maxLength - 1) + "…"
  return flat
}

// Text handed to something the shell draws for us - a bar tooltip - where a
// Text item in the shell's own code renders it and we cannot pin it to
// PlainText from here. Qt's AutoText treats a stray `<` as the start of markup,
// and markup fetches what it is told to fetch; a chat message is exactly the
// place a crafted one would arrive. Taking the `<` away takes the decision away.
function plainText(value) {
  return String(value === undefined || value === null ? "" : value).replace(/</g, "")
}

// How much room the window gives things.
//
// One multiplier over the shell's own spacing tokens rather than a set of
// hand-picked pixel values: the theme already decides what "a gap" is, and
// this says how generous to be with it. Sizes still scale with the font that
// way, which hand-picked numbers would stop doing.
var DENSITY = { compact: 0.6, cosy: 1.0, roomy: 1.7, spacious: 2.4 }

function densityScale(name) {
  var found = DENSITY[String(name || "").toLowerCase()]
  return typeof found === "number" ? found : DENSITY.cosy
}

function densityNames() {
  return ["compact", "cosy", "roomy", "spacious"]
}

function sortNames() {
  return ["recent", "name"]
}

// Whether you are already one of the people who reacted with this emoji.
//
// It decides which way a chip toggles: clicking one you are part of takes
// yours off, clicking one you are not adds it. Kept here rather than inline in
// the delegate so the decision can be tested - getting it backwards would look
// like reactions that refuse to go away.
function reactionIsMine(reactions, name) {
  var rows = reactions || []
  var want = String(name || "")
  for (var i = 0; i < rows.length; i++)
    if (String(rows[i].name) === want) return rows[i].mine === true
  return false
}

// ---------------------------------------------------------------- links

// A message as markup with its links clickable.
//
// The text is escaped FIRST and links added afterwards, never the other way
// round. The words come from whoever sent the message, so anything they wrote
// that looks like markup has to stop being markup before this builds any - and
// what this builds is only ever an <a>. Rich text fetches what it is told to
// fetch, so a message must never get to choose the tags.
//
// Only http, https and mailto become links. A javascript: or data: URL is left
// as the plain words it was.
var LINKABLE = /\b(?:https?:\/\/|www\.)[^\s<>"'\)\]]+|(?:\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b)/g

function escapeHtml(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function hasLink(text, links) {
  if (links && links.length > 0) return true
  LINKABLE.lastIndex = 0
  return LINKABLE.test(String(text || ""))
}

// Only somewhere to go, never something to run - the same three schemes the
// Python side allows, checked again here because this is what builds the tag.
function safeHref(href) {
  var url = String(href || "").trim()
  var lowered = url.toLowerCase()
  if (lowered.indexOf("http://") === 0 || lowered.indexOf("https://") === 0
      || lowered.indexOf("mailto:") === 0) return url
  return ""
}

// One anchor, out of text that has not been escaped yet.
function anchor(href, label, tint) {
  var url = escapeHtml(href)
  var words = escapeHtml(label)
  if (tint === "") return '<a href="' + url + '">' + words + '</a>'
  // Both the style and the font tag: Qt honours one or the other depending on
  // the rich-text path, and an uncoloured link is the thing being fixed.
  return '<a href="' + url + '" style="color:' + tint + '">'
    + '<font color="' + tint + '">' + words + '</font></a>'
}

// `links` are the spans slack.py found in the message's own mrkdwn - the ones
// where the address is inside `<url|words>` and nowhere in the words, which is
// what Slack writes whenever anybody uses the composer's link button. Text
// outside those spans still gets the addresses somebody typed out in full.
//
// `color` is a hex string from the theme's own palette. A TextEdit has no
// linkColor - that is a Text property - so an anchor rendered in one comes out
// in Qt's default blue, which belongs to no theme. Since this builds the
// anchor, it can say what colour it should be.
function linkify(text, color, links) {
  var tint = String(color || "")
  var plain = String(text === undefined || text === null ? "" : text)
  var spans = usableSpans(plain, links)
  var html = ""
  var at = 0
  for (var i = 0; i < spans.length; i++) {
    html += autoLinked(plain.substring(at, spans[i].start), tint)
    html += anchor(spans[i].href, plain.substring(spans[i].start, spans[i].end), tint)
    at = spans[i].end
  }
  html += autoLinked(plain.substring(at), tint)
  // Newlines carry no meaning in rich text, and a transcript is full of them.
  return html.replace(/\n/g, "<br>")
}

// The spans worth drawing: in order, inside the text, not overlapping, and
// pointing somewhere it is safe to go. Offsets come from a message somebody
// else wrote, so none of that is assumed.
function usableSpans(plain, links) {
  var list = []
  var all = links || []
  for (var i = 0; i < all.length; i++) {
    var href = safeHref(all[i] && all[i].href)
    var start = Number(all[i] && all[i].start)
    var end = Number(all[i] && all[i].end)
    if (href === "" || !isFinite(start) || !isFinite(end)) continue
    if (start < 0 || end > plain.length || end <= start) continue
    list.push({ start: start, end: end, href: href })
  }
  list.sort(function(a, b) { return a.start - b.start })
  var kept = []
  var reached = 0
  for (var j = 0; j < list.length; j++) {
    if (list[j].start < reached) continue
    kept.push(list[j])
    reached = list[j].end
  }
  return kept
}

// The prose between the links: escaped, with any address somebody typed out in
// full turned into a link of its own. Slack wraps a pasted URL in <> and this
// plugin turns that into a span - but a message that arrives from an app as
// plain text has bare addresses in it and nothing marking them.
function autoLinked(plain, tint) {
  var escaped = escapeHtml(plain)
  LINKABLE.lastIndex = 0
  return escaped.replace(LINKABLE, function(match) {
    // Trailing punctuation is nearly always the sentence, not the address.
    var trail = ""
    while (match.length > 0 && ".,;:!?".indexOf(match.charAt(match.length - 1)) !== -1) {
      trail = match.charAt(match.length - 1) + trail
      match = match.substring(0, match.length - 1)
    }
    var href = match
    if (match.indexOf("@") !== -1 && match.indexOf("//") === -1) href = "mailto:" + match
    else if (match.toLowerCase().indexOf("www.") === 0) href = "https://" + match
    if (tint === "") return '<a href="' + href + '">' + match + '</a>' + trail
    return '<a href="' + href + '" style="color:' + tint + '">'
      + '<font color="' + tint + '">' + match + '</font></a>' + trail
  })
}

// ------------------------------------------------------------------ canvases

// A canvas's Markdown, as something safe to put in front of a renderer.
//
// Rendered Markdown is the one place in this window where a document does
// choose its own markup, so what it may choose is settled here first. Two
// things are taken out and everything else is left alone:
//
//   - Every picture. `![](https://evil/)` renders as a request to a host
//     nobody vetted, which is the fetch invariant 2 exists to prevent, and it
//     is the one Markdown construct that reaches the network by itself.
//   - Every tag. The helper escapes `<` on the way out so a canvas cannot
//     write one, but this also renders what the person editing has typed, and
//     an editor is not the place to find out what `<img>` does.
//
// Slack writes a mention as a picture pointing at a user id rather than at a
// host - `![](@U0123ABC)` - which names nowhere to fetch from. Those become
// the person's name, which is what the id was standing in for.
function previewMarkdown(markdown, names) {
  var people = names || {}
  return String(markdown === undefined || markdown === null ? "" : markdown)
    .replace(/!\[[^\]]*\]\(\s*@([UWB][A-Z0-9]{2,})\s*\)/g, function(match, id) {
      var found = people[id]
      return "@" + String(found ? found : id)
    })
    .replace(/!\[[^\]]*\]\(\s*#(C[A-Z0-9]{2,})\s*\)/g, function(match, id) {
      var found = people[id]
      return "#" + String(found ? found : id)
    })
    // Anything still shaped like a picture is one, and none of them are drawn.
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/<[^>]*>/g, "")
}

// Why this canvas is not one to edit here, in a sentence, or "" when it is.
//
// Said rather than shown as a disabled button with no explanation: every one
// of these has something the reader can do about it, and two of them are not
// the reader's fault at all.
function canvasNote(canvas) {
  if (!canvas) return ""
  if (canvas.canWrite !== true) {
    return "This token cannot write canvases. Add canvases:write to your Slack app, "
         + "reinstall it, and paste the new token in Settings."
  }
  if (canvas.truncated === true || String(canvas.markdown || "") === "") {
    return "This canvas is longer than this window can read, so it will not rewrite it. "
         + "You can still add to the end of it."
  }
  var lossy = canvas.lossy || []
  if (lossy.length > 0) {
    return "This canvas holds " + listOf(lossy) + ", which this window cannot write back, "
         + "so it will not rewrite it. You can still add to the end of it."
  }
  return ""
}

// "a picture", "a picture and an embed", "a, b and c".
function listOf(phrases) {
  var items = []
  for (var i = 0; i < (phrases || []).length; i++) {
    if (String(phrases[i])) items.push(String(phrases[i]))
  }
  if (items.length === 0) return "something"
  if (items.length === 1) return items[0]
  return items.slice(0, -1).join(", ") + " and " + items[items.length - 1]
}

// ---------------------------------------------------------------- presence

// Slack knows two states where Teams knows nine: a person is active or they
// are not. Drawn in the theme's own colours rather than hardcoded traffic
// lights, and told apart by shape as well as hue - a filled circle for active,
// a ring for away - so the states stay apart on a theme whose green and grey
// sit close together, and for anyone who cannot tell those apart.
function presenceColor(state, palette) {
  var colors = palette || {}
  switch (String(state || "")) {
    case "active": return colors.green || ""
    case "away":   return colors.muted || ""
    default:       return ""
  }
}

function presenceLabel(state) {
  switch (String(state || "")) {
    case "active": return "Active"
    case "away":   return "Away"
    default:       return ""
  }
}

// ---------------------------------------------------------------- the account

// The one workspace, as a view the UI can bind to without null checks.
function accountView(snapshot, alias) {
  var accounts = (snapshot && snapshot.accounts) || []
  for (var i = 0; i < accounts.length; i++) {
    if (String(accounts[i].alias) !== String(alias)) continue
    var data = accounts[i]
    return {
      alias: String(data.alias || ""),
      ok: data.ok === true,
      loaded: true,
      team: data.team || "",
      url: data.url || "",
      userId: data.userId || "",
      userName: data.userName || "",
      displayName: data.displayName || "",
      // Every capability the helper reports has to be carried across here.
      // Missing one does not fail loudly: the flag reads undefined, which is
      // falsey, so the feature quietly stays switched off and the button
      // offering to enable it stays switched on for ever.
      canPost: data.post === true,
      canUpload: data.upload === true,
      canReact: data.react === true,
      canMarkRead: data.markRead === true,
      canSearch: data.search === true,
      canOpenDm: data.openDm === true,
      canJoin: data.join === true,
      canSeePresence: data.presence === true,
      canFindPeople: data.people === true,
      dms: data.dms || [],
      channels: data.channels || [],
      unreadCount: Number(data.unreadCount || 0),
      unreadMessages: Number(data.unreadMessages || 0),
      covered: Number(data.covered || 0),
      total: Number(data.total || 0),
      coveredChannels: Number(data.coveredChannels || 0),
      totalChannels: Number(data.totalChannels || 0),
      // Whether the one search everything hangs on answered.
      feed: data.feed !== false,
      // Direct messages the sidebar did not draw. Said out loud in a row of
      // its own rather than left as a list that quietly stops.
      hiddenDms: Number(data.hiddenDms || 0),
      missingScopes: data.missingScopes || [],
      errorCode: data.error ? String(data.error.code || "") : "",
      errorMessage: data.error ? String(data.error.message || "") : "",
      warnings: data.warnings || []
    }
  }
  return {
    alias: String(alias || ""), ok: false, loaded: false, team: "", url: "",
    userId: "", userName: "", displayName: "",
    canPost: false, canUpload: false, canReact: false, canMarkRead: false, canSearch: false,
    canOpenDm: false, canJoin: false, canSeePresence: false, canFindPeople: false,
    dms: [], channels: [], unreadCount: 0, unreadMessages: 0, covered: 0, total: 0,
    coveredChannels: 0, totalChannels: 0, hiddenDms: 0, feed: true,
    missingScopes: [], errorCode: "", errorMessage: "", warnings: []
  }
}

// ---------------------------------------------------------------- the sidebar

function subtitleFor(row) {
  var who = String(row.lastFrom || "").trim()
  var text = oneLine(row.lastText || "", 120)
  if (text === "") return oneLine(row.topic || "", 120)
  // A direct message is titled with the person's name, so repeating it in
  // front of every line only takes room from what they said.
  if (who === "" || String(row.kind) === "im") return text
  return who + ": " + text
}

function conversationRow(row, presence) {
  // Presence arrives after the sidebar does - it is one request per person, so
  // the poll no longer waits for it - and is keyed by the person rather than
  // by the conversation. A row takes whichever has been heard: the map when it
  // has arrived, the snapshot's own value otherwise.
  var who = String(row.withUserId || "")
  var found = (presence && who && presence[who]) ? presence[who] : row.presence
  return {
    kind: "conversation",
    key: "c:" + String(row.id || ""),
    id: String(row.id || ""),
    channelKind: String(row.kind || "channel"),
    title: String(row.title || ""),
    subtitle: subtitleFor(row),
    // Carried through because the window's header draws it under the title -
    // what a channel is for, said where somebody arriving in it would look.
    topic: String(row.topic || ""),
    when: String(row.when || ""),
    ts: String(row.ts || ""),
    unread: row.unread === true,
    unreadCount: Number(row.unreadCount || 0),
    userId: who,
    presence: (found && found.state) ? String(found.state) : "",
    avatar: String(row.avatar || ""),
    private: row.private === true,
    // Starred in Slack. The helper has already sorted these to the top of
    // their section; the row carries it so the sidebar can say why one is
    // there rather than leaving the order looking arbitrary.
    starred: row.starred === true,
    // Whether this row was given a preview this poll. One that was not is
    // still perfectly openable; it has nothing to say about what is in it.
    current: row.current === true,
    depth: 0
  }
}

// The sidebar: the people talking to you, then the rooms you are in.
//
// Direct messages lead because a DM is a tap on the shoulder and a channel is
// a room you visit. Both are already ordered by the helper - by recency or by
// name, whichever the settings ask for - so this only groups them and says
// which have headings.
function conversationRows(view, options) {
  var settings = options || {}
  var onlyUnread = settings.unreadOnly === true
  var filter = String(settings.filter || "").trim().toLowerCase()
  var showAllDms = settings.showAllDms === true
  var rows = []

  function keep(list) {
    var kept = []
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (onlyUnread && row.unread !== true) continue
      if (filter !== "") {
        var haystack = (String(row.title || "") + " " + String(row.lastText || "")).toLowerCase()
        if (haystack.indexOf(filter) === -1) continue
      }
      kept.push(row)
    }
    return kept
  }

  var dms = keep((view && view.dms) || [])
  var channels = keep((view && view.channels) || [])
  var presence = settings.presence || null

  // A DM with no date on it is one nothing has been said in lately. The helper
  // pads the section out with them, in interest order, so the list does not
  // stop at the four people who wrote this week - useful, and still not what
  // the eye is looking for. So they fold behind one row and the dated ones
  // stand on their own.
  //
  // Never folded: anything unread, because a date is not what makes a DM
  // matter. And nothing at all while a filter or the unread toggle is on -
  // those are already somebody asking for a particular subset.
  var dated = []
  var quiet = []
  for (var q = 0; q < dms.length; q++) {
    if (String(dms[q].when || "") !== "" || dms[q].unread === true) dated.push(dms[q])
    else quiet.push(dms[q])
  }
  // All of them quiet is a new account or a very quiet week, and a section
  // that is nothing but "show 12 more" says less than the twelve names do.
  var foldable = !onlyUnread && filter === "" && dated.length > 0 && quiet.length > 0
  var shownDms = (foldable && !showAllDms) ? dated : dms

  if (dms.length > 0) rows.push({ kind: "heading", key: "h:dms", title: "Direct messages", depth: 0 })
  for (var d = 0; d < shownDms.length; d++) rows.push(conversationRow(shownDms[d], presence))

  // The one row that stands for the rest of them. Picked like a conversation -
  // by pointer or by cursor - and the window turns it into the other half of
  // the list rather than into anything being opened.
  if (foldable)
    rows.push({ kind: "more", key: "more:dms", expanded: showAllDms,
                title: showAllDms ? "Show fewer" : ("Show " + quiet.length + " more"),
                subtitle: showAllDms ? "" : "quiet - n finds anyone",
                when: "", unread: false, depth: 0 })

  // How many are not here at all, and where they are. An account that has been
  // on Slack for years has hundreds of group DMs that were one conversation in
  // 2023; the sidebar draws the ones with something in them, and this says so
  // rather than letting the list quietly stop. Only once the fold is open:
  // two "there is more" lines under each other makes neither of them mean
  // anything.
  var hidden = Number((view && view.hiddenDms) || 0)
  if (dms.length > 0 && hidden > 0 && !onlyUnread && filter === ""
      && (!foldable || showAllDms))
    rows.push({ kind: "note", key: "note:more-dms",
                title: "and " + hidden + " older direct message" + (hidden === 1 ? "" : "s"),
                subtitle: "press n to jump to one", when: "", unread: false, depth: 0 })

  if (channels.length > 0) rows.push({ kind: "heading", key: "h:channels", title: "Channels", depth: 0 })
  for (var c = 0; c < channels.length; c++) rows.push(conversationRow(channels[c], presence))

  if (rows.length === 0) {
    rows.push({
      kind: "note",
      key: "note:empty",
      title: onlyUnread ? "Nothing unread"
                        : (filter !== "" ? "Nothing matches" : "Nothing here yet"),
      subtitle: "", when: "", unread: false, depth: 0
    })
  }
  return rows
}

// Rows a cursor may land on - never a heading, never a note. The row that
// unfolds the quiet direct messages is one of them: it is something to press
// Return on, which is the whole reason it is not a note.
function selectableRows(rows) {
  var out = []
  var list = rows || []
  for (var i = 0; i < list.length; i++)
    if (list[i].kind === "conversation" || list[i].kind === "more") out.push(i)
  return out
}

// What the sidebar says under the workspace name: how much of it is being kept
// current, when that is not all of it. Said plainly rather than left as a
// mystery about why a channel has no preview on it.
// What to say about how current the list is - which, when everything is
// working, is nothing at all.
//
// The previews and the unread marks come from one search across the whole
// workspace, so a row without a preview means nothing has been said in it
// lately rather than that this plugin ran out of budget. There is nothing to
// apologise for until that search is unavailable, and then it is worth saying
// plainly, because without it the sidebar cannot know what is new.
function coverageLabel(view) {
  if (!view || view.loaded !== true) return ""
  if (view.feed === false)
    return "no search access - previews and unread marks are off"
  return ""
}

// ---------------------------------------------------------------- jumping

// The quick switcher's rows: what you are already in, then the rest of the
// workspace.
//
// Conversations you are in come first and always match on their title alone -
// they are the ones you meant nine times out of ten. A channel you are not in
// is offered too, with joining as what opening it means, and a person becomes
// a DM. The three are told apart by `action`, so the window does not have to
// guess what pressing Enter on a row should do.
function switcherRows(query, view, directory, limit) {
  var text = String(query || "").trim().toLowerCase().replace(/^[#@]/, "")
  var max = limit || 12
  var rows = []
  var seen = {}

  function matches(haystack) {
    return text === "" || String(haystack || "").toLowerCase().indexOf(text) !== -1
  }

  var mine = ((view && view.dms) || []).concat((view && view.channels) || [])
  for (var i = 0; i < mine.length && rows.length < max; i++) {
    var row = mine[i]
    if (!matches(row.title)) continue
    seen[String(row.id)] = true
    rows.push({
      kind: "conversation", action: "open", key: "s:c:" + row.id, id: String(row.id),
      title: String(row.title || ""), subtitle: subtitleFor(row),
      unread: row.unread === true, channelKind: String(row.kind || "channel"),
      avatar: String(row.avatar || ""), userId: ""
    })
  }

  var channels = (directory && directory.channels) || []
  for (var c = 0; c < channels.length && rows.length < max; c++) {
    var channel = channels[c]
    if (seen[String(channel.id)]) continue
    if (!matches(channel.name)) continue
    rows.push({
      kind: "channel", action: channel.member === true ? "open" : "join",
      key: "s:ch:" + channel.id, id: String(channel.id),
      title: "#" + String(channel.name || ""),
      subtitle: channel.member === true ? oneLine(channel.topic || "", 90)
                                        : "not in this channel - Enter joins it",
      unread: false, channelKind: "channel", avatar: "", userId: ""
    })
  }

  var people = (directory && directory.people) || []
  for (var p = 0; p < people.length && rows.length < max; p++) {
    var person = people[p]
    if (!matches(person.name) && !matches(person.handle)) continue
    rows.push({
      kind: "person", action: "dm", key: "s:p:" + person.id, id: String(person.id),
      title: String(person.name || ""),
      subtitle: [person.handle ? "@" + person.handle : "", person.title || ""]
        .filter(function(part) { return part !== "" }).join("  ·  "),
      unread: false, channelKind: "im", avatar: "", userId: String(person.id)
    })
  }
  return rows
}

// One search result, as a row. The conversation it was in leads, because that
// is what pressing Enter on it opens.
// Who to ask about, for the presence dots: the people the sidebar is actually
// drawing, and nobody else. It is one request each, so the list is short and
// it is the visible rows rather than the first twenty of four hundred.
function presenceWanted(view, limit) {
  var out = []
  var rows = (view && view.dms) || []
  for (var i = 0; i < rows.length && out.length < (limit || 20); i++) {
    var who = String(rows[i].withUserId || "")
    if (who !== "" && out.indexOf(who) === -1) out.push(who)
  }
  return out
}

// The same thing, but only about the people the sidebar is actually drawing.
//
// `presenceWanted` walks every direct message in the snapshot, which is up to
// thirty of them - and the sidebar folds the quiet ones away behind one row,
// so most of those are people whose dot is not on screen to be looked at. One
// request each, against a bucket of fifty a minute. These rows are the ones
// `conversationRows` produced, headings and the fold row included, so the
// conversations among them are exactly what is visible.
function presenceWantedFromRows(rows, limit) {
  var out = []
  var list = rows || []
  for (var i = 0; i < list.length && out.length < (limit || 20); i++) {
    if (list[i].kind !== "conversation") continue
    var who = String(list[i].userId || "")
    if (who !== "" && out.indexOf(who) === -1) out.push(who)
  }
  return out
}

function searchRows(matches) {
  var list = matches || []
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var match = list[i]
    rows.push({
      key: "m:" + String(match.channel || "") + ":" + String(match.ts || ""),
      channel: String(match.channel || ""),
      channelName: String(match.channelName || ""),
      channelKind: String(match.kind || "channel"),
      from: String(match.from || ""),
      text: oneLine(match.text || "", 240),
      links: match.links || [],
      ts: String(match.ts || ""),
      when: String(match.when || "")
    })
  }
  return rows
}

// ---------------------------------------------------------------- time

function parseDate(value) {
  if (!value) return null
  var when = new Date(String(value))
  return isNaN(when.getTime()) ? null : when
}

function pad(value) { return value < 10 ? "0" + value : String(value) }

function timeOfDay(date) {
  return pad(date.getHours()) + ":" + pad(date.getMinutes())
}

// "14:02" today, "Tue 14:02" this week, "3 Mar" older. A transcript wants the
// clock; a conversation list wants to know how stale it is.
function whenLabel(value, now) {
  var when = parseDate(value)
  if (!when) return ""
  var today = now || new Date()
  var sameDay = when.getFullYear() === today.getFullYear()
    && when.getMonth() === today.getMonth()
    && when.getDate() === today.getDate()
  if (sameDay) return timeOfDay(when)
  var days = Math.floor((today - when) / 86400000)
  var weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][when.getDay()]
  if (days < 7) return weekday + " " + timeOfDay(when)
  var month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][when.getMonth()]
  return when.getDate() + " " + month
}

// A day's worth of transcript gets a line saying which day it was. Without it
// a conversation that has been going for a week is one unbroken column of
// clock times that say nothing about which morning they were.
function dayLabel(value, now) {
  var when = parseDate(value)
  if (!when) return ""
  var today = now || new Date()
  function sameDate(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()
      && a.getDate() === b.getDate()
  }
  if (sameDate(when, today)) return "Today"
  var yesterday = new Date(today.getTime() - 86400000)
  if (sameDate(when, yesterday)) return "Yesterday"
  var weekday = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][when.getDay()]
  if ((today - when) < 6 * 86400000) return weekday
  var month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][when.getMonth()]
  return weekday + " " + when.getDate() + " " + month
}

// ---------------------------------------------------------------- transcript

function fileLabel(row) {
  var size = Number(row && row.size || 0)
  var kind = String(row && row.kind || "file")
  if (size <= 0) return kind
  if (size < 1024) return kind + " · " + size + " B"
  if (size < 1024 * 1024) return kind + " · " + Math.round(size / 1024) + " kB"
  return kind + " · " + (Math.round(size / 1024 / 102.4) / 10) + " MB"
}

function threadLabel(count, unread) {
  var n = Number(count || 0)
  if (n <= 0) return ""
  var label = n === 1 ? "1 reply" : n + " replies"
  // The fact, not a number: Slack sends whether a thread you follow has
  // something new in it and never how much of it is new, so a count here would
  // be invented. See slack.py's message_row.
  return unread === true ? label + " · new" : label
}

// Consecutive messages from one person are one block: repeating the name on
// every line turns a conversation into a list of labels. A day boundary breaks
// a block even when the same person is still talking, because the divider that
// says which day it is has to go between them.
function groupMessages(messages, meId, now) {
  var groups = []
  var list = messages || []
  var lastDay = ""
  for (var i = 0; i < list.length; i++) {
    var message = list[i]
    var day = dayLabel(message.when, now)
    var mine = String(message.fromId || "") === String(meId || "") && String(meId || "") !== ""
    var last = groups.length > 0 ? groups[groups.length - 1] : null
    var line = {
      id: message.id, ts: message.ts, text: message.text, when: message.when,
      edited: message.edited === true, images: message.images || [],
      files: message.files || [], links: message.links || [],
      reactions: message.reactions || [],
      threadTs: String(message.threadTs || ""),
      replyCount: Number(message.replyCount || 0),
      threadUnread: message.threadUnread === true,
      parent: message.parent === true
    }
    var sameBlock = last && !message.system && !last.system && day === lastDay
      && String(last.fromId) === String(message.fromId || "")
    if (sameBlock) {
      last.lines.push(line)
      last.when = message.when
      continue
    }
    groups.push({
      key: String(message.id || i),
      from: String(message.from || (message.system ? "" : "Someone")),
      fromId: String(message.fromId || ""),
      avatar: String(message.avatar || ""),
      mine: mine,
      system: message.system === true,
      when: message.when,
      // The day this block starts, drawn as a divider above it - but only on
      // the first block of that day.
      day: day === lastDay ? "" : day,
      lines: [line]
    })
    lastDay = day
  }
  return groups
}
