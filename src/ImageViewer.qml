import QtQuick
import QtCore
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One picture, at the size the window can give it, with a way to keep a copy.
//
// The transcript draws a thumbnail cropped to a tidy rectangle; this is the
// whole thing, letterboxed rather than cropped, because the point of opening a
// picture is to see the parts the thumbnail cut off.
//
// It is a layer of the window rather than a handoff to whatever else is
// installed. Handing it off was all there was before, and it took the one
// thing anybody opens a picture for - keeping it - somewhere this plugin could
// not follow. Open is still here for the cases a real viewer is wanted
// (zooming, a slideshow of a folder); it is no longer the only way through.
Item {
  id: root

  // The cached file slack.py fetched. Named by digest, which is why the
  // suggested filename below has to be built rather than read off it.
  property string path: ""
  // What the message called the picture, if it said.
  property string alt: ""
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal closeRequested()

  readonly property string extension: {
    var dot = path.lastIndexOf(".")
    var slash = path.lastIndexOf("/")
    return dot > slash && dot >= 0 ? path.substring(dot) : ""
  }

  // What to call it when it is saved. The cache names files by digest, so the
  // message's own words are the only human name there is - and failing that a
  // plain one, because nobody wants a sha256 in their Downloads folder.
  readonly property string suggestedName: {
    var base = String(alt || "").trim()
      .replace(/[\/\\:*?"<>|]+/g, " ")
      .replace(/\s+/g, " ")
      .trim()
    if (base.length > 60) base = base.substring(0, 60).trim()
    if (base === "") base = "slack-image"
    return base + extension
  }

  // What happened to the last save, said here rather than in a dialog nobody
  // asked for. Cleared when another one starts.
  property string notice: ""
  property string problem: ""

  function save() {
    if (path === "") return
    notice = ""
    problem = ""
    // Pre-filled, so Enter in the dialog is a complete answer.
    saveDialog.selectedFile = saveDialog.currentFolder + "/" + encodeURIComponent(suggestedName)
    saveDialog.open()
  }

  function openExternally() {
    if (path === "") return
    Quickshell.execDetached(["xdg-open", path])
  }

  FileDialog {
    id: saveDialog
    title: "Save image as"
    fileMode: FileDialog.SaveFile
    currentFolder: StandardPaths.writableLocation(StandardPaths.DownloadLocation)
    onAccepted: root.copyTo(selectedFile)
  }

  function copyTo(fileUrl) {
    var target = decodeURIComponent(String(fileUrl).replace(/^file:\/\//, ""))
    if (target === "") return
    copyProc.target = target
    // cp rather than reading the bytes through QML: the picture can be several
    // megabytes and the shell process has no reason to hold a copy of it.
    // `--` because a filename somebody typed may begin with a dash.
    copyProc.command = ["cp", "--", root.path, target]
    copyProc.running = true
  }

  Process {
    id: copyProc
    running: false
    property string target: ""
    stderr: StdioCollector { id: copyErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        // The folder, not the whole path: the name is the part just chosen and
        // the place is the part worth confirming.
        var cut = copyProc.target.lastIndexOf("/")
        root.notice = "Saved to " + (cut > 0 ? copyProc.target.substring(0, cut) : copyProc.target)
        root.problem = ""
        return
      }
      root.problem = Model.oneLine(copyErr.text || "Could not save this image", 160)
      root.notice = ""
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.97)

    // Clicking away from the picture closes it, the way the other layers do.
    MouseArea { anchors.fill: parent; onClicked: root.closeRequested() }

    Column {
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.spacing.xxl * 2, Style.space(1100))
      height: parent.height - Style.spacing.xxl * 2
      spacing: Style.spacing.md

      Text {
        width: parent.width
        visible: root.alt !== ""
        text: root.alt
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Qt.darker(root.fg, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // The whole picture, fitted rather than cropped, and never blown up past
      // its own size - an enlarged thumbnail is worse than a small one.
      Image {
        id: picture
        width: parent.width
        height: parent.height - y - actions.height - parent.spacing
        source: root.path !== "" ? "file://" + root.path : ""
        fillMode: Image.PreserveAspectFit
        mipmap: true
        asynchronous: true
        // Clicks on the picture itself are not clicks away from it.
        MouseArea { anchors.fill: parent }
      }

      Row {
        id: actions
        spacing: Style.spacing.sm

        Button {
          text: "Save as…"
          tooltipText: "Keep a copy of this picture"
          bordered: true
          enabled: !copyProc.running && root.path !== ""
          foreground: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.save()
        }

        Button {
          text: "Open"
          tooltipText: "Open it in whatever views pictures on this machine"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.openExternally()
        }

        Button {
          text: "Close"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.closeRequested()
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.notice !== "" || root.problem !== ""
          text: root.problem !== "" ? root.problem : root.notice
          textFormat: Text.PlainText
          elide: Text.ElideMiddle
          color: root.problem !== "" ? Color.urgent : Qt.darker(root.fg, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Keeps the outcome and the key hint from running together.
        Item { width: Style.spacing.lg; height: 1 }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "s save · o open · Esc close"
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
