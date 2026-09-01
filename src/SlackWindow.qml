import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Slack window: conversations on the left, the transcript on the right, a
// box to answer in, and threads as a view of their own.
//
// A real Hyprland toplevel, hosted by the shell because the manifest declares
// the "panel" kind. Summon it with:
//   omarchy-shell shell toggle janrenz.omarchy.slack
Item {
  id: root

  readonly property string pluginId: "janrenz.omarchy.slack"

  // ---- host injections ----------------------------------------------------
  property var shell: null
  property var manifest: null

  property bool closingFromHost: false

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return decodeURIComponent(url.replace(/\/$/, ""))
  }

  // Deliberately not called `service`: the shell assigns that name on every
  // panel it loads and would overwrite it with null for a plugin that declares
  // no service kind.
  readonly property alias slackService: service
  // The toplevel itself, so the development harness can photograph what this
  // draws without the shell in the way. Nothing in the plugin uses it.
  readonly property alias floatingWindow: window

  function open(_payloadJson) {
    closingFromHost = false
    loadSettings()
    window.visible = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // ---- the widget's settings ----------------------------------------------
  // The window is one per plugin and the widget owns the configuration, so the
  // window reads it out of shell.json rather than having any of its own.
  property var settings: ({})
  property bool settingsLoaded: false
  property string settingsError: ""

  function loadSettings() {
    if (configProc.running || pluginDir === "") return
    configProc.command = ["python3", pluginDir + "/config.py",
                          "--plugin-id", root.pluginId, "--list"]
    configProc.running = true
  }

  Process {
    id: configProc
    running: false
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.settingsLoaded = true
      if (exitCode !== 0) {
        root.settingsError = Model.oneLine(configErr.text || "Could not read the bar layout", 160)
        return
      }
      var parsed = Model.parseJson(configOut.text, null)
      if (!parsed || parsed.ok === false) {
        root.settingsError = "Could not read the bar layout"
        return
      }
      var widgets = parsed.widgets || []
      if (widgets.length === 0) {
        root.settingsError = "No Slack widget in the bar. Add one and give it a workspace name."
        return
      }
      root.settingsError = ""
      root.settings = widgets[0].settings || {}
    }
  }

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
  }

  // ---- keyboard -----------------------------------------------------------
  //
  // Omarchy is keyboard-first, so this is a focus ladder rather than a handful
  // of shortcuts: list -> conversation -> message box, with h and l moving
  // between them and Escape walking back out one rung at a time. j and k
  // always mean "down and up in whatever has focus".
  //
  // "list" or "conversation". The message box is a real focus, so it is asked
  // rather than tracked.
  property string focusPane: "list"
  property bool showHelp: false
  property bool showSettings: false
  property bool showSwitcher: false
  property bool showSearch: false
  property bool filtering: false

  // The list that is actually on screen: narrow, that is the drawer's copy.
  function activeList() {
    return listDrawerOpen ? drawerList : conversations
  }

  function focusList() {
    focusPane = "list"
    // Narrow, the list is not on screen at all - bringing it out is what
    // "go back to the list" has to mean there.
    if (!columns.roomForBoth && service.reading) listDrawerOpen = true
    keyCatcher.forceActiveFocus()
  }

  function focusConversation() {
    if (!service.reading) return
    focusPane = "conversation"
    listDrawerOpen = false
    keyCatcher.forceActiveFocus()
  }

  // How much of the transcript's right edge its scrollbar covers. The bar is
  // drawn over the content, not beside it, so anything anchored right has to
  // step in by this much or it sits under a bar that takes the pointer first.
  readonly property real scrollGutter: {
    var bar = transcript.ScrollBar.vertical
    return bar ? bar.width : 0
  }

  // ---- the message the keyboard is on -------------------------------------
  //
  // Held by id, not by index. The transcript is re-read underneath this - a
  // refresh, a message sent, somebody else's arriving - and an index would
  // quietly come to mean a different message than the one it was put on.
  property string cursorMessageId: ""
  // Whose picker is open, at most one at a time. Owned here rather than by
  // each row so that opening one closes the last, and so the keyboard and the
  // mouse are opening the same thing.
  property string pickingMessageId: ""

  function messageById(id) {
    var list = service.messages
    for (var i = 0; i < list.length; i++)
      if (String(list[i].id) === String(id)) return list[i]
    return null
  }

  function messageIndex(id) {
    var list = service.messages
    for (var i = 0; i < list.length; i++)
      if (String(list[i].id) === String(id)) return i
    return -1
  }

  // j and k walk the transcript a message at a time. The first press starts at
  // the newest, which is what is on screen and what a conversation opens on.
  function moveMessageCursor(step) {
    var list = service.messages
    if (list.length === 0) { cursorMessageId = ""; return }
    // Walking away from the bottom is taking over from the follow-the-newest
    // behaviour, the same as scrolling by hand is.
    transcript.followNewest = false
    var at = messageIndex(cursorMessageId)
    var next = at < 0 ? list.length - 1 : Math.max(0, Math.min(list.length - 1, at + step))
    cursorMessageId = String(list[next].id || "")
    // Moving the cursor is not the moment to keep a half-open picker from the
    // message being left behind.
    pickingMessageId = ""
  }

  function cursoredMessage() {
    if (cursorMessageId === "" || messageIndex(cursorMessageId) < 0) {
      var list = service.messages
      if (list.length === 0) return null
      cursorMessageId = String(list[list.length - 1].id || "")
    }
    return messageById(cursorMessageId)
  }

  // Open the picker on the message under the cursor, putting the cursor on the
  // newest first if it is not anywhere yet - pressing e straight after opening
  // a conversation should react to the message you are looking at.
  function startPicking() {
    if (!service.reading) return
    var row = cursoredMessage()
    if (!row) return
    focusPane = "conversation"
    pickingMessageId = pickingMessageId === cursorMessageId ? "" : cursorMessageId
  }

  // The nth choice, by number, because nine of them numbered is faster than
  // nine of them arrowed through.
  function reactWith(index) {
    var choices = service.reactionChoices
    if (index < 0 || index >= choices.length) return
    var row = messageById(pickingMessageId)
    if (!row) return
    var name = String(choices[index].name || "")
    if (name === "") return
    pickingMessageId = ""
    // Pressing the one you already gave takes it back, the same as clicking
    // the chip does.
    service.react(row.ts, name, Model.reactionIsMine(row.reactions, name))
  }

  // The thread on the message under the cursor. Threads are where half of a
  // busy workspace's conversation happens, so they get a key of their own.
  function openThreadHere() {
    if (!service.reading || service.inThread) return
    var row = cursoredMessage()
    if (!row) return
    var parent = String(row.threadTs || "") !== "" ? String(row.threadTs) : String(row.ts)
    service.openThread(parent, row)
    focusPane = "conversation"
  }

  // Spacing, as properties rather than service.pad() calls inside each
  // binding: a binding that reaches its dependency through a function call
  // does not reliably re-run when that dependency changes.
  readonly property real densityScale: service.densityScale
  // Vertical only. Spacing is about how much air there is between things you
  // read down a list; widening the left and right margins just takes width
  // away from the words, which is the opposite of roomy.
  readonly property int padPanel: Math.max(1, Math.round(Style.spacing.panelPadding * densityScale))
  readonly property int padGap: Math.max(1, Math.round(Style.spacing.panelGap * densityScale))
  readonly property int padMessages: Math.max(1, Math.round(Style.spacing.lg * densityScale))
  readonly property int padLines: Math.max(1, Math.round(Style.spacing.xs * densityScale))
  readonly property int padReading: Math.max(1, Math.round(Style.spacing.md * densityScale))

  // The corner mark. This window and the Teams one are the same shape, the
  // same kit and usually the same size, so nothing on screen said which of
  // the two you had just summoned. The app's own glyph, in the app's own
  // colour, where a title bar would carry its icon, says it at a glance.
  readonly property color brandColor: "#36C5F0"
  readonly property int markSize: Math.round(Style.font.heading + Style.spacing.md * 2)

  // The list's marker column - the unread bar. It comes out of the panel's
  // left padding rather than out of the rows, so CHANNELS, every name and the
  // window title all begin on the same line.
  readonly property int listGutter: Style.spacing.md + Style.space(10)

  // The conversation list, over the transcript, for when the window is too
  // narrow to show both at once.
  property bool listDrawerOpen: false

  function toggleListDrawer() {
    listDrawerOpen = !listDrawerOpen
    if (listDrawerOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openSwitcher() {
    showSearch = false
    showSwitcher = true
    service.lookUp("")
    Qt.callLater(function() { if (switcher.item) switcher.item.focusInput() })
  }

  function closeSwitcher() {
    showSwitcher = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openSearch() {
    showSwitcher = false
    showSearch = true
    Qt.callLater(function() { if (searchPane.item) searchPane.item.focusInput() })
  }

  function closeSearch() {
    showSearch = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function startFiltering() {
    filtering = true
    if (!columns.roomForBoth && service.reading) listDrawerOpen = true
    Qt.callLater(function() { filterField.forceActiveFocus() })
  }

  function stopFiltering(clear) {
    if (clear === true) service.filterText = ""
    filtering = service.filterText !== ""
    keyCatcher.forceActiveFocus()
  }

  // Escape unwinds one layer at a time, innermost first, and never further
  // than one. A picture is not in this list: it opens in its own window, so
  // closing that closes the picture and leaves Slack alone.
  function dismiss() {
    if (showHelp) { showHelp = false; return }
    if (showSwitcher) { closeSwitcher(); return }
    if (showSearch) { closeSearch(); return }
    if (showSettings) { showSettings = false; return }
    if (pickingMessageId !== "") { pickingMessageId = ""; return }
    if (composer.activeFocus) { leaveComposer(); return }
    if (filterField.activeFocus) { stopFiltering(true); return }
    if (listDrawerOpen) { listDrawerOpen = false; focusPane = "list"; return }
    // Out of the thread and back to the channel it hangs off, which is one
    // step and not two: leaving a thread should not also close the channel.
    if (service.inThread) { service.closeThread(); return }
    // Back to the list with the conversation still open.
    if (focusPane === "conversation") { focusPane = "list"; return }
    if (service.reading) { service.closeConversation(); return }
    requestClose()
  }

  // Only where there is something to type into. Focusing a composer that is
  // not on screen would take the keys away from the conversation list and give
  // them to nothing.
  function focusComposer() {
    if (!service.reading) return
    composer.forceActiveFocus()
  }

  // ---- scrolling by keyboard ---------------------------------------------

  function scrollTarget() {
    if (listDrawerOpen) return drawerScroll
    if (focusPane === "conversation" && service.reading && transcript.visible) return transcript
    return sidebarScroll.visible ? sidebarScroll : null
  }

  function scrollBy(view, dy) {
    var flick = view ? view.contentItem : null
    if (!flick) return
    // Any deliberate scroll means the reader has taken over, so stop dragging
    // them back to the newest message.
    if (view === transcript) transcript.followNewest = false
    var limit = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(limit, flick.contentY + dy))
  }

  function scrollToEnd(view, toBottom) {
    var flick = view ? view.contentItem : null
    if (!flick) return
    if (view === transcript) transcript.followNewest = toBottom === true
    flick.contentY = toBottom === true ? Math.max(0, flick.contentHeight - flick.height) : 0
  }

  // Keep the cursored row on screen. Without this, j walks the cursor off the
  // bottom of the list and there is no sign of where it went.
  function ensureVisible(view, itemY, itemHeight) {
    var flick = view ? view.contentItem : null
    if (!flick || itemHeight <= 0) return
    var margin = Style.spacing.lg
    if (itemY - margin < flick.contentY)
      flick.contentY = Math.max(0, itemY - margin)
    else if (itemY + itemHeight + margin > flick.contentY + flick.height)
      flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height),
                                            itemY + itemHeight + margin - flick.height))
  }

  // Back to the conversation, with the draft left exactly as it is. The key
  // catcher is stood down while the composer has focus - it claims bare
  // letters - so this is the only way back to the keyboard without the mouse.
  function leaveComposer() {
    focusPane = "conversation"
    keyCatcher.forceActiveFocus()
  }

  FloatingWindow {
    id: window
    title: service.openConversation
      ? ("Slack — " + String(service.openConversation.title || ""))
      : "Slack"
    color: Color.background
    implicitWidth: 1080
    implicitHeight: 720
    minimumSize: Qt.size(640, 420)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      // PanelKeyCatcher's vocabulary is Escape, Tab, the arrows, j/k/h/l and
      // Return; Page, Home, End and the control chords are not in it and
      // arrive here instead. AfterItem so the catcher still gets first refusal
      // on what it does know.
      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        var control = (event.modifiers & Qt.ControlModifier) !== 0
        // The one chord that works from anywhere, including out of a text
        // field: it is how everybody who uses Slack moves around it.
        if (control && event.key === Qt.Key_K) {
          root.openSwitcher()
          event.accepted = true
          return
        }
        // While a field has focus the rest of these belong to the text in it.
        if (composer.activeFocus || filterField.activeFocus) return
        if (root.showSwitcher || root.showSearch) return
        var view = root.listDrawerOpen ? drawerScroll : root.scrollTarget()
        if (!view) return
        var page = Math.max(Style.space(80), view.height * 0.9)
        var half = page / 2

        if (event.key === Qt.Key_PageDown) root.scrollBy(view, page)
        else if (event.key === Qt.Key_PageUp) root.scrollBy(view, -page)
        else if (event.key === Qt.Key_Home) root.scrollToEnd(view, false)
        else if (event.key === Qt.Key_End) root.scrollToEnd(view, true)
        // The vim pair, for hands already on the home row.
        else if (control && event.key === Qt.Key_D) root.scrollBy(view, half)
        else if (control && event.key === Qt.Key_U) root.scrollBy(view, -half)
        else if (control && event.key === Qt.Key_F) root.scrollBy(view, page)
        else if (control && event.key === Qt.Key_B) root.scrollBy(view, -page)
        else return
        event.accepted = true
      }

      // The conversation list as a layer over the transcript.
      //
      // Qt's own answer to this is Controls' Drawer, and it is the right shape
      // - edge-anchored, modal, dismissed by the scrim. It does not work here:
      // inside a Quickshell FloatingWindow it reports visible with position
      // stuck at 0, so it never actually slides in. The shell's own panels
      // hand-roll their overlays for the same reason. This follows them.
      Item {
        id: listDrawer
        anchors.fill: parent
        visible: drawerSlide.x > -drawerPanel.width
        z: 80

        // Dimmed, not blacked out: the conversation underneath is the thing
        // being navigated away from, and it should still be legible.
        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.6)
          opacity: root.listDrawerOpen ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }

          MouseArea {
            anchors.fill: parent
            enabled: root.listDrawerOpen
            onClicked: root.listDrawerOpen = false
          }
        }

        Item {
          id: drawerSlide
          width: drawerPanel.width
          height: parent.height
          x: root.listDrawerOpen ? 0 : -drawerPanel.width
          Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

          Rectangle {
            id: drawerPanel
            width: Math.min(Style.space(320), listDrawer.width * 0.85)
            height: parent.height
            color: Color.background
            border.width: Style.space(1)
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

            // Swallows clicks so the list does not dismiss itself.
            MouseArea { anchors.fill: parent }

            ScrollView {
              id: drawerScroll
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              clip: true

              ConversationList {
                id: drawerList
                width: drawerPanel.width - Style.spacing.md * 2
                density: service.densityScale
                palette: service.themeColors
                showAvatars: service.wantAvatars
                rows: service.conversations
                selectedKey: service.openConversation ? String(service.openConversation.key) : ""
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onPicked: function(row) {
                  service.openConversationRow(row, "")
                  root.listDrawerOpen = false
                  if (service.reading) root.focusPane = "conversation"
                }
              }
            }
          }
        }
      }

      // The keyboard, listed. Over everything, because ? works from anywhere.
      Item {
        anchors.fill: parent
        visible: root.showHelp
        z: 110

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.97)

          MouseArea { anchors.fill: parent; onClicked: root.showHelp = false }

          KeyHelp {
            anchors.centerIn: parent
            fg: Color.foreground
            fontFamily: Style.font.family
          }
        }
      }

      // Jump to anything, and search everything. Loaders, because both carry a
      // list and neither is on screen most of the time.
      Loader {
        id: switcher
        anchors.fill: parent
        z: 95
        active: root.showSwitcher
        visible: active
        sourceComponent: QuickSwitcher {
          // The full path, and not the bare `service` id, because this is
          // inside a Loader's sourceComponent. An id from the enclosing file
          // reaches an ordinary child (the settings form below is written that
          // way and works), but inside an inline Component the object's own
          // property of that name wins - so `service: service` binds this
          // property to itself. It reads perfectly and hands over nothing at
          // all: the switcher came up saying "nothing matches" over a list of
          // twelve things.
          service: root.slackService
          fg: Color.foreground
          accent: Color.accent
          fontFamily: Style.font.family
          onClosed: root.closeSwitcher()
        }
      }

      Loader {
        id: searchPane
        anchors.fill: parent
        z: 95
        active: root.showSearch
        visible: active
        sourceComponent: SearchPane {
          // Inside a Loader, so the full path - see the switcher above.
          service: root.slackService
          fg: Color.foreground
          accent: Color.accent
          fontFamily: Style.font.family
          onClosed: root.closeSearch()
        }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // Stands down whenever a field has focus: it consumes bare letters to
        // drive the cursor, which would eat them out of a message.
        blocked: composer.activeFocus || filterField.activeFocus || tokenBox.activeFocus
                 || root.showSwitcher || root.showSearch
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) {
            // Down and up in whatever has focus: the list's cursor, or the
            // transcript's.
            if (root.focusPane === "list" || root.listDrawerOpen) root.activeList().moveCursor(dy)
            else root.moveMessageCursor(dy)
            return
          }
          // Left steps back towards the list, right steps in towards the
          // message box, one rung per press.
          if (dx < 0) {
            if (root.focusPane === "conversation") root.focusList()
          } else if (dx > 0) {
            if (root.focusPane === "list") root.focusConversation()
            else root.focusComposer()
          }
        }
        onActivateRequested: root.activeList().activateCursor()
        onCloseRequested: root.dismiss()
        // Tab is how most people expect to reach the box they type in; l and
        // the right arrow already do it, but only for those who knew.
        onTabRequested: root.focusComposer()
        onTextKey: function(text) {
          var view = root.scrollTarget()
          // While the picker is open the digits are the choices, and nothing
          // else should be acting on the conversation behind it.
          if (root.pickingMessageId !== "") {
            if (text >= "1" && text <= "9") root.reactWith(Number(text) - 1)
            else if (text === "e" || text === "+") root.pickingMessageId = ""
            return
          }
          if (text === "e" || text === "+") root.startPicking()
          else if (text === "t") root.openThreadHere()
          else if (text === "r") service.reloadConversation()
          else if (text === "u") service.unreadOnly = !service.unreadOnly
          else if (text === "m") service.markCurrentRead()
          else if (text === "f") root.startFiltering()
          else if (text === "n") root.openSwitcher()
          else if (text === "/") root.openSearch()
          // The comma is what most applications use for preferences.
          else if (text === ",") root.showSettings = !root.showSettings
          else if (text === "?") root.showHelp = !root.showHelp
          // Where the hands already are, for the box you type in.
          else if (text === "i") root.focusComposer()
          else if (text === "g") root.scrollToEnd(view, false)
          else if (text === "G") root.scrollToEnd(view, true)
        }

        Column {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.panelPadding
          anchors.rightMargin: Style.spacing.panelPadding
          anchors.topMargin: root.padPanel
          anchors.bottomMargin: root.padPanel
          spacing: root.padGap

          // ---------------- header ----------------
          Item {
            width: parent.width
            height: Math.max(heading.implicitHeight, appMark.height)

            // Which of the two this is - see brandColor above. A tinted tile
            // rather than a bare glyph, so it reads as the window's mark and
            // not as the first character of the title.
            Rectangle {
              id: appMark
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: root.markSize
              height: root.markSize
              radius: Style.cornerRadius
              color: Util.alpha(root.brandColor, 0.16)

              // Nerd Font logos are not centred in their own advance width;
              // OpticalGlyph puts the painted shape in the middle of the tile
              // rather than the box Qt reserves for it.
              OpticalGlyph {
                anchors.fill: parent
                text: "\u{F04B1}"   // nf-md-slack
                color: root.brandColor
                fontFamily: Style.font.family
                fontSize: Style.font.iconLarge
              }
            }

            Column {
              id: heading
              anchors.left: appMark.right
              anchors.leftMargin: Style.spacing.md
              // Bounded by where the buttons start, so a long channel name
              // runs out of room before it reaches them. elide does nothing on
              // a Text that is free to be as wide as it likes.
              anchors.right: headerActions.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Row {
                width: parent.width
                spacing: Style.spacing.md

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  // Whatever the status bits beside it do not need. They are
                  // short and they come and go; the title is the part that has
                  // to give way.
                  width: Math.max(0, heading.width - status.width
                                     - (status.width > 0 ? parent.spacing : 0))
                  text: service.inThread
                    ? "Thread"
                    : (service.openConversation
                       ? String(service.openConversation.title || "")
                       : (service.view.team !== "" ? service.view.team : "Slack"))
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                }

                // Grouped so their combined width can be measured and taken
                // off the title's, rather than each one pushing it along.
                Row {
                  id: status
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.md

                  Spinner {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: service.loading || service.messagesLoading
                    color: Color.accent
                    dotSize: Style.space(4)
                  }

                  // Only for the first fetch, which is the slow one: it reads
                  // a preview for every conversation. Later refreshes need no
                  // explaining, and a line of text appearing every couple of
                  // minutes would push the header around.
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: service.loading && !service.signedIn
                    text: "reading your conversations…"
                    textFormat: Text.PlainText
                    color: Qt.darker(Color.foreground, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // What this conversation is for, or the way back out of a
              // thread. One line, under the title, where a subtitle belongs.
              Text {
                width: parent.width
                visible: text !== "" && !root.showSettings
                text: {
                  if (service.inThread && service.openConversation)
                    return "in " + String(service.openConversation.title || "") + " — Esc goes back"
                  if (service.openConversation)
                    return Model.oneLine(String(service.openConversation.topic || ""), 160)
                  if (service.signedIn) {
                    var coverage = Model.coverageLabel(service.view)
                    return coverage === "" ? String(service.view.userName || "")
                                           : coverage
                  }
                  return ""
                }
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              // Only when the list has nowhere else to be: wide enough and it
              // is already on screen, and a button that shows what is already
              // shown teaches people to ignore buttons.
              Button {
                visible: service.signedIn && !columns.roomForBoth && service.reading
                          && !root.showSettings
                text: "Conversations"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: root.toggleListDrawer()
              }

              Button {
                visible: service.signedIn && !root.showSettings
                text: "?"
                tooltipText: "What the keyboard does"
                bordered: true
                foreground: Qt.darker(Color.foreground, 1.4)
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: root.showHelp = !root.showHelp
              }

              PanelActionButton {
                // Braces matter: \u takes exactly four hex digits, so
                // "3" is U+F049 followed by a literal "3" - which draws
                // the wrong glyph with a stray digit on top of it.
                iconText: root.showSettings ? "\u{F0156}" : "\u{F0493}"
                tooltipText: root.showSettings ? "Close settings" : "Settings"
                foreground: Color.foreground
                // Boxed, and the height of the outlined buttons on either
                // side of it. A bare glyph between two boxes reads as a stray
                // character rather than as the next control along.
                bordered: true
                size: refreshButton.height
                onClicked: root.showSettings = !root.showSettings
              }

              // Only while there is something to mark. Opening a conversation
              // already reads it, so most of the time this would be a button
              // that does nothing; it appears for the ones that stay lit -
              // a thread reply nobody opened the thread for, or a poll that
              // marked read while the window was closed.
              Button {
                visible: service.canMarkCurrentRead && !root.showSettings
                text: "Mark read"
                tooltipText: "Mark this conversation read  (m)"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.markCurrentRead()
              }

              Button {
                visible: service.signedIn && !root.showSettings
                text: "Unread"
                tooltipText: service.unreadOnly
                  ? "Showing only what is unread" : "Show only what is unread"
                selected: service.unreadOnly
                bordered: true
                foreground: service.unreadOnly ? Color.accent : Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.unreadOnly = !service.unreadOnly
              }

              Button {
                visible: service.signedIn && service.canSearch && !root.showSettings
                text: "Search"
                tooltipText: "Search every message in the workspace  (/)"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: root.openSearch()
              }

              Button {
                visible: service.signedIn && !root.showSettings
                text: "Jump to"
                tooltipText: "Any channel or person  (n, or Ctrl-k)"
                bordered: true
                foreground: Color.accent
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: root.openSwitcher()
              }

              Button {
                // Named because the settings button measures itself against
                // it; height is computed even while this one is hidden.
                id: refreshButton
                visible: service.configured && !root.showSettings
                enabled: !service.loading
                text: "Refresh"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.refreshEverything()
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---------------- not ready yet ----------------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: !root.showSettings
                     && (root.settingsError !== "" || !service.configured || service.needsSignIn)

            Text {
              width: parent.width
              visible: root.settingsError !== ""
              text: root.settingsError
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              visible: root.settingsError === "" && !service.configured && root.settingsLoaded
              text: "Give this widget a workspace name in settings - a short label such as "
                    + "work - and then paste a token below."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            // Signing in, which for Slack is a token and not a flow: Slack
            // will not redirect a browser to a machine with no https address,
            // so there is nothing here to host. The steps are spelled out
            // because this is the one part nobody can do for the user.
            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: service.configured && service.needsSignIn

              // Why the last attempt did not work, where the next one is
              // being made. Slack hands out four things that all look like
              // tokens and accepts every one of them at the door, so "that is
              // the wrong one, and here is which one" has to be said right
              // above the box.
              Text {
                width: parent.width
                visible: service.view.errorMessage !== "" && service.signInError === ""
                text: service.view.errorMessage
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                text: "Slack needs an app of your own. On api.slack.com/apps: create one from "
                      + "the manifest in this plugin's README, install it to your workspace, "
                      + "and copy the User OAuth Token it shows you - the one starting xoxp."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              TextField {
                id: tokenBox
                width: Math.min(Style.space(420), parent.width)
                placeholderText: "xoxp-…"
                password: true
                foreground: Color.foreground
                accent: Color.accent
                Keys.onPressed: function(event) {
                  if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
                  service.signIn(tokenBox.text)
                  tokenBox.text = ""
                  event.accepted = true
                }
              }

              Row {
                spacing: Style.spacing.sm

                Button {
                  enabled: !service.signingIn && tokenBox.text.trim() !== ""
                  text: service.signingIn ? "Checking…" : "Sign in"
                  bordered: true
                  foreground: Color.accent
                  fontFamily: Style.font.family
                  fontSize: Style.font.caption
                  onClicked: {
                    service.signIn(tokenBox.text)
                    // The field is emptied the moment the helper has it. A
                    // credential left sitting in a text field is a credential
                    // in a screenshot.
                    tokenBox.text = ""
                  }
                }

                Button {
                  text: "Open api.slack.com/apps"
                  bordered: true
                  foreground: Color.foreground
                  fontFamily: Style.font.family
                  fontSize: Style.font.caption
                  onClicked: service.openUrl("https://api.slack.com/apps")
                }
              }

              Text {
                width: parent.width
                visible: service.signInError !== "" || service.signInMessage !== ""
                text: service.signInError !== "" ? service.signInError : service.signInMessage
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: service.signInError !== "" ? Color.urgent : Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------------- settings ----------------
          ScrollView {
            id: settingsScroll
            width: parent.width
            height: parent.height - y
            visible: root.showSettings
            clip: true

            SettingsForm {
              // Measured against the ScrollView and not against `parent`: the
              // parent here is the Flickable inside it, whose width follows
              // its content, and a form that sizes itself from its own
              // container ends up whatever width the first paint guessed.
              // Capped, because a settings form the width of a 1080px window
              // is a line of text nobody can follow back to the left margin.
              width: Math.min(Style.space(560), settingsScroll.width - Style.spacing.xxl)
              service: root.slackService
              onCloseRequested: root.showSettings = false
            }
          }

          // ---------------- the two columns ----------------
          Row {
            id: columns
            // Out into the panel's left padding by exactly the list's marker
            // gutter, so what is written in the rows lands on the panel's left
            // edge. Every other child of this Column keeps the full padding.
            x: -root.listGutter
            width: parent.width + root.listGutter
            height: parent.height - y
            spacing: Style.spacing.xxl
            // Drawn during the first fetch too, so the placeholder rows below
            // stand where the real ones will be. Before this the window was
            // simply blank for the length of the fetch, which read as broken.
            visible: (service.signedIn || service.loading)
                     && root.settingsError === "" && service.configured
                     && !service.needsSignIn && !root.showSettings

            // A tiling compositor hands this window whatever the layout has
            // left, and Style.space() scales with the font, so a fixed "is
            // there room for two columns" threshold is easily missed. When
            // there is not room for both, show the one that is any use: the
            // list until a conversation is picked, the transcript after.
            readonly property bool roomForBoth: width >= Style.space(560)
            readonly property bool showSidebar: roomForBoth || !service.reading
            readonly property bool showReader: roomForBoth || service.reading
            // The gutter is width the sidebar takes back, so the divider and
            // the reader beside it stay exactly where they were and it is only
            // the names that move.
            readonly property real sidebarWidth: !showSidebar ? 0
              : (roomForBoth ? Math.max(Style.space(220), Math.min(Style.space(340), width * 0.29))
                               + root.listGutter
                             : width)
            readonly property real readerWidth: !showReader ? 0
              : (roomForBoth ? width - sidebarWidth - spacing * 2 - Style.space(1) : width)

            Column {
              width: columns.sidebarWidth
              height: columns.height
              visible: columns.showSidebar
              spacing: root.padReading

              // Filtering what is already listed, which is a different thing
              // from the switcher: this narrows the rows in front of you,
              // that one goes looking through the workspace.
              TextField {
                id: filterField
                x: root.listGutter
                width: parent.width - root.listGutter
                visible: root.filtering || service.filterText !== ""
                placeholderText: "Filter these conversations"
                foreground: Color.foreground
                accent: Color.accent
                text: service.filterText
                onTextChanged: if (text !== service.filterText) service.filterText = text
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.stopFiltering(true); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                           || event.key === Qt.Key_Down) {
                    root.stopFiltering(false)
                    root.focusPane = "list"
                    event.accepted = true
                  }
                }
              }

              // Nothing fetched yet. Rows rather than a spinner: they hold the
              // sidebar at the size it is about to have, so the list does not
              // shove the layout around when it lands.
              Item {
                width: parent.width
                height: skeleton.implicitHeight
                visible: service.conversations.length <= 1 && service.loading

                LoadingRows {
                  id: skeleton
                  anchors.left: parent.left
                  anchors.leftMargin: root.listGutter
                  width: parent.width - root.listGutter
                  rows: 8
                  fg: Color.foreground
                }
              }

              ScrollView {
                id: sidebarScroll
                width: parent.width
                height: parent.height - y
                visible: !(service.conversations.length <= 1 && service.loading)
                clip: true

                ConversationList {
                  id: conversations
                  width: columns.sidebarWidth
                  density: service.densityScale
                  palette: service.themeColors
                  showAvatars: service.wantAvatars
                  markerGutter: root.listGutter
                  rows: service.conversations
                  selectedKey: service.openConversation ? String(service.openConversation.key) : ""
                  fg: Color.foreground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  onCursorMoved: function(itemY, itemHeight) {
                    root.ensureVisible(sidebarScroll, itemY, itemHeight)
                  }
                  onPicked: function(row) {
                    service.openConversationRow(row, "")
                    // Opening something is a step inwards: the keys should now
                    // be driving what was opened, not the list behind it.
                    root.listDrawerOpen = false
                    if (service.reading) root.focusPane = "conversation"
                  }
                }
              }
            }

            Rectangle {
              width: Style.space(1)
              height: columns.height
              visible: columns.roomForBoth
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
            }

            Item {
              width: columns.readerWidth
              height: columns.height
              visible: columns.showReader

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.spacing.xxl
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: columns.roomForBoth && !service.reading
                text: service.conversations.length <= 1
                  ? "Nothing here yet" : "Pick a conversation, or press n to jump to one"
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.8)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Column {
                anchors.fill: parent
                // Narrow, this column stands where the sidebar would and has
                // to give the marker gutter back itself; wide, the sidebar has
                // already taken it.
                anchors.leftMargin: columns.roomForBoth ? 0 : root.listGutter
                spacing: root.padReading
                visible: service.reading

                // A thread is a view of its own, and the way out of it is
                // where the way in was: at the top, above what it contains.
                Rectangle {
                  width: parent.width
                  visible: service.inThread
                  implicitHeight: threadBack.implicitHeight + Style.spacing.sm * 2
                  radius: Style.space(5)
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)

                  Text {
                    id: threadBack
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    text: "← back to " + (service.openConversation
                          ? String(service.openConversation.title || "the conversation") : "")
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: service.closeThread()
                  }
                }

                Text {
                  width: parent.width
                  visible: service.messagesError !== ""
                  text: service.messagesError
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                LoadingRows {
                  width: parent.width
                  visible: service.messagesLoading && service.messages.length === 0
                  rows: 5
                  fg: Color.foreground
                }

                ScrollView {
                  id: transcript
                  width: parent.width
                  visible: !(service.messagesLoading && service.messages.length === 0)
                  height: parent.height - composerBox.height - answer.height
                          - parent.spacing * (service.inThread ? 4 : 2)
                          - (service.inThread ? threadBack.implicitHeight + Style.spacing.sm * 2 : 0)
                          - (service.messagesError !== "" ? Style.space(20) : 0)
                  clip: true

                  // The newest message is at the bottom, so that is where a
                  // conversation should open and where it should be again
                  // after you send something.
                  //
                  // Following rather than scrolling once: the rows arrive
                  // before they have been laid out, so a single jump lands
                  // short of the end by however much the transcript is still
                  // about to grow. This keeps up until it settles, and lets go
                  // the moment the reader scrolls back for themselves.
                  property bool followNewest: true

                  function toNewest() {
                    var flick = transcript.contentItem
                    if (!flick) return
                    flick.contentY = Math.max(0, flick.contentHeight - flick.height)
                  }

                  Connections {
                    target: service
                    function onMessagesChanged() {
                      transcript.followNewest = true
                      Qt.callLater(transcript.toNewest)
                    }
                  }

                  Connections {
                    target: transcript.contentItem
                    // Dragged or flicked by hand, as opposed to moved by the
                    // line above.
                    function onMovementStarted() { transcript.followNewest = false }
                  }

                  Column {
                    id: transcriptColumn
                    width: transcript.width
                    spacing: root.padMessages
                    onHeightChanged: if (transcript.followNewest) transcript.toNewest()

                    Repeater {
                      model: Model.groupMessages(service.messages, service.view.userId, new Date())

                      delegate: Column {
                        id: group
                        required property var modelData
                        width: parent ? parent.width : 0
                        spacing: Style.spacing.xs

                        // Which day this is. Only above the first block of it,
                        // so a conversation that has been going for a week is
                        // not one unbroken column of clock times.
                        Item {
                          width: parent.width
                          visible: String(group.modelData.day || "") !== ""
                          height: visible ? dayText.implicitHeight + Style.spacing.sm : 0

                          Rectangle {
                            anchors.verticalCenter: dayText.verticalCenter
                            anchors.left: parent.left
                            anchors.right: dayText.left
                            anchors.rightMargin: Style.spacing.md
                            height: Style.space(1)
                            color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                                           Color.foreground.b, 0.12)
                          }

                          Text {
                            id: dayText
                            anchors.right: parent.right
                            anchors.rightMargin: root.scrollGutter
                            anchors.bottom: parent.bottom
                            text: String(group.modelData.day || "")
                            textFormat: Text.PlainText
                            color: Qt.darker(Color.foreground, 1.6)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                          }
                        }

                        Row {
                          width: parent.width
                          spacing: Style.spacing.md

                          Avatar {
                            id: groupFace
                            visible: service.wantAvatars && !group.modelData.system
                            size: Math.max(Style.space(24), Style.font.body * 1.9)
                            path: String(group.modelData.avatar || "")
                            name: String(group.modelData.from || "")
                            fg: Color.foreground
                            accent: Color.accent
                            fontFamily: Style.font.family
                          }

                          Column {
                            width: parent.width - (groupFace.visible
                              ? groupFace.width + parent.spacing : 0)
                            spacing: Style.spacing.xxs

                            Text {
                              width: parent.width
                              visible: !group.modelData.system
                              text: String(group.modelData.from || "") + "  "
                                    + Model.whenLabel(group.modelData.when, new Date())
                              textFormat: Text.PlainText
                              elide: Text.ElideRight
                              color: group.modelData.mine ? Color.accent
                                                          : Qt.darker(Color.foreground, 1.4)
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                              font.bold: true
                            }

                            Repeater {
                              model: group.modelData.lines

                              // Selectable: the whole point of a transcript is
                              // that you can take a line out of it. A plain
                              // Text item cannot be selected at all.
                              delegate: Column {
                                id: line
                                required property var modelData
                                width: parent ? parent.width : 0
                                spacing: root.padLines

                                // Hover for the whole line, read by the add
                                // button below. It cannot live on the reaction
                                // row: that row has no height on a message
                                // nobody has reacted to, and an item with no
                                // height receives no hover at all.
                                HoverHandler { id: lineHover }

                                Item {
                                  id: lineBox
                                  width: parent.width
                                  implicitHeight: lineText.visible ? lineText.implicitHeight : 0

                                  readonly property bool cursored:
                                    root.focusPane === "conversation"
                                    && String(root.cursorMessageId) === String(line.modelData.id)

                                  // Walk the cursor off the edge and there is
                                  // no sign of where it went, so bring it back
                                  // on.
                                  onCursoredChanged: if (cursored) Qt.callLater(function() {
                                    var pos = lineBox.mapToItem(transcriptColumn, 0, 0)
                                    root.ensureVisible(transcript, pos.y, lineBox.height)
                                  })

                                  // Which message the keys are on, and which
                                  // one a search jumped to. Behind the text
                                  // rather than around it, so nothing shifts.
                                  Rectangle {
                                    anchors.fill: parent
                                    anchors.leftMargin: -Style.spacing.xs
                                    anchors.rightMargin: -Style.spacing.xs
                                    radius: Style.space(4)
                                    visible: lineBox.cursored
                                             || (service.anchorTs !== ""
                                                 && String(service.anchorTs) === String(line.modelData.ts))
                                    color: (service.anchorTs !== ""
                                            && String(service.anchorTs) === String(line.modelData.ts))
                                      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)
                                      : Qt.rgba(Color.foreground.r, Color.foreground.g,
                                                Color.foreground.b, 0.08)
                                  }

                                  SelectableText {
                                    id: lineText
                                    width: parent.width - root.scrollGutter
                                    visible: text !== ""
                                    // Escaped first, then links added - so a
                                    // message can never choose its own markup.
                                    // Lines without a link stay plain text,
                                    // which is cheaper and cannot be got wrong
                                    // at all.
                                    readonly property bool linked:
                                      Model.hasLink(line.modelData.text, line.modelData.links)
                                    // Tinted from the theme: a TextEdit has no
                                    // linkColor, so an untinted anchor comes
                                    // out in Qt's default blue, which belongs
                                    // to no theme.
                                    text: linked ? Model.linkify(line.modelData.text,
                                                                 service.themeColors.blue
                                                                 || service.themeColors.accent || "",
                                                                 line.modelData.links)
                                                 : String(line.modelData.text || "")
                                    onLinkActivated: function(url) { service.openUrl(url) }
                                    HoverHandler {
                                      enabled: parent.hoveredLink !== ""
                                      cursorShape: Qt.PointingHandCursor
                                    }
                                    textFormat: linked ? TextEdit.RichText : TextEdit.PlainText
                                    color: Color.foreground
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall
                                  }

                                  // A plus rather than a face, so it does not
                                  // read as one more reaction among the ones
                                  // already there. Quiet until the message is
                                  // pointed at, and never a column of plus
                                  // signs down a transcript nobody is
                                  // touching.
                                  Rectangle {
                                    id: addReaction
                                    anchors.right: parent.right
                                    // Clear of the scrollbar, which is drawn
                                    // over the content rather than beside it.
                                    anchors.rightMargin: root.scrollGutter
                                    anchors.top: parent.top
                                    width: plusGlyph.implicitWidth + Style.spacing.md
                                    height: Math.min(plusGlyph.implicitHeight + Style.spacing.xs * 2,
                                                     Math.max(plusGlyph.implicitHeight,
                                                              lineText.implicitHeight))
                                    radius: height / 2
                                    visible: lineText.visible && !reactions.picking
                                             && service.canReact
                                    opacity: addPointer.containsMouse ? 1.0
                                           : (lineHover.hovered || lineBox.cursored) ? 0.55 : 0.0
                                    Behavior on opacity { NumberAnimation { duration: 120 } }
                                    color: addPointer.containsMouse
                                      ? Qt.rgba(Color.foreground.r, Color.foreground.g,
                                                Color.foreground.b, 0.14)
                                      : Qt.rgba(Color.foreground.r, Color.foreground.g,
                                                Color.foreground.b, 0.06)

                                    Text {
                                      id: plusGlyph
                                      anchors.centerIn: parent
                                      text: "+"
                                      textFormat: Text.PlainText
                                      color: Qt.darker(Color.foreground, 1.4)
                                      font.family: Style.font.family
                                      font.pixelSize: Style.font.caption
                                    }

                                    MouseArea {
                                      id: addPointer
                                      anchors.fill: parent
                                      hoverEnabled: true
                                      enabled: !service.reacting
                                      cursorShape: Qt.PointingHandCursor
                                      onClicked: {
                                        root.cursorMessageId = String(line.modelData.id)
                                        root.pickingMessageId = String(line.modelData.id)
                                      }
                                    }
                                  }
                                }

                                ReactionBar {
                                  id: reactions
                                  width: parent.width
                                  // Opened from the row rather than by itself,
                                  // so the keyboard and the mouse open the
                                  // same one and a second one closes the first.
                                  picking: String(root.pickingMessageId) === String(line.modelData.id)
                                  numbered: true
                                  reactions: line.modelData.reactions || []
                                  choices: service.reactionChoices
                                  busy: service.reacting
                                  fg: Color.foreground
                                  accent: Color.accent
                                  fontFamily: Style.font.family
                                  onToggled: function(name) {
                                    root.pickingMessageId = ""
                                    service.react(line.modelData.ts, name,
                                                  Model.reactionIsMine(line.modelData.reactions, name))
                                  }
                                }

                                // What hangs off this message. Slack's threads
                                // are where half the conversation happens, and
                                // a channel that only showed the parents would
                                // be showing half of it.
                                Rectangle {
                                  visible: !service.inThread
                                           && Number(line.modelData.replyCount || 0) > 0
                                  implicitWidth: replies.implicitWidth + Style.spacing.lg
                                  implicitHeight: replies.implicitHeight + Style.spacing.xs * 2
                                  radius: height / 2
                                  color: threadPointer.containsMouse
                                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                                    : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)

                                  Text {
                                    id: replies
                                    anchors.centerIn: parent
                                    text: Model.threadLabel(line.modelData.replyCount) + "  ›"
                                    textFormat: Text.PlainText
                                    color: Color.accent
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                  }

                                  MouseArea {
                                    id: threadPointer
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                      root.cursorMessageId = String(line.modelData.id)
                                      service.openThread(String(line.modelData.threadTs
                                        || line.modelData.ts), line.modelData)
                                      root.focusPane = "conversation"
                                    }
                                  }
                                }

                                Repeater {
                                  model: line.modelData.images || []

                                  delegate: MessageImage {
                                    required property var modelData
                                    url: String(modelData.url || "")
                                    alt: String(modelData.alt || "")
                                    intrinsicWidth: Number(modelData.width || 0)
                                    intrinsicHeight: Number(modelData.height || 0)
                                    account: service.alias
                                    pluginDir: root.pluginDir
                                    maxWidth: Math.min(Style.space(320),
                                                       columns.readerWidth - Style.spacing.xxl)
                                  }
                                }

                                // Anything that is not a picture: a name, what
                                // kind of thing it is, and how big. A
                                // transcript is not a file manager, so it
                                // opens in the browser where the file already
                                // has a page.
                                Repeater {
                                  model: line.modelData.files || []

                                  delegate: Rectangle {
                                    required property var modelData
                                    implicitWidth: Math.min(fileRow.implicitWidth + Style.spacing.lg,
                                                            line.width)
                                    implicitHeight: fileRow.implicitHeight + Style.spacing.sm * 2
                                    radius: Style.space(5)
                                    color: filePointer.containsMouse
                                      ? Qt.rgba(Color.foreground.r, Color.foreground.g,
                                                Color.foreground.b, 0.12)
                                      : Qt.rgba(Color.foreground.r, Color.foreground.g,
                                                Color.foreground.b, 0.06)
                                    border.width: Style.space(1)
                                    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                                                          Color.foreground.b, 0.12)

                                    Row {
                                      id: fileRow
                                      anchors.left: parent.left
                                      anchors.leftMargin: Style.spacing.md
                                      anchors.verticalCenter: parent.verticalCenter
                                      spacing: Style.spacing.sm

                                      Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: ""
                                        textFormat: Text.PlainText
                                        color: Qt.darker(Color.foreground, 1.4)
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                      }

                                      Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: String(modelData.name || "file")
                                        textFormat: Text.PlainText
                                        elide: Text.ElideRight
                                        color: Color.foreground
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                      }

                                      Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: Model.fileLabel(modelData)
                                        textFormat: Text.PlainText
                                        color: Qt.darker(Color.foreground, 1.6)
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                      }
                                    }

                                    MouseArea {
                                      id: filePointer
                                      anchors.fill: parent
                                      hoverEnabled: true
                                      enabled: String(modelData.link || "") !== ""
                                      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                      onClicked: service.openUrl(String(modelData.link))
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }

                // ---------------- answering ----------------
                Rectangle {
                  id: composerBox
                  width: parent.width
                  height: Style.space(84)
                  radius: Style.space(5)
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                  border.width: Style.space(1)
                  border.color: composer.activeFocus
                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
                    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

                  ScrollView {
                    anchors.fill: parent
                    anchors.margins: Style.spacing.sm
                    clip: true

                    TextArea {
                      id: composer
                      placeholderText: service.inThread
                        ? "Reply in thread — Shift+Enter to send"
                        : "Message — Shift+Enter to send"
                      wrapMode: TextArea.Wrap
                      enabled: service.canPost
                      color: Color.foreground
                      placeholderTextColor: Qt.darker(Color.foreground, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      background: null
                      text: service.draft
                      onTextChanged: if (text !== service.draft) service.draft = text
                      // Enter is a newline; Shift+Enter sends, and Ctrl+Enter
                      // still does too for anyone with it in their fingers. A
                      // chat box that sends on Enter alone posts half-written
                      // thoughts.
                      //
                      // Escape and Tab hand the keyboard back to the
                      // conversation, since the key catcher cannot hear
                      // anything while this has focus.
                      Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backtab
                            || event.key === Qt.Key_Tab) {
                          root.leaveComposer()
                          event.accepted = true
                          return
                        }
                        if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
                        if (!(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) return
                        service.send()
                        event.accepted = true
                      }
                    }
                  }
                }

                Row {
                  id: answer
                  spacing: Style.spacing.sm

                  Button {
                    enabled: !service.sending && service.draft.trim() !== "" && service.canPost
                    text: service.sending ? "Sending…" : (service.inThread ? "Reply" : "Send")
                    bordered: true
                    foreground: Color.accent
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    onClicked: service.send()
                  }

                  // Slack's "also send to #channel". Only in a thread, because
                  // that is the only place it means anything - and worth
                  // having, since a thread reply reaches nobody who is not
                  // already in the thread.
                  Button {
                    visible: service.inThread
                    text: service.alsoToChannel ? "Also in channel ✓" : "Also in channel"
                    tooltipText: "Send this reply to the channel as well as the thread"
                    selected: service.alsoToChannel
                    bordered: true
                    foreground: service.alsoToChannel ? Color.accent
                                                      : Qt.darker(Color.foreground, 1.4)
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    onClicked: service.alsoToChannel = !service.alsoToChannel
                  }

                  Button {
                    enabled: !service.messagesLoading
                    text: "Reload"
                    bordered: true
                    foreground: Color.foreground
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    onClicked: service.reloadConversation()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                    text: service.sendError !== "" ? service.sendError
                          : (service.reactError !== "" ? service.reactError
                             : (service.markReadError !== "" ? service.markReadError : ""))
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Color.urgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
