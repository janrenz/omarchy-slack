import QtQuick
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One person's picture, or the letters of their name when there is none.
//
// The picture is a local file: slack.py fetched it, checked the host before
// it did, and cached it on disk. This item never reaches the network - a
// window that renders other people's messages should not also be making
// requests on their behalf, and an <img src> in a message would otherwise be
// a way to find out when somebody read it.
Item {
  id: root

  // A path on disk, not a URL. Empty means the letters.
  property string path: ""
  property string name: ""
  // A glyph instead of letters - "#" for a channel, which has no face.
  property string glyph: ""
  property int size: Style.space(22)
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  // "active", "away", or "" for no dot at all. Group conversations get none,
  // because a group is not away.
  property string presence: ""
  property var palette: ({})

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size

  // Whether the picture is up, so the letters underneath get out of its way.
  // Held here rather than read off the Image, because the picture lives in a
  // Loader that does not exist until there is one to draw.
  property bool pictureReady: false
  onPathChanged: pictureReady = false

  readonly property string initials: {
    var words = String(name || "").replace(/^[#@]/, "").trim().split(/\s+/)
    if (words.length === 0 || words[0] === "") return "?"
    if (words.length === 1) return words[0].substring(0, 1).toUpperCase()
    return (words[0].substring(0, 1) + words[words.length - 1].substring(0, 1)).toUpperCase()
  }

  // A face is a circle; a channel's glyph is a rounded square, because a
  // channel is not a person and should not look like one.
  Rectangle {
    id: plate
    anchors.fill: parent
    radius: root.glyph !== "" ? Style.space(4) : width / 2
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)

    Text {
      anchors.centerIn: parent
      visible: !root.pictureReady
      text: root.glyph !== "" ? root.glyph : root.initials
      textFormat: Text.PlainText
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.75)
      font.family: root.fontFamily
      font.pixelSize: Math.max(Style.font.caption, root.size * 0.42)
      font.bold: root.glyph === ""
    }
  }

  // The picture, in a shape of its own.
  //
  // `clip: true` on the plate above will not do it: a Rectangle clips its
  // children to its bounding box and not to its corners, so a photograph came
  // out square inside a round plate. ClippingRectangle clips to the corners
  // properly, at the cost of a render pass each - hence the Loader, since
  // letters and glyphs are most of a sidebar and need none of it.
  //
  // That render pass is a ShaderEffect, and the software scene graph cannot
  // draw one: under it the picture would be missing altogether rather than
  // merely square. That is what this plugin's offscreen harness runs on -
  // QT_QPA_PLATFORM=offscreen forces the software backend whatever
  // QSG_RHI_BACKEND says - so there the picture is drawn plainly and a face is
  // square again, which is the right thing to degrade to.
  readonly property bool canRoundPictures: GraphicsInfo.api !== GraphicsInfo.Software

  Loader {
    anchors.fill: parent
    active: root.path !== ""
    sourceComponent: root.canRoundPictures ? roundedPicture : picture
  }

  Component {
    id: roundedPicture
    ClippingRectangle {
      color: "transparent"
      radius: plate.radius
      // The picture itself is declared once, below; a Component carries the
      // scope it was declared in, so `root` still means the avatar in there.
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
      // Decoded at the size actually drawn. A workspace's avatars are 72px
      // originals and a sidebar draws them at twenty; decoding them full-size
      // is memory the shell process keeps for the session.
      sourceSize.width: Math.round(root.size * 2)
      sourceSize.height: Math.round(root.size * 2)
      visible: status === Image.Ready
      onStatusChanged: root.pictureReady = (status === Image.Ready)
      Component.onCompleted: root.pictureReady = (status === Image.Ready)
    }
  }

  // Whether they are around, in the corner of their own picture - which is
  // where Slack puts it and where it cannot be mistaken for something about
  // the conversation. Filled for active, a ring for away: shape as well as
  // hue, so it still reads on a theme whose green and grey sit close together.
  Rectangle {
    id: dot
    visible: root.presence !== "" && Model.presenceColor(root.presence, root.palette) !== ""
    width: Math.max(Style.space(6), root.size * 0.3)
    height: width
    radius: width / 2
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -width * 0.15
    anchors.bottomMargin: -width * 0.15
    color: root.presence === "away" ? Color.background
                                    : Model.presenceColor(root.presence, root.palette)
    border.width: Style.space(2)
    border.color: root.presence === "away"
      ? Model.presenceColor(root.presence, root.palette)
      : Color.background
  }
}
