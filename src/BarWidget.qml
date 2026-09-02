import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon, and the small dropdown behind it.
//
// The dropdown answers the question a bar is asked - whether anything needs
// you - and hands everything else to the window: a conversation is a thing you
// read and answer, which wants somewhere that does not close on click-away
// half way through a reply. See BarPanel.qml for what that division buys and
// where it is drawn.
BarWidget {
  id: root
  moduleName: "janrenz.omarchy.slack"

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return decodeURIComponent(url.replace(/\/$/, ""))
  }

  readonly property string barLabel: String(setting("label", "")).trim()
  readonly property string barIcon: String(setting("icon", "\u{F04B1}"))   // nf-md-slack
  readonly property bool tintOnUnread: setting("tintOnUnread", true) !== false
  readonly property bool showCount: setting("showCount", false) === true

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // The window, which the shell owns because the manifest declares the "panel"
  // kind. Nothing about the dropdown changes this route: a plugin that is both
  // a bar widget and a panel is routed to its panel by the shell, so
  // `omarchy-shell shell toggle janrenz.omarchy.slack` still means the window.
  //
  // Summon rather than toggle, which is what the icon means by opening the
  // window: the shell's toggle knows only "open", and a window on another
  // workspace is open - so a click meant to reach it hid it instead, and the
  // second click brought it back to the workspace you were on all along. The
  // window itself is still what closes it, and the toggle above is still what
  // a keybinding gets.
  function openWindow() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon",
                             "janrenz.omarchy.slack", "{}"])
  }

  // Everything the panel needs that it cannot reach from inside a Loader. The
  // bar hands these to a panel it mounts itself; one nested in a widget has to
  // be given them.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // The shape the bar uses to route summon/hide/toggle and to draw the
  // open-panel mark. It has to live on the widget in the bar slot, not on the
  // panel nested inside it.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // Whether this is the copy of the widget that speaks.
  //
  // A bar surface is built per monitor, so this widget is live once per screen
  // - and every one of them used to announce, which on a two-monitor desktop
  // meant two toasts for every message, each with its own replace-id so they
  // stacked rather than updated. The first live instance is the one that
  // announces; the others draw the same count off the same snapshot and say
  // nothing.
  //
  // `bar.moduleSlots` is read so that this re-elects: it changes when a
  // monitor arrives or goes, and without it unplugging the elected screen
  // would take the notifications with it.
  //
  // Failing open, for the moment before the slots have registered: two
  // services that both think they speak cost nothing, because the Notifier's
  // first round through a workspace is silent by design and the helper's own
  // lock keeps the duplicate poll from reaching Slack.
  readonly property bool primaryInstance: {
    var slots = root.bar ? root.bar.moduleSlots : null
    if (!slots || typeof root.bar.moduleWidgets !== "function") return true
    var peers = root.bar.moduleWidgets(root.moduleName)
    return peers.length === 0 || peers[0] === root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    // The bar is always here and the window is not, so new messages are
    // announced from behind the icon rather than from behind the window - and
    // from behind one icon rather than one per monitor. See primaryInstance.
    notifies: root.primaryInstance
    // Faces and presence are a request each and are only ever looked at in the
    // window. The bar draws a count, and the dropdown draws names.
    wantsDecoration: false
    // The dropdown shows what is waiting and nothing else, so the filtering is
    // done once here rather than by a second copy of conversationRows in the
    // panel. Fixed rather than a toggle: the whole list is what the window is
    // for. `unreadCount` comes off the snapshot rather than off these rows, so
    // the icon still counts the same things it always did.
    unreadOnly: true
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("BarPanel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var face = Model.plainText(root.barLabel !== "" ? root.barLabel : root.barIcon)
      if (root.showCount && service.unreadCount > 0) return face + " " + service.unreadCount
      return face
    }
    slotSize: (root.barLabel !== "" || (root.showCount && service.unreadCount > 0))
      ? Style.bar.statusSlot * 2 : Style.bar.iconSlot
    active: root.tintOnUnread && service.unreadCount > 0

    tooltipText: {
      if (!service.configured)
        return "Slack: name this workspace in settings, then paste a token"
      if (service.needsSignIn) return "Slack: paste a token to sign in"
      if (!service.signedIn) return "Slack: loading…"
      var lines = [Model.plainText(service.view.team || service.alias)]
      lines.push(service.unreadCount === 0
        ? "nothing unread"
        : (service.unreadCount === 1 ? "1 conversation waiting"
                                     : service.unreadCount + " conversations waiting"))
      var coverage = Model.coverageLabel(service.view)
      if (coverage !== "") lines.push(coverage)
      // A bar that is not moving because nobody is at the machine looks exactly
      // like a bar that is broken. Say which.
      if (service.pollReason !== "") lines.push(service.pollReason)
      for (var i = 0; i < service.warnings.length; i++)
        lines.push(Model.plainText(service.warnings[i].message))
      return lines.join("\n")
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) service.refresh()
      // Right button goes straight to the window, which is where somebody who
      // knows they are about to write a reply wants to be - and is the route
      // that survives the dropdown being no use to them.
      else if (b === Qt.RightButton) root.openWindow()
      else root.togglePanel()
    }
  }
}
