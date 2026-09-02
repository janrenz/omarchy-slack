import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the Slack widget and window share: the workspace, the poll timer,
// the conversation being read, the thread hanging off it, and the one place
// that knows how to run the helper.
//
// Nothing here ever holds a token. slack.py does, and this runs it and reads
// JSON back - the same split the Teams and Office 365 plugins use, because a
// process that renders other people's messages should not also hold the
// credentials.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""

  readonly property string alias: String(setting("account", "")).trim()
  readonly property int conversationCount: intSetting("conversations", 40, 5, 120)
  readonly property string sortOrder: String(setting("sort", "recent")) === "name" ? "name" : "recent"
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 120, 30, 3600)
  readonly property bool notifyOnNew: setting("notify", true) !== false
  readonly property bool wantAvatars: setting("avatars", true) !== false
  readonly property bool wantPresence: setting("presence", true) !== false
  // Whether the coding-agent handover is on offer at all. Off takes away the a
  // key, the button, and the route an agent uses to hand a draft back - see the
  // README's "Your coding agent" section.
  readonly property bool agentHandover: setting("agentHandover", true) !== false
  readonly property bool demo: setting("demo", false) === true

  // The bar draws a count and nothing else. Faces and presence are one request
  // each and are only ever looked at in the window, so the widget turns them
  // off and the window turns them on.
  property bool wantsDecoration: true
  // Whose job it is to announce new messages. There is a Service behind the
  // bar icon and another behind the window, both polling the same workspace,
  // and both announcing would say everything twice. The bar's is the one that
  // is always there, so the bar's is the one that speaks.
  property bool notifies: false

  // How much room to give things. A multiplier over the theme's spacing rather
  // than pixel values of our own, so it still follows the font size.
  readonly property string density: String(setting("density", "cosy"))
  readonly property real densityScale: Model.densityScale(density)

  function pad(px) { return Math.max(1, Math.round(px * densityScale)) }

  // A workspace name is all it takes. Unlike Teams there is no client id to
  // configure - the token is pasted in the window and lives in a file only
  // this user can read.
  readonly property bool configured: alias !== ""

  property var snapshot: null
  property bool loading: false
  property string errorCode: ""
  property string errorMessage: ""

  readonly property var view: Model.accountView(snapshot, alias)
  readonly property bool signedIn: view.ok === true
  readonly property bool needsSignIn: view.errorCode === "auth_required"
  readonly property int unreadCount: view.unreadCount || 0
  readonly property var warnings: view.warnings || []
  readonly property var missingScopes: view.missingScopes || []

  readonly property bool canPost: view.canPost === true
  readonly property bool canUpload: view.canUpload === true
  readonly property bool canReact: view.canReact === true
  readonly property bool canMarkRead: view.canMarkRead === true
  readonly property bool canSearch: view.canSearch === true
  readonly property bool canJump: view.canFindPeople === true || view.canJoin === true
                                  || view.canOpenDm === true

  // Show only what is waiting. A view of the list rather than a setting, so it
  // is not remembered between sessions: it answers "what needs me now", and
  // that question is asked fresh each time.
  property bool unreadOnly: false
  // What has been typed into the filter above the list. Filters the rows that
  // are already here, which is a different thing from the quick switcher -
  // that one goes looking through the whole workspace.
  property string filterText: ""
  // Whether the direct messages nothing has been said in lately are unfolded.
  // A view of the list like unreadOnly, and forgotten the same way: the fold
  // is there so the section reads at a glance, and it should read that way
  // again the next time the window is opened.
  property bool showAllDms: false

  readonly property var conversations: Model.conversationRows(
    view, { unreadOnly: unreadOnly, filter: filterText, presence: presenceByUser,
            showAllDms: showAllDms })

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var parsed = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(parsed)) parsed = fallback
    return Math.max(min, Math.min(max, parsed))
  }

  function helper() { return pluginDir + "/slack.py" }

  function base(command) {
    var argv = ["python3", helper(), command, "--account", alias]
    return argv
  }

  // ---- fetching ---------------------------------------------------------

  // A fetch that was asked for while one was already in flight. Dropping it,
  // which is what the Teams plugin does, is fine when the two would have asked
  // the same question - and this one might not: the settings arriving is
  // itself a reason to refresh, and the fetch already running was started
  // before them.
  property bool refreshQueued: false

  // How old a snapshot may be and still be worth handing straight back.
  //
  // There are two of these services - one behind the bar icon, one behind the
  // window - and both poll the same workspace. The one that announces new
  // messages is the timekeeper and always does the work; the other reads what
  // that one wrote, so an open window costs no extra requests at all. If the
  // bar is not running, the other one's snapshot ages out and it takes over.
  readonly property int shareAge: notifies ? 0 : Math.round(refreshIntervalSec * 0.75)
  // Whether anything has been drawn yet. Until then, anything on disk beats a
  // blank sidebar for the length of a poll.
  property bool painted: false

  function refresh(options) {
    if (!configured || pluginDir === "") return
    var wants = options || {}
    if (fetchProc.running) { refreshQueued = true; return }
    refreshQueued = false
    loading = true
    var command = ["python3", helper(), "fetch", "--account", alias,
                   "--conversations", String(conversationCount), "--sort", sortOrder]
    // Nothing drawn yet: take whatever is on disk, however old, and paint it
    // now. The poll behind it replaces it a few seconds later.
    var maxAge = wants.fresh === true ? 0
               : (!painted ? 900 : (wants.maxAge === undefined ? shareAge : wants.maxAge))
    if (maxAge > 0) command = command.concat(["--max-age", String(maxAge)])
    if (wants.fresh === true) command.push("--fresh")
    if (!wantsDecoration || !wantAvatars) command.push("--no-avatars")
    if (!wantsDecoration || !wantPresence) command.push("--no-presence")
    if (demo) command.push("--demo")
    fetchProc.command = command
    fetchProc.running = true
  }

  // What Refresh means: re-read the list, and the conversation being read.
  // They come from different requests, so refreshing only the list left a new
  // message showing in the sidebar and missing from the conversation it
  // belonged to.
  //
  // The background poll still leaves the transcript alone: re-reading it every
  // couple of minutes unasked is not the same as being asked for it.
  function refreshEverything() {
    // Asked for by hand, so nothing cached will do: the conversation list is
    // re-read too, which is how a channel joined in Slack itself turns up here.
    refresh({ fresh: true })
    reloadConversation(true)
  }

  Process {
    id: fetchProc
    running: false
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    stderr: StdioCollector { id: fetchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        root.errorCode = "helper_failed"
        root.errorMessage = Model.oneLine(fetchErr.text || "The helper could not be run", 160)
        return
      }
      var parsed = Model.parseJson(fetchOut.text, null)
      if (!parsed) {
        root.errorCode = "bad_output"
        root.errorMessage = "Could not read the helper's response"
        return
      }
      root.errorCode = ""
      root.errorMessage = ""
      root.snapshot = parsed
      root.painted = true
      // Announced whether this snapshot was earned here or read off disk.
      // There is exactly one service that speaks - see `notifies`, elected in
      // BarWidget.qml - so there is nobody to say it twice, and skipping a
      // shared snapshot used to mean a message announced by nobody at all
      // when the poll that found it was somebody else's. Notifier.observe is
      // keyed by conversation and ts and drops what it has already said, so
      // seeing the same snapshot twice is silent.
      root.announceNew()
      root.loadPresence()
      // Painted from a snapshot somebody else earned, and worth replacing with
      // a poll of our own only when it is genuinely old: that is the bootstrap
      // case, where anything on disk beats a blank sidebar for the length of a
      // poll. A snapshot from this interval is already what a poll would have
      // produced - chasing that one is how this service became the third
      // poller on a two-monitor desktop, and now that the helper hands back
      // what another process's poll wrote it would not even terminate: every
      // answer would come back shared and ask for one more.
      if (parsed.cached === true && Number(parsed.age || 0) > root.refreshIntervalSec)
        Qt.callLater(function() { root.refresh({ maxAge: 0 }) })
      // A conversation open while the list refreshed is still the one being
      // read; reloading it here would scroll the transcript out from under
      // whoever is reading it.
      if (root.refreshQueued) Qt.callLater(root.refresh)
    }
  }

  // ---- when it is worth asking at all -------------------------------------
  //
  // See PollGate.qml. It gates the timer only: a refresh anybody asked for by
  // hand still goes out, because a failure the user can see beats a silence
  // they cannot.
  // A poll costs a search against Slack's budget whether or not anybody is here.
  readonly property bool pausePolling: setting("pausePolling", true) !== false

  PollGate {
    id: poll
    pauseWhenAway: root.pausePolling
    pauseWhenOffline: root.pausePolling
    slowOnBattery: root.pausePolling
  }

  // For a host that wants to explain a sidebar that is not moving.
  readonly property string pollReason: poll.reason

  // triggeredOnStart is what makes waking up and coming back online immediate:
  // the gate opening restarts this timer, and a restarted timer fires at once
  // rather than an interval later.
  Timer {
    interval: root.refreshIntervalSec * 1000 * poll.intervalScale
    repeat: true
    running: root.configured && !poll.paused
    triggeredOnStart: true
    // Deferred for the same reason the handlers above are: this fires the
    // moment `configured` flips, which is the moment the settings are still
    // arriving.
    onTriggered: root.scheduleRefresh()
  }

  // Deferred, every one of them. These three fire while the property system is
  // still settling: `configured` depends on the alias alone, so its handler
  // runs before the bindings for everything else read out of the same settings
  // - and a fetch started there asked with the old values. It cost an hour to
  // find, because what it looked like was the demo fixtures being ignored.
  function scheduleRefresh() { Qt.callLater(refresh) }

  onConfiguredChanged: if (configured) { loadPalette(); loadReactionChoices(); scheduleRefresh() }
  onPluginDirChanged: if (configured) { loadPalette(); loadReactionChoices(); scheduleRefresh() }
  onSettingsChanged: if (configured) scheduleRefresh()

  // ---- telling you something arrived -------------------------------------

  // The argv omarchy's notification service runs when a toast is clicked. It
  // goes through the shell rather than the window, because the click may
  // arrive when no window is loaded - summon() mounts it and hands the payload
  // to open(), and delivers it straight away when it is already up.
  readonly property string pluginId: "janrenz.omarchy.slack"

  function summonArgv(payloadJson) {
    return ["omarchy-shell", "shell", "summon", pluginId, String(payloadJson || "{}")]
  }

  // JSON.stringify rather than a hand-built string: a conversation id comes
  // from the server, and quoting it is not ours to guess at.
  function openConversationArgv(id, ts) {
    return summonArgv(JSON.stringify({
      conversation: String(id || ""),
      message: String(ts || "")
    }))
  }

  Notifier {
    id: notifier
    appName: "Slack"
    plural: "new messages"
    // The same glyph the bar widget defaults to, so the toast is recognisably
    // this plugin's at a glance.
    glyph: "󰒱"
    // Clicking a digest opens the window on whatever it was showing: a digest
    // is about several conversations, so there is no one to open.
    defaultExec: root.summonArgv("{}")
    // Not while the demo fixtures are on: dev/showcase.sh turns them on to
    // take the README's pictures, and a screenshot run should not push six
    // notifications about invented people onto a real desktop.
    enabled: root.notifies && root.notifyOnNew && !root.demo
  }

  // Another workspace's messages are not this one's, and signing out means the
  // next sign-in starts over: prime again rather than announce the backlog.
  //
  // What was open goes with it. A conversation left on screen after the token
  // stopped working is a window still headed "#platform" over a sign-in box,
  // which is the one moment it matters that the header says where you are.
  onAliasChanged: { notifier.forget(); snapshot = null; closeConversation() }
  onSignedInChanged: if (!signedIn) { notifier.forget(); closeConversation() }

  function announceNew() {
    var rows = (view.dms || []).concat(view.channels || [])
    var fresh = []
    var present = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      // The conversation and when it last spoke. The next message in the same
      // one is a new thing to be told about; the same message polled again is
      // not.
      var id = String(row.id || "") + "@" + String(row.ts || "")
      present.push(id)
      if (row.unread !== true) continue
      // Your own last word is not news.
      var from = String(row.lastFrom || "")
      if (from === "you") continue
      var title = String(row.title || "")
      fresh.push({
        id: id,
        summary: title,
        // A direct message is titled with the person's name, so repeating it
        // in front of every line only takes room from what they said.
        body: (from !== "" && from !== title ? from + ": " : "") + String(row.lastText || ""),
        // Clicking it opens that conversation on that message.
        exec: root.openConversationArgv(row.id, row.ts),
        // Three messages in one conversation are one conversation with
        // something to say, so the newest updates the toast the last one left
        // rather than stacking a third under it. Keyed by conversation, which
        // is exactly what the announced id is not: that one carries the ts, so
        // that a *new* message counts as news.
        replaceKey: String(row.id || "")
      })
    }
    notifier.observe("", fresh, present)
  }

  // ---- who is around -----------------------------------------------------
  //
  // Asked for after the sidebar is on screen rather than before, because it is
  // one request per person: twenty of them were five of the nine seconds a
  // poll used to take, all of it in front of the first thing anybody sees.

  property var presenceByUser: ({})

  function loadPresence() {
    if (!wantsDecoration || !wantPresence || !view.canSeePresence) return
    if (presenceProc.running || pluginDir === "") return
    var people = Model.presenceWantedFromRows(conversations, 20)
    if (people.length === 0) return
    var command = ["python3", helper(), "presence", "--account", alias]
    for (var i = 0; i < people.length; i++) command = command.concat(["--user", people[i]])
    if (demo) command.push("--demo")
    presenceProc.command = command
    presenceProc.running = true
  }

  Process {
    id: presenceProc
    running: false
    stdout: StdioCollector { id: presenceOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(presenceOut.text, null)
      // A dot nobody can draw is not worth an error anybody has to read.
      if (exitCode !== 0 || !parsed || parsed.ok === false) return
      root.presenceByUser = parsed.presence || ({})
    }
  }

  // ---- one conversation --------------------------------------------------

  property var openConversation: null
  property var messages: []
  property bool messagesLoading: false
  property string messagesError: ""
  // The message a search result asked to be shown, so the transcript can say
  // which one it jumped to.
  property string anchorTs: ""

  // The thread being read, by its parent's ts. A thread is the one shape Slack
  // has that Teams does not, and it is where half of a busy workspace's
  // conversation actually happens - so it is a view of its own rather than a
  // few replies flattened into the channel.
  property string threadTs: ""
  property var threadParent: null

  readonly property bool reading: openConversation !== null
  readonly property bool inThread: threadTs !== ""

  // `fresh` means go to Slack whatever is on disk. Opening a conversation does
  // not: the helper keeps the last transcript it read and can tell, out of
  // what the poll already remembers, whether it is still current - which is
  // what makes clicking through four channels cost one request instead of one
  // refusal each. See the "a transcript, remembered" section of slack.py.
  // Pressing r means it, and so does the reload after sending or reacting:
  // that one is looking for something Slack has just been told and nothing
  // local knows yet.
  function fetchMessages(row, thread, anchor, fresh) {
    if (!row) return
    messagesError = ""
    messagesLoading = true
    if (messageProc.running) messageProc.running = false
    var command = ["python3", helper(), "messages", "--account", alias,
                   "--channel", String(row.id), "--top", "40"]
    if (String(thread || "") !== "") command = command.concat(["--thread", String(thread)])
    if (String(anchor || "") !== "") command = command.concat(["--around", String(anchor)])
    if (fresh === true) command.push("--fresh")
    if (!wantAvatars) command.push("--no-avatars")
    if (demo) command.push("--demo")
    messageProc.command = command
    messageProc.running = true
  }

  function openConversationRow(row, anchor) {
    if (!row) return
    if (openConversation && String(openConversation.key) === String(row.key)
        && String(anchor || "") === "") {
      closeConversation()
      return
    }
    openConversation = row
    threadTs = ""
    threadParent = null
    anchorTs = String(anchor || "")
    // Another conversation's canvas is not this one's, and the transcript that
    // is about to land says whether this one has any.
    canvasFileId = ""
    canvasOpen = false
    canvas = null
    canvasError = ""
    // A different conversation, so what is on screen belongs to the last one.
    messages = []
    draft = ""
    fetchMessages(row, "", anchorTs)

    // Opening a conversation is reading it - but only when there was something
    // to read, so this is not a write on every click. What it is marked read
    // up to is the newest message, which is known once the transcript lands.
    markOnLoad = row.unread === true
  }

  // The sidebar row for a conversation id, when there is one. What the quick
  // switcher and a search result hand over is an id and a name; the row knows
  // whether anything in it is unread, which is what decides whether opening it
  // is also reading it.
  function rowFor(id) {
    var lists = [view.dms || [], view.channels || []]
    for (var l = 0; l < lists.length; l++)
      for (var i = 0; i < lists[l].length; i++)
        if (String(lists[l][i].id) === String(id)) return Model.conversationRow(lists[l][i])
    return null
  }

  // Somewhere the sidebar has no row for: a search result, a channel just
  // joined, a DM just opened. Given the same shape a row has so that
  // everything downstream - the header, the composer, marking read - carries
  // on without knowing the difference.
  function openById(id, title, kind, anchor) {
    if (String(id || "") === "") return
    // Jumping to the conversation you are already reading is not a request to
    // close it, which is what openConversationRow would make of it - that
    // toggle belongs to clicking a row in the sidebar. Without an anchor there
    // is nothing to re-read, so this is already done.
    if (openConversation && String(openConversation.id) === String(id)
        && String(anchor || "") === "") return
    var known = rowFor(id)
    if (known) {
      // The real row, so its unread mark comes with it and opening it clears
      // that mark the way opening it from the sidebar would.
      if (String(title || "") !== "") known.title = String(title)
      openConversationRow(known, anchor)
      return
    }
    openConversationRow({
      kind: "conversation", key: "c:" + String(id), id: String(id),
      title: String(title || ""), channelKind: String(kind || "channel"),
      subtitle: "", topic: "", when: "", ts: "", unread: false, unreadCount: 0,
      presence: "", avatar: "", current: false
    }, anchor)
  }

  property bool markOnLoad: false

  function closeConversation() {
    openConversation = null
    threadTs = ""
    threadParent = null
    anchorTs = ""
    messages = []
    messagesError = ""
    draft = ""
    canvasFileId = ""
    canvasOpen = false
    canvas = null
    canvasError = ""
  }

  function openThread(parentTs, parentRow) {
    var ts = String(parentTs || "")
    if (ts === "" || !openConversation) return
    threadTs = ts
    threadParent = parentRow || null
    anchorTs = ""
    messages = []
    draft = ""
    fetchMessages(openConversation, ts, "")
  }

  function closeThread() {
    if (threadTs === "") return
    threadTs = ""
    threadParent = null
    messages = []
    draft = ""
    fetchMessages(openConversation, "", "")
  }

  // Re-read what is open. Deliberately not by closing and reopening it: that
  // emptied the transcript before the new rows arrived, so it flashed blank.
  // The same rows stay on screen until better ones land.
  function reloadConversation(fresh) {
    if (!openConversation) return
    fetchMessages(openConversation, threadTs, anchorTs, fresh)
  }

  Process {
    id: messageProc
    running: false
    stdout: StdioCollector { id: messageOut; waitForEnd: true }
    stderr: StdioCollector { id: messageErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.messagesLoading = false
      var parsed = Model.parseJson(messageOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.messagesError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(messageErr.text || "Could not read this conversation", 160)
        return
      }
      root.messagesError = ""
      root.messages = parsed.messages || []
      // Marked read up to the newest message actually read, which is only
      // known now.
      if (root.markOnLoad && root.threadTs === "" && root.messages.length > 0) {
        root.markOnLoad = false
        root.markRead(root.newestKnownTs())
      }
      // Reading a thread is reading it. Slack has no method for a thread's read
      // mark, so this is remembered on this machine - see threadRead below.
      if (root.threadTs !== "" && root.messages.length > 0) root.threadRead()
      // Whether this channel keeps a canvas. It arrives with the transcript
      // because the helper can answer it there for one cheap request; nothing
      // is downloaded until somebody presses the button.
      if (root.threadTs === "") root.canvasFileId = String(parsed.canvasFileId || "")
    }
  }

  // ---- the channel's canvas ----------------------------------------------
  //
  // A channel canvas is the document pinned to the top of a channel, and until
  // now reading one meant leaving for Slack. It is fetched only when asked
  // for: it is a document, and most of the time it is not what was being
  // opened.

  property string canvasFileId: ""
  property var canvas: null
  property bool canvasOpen: false
  property bool canvasLoading: false
  property string canvasError: ""

  readonly property bool hasCanvas: canvasFileId !== ""

  function toggleCanvas() {
    if (canvasOpen) {
      canvasOpen = false
      return
    }
    if (!hasCanvas || !openConversation) return
    canvasOpen = true
    // Kept from last time where it is the same one: a canvas is a document
    // somebody is reading beside the conversation, and re-fetching it on every
    // glance would mean the pane going blank each time it opened.
    if (canvas && String(canvas.fileId) === canvasFileId) return
    loadCanvas()
  }

  function loadCanvas() {
    if (!openConversation || canvasFileId === "" || pluginDir === "") return
    if (canvasProc.running) canvasProc.running = false
    canvasError = ""
    canvasLoading = true
    var command = ["python3", helper(), "canvas", "--account", alias,
                   "--channel", String(openConversation.id), "--file", canvasFileId]
    if (demo) command.push("--demo")
    canvasProc.command = command
    canvasProc.running = true
  }

  Process {
    id: canvasProc
    running: false
    stdout: StdioCollector { id: canvasOut; waitForEnd: true }
    stderr: StdioCollector { id: canvasErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.canvasLoading = false
      var parsed = Model.parseJson(canvasOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.canvasError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(canvasErr.text || "Could not read this canvas", 160)
        return
      }
      root.canvasError = ""
      root.canvas = parsed.canvas || null
      // The channel said it had one and the helper found none - somebody
      // deleted it, or emptied it. Take the button away rather than leaving it
      // to fail again.
      if (!root.canvas) root.canvasFileId = ""
    }
  }

  // ---- marking read ------------------------------------------------------

  // A thread the reader has now seen.
  //
  // `conversations.mark` is the channel's mark and Slack offers nothing for a
  // thread, so the chip in the channel would go on saying "new" about a thread
  // that was read right here - and it is this window's job to be where the
  // reading happens. slack.py keeps the mark on this machine and only ever
  // uses it to take a mark off, never to invent one.
  function threadRead() {
    if (!openConversation || threadTs === "" || pluginDir === "" || demo) return
    if (threadReadProc.running) return
    var newest = threadTs
    for (var i = 0; i < messages.length; i++) {
      var ts = String(messages[i].ts || "")
      if (ts !== "" && Number(ts) > Number(newest)) newest = ts
    }
    threadReadProc.command = ["python3", helper(), "thread-read", "--account", alias,
                              "--channel", String(openConversation.id),
                              "--ts", String(threadTs), "--upto", newest]
    threadReadProc.running = true
  }

  Process {
    id: threadReadProc
    running: false
    // Local bookkeeping: there is nothing for the window to say if it fails,
    // and nothing it could offer to do about it. The chip simply keeps its
    // mark, which is what it did before any of this existed.
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }


  property string markReadError: ""

  function markRead(ts) {
    var stamp = String(ts || "")
    if (!openConversation || stamp === "" || markReadProc.running || pluginDir === "") return
    if (demo) return
    if (!canMarkRead) return
    markReadProc.command = ["python3", helper(), "mark-read", "--account", alias,
                            "--channel", String(openConversation.id), "--ts", stamp]
    markReadProc.running = true
  }

  // The newest thing this conversation is known to hold.
  //
  // Not simply the last row of the transcript: the transcript is the channel
  // timeline, and a reply inside a thread is not in it. A thread reply is
  // exactly what leaves a conversation unread with nothing on screen left to
  // read - the sidebar row's ts comes from the search feed, which does see
  // replies, so it can be newer than anything the transcript holds. Slack
  // takes a reply's ts for conversations.mark and keeps it, so marking up to
  // the newer of the two is what makes those rows go quiet.
  //
  // The row is looked up again rather than read off openConversation, which
  // is the snapshot taken when the conversation was opened and does not grow
  // a newer ts while it stays open.
  function newestKnownTs() {
    if (!openConversation) return ""
    var seen = messages.length > 0 ? String(messages[messages.length - 1].ts || "") : ""
    var fresh = rowFor(String(openConversation.id))
    var candidates = [seen, String(openConversation.ts || ""),
                      fresh ? String(fresh.ts || "") : ""]
    var best = ""
    for (var i = 0; i < candidates.length; i++)
      if (candidates[i] !== ""
          && (best === "" || parseFloat(candidates[i]) > parseFloat(best)))
        best = candidates[i]
    return best
  }

  // Whether marking read would do anything: something is open, something in
  // it is still waiting, and nothing is already on its way to clearing it.
  // What the button hangs its visibility on.
  //
  // The three "on its way" guards are what keep it from blinking into
  // existence for a second every time an unread conversation is opened -
  // opening one already marks it read, and the button is for the rows that
  // are still lit once that has run its course.
  readonly property bool canMarkCurrentRead: {
    if (!openConversation || !canMarkRead) return false
    if (markOnLoad || markingRead || loading) return false
    var fresh = rowFor(String(openConversation.id))
    return fresh ? fresh.unread === true : openConversation.unread === true
  }

  // What the m key does: mark this conversation read up to whatever it is
  // known to hold, without having to open every unread one to make the bar go
  // quiet.
  function markCurrentRead() {
    markRead(newestKnownTs())
  }

  readonly property bool markingRead: markReadProc.running

  Process {
    id: markReadProc
    running: false
    stdout: StdioCollector { id: markReadOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(markReadOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.markReadError = parsed && parsed.error
          ? String(parsed.error.message) : "Could not mark this conversation read"
        return
      }
      root.markReadError = ""
      // The mark lives in the conversation list, which this has just changed
      // on the server; re-read it so the list agrees with what was done.
      root.refresh()
    }
  }

  // ---- sending -----------------------------------------------------------

  property string draft: ""
  property bool sending: false
  property string sendError: ""
  // A thread reply that also lands in the channel, which is Slack's "also send
  // to #channel" tick and the only way a thread reaches anyone not in it.
  property bool alsoToChannel: false

  function send() {
    if (sending || !openConversation || draft.trim() === "" || pluginDir === "") return
    if (!canPost) { sendError = "This token cannot post messages"; return }
    sending = true
    sendError = ""
    var command = ["python3", helper(), "send", "--account", alias,
                   "--channel", String(openConversation.id), "--stdin"]
    if (threadTs !== "") {
      command = command.concat(["--thread", threadTs])
      if (alsoToChannel) command.push("--broadcast")
    }
    if (demo) command.push("--demo")
    sendProc.command = command
    sendProc.running = true
  }

  // ---- sending a file ------------------------------------------------------
  //
  // Three requests inside slack.py, and the middle one is the only place this
  // plugin ever *sends* the user's data anywhere - so the path goes in over
  // stdin like a message does, and the helper checks the host Slack named
  // before any of the bytes leave.

  property bool uploading: false
  property string uploadError: ""
  // What was sent, for a line that says so. Cleared by the next attempt.
  property string uploadNotice: ""
  property string uploadPath: ""

  function uploadFile(path) {
    var file = String(path || "").trim()
    if (!openConversation || file === "" || pluginDir === "") return
    // Both of these used to be a silent return, which is what a file dropped
    // on the window looked like from the outside: nothing happened and nothing
    // said why. They are the two answers a drop most often deserves.
    if (uploading) {
      uploadError = "One file at a time - the last one is still going up"
      return
    }
    if (!canUpload) {
      uploadError = "This token cannot send files. Add files:write to your Slack app, "
                  + "reinstall it, and paste the new token in Settings."
      return
    }
    uploading = true
    uploadError = ""
    uploadNotice = ""
    uploadPath = file
    var command = ["python3", helper(), "upload", "--account", alias,
                   "--channel", String(openConversation.id), "--stdin"]
    if (threadTs !== "") command = command.concat(["--thread", threadTs])
    if (demo) command.push("--demo")
    uploadProc.command = command
    uploadProc.running = true
  }

  Process {
    id: uploadProc
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: uploadOut; waitForEnd: true }
    stderr: StdioCollector { id: uploadErrOut; waitForEnd: true }
    // Whatever is in the message box rides along as the file's comment, which
    // is what Slack itself does when you drop a file on a conversation with
    // something already typed.
    onStarted: uploadProc.write(JSON.stringify({
      file: root.uploadPath, comment: root.draft
    }) + "\n")
    onExited: function(exitCode) {
      root.uploading = false
      var parsed = Model.parseJson(uploadOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.uploadError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(uploadErrOut.text || "Could not send that file", 160)
        // The draft stays put, for the same reason a failed send leaves it:
        // the comment is something somebody typed.
        return
      }
      root.uploadNotice = "Sent " + String(parsed.title || "that file")
      root.draft = ""
      root.reloadConversation(true)
      root.refresh()
    }
  }

  Process {
    id: sendProc
    running: false
    // The message goes in over stdin rather than as an argument. Anyone on
    // this machine can read /proc/<pid>/cmdline; nobody can read another
    // process's stdin.
    stdinEnabled: true
    stdout: StdioCollector { id: sendOut; waitForEnd: true }
    stderr: StdioCollector { id: sendErrOut; waitForEnd: true }
    onStarted: sendProc.write(JSON.stringify({ text: root.draft }) + "\n")
    onExited: function(exitCode) {
      root.sending = false
      var parsed = Model.parseJson(sendOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.sendError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(sendErrOut.text || "Could not send that message", 160)
        // The draft stays put. Losing what someone typed because the network
        // blinked is the one failure they cannot recover from.
        return
      }
      root.draft = ""
      root.reloadConversation(true)
      root.refresh()
    }
  }

  // ---- reactions ---------------------------------------------------------

  // What the picker offers, asked of the helper rather than listed here, so
  // the picker and the sender cannot disagree about what a name means.
  property var reactionChoices: []
  property bool reacting: false
  property string reactError: ""

  function loadReactionChoices() {
    if (reactionChoicesProc.running || pluginDir === "" || reactionChoices.length > 0) return
    reactionChoicesProc.command = ["python3", helper(), "reactions"]
    reactionChoicesProc.running = true
  }

  Process {
    id: reactionChoicesProc
    running: false
    stdout: StdioCollector { id: reactionChoicesOut; waitForEnd: true }
    onExited: function(_exitCode) {
      var parsed = Model.parseJson(reactionChoicesOut.text, null)
      if (parsed && parsed.ok !== false) root.reactionChoices = parsed.reactions || []
    }
  }

  function react(ts, name, remove) {
    var stamp = String(ts || "")
    if (stamp === "" || !openConversation || reacting || pluginDir === "") return
    if (demo) return
    if (!canReact) { reactError = "This token cannot react to messages"; return }
    reacting = true
    reactError = ""
    var command = ["python3", helper(), "react", "--account", alias,
                   "--channel", String(openConversation.id), "--ts", stamp,
                   "--emoji", String(name)]
    if (remove === true) command.push("--remove")
    reactProc.command = command
    reactProc.running = true
  }

  Process {
    id: reactProc
    running: false
    stdout: StdioCollector { id: reactOut; waitForEnd: true }
    stderr: StdioCollector { id: reactErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.reacting = false
      var parsed = Model.parseJson(reactOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.reactError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(reactErrOut.text || "Could not change that reaction", 160)
        return
      }
      root.reactError = ""
      // Re-read rather than guess at the new count: somebody else may have
      // reacted in the meantime, and the transcript should show what is there.
      root.reloadConversation(true)
    }
  }

  // ---- jumping to anything -----------------------------------------------
  //
  // Slack's own Ctrl-K, which is how most people who use Slack navigate it.
  // The lists it searches are cached by the helper and filtered there, so
  // typing is not a network round trip per keystroke.

  property var directory: ({ people: [], channels: [] })
  property bool directoryLoading: false
  property string directoryError: ""
  property string switcherQuery: ""
  property bool switching: false

  readonly property var switcherRows: Model.switcherRows(switcherQuery, view, directory, 12)

  function lookUp(query) {
    switcherQuery = String(query || "")
    if (directoryProc.running || pluginDir === "" || !configured) return
    directoryLoading = true
    var command = ["python3", helper(), "directory", "--account", alias,
                   "--query", switcherQuery]
    if (demo) command.push("--demo")
    directoryProc.command = command
    directoryProc.running = true
  }

  Process {
    id: directoryProc
    running: false
    stdout: StdioCollector { id: directoryOut; waitForEnd: true }
    stderr: StdioCollector { id: directoryErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.directoryLoading = false
      var parsed = Model.parseJson(directoryOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.directoryError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(directoryErrOut.text || "Could not look that up", 160)
        return
      }
      root.directoryError = String(parsed.warning || "")
      root.directory = { people: parsed.people || [], channels: parsed.channels || [] }
    }
  }

  // Enter on a switcher row. Which of the three things it does is decided by
  // the row, not guessed at here.
  function jumpTo(row) {
    if (!row) return
    if (row.action === "open") {
      openById(row.id, row.title, row.channelKind, "")
      return
    }
    if (row.action === "join") { joinChannel(row.id, row.title); return }
    if (row.action === "dm") { openDirect(row.userId || row.id, row.title); return }
  }

  property bool joining: false
  property string jumpError: ""

  function joinChannel(id, title) {
    if (joining || pluginDir === "") return
    joining = true
    jumpError = ""
    pendingTitle = String(title || "")
    pendingKind = "channel"
    var command = ["python3", helper(), "join", "--account", alias, "--channel", String(id)]
    if (demo) command.push("--demo")
    jumpProc.command = command
    jumpProc.running = true
  }

  function openDirect(userId, title) {
    if (joining || pluginDir === "" || String(userId || "") === "") return
    joining = true
    jumpError = ""
    pendingTitle = String(title || "")
    pendingKind = "im"
    var command = ["python3", helper(), "open-dm", "--account", alias, "--user", String(userId)]
    if (demo) command.push("--demo")
    jumpProc.command = command
    jumpProc.running = true
  }

  property string pendingTitle: ""
  property string pendingKind: "channel"

  Process {
    id: jumpProc
    running: false
    stdout: StdioCollector { id: jumpOut; waitForEnd: true }
    stderr: StdioCollector { id: jumpErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.joining = false
      var parsed = Model.parseJson(jumpOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.jumpError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(jumpErrOut.text || "Could not open that", 160)
        return
      }
      root.jumpError = ""
      root.openById(String(parsed.id || ""),
                    String(parsed.title || root.pendingTitle), root.pendingKind, "")
      // It is a conversation of yours now, so the list has to be read again -
      // the cached one does not have it in it.
      root.refresh({ fresh: true })
    }
  }

  // ---- searching ---------------------------------------------------------

  property var searchResults: []
  property bool searching: false
  property string searchError: ""
  property string searchQuery: ""

  function searchMessages(query) {
    var text = String(query || "").trim()
    searchQuery = text
    searchError = ""
    if (text === "") { searchResults = []; return }
    if (!canSearch) {
      searchError = "This token cannot search. Add search:read to your Slack app and reinstall it."
      return
    }
    if (searchProc.running || pluginDir === "") return
    searching = true
    var command = ["python3", helper(), "search", "--account", alias, "--query", text]
    if (demo) command.push("--demo")
    searchProc.command = command
    searchProc.running = true
  }

  function clearSearch() {
    searchQuery = ""
    searchResults = []
    searchError = ""
  }

  Process {
    id: searchProc
    running: false
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    stderr: StdioCollector { id: searchErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.searching = false
      var parsed = Model.parseJson(searchOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.searchError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(searchErrOut.text || "Could not search", 160)
        root.searchResults = []
        return
      }
      root.searchError = ""
      root.searchResults = Model.searchRows(parsed.matches || [])
    }
  }

  // ---- signing in --------------------------------------------------------
  //
  // A pasted token, and no flow to speak of: Slack will not send a browser
  // back to a machine with no https address, so there is nothing for this
  // plugin to host. The token goes to the helper over stdin - anyone on this
  // machine can read another process's arguments, and nobody can read its
  // stdin - and is never held here.

  property bool signingIn: false
  property string signInMessage: ""
  property string signInError: ""
  // Held for exactly as long as it takes to hand to the helper, and cleared
  // the moment the process has it.
  property string pendingToken: ""

  function signIn(token) {
    if (signingIn || pluginDir === "" || !configured) return
    var text = String(token || "").trim()
    if (text === "") { signInError = "Paste the User OAuth Token from your Slack app"; return }
    signingIn = true
    signInError = ""
    signInMessage = "Checking that token…"
    pendingToken = text
    loginProc.command = ["python3", helper(), "login-set", "--account", alias]
    loginProc.running = true
  }

  Process {
    id: loginProc
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: loginOut; waitForEnd: true }
    stderr: StdioCollector { id: loginErrOut; waitForEnd: true }
    onStarted: {
      loginProc.write(JSON.stringify({ token: root.pendingToken }) + "\n")
      root.pendingToken = ""
    }
    onExited: function(exitCode) {
      root.signingIn = false
      root.pendingToken = ""
      var parsed = Model.parseJson(loginOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.signInError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(loginErrOut.text || "Could not use that token", 160)
        root.signInMessage = ""
        return
      }
      root.signInError = ""
      root.signInMessage = "Signed in to " + String(parsed.team || "Slack")
        + " as " + String(parsed.user || "")
      root.refresh()
    }
  }

  function signOut() {
    if (pluginDir === "" || !configured) return
    signOutProc.command = ["python3", helper(), "remove", "--account", alias]
    signOutProc.running = true
  }

  Process {
    id: signOutProc
    running: false
    stdout: StdioCollector { id: signOutOut; waitForEnd: true }
    onExited: function(_exitCode) {
      root.snapshot = null
      root.closeConversation()
      root.signInMessage = ""
      // Nothing on disk is worth believing about a workspace that has just
      // been signed out of, and this is the one refresh where being told the
      // truth matters more than being told quickly: the token box only appears
      // once the answer says nobody is signed in.
      root.painted = false
      root.refresh({ fresh: true })
    }
  }

  // ---- saving settings ---------------------------------------------------

  property bool saving: false
  property string saveError: ""
  signal settingsSaved()

  function saveSettings(patch) {
    if (saving || pluginDir === "") return false
    saving = true
    saveError = ""
    saveProc.command = ["python3", pluginDir + "/config.py",
                        "--plugin-id", "janrenz.omarchy.slack",
                        "--set", JSON.stringify(patch || {})]
    saveProc.running = true
    return true
  }

  Process {
    id: saveProc
    running: false
    stdout: StdioCollector { id: saveOut; waitForEnd: true }
    stderr: StdioCollector { id: saveErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.saving = false
      var parsed = Model.parseJson(saveOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.saveError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(saveErrOut.text || "Could not save these settings", 160)
        return
      }
      root.saveError = ""
      // The shell watches shell.json and hands the new values back through
      // `settings`; this only says the write landed.
      root.settingsSaved()
    }
  }

  // ---- the theme's colours -----------------------------------------------

  property var themeColors: ({})

  function loadPalette() {
    if (paletteProc.running || pluginDir === "") return
    paletteProc.command = ["python3", helper(), "palette"]
    paletteProc.running = true
  }

  Process {
    id: paletteProc
    running: false
    stdout: StdioCollector { id: paletteOut; waitForEnd: true }
    onExited: function(_exitCode) {
      var parsed = Model.parseJson(paletteOut.text, null)
      if (parsed && parsed.colors) root.themeColors = parsed.colors
    }
  }

  // ---- demo auto-open ------------------------------------------------------
  //
  // Screenshots have to be reproducible, and there is no key that opens a
  // conversation - only a click, which an automated run cannot aim at a row
  // whose position depends on the theme's font size. So demo mode can be told
  // which conversation to open and does it itself, as soon as the list is
  // there. Ignored unless "demo" is on, so it can never touch a real workspace.
  readonly property string demoOpen: demo ? String(setting("demoOpen", "")).trim() : ""
  property bool demoOpened: false

  onConversationsChanged: {
    if (demoOpen === "" || demoOpened) return
    var rows = conversations
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "conversation" && String(rows[i].id) === demoOpen) {
        demoOpened = true
        // Not openConversationRow: opening the one that is already open is
        // how a click closes it, and the fixtures re-open the same
        // conversation every time the list is refreshed.
        if (!openConversation || String(openConversation.id) !== demoOpen)
          openConversationRow(rows[i], "")
        return
      }
    }
  }

  // The last gate before xdg-open, which opens whatever it is handed - a
  // file:// path, a handler registered for some scheme nobody remembers
  // installing. Both sides that build a link already keep to these three, so
  // this changes nothing that works; it is here so that a link arriving by
  // some route added later cannot reach the opener without passing it.
  function openUrl(url) {
    var target = String(url || "").trim()
    var lowered = target.toLowerCase()
    if (lowered.indexOf("http://") !== 0 && lowered.indexOf("https://") !== 0
        && lowered.indexOf("mailto:") !== 0) return
    Quickshell.execDetached(["xdg-open", target])
  }
}
