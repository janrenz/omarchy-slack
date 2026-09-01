import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Development harness: the real window, on fixture data, rendered offscreen.
//
//   dev/run.sh                 # start it
//   dev/shot.sh out.png        # photograph what it is drawing
//
// This loads SlackWindow.qml itself rather than a copy of its parts, so what
// is being looked at is the window the shell would host - the same layout, the
// same key handling, the same service underneath. Only two things differ: the
// settings come from here instead of from shell.json, and `demo` is on, which
// makes slack.py answer every read from its own fixtures and refuse every
// write. Nothing here can touch a real workspace.
ShellRoot {
  SlackWindow {
    id: panel

    Component.onCompleted: panel.open("{}")

    // The window reads its settings out of the bar layout, and in a harness
    // there is no bar. That read is asynchronous, so this waits for it to land
    // and then puts fixture settings in its place - otherwise the window would
    // be showing "no Slack widget in the bar", which is true and not useful.
    Timer {
      running: true
      interval: 600
      onTriggered: {
        panel.settingsError = ""
        panel.settings = {
          account: "demo",
          demo: true,
          demoOpen: dev.openConversation,
          density: dev.density,
          conversations: 25,
          avatars: true,
          presence: true
        }
      }
    }
  }

  // The grabbed item is the window's FocusScope, which is transparent: the
  // colour behind it belongs to the window, and the window is not what gets
  // photographed. So a rectangle in the theme's background colour is put
  // behind it once, or every screenshot is dark text on nothing.
  //
  // Out here rather than on the IpcHandler: everything declared on one of
  // those has to be a type that can cross IPC, and an Item is not.
  QtObject {
    id: backdrop

    property var rect: null

    function paint(item) {
      if (backdrop.rect) return
      backdrop.rect = Qt.createQmlObject(
        'import QtQuick; Rectangle { z: -1000; anchors.fill: parent }', item, "backdrop")
      backdrop.rect.color = Color.background
    }
  }

  IpcHandler {
    id: dev
    target: "dev"

    property string density: "cosy"
    property string openConversation: "demo-channel-0"

    // The harness draws its own screenshots rather than being photographed off
    // the screen: offscreen means there is no screen, and a compositor grab of
    // a window that is not mapped anywhere gets whatever is in front of it.
    function shot(path: string): void {
      // The window's own content item is created by Quickshell rather than by
      // the QML engine, and grabToImage refuses it ("item has no QML engine").
      // Its first child is the FocusScope the window declares, which fills it
      // and is an ordinary QML item - so that is what gets photographed.
      var content = panel.floatingWindow ? panel.floatingWindow.contentItem : null
      var item = content && content.children.length > 0 ? content.children[0] : content
      if (!item) { console.log("shot", path, "no window yet"); return }
      backdrop.paint(item)
      var started = item.grabToImage(function(result) {
        console.log("shot", path, result ? result.saveToFile(path) : "no result")
      })
      if (!started) console.log("shot", path, "grab refused - is the window mapped?")
    }

    // Which conversation the demo opens by itself, and how much room to give
    // things: the two knobs worth turning while looking at a layout.
    function open(id: string): void {
      dev.openConversation = id
      panel.settings = Object.assign({}, panel.settings, { demoOpen: id })
      panel.slackService.demoOpened = false
    }


    // Point the harness at a real workspace instead of the fixtures - for
    // looking at what a sign-in that went wrong actually says. Reads whatever
    // token is already stored for that alias; it never writes one.
    function account(name: string): void {
      panel.settings = { account: name, demo: false, avatars: true, presence: true,
                         conversations: 25, density: dev.density }
    }

    function faces(on: bool): void {
      panel.settings = Object.assign({}, panel.settings, { avatars: on })
    }

    function spacing(name: string): void {
      dev.density = name
      panel.settings = Object.assign({}, panel.settings, { density: name })
    }

    // The overlays, which have no other way of being reached from a script.
    // Not called show(): `qs ipc show` is a subcommand of its own, and the
    // argument parser takes the call for that one and refuses the argument.
    function pane(what: string): void {
      panel.showHelp = what === "help"
      panel.showSettings = what === "settings"
      if (what === "switcher") panel.openSwitcher()
      else panel.showSwitcher = false
      if (what === "search") panel.openSearch()
      else panel.showSearch = false
    }

    // The thread on the newest message, which in the fixtures is the one that
    // has replies. Aiming at a particular message from a script means knowing
    // its ts, and the fixtures make those out of the clock.
    // A search, run rather than typed: the pane fires its query on Enter and
    // a script has no Enter to press.
    function find(query: string): void {
      panel.openSearch()
      panel.slackService.searchMessages(query)
    }

    function thread(): void {
      panel.focusPane = "conversation"
      panel.openThreadHere()
    }




    // Out of a thread and back to the conversation it hangs off.
    function back(): void {
      panel.slackService.closeThread()
    }

    // What is actually on screen, by type and geometry - for when something is
    // drawn that no line of the plugin appears to draw.
    function tree(): string {
      var out = []
      function walk(item, depth) {
        if (!item || depth > 14) return
        for (var i = 0; i < item.children.length; i++) {
          var child = item.children[i]
          var name = child.toString().split("_QMLTYPE")[0].split("(")[0]
          if (child.width > 0 && child.height > 0
              && (name.indexOf("Image") >= 0 || name.indexOf("Avatar") >= 0))
            out.push(Array(depth + 1).join("  ") + child.toString().split("_QMLTYPE")[0].split("(")[0]
                     + " @" + Math.round(child.x) + "," + Math.round(child.y)
                     + " " + Math.round(child.width) + "x" + Math.round(child.height)
                     + (child.source !== undefined ? " src=" + child.source : "")
                     + " visible=" + child.visible
                     + (child.text !== undefined ? " text=" + String(child.text).substring(0, 24) : ""))
          walk(child, depth + 1)
        }
      }
      var content = panel.floatingWindow ? panel.floatingWindow.contentItem : null
      walk(content && content.children.length ? content.children[0] : content, 0)
      return out.join("\n")
    }

    function state(): string {
      var service = panel.slackService
      return JSON.stringify({
        signedIn: service.signedIn,
        loading: service.loading,
        rows: service.conversations.length,
        reading: service.reading,
        inThread: service.inThread,
        messages: service.messages.length,
        error: service.errorMessage,
        messagesError: service.messagesError,
        settingsError: panel.settingsError
      })
    }
  }
}
