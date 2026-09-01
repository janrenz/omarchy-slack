import QtQuick
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

  readonly property string initials: {
    var words = String(name || "").replace(/^[#@]/, "").trim().split(/\s+/)
    if (words.length === 0 || words[0] === "") return "?"
    if (words.length === 1) return words[0].substring(0, 1).toUpperCase()
    return (words[0].substring(0, 1) + words[words.length - 1].substring(0, 1)).toUpperCase()
  }

  Rectangle {
    id: plate
    anchors.fill: parent
    radius: root.glyph !== "" ? Style.space(4) : width / 2
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
    clip: true

    Text {
      anchors.centerIn: parent
      visible: picture.status !== Image.Ready
      text: root.glyph !== "" ? root.glyph : root.initials
      textFormat: Text.PlainText
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.75)
      font.family: root.fontFamily
      font.pixelSize: Math.max(Style.font.caption, root.size * 0.42)
      font.bold: root.glyph === ""
    }

    Image {
      id: picture
      anchors.fill: parent
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
