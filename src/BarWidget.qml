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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    // The bar is always here and the window is not, so new messages are
    // announced from behind the icon rather than from behind the window.
    notifies: true
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
