import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The dropdown behind the bar icon, and deliberately only one thing: what is
// waiting.
//
// That is the question a bar is asked - "does anything need me" - and it is
// answered by picking from a short list, which is what a popup that closes on
// click-away can do. Reading a conversation and writing a reply is not: a
// click-away half way through a sentence loses the sentence. So everything
// else - the transcript, the message box, files, reactions, threads, search,
// the settings form - stays in the window, and every row here is a way into it
// rather than a smaller copy of it.
//
// Nothing is fetched for this panel. It binds to the Service the bar icon
// already owns, with `unreadOnly` set on it, so opening the dropdown costs
// Slack no request at all - see BarWidget.qml.
Panel {
  id: root
  moduleName: "janrenz.omarchy.slack"
  // A keybinding can summon this particular widget's dropdown by claiming a
  // name for it: set "ipcTarget": "slack" on the widget and bind
  // `omarchy-shell slack toggle`. Empty means no handler, so nothing collides
  // with the window, which answers to `omarchy-shell shell toggle` on the
  // plugin id.
  ipcTarget: String(setting("ipcTarget", "")).trim()
  manageIpc: ipcTarget !== ""

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  // The bar identifies panels by the widget mounted in its slot, not by the
  // panel nested inside it.
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color accent: root.bar ? root.bar.urgent : Color.urgent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)

  // Rows come from the Service already filtered to what is unread, so this
  // draws the same list the window's unread toggle draws - including its
  // "Nothing unread" note, which is a truer empty state than a blank panel.
  //
  // Minus the headings. "Direct messages" over a list where a heading is a
  // third of the rows says nothing the panel has not already said, and the
  // alternative - another argument to conversationRows - would put the
  // decision in the one place that must keep working for the window too.
  readonly property var rows: {
    var all = service ? service.conversations : []
    return all.filter(function(row) { return String(row.kind) !== "heading" })
  }

  // Hand a conversation to the window. The payload is the same shape a clicked
  // notification sends, because it lands in the same applyPayload.
  function openWindow(payload) {
    try {
      Quickshell.execDetached(["omarchy-shell", "shell", "summon",
                               "janrenz.omarchy.slack", JSON.stringify(payload || {})])
    } catch (e) {
      console.warn("slack: summon threw: " + e)
    }
    // The dropdown has done its job the moment the window is up; leaving it
    // open would put the same conversation on screen twice.
    root.close()
  }

  // No message id: the panel is a list of conversations rather than of
  // messages, and a conversation opened on its newest is where the row's
  // preview came from anyway. Anchoring on the row's `ts` is the notification's
  // job, which is about one message having arrived.
  // The name and kind travel with the id. A summon that has to mount the
  // window gets there before its first poll does, so this is the difference
  // between a header that says where you are and one that is blank until the
  // sidebar arrives.
  function openRow(row) {
    if (!row) return
    if (String(row.kind) === "conversation")
      root.openWindow({ conversation: String(row.id),
                        title: String(row.title || ""),
                        kind: String(row.channelKind || "") })
  }

  // Whether there is anything to mark, and whether this token may. A workspace
  // signed in without the scope cannot - see canMarkRead - and an offer that
  // would fail is worse than no offer.
  readonly property bool canMarkAll: !!service && service.canMarkRead
                                     && service.unreadCount > 0

  // "Mark all as read", asked for but not yet done.
  //
  // Slack has no route back to unread, so this is the one thing in the panel
  // that cannot be undone - and in a popup whose other keys are one keystroke
  // each, that is too easy to do by accident. So it is asked twice: the hint
  // line says how many and what will happen, and `m` again does it. Anything
  // else at all backs out, and Escape backs out of this before it backs out of
  // the panel.
  property bool armingMarkAll: false

  function markAll() {
    if (!canMarkAll) { armingMarkAll = false; return }
    if (!armingMarkAll) { armingMarkAll = true; return }
    armingMarkAll = false
    service.markAllRead()
  }

  function open() {
    // Every opening starts on what is waiting, an armed question included:
    // coming back to a panel still holding a question from last time is how
    // the answer gets given by accident.
    armingMarkAll = false
    list.cursorIndex = -1
    root.controller.show()
    if (service) service.refresh()
  }

  function close() {
    armingMarkAll = false
    root.controller.hide()
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // What the bar's own hotkey route calls; there is nothing to prime here that
  // opening does not already do.
  function openFromHotkey() { root.open() }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)
    // The panel changes height as conversations are read and drop out of the
    // list; easing it stops the card snapping between sizes.
    Behavior on contentHeight { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        root.armingMarkAll = false
        if (dy !== 0) list.moveCursor(dy)
      }
      onActivateRequested: {
        root.armingMarkAll = false
        list.activateCursor()
      }
      onCloseRequested: {
        // One layer at a time: the question you were asked, then the panel.
        if (root.armingMarkAll) root.armingMarkAll = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "m") { root.markAll(); return }
        // Any other key is an answer of "no" to a question that was asked.
        root.armingMarkAll = false
        if (text === "r" && root.service) root.service.refresh()
        else if (text === "o") root.openWindow({})
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.lg

        // ---------------- header ----------------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerText.implicitHeight, headerActions.implicitHeight)

          Column {
            id: headerText
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              width: parent.width
              text: "Slack"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            // Which workspace this is, and what is waiting. One line, because a
            // line that appears and disappears pushes the whole panel around.
            Text {
              width: parent.width
              text: {
                if (!root.service) return ""
                if (!root.service.configured)
                  return "name this workspace in settings, then paste a token"
                if (root.service.needsSignIn) return "paste a token — opens the window"
                if (!root.service.signedIn) return "loading…"
                var parts = []
                var who = Model.plainText(root.service.view.team || root.service.alias)
                if (who !== "") parts.push(who)
                parts.push(root.service.unreadCount === 0
                  ? "nothing unread"
                  : (root.service.unreadCount === 1
                     ? "1 conversation waiting"
                     : root.service.unreadCount + " conversations waiting"))
                return parts.join(" · ")
              }
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            PanelActionButton {
              iconText: "\u{F012C}"   // nf-md-check_all
              // Only while there is something to mark and a token that may.
              visible: root.canMarkAll
              tooltipText: root.armingMarkAll
                ? "Mark " + root.service.unreadCount + " read — again to confirm"
                : "Mark all as read  ·  m"
              // Armed, it is the one thing here that changes anything, and it
              // says so in the colour the panel uses for that.
              foreground: root.armingMarkAll ? root.accent : root.fg
              onClicked: root.markAll()
            }

            PanelActionButton {
              iconText: "\u{F03CC}"   // nf-md-open_in_new
              tooltipText: "Open the window  ·  o"
              foreground: root.fg
              onClicked: root.openWindow({})
            }

            PanelActionButton {
              iconText: "\u{F0450}"   // nf-md-refresh
              // The one place a paused poll is visible from the bar, and it
              // belongs beside the hand-driven refresh: a panel that is not
              // moving because nobody is at the machine looks exactly like a
              // panel that is broken.
              readonly property string paused: root.service ? root.service.pollReason : ""
              tooltipText: root.service && root.service.loading
                ? "Updating…"
                : (paused !== "" ? "Refresh — " + paused : "Refresh  ·  r")
              foreground: root.fg
              visible: !!root.service && root.service.configured
              onClicked: if (root.service) root.service.refresh()
            }
          }
        }

        PanelSeparator { width: parent.width }

        // ---------------- what is waiting ----------------
        // The list is measured on the outside and scrolls on the inside.
        // Sizing the ScrollView from its own content instead would make the
        // rows' width depend on the height they are being asked for.
        Item {
          width: parent.width
          visible: !!root.service && root.service.signedIn
          // Room for about six rows before it scrolls. Longer than that and
          // the panel is being used as the window, which is what the window is
          // for.
          implicitHeight: Math.min(list.implicitHeight, Style.space(300))

          ScrollView {
            anchors.fill: parent
            clip: true

            ConversationList {
              id: list
              width: parent ? parent.width : 0
              rows: root.rows
              fg: root.fg
              dim: root.dim
              accent: root.accent
              fontFamily: root.fontFamily
              palette: root.service ? root.service.themeColors : ({})
              // The bar's Service asks for no faces - see `wantsDecoration` in
              // BarWidget.qml - so a row here has no avatar to draw, and a
              // gutter of placeholders is worse than no gutter.
              showAvatars: false
              // Tighter than the window's, which is the user's choice for a
              // place they sit and read. This is a glance.
              density: Model.densityScale("compact")
              onPicked: function(row) { root.openRow(row) }
            }
          }
        }

        // Signing in, and anything the workspace is complaining about. Both go
        // to the window rather than being answered here: pasting a token needs
        // somewhere to sit that does not close on click-away.
        Text {
          width: parent.width
          visible: !!root.service && root.service.configured && !root.service.signedIn
          text: root.service && root.service.needsSignIn
            ? "This workspace needs a token. Opening the window is where it goes."
            : "Waiting for the first fetch…"
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.service ? root.service.warnings : []

          delegate: Text {
            required property var modelData
            width: column.width
            text: Model.plainText(modelData.message)
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          text: {
            if (root.armingMarkAll && root.service)
              return "Mark " + root.service.unreadCount + " read?  m confirms  ·  Esc cancels"
            if (root.service && root.service.markingRead) return "Marking read…"
            var keys = ["o window", "r refresh"]
            // "m read all" rather than "m mark all read": a third key is what
            // this line has room for, and not a word more.
            if (root.canMarkAll) keys.splice(0, 0, "m read all")
            return keys.join("  ·  ")
          }
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.armingMarkAll ? root.accent : Qt.darker(root.fg, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
