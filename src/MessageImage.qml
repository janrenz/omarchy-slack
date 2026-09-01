import QtQuick
import Quickshell
import Quickshell.Widgets
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
  // Asked for, not acted on: the whole picture is a layer of the window, and
  // the thumbnail has no business knowing how the window draws it.
  signal openRequested(string path, string alt)

  property real maxWidth: Style.space(320)
  property real maxHeight: Style.space(260)

  readonly property real ratio: (intrinsicWidth > 0 && intrinsicHeight > 0)
    ? intrinsicHeight / intrinsicWidth : 0.62

  readonly property real drawWidth: Math.min(maxWidth, parent ? parent.width : maxWidth)
  readonly property real drawHeight: Math.min(maxHeight, drawWidth * ratio)

  property string path: ""
  // The picture's load state, kept here because the Image itself lives in a
  // Component below and cannot be reached by id from the rows that ask.
  property int pictureStatus: Image.Null
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

    // The picture, clipped to the corners above rather than to the box they
    // are cut out of: `clip: true` on a Rectangle clips children to its
    // bounding box and not to its radius, so a photograph came out square
    // inside a rounded frame. Only the picture goes inside the
    // ClippingRectangle - its render pass hides what it wraps from the input
    // system, so the MouseArea below has to stay out of it.
    //
    // The software scene graph cannot draw that render pass at all, and would
    // drop the picture rather than square it. That is what the offscreen
    // harness runs on, so there the plain Image stands in.
    readonly property bool canRoundPictures: GraphicsInfo.api !== GraphicsInfo.Software

    Loader {
      anchors.fill: parent
      sourceComponent: canRoundPictures ? roundedPicture : picture
    }

    Component {
      id: roundedPicture
      ClippingRectangle {
        color: "transparent"
        radius: Style.space(5)
        Loader { anchors.fill: parent; sourceComponent: picture }
      }
    }

    Component {
      id: picture
      Image {
        source: root.path !== "" ? "file://" + root.path : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // The full-size picture can be thousands of pixels; decoding it at the
        // size actually drawn keeps a transcript of photographs from eating
        // hundreds of megabytes in the shell process.
        sourceSize.width: Math.round(root.drawWidth * 2)
        visible: status === Image.Ready
        onStatusChanged: root.pictureStatus = status
        Component.onCompleted: root.pictureStatus = status
      }
    }

    Spinner {
      anchors.centerIn: parent
      visible: root.loading || (root.path !== "" && root.pictureStatus === Image.Loading)
      color: Color.accent
      dotSize: Style.space(4)
    }

    Text {
      anchors.centerIn: parent
      width: parent.width - Style.spacing.lg
      visible: root.problem !== "" || root.pictureStatus === Image.Error
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
      // The transcript shows a thumbnail cropped to a tidy rectangle; the
      // whole picture opens in the window, where it can also be saved. It used
      // to go straight to xdg-open, which took the one thing anybody opens a
      // picture for - keeping a copy - somewhere this plugin could not follow.
      onClicked: root.openRequested(root.path, root.alt)
    }
  }
}
