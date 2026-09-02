import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon. There is no dropdown behind it: a conversation is a thing you
// read and answer, which wants a window, so the icon opens the window rather
// than a popup that would close on click-away half way through a reply.
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

  function openWindow() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "janrenz.omarchy.slack"])
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

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    // The bar is always here and the window is not, so new messages are
    // announced from behind the icon rather than from behind the window - and
    // from behind one icon rather than one per monitor. See primaryInstance.
    notifies: root.primaryInstance
    // Faces and presence are a request each and are only ever looked at in the
    // window. The bar draws a count.
    wantsDecoration: false
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
      else root.openWindow()
    }
  }
}
