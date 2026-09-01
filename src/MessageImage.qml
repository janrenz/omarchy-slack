import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One picture from a message.
//
// Slack serves these from files.slack.com, which will not hand a file over
// without the account's token - and QML has no business holding one. So
// slack.py fetches it, checks the host before it attaches the token, caches it
// by URL digest and hands back a path. Nothing here ever reaches the network:
// an <img src> in a message is written by whoever sent the message, and a
// window that fetched it would be telling them when it was read.
Item {
  id: root

  property string url: ""
  property string alt: ""
  // What the message says the picture is, used to reserve the right shape
  // before it has loaded so the transcript does not jump when it does.
  property int intrinsicWidth: 0
  property int intrinsicHeight: 0
  property string account: ""
  property string pluginDir: ""
  property real maxWidth: Style.space(320)
  property real maxHeight: Style.space(260)

  readonly property real ratio: (intrinsicWidth > 0 && intrinsicHeight > 0)
    ? intrinsicHeight / intrinsicWidth : 0.62

  readonly property real drawWidth: Math.min(maxWidth, parent ? parent.width : maxWidth)
  readonly property real drawHeight: Math.min(maxHeight, drawWidth * ratio)

  property string path: ""
  property string problem: ""
  property bool loading: false

  width: drawWidth
  height: drawHeight

  Component.onCompleted: load()

  function load() {
    if (url === "" || account === "" || pluginDir === "" || loading || path !== "") return
    loading = true
    fetchProc.command = ["python3", pluginDir + "/slack.py", "image",
                         "--account", account, "--url", url]
    fetchProc.running = true
  }

  Process {
    id: fetchProc
    running: false
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    stderr: StdioCollector { id: fetchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      var parsed = null
      try { parsed = JSON.parse(String(fetchOut.text || "")) } catch (e) { parsed = null }
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.problem = parsed && parsed.error ? String(parsed.error.message) : "Could not load this image"
        return
      }
      root.path = String(parsed.path || "")
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.space(5)
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
    border.width: Style.space(1)
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
    clip: true

    Image {
      id: picture
      anchors.fill: parent
      source: root.path !== "" ? "file://" + root.path : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      // The full-size picture can be thousands of pixels; decoding it at the
      // size actually drawn keeps a transcript of photographs from eating
      // hundreds of megabytes in the shell process.
      sourceSize.width: Math.round(root.drawWidth * 2)
      visible: status === Image.Ready
    }

    Spinner {
      anchors.centerIn: parent
      visible: root.loading || (root.path !== "" && picture.status === Image.Loading)
      color: Color.accent
      dotSize: Style.space(4)
    }

    Text {
      anchors.centerIn: parent
      width: parent.width - Style.spacing.lg
      visible: root.problem !== "" || picture.status === Image.Error
      text: root.problem !== "" ? root.problem : "Could not show this image"
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.path !== ""
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      // The transcript shows a thumbnail; the whole picture opens in whatever
      // views images on this machine. That is its own window - closing it
      // closes the picture and leaves Slack where it was.
      onClicked: Quickshell.execDetached(["xdg-open", root.path])
    }
  }
}
