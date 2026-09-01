import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The sidebar: the people talking to you, then the rooms you are in. Rows
// arrive from Model.conversationRows already grouped and in order, so this
// only draws them and says which was picked.
Column {
  id: root

  property var rows: []
  property string selectedKey: ""
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int cursorIndex: -1
  // How generously to space the rows. 1.0 is the theme's own spacing.
  property real density: 1.0
  // The theme's named colours, for the presence dot.
  property var palette: ({})
  property bool showAvatars: true

  // Properties, not a pad() call inside each binding. A binding that reaches
  // its dependency through a function call does not reliably re-run when that
  // dependency changes - which is exactly what happened in the Teams plugin:
  // the numbers changed and the rows did not move.
  readonly property int rowGap: Math.max(1, Math.round(Style.spacing.sm * density))
  readonly property int rowPadding: Math.max(1, Math.round(Style.spacing.md * density))
  // Not scaled: a wider left margin on every row just narrows the names.
  readonly property int rowIndent: Style.spacing.md
  readonly property int faceSize: Math.max(Style.space(20), Style.font.body * 1.7)

  // The column the unread bar stands in, to the left of every row. The pane
  // holding this list hands it this much of its own left padding, so that the
  // names - not the markers - line up with the window title.
  property int markerGutter: rowIndent + Style.space(6)

  signal picked(var row)
  // Where the cursored row sits, so the pane holding this list can keep it on
  // screen. The list cannot scroll itself: it does not know it is in one.
  signal cursorMoved(real itemY, real itemHeight)

  spacing: rowGap

  readonly property var selectable: Model.selectableRows(rows)

  function moveCursor(step) {
    if (selectable.length === 0) return
    var next = cursorIndex < 0 ? (step > 0 ? 0 : selectable.length - 1) : cursorIndex + step
    cursorIndex = Math.max(0, Math.min(selectable.length - 1, next))
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= selectable.length) return
    root.picked(rows[selectable[cursorIndex]])
  }

  Repeater {
    model: root.rows

    delegate: Rectangle {
      id: line
      required property var modelData
      required property int index

      readonly property bool isHeading: modelData.kind === "heading"
      readonly property bool isNote: modelData.kind === "note"
      // Headings label; notes explain. Neither is something to click.
      readonly property bool inert: isHeading || isNote
      readonly property bool isChannel: String(modelData.channelKind || "") === "channel"
      readonly property bool selected: !inert && root.selectedKey === String(modelData.key)
      readonly property int pickIndex: root.selectable.indexOf(index)
      readonly property bool cursored: !inert && root.cursorIndex >= 0
                                       && root.cursorIndex === pickIndex
      onCursoredChanged: if (cursored) root.cursorMoved(y, height)

      width: parent ? parent.width : 0
      // The row's own padding, top and bottom, is what "spacing" is judged by.
      // It comes off md rather than sm because a multiplier over 4px cannot
      // produce a difference anybody can see.
      implicitHeight: Math.max(body.implicitHeight, face.visible ? face.height : 0)
                      + root.rowPadding * 2
      radius: Style.space(5)
      color: {
        if (inert) return "transparent"
        if (selected) return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
        if (hover.containsMouse || cursored) return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        return "transparent"
      }
      Behavior on color { ColorAnimation { duration: 120 } }

      // Unread is a bar down the leading edge - it is about the conversation.
      // Presence is a dot on somebody's face - it is about the person. Told
      // apart by shape and by place rather than by hue, so a conversation can
      // be unread and its person active and say both at once.
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.spacing.xxs
        anchors.bottomMargin: Style.spacing.xxs
        width: Style.space(3)
        radius: width
        visible: line.modelData.unread === true
        color: root.accent
      }

      Avatar {
        id: face
        anchors.left: parent.left
        anchors.leftMargin: root.markerGutter
        anchors.verticalCenter: parent.verticalCenter
        visible: !line.inert && (root.showAvatars || line.isChannel)
        size: root.faceSize
        // A channel has no face. The hash it is called by is the icon it
        // already has, and drawing initials for "#platform" would be a "P"
        // that means nothing.
        glyph: line.isChannel ? (line.modelData.private === true ? "" : "#") : ""
        path: String(line.modelData.avatar || "")
        name: String(line.modelData.title || "")
        presence: String(line.modelData.presence || "")
        palette: root.palette
        fg: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
      }

      Column {
        id: body
        anchors.left: parent.left
        // Stops where the timestamp starts. Without this the title is free to
        // be as wide as it likes, elide does nothing, and a long name runs
        // straight under the time - which it did, at compact spacing.
        anchors.right: stamp.visible ? stamp.left : parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.markerGutter
                            + (face.visible ? face.size + Style.spacing.md : 0)
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.xxs

        Row {
          width: parent.width
          spacing: Style.spacing.xs

          // With avatars off there is nowhere to put the presence dot but in
          // front of the name, which is where the Teams plugin puts it.
          Rectangle {
            id: bareDot
            anchors.verticalCenter: title.verticalCenter
            width: Style.space(7)
            height: width
            radius: width
            visible: !face.visible && !line.inert
                     && Model.presenceColor(line.modelData.presence, root.palette) !== ""
            color: String(line.modelData.presence) === "away"
                   ? "transparent" : Model.presenceColor(line.modelData.presence, root.palette)
            border.width: String(line.modelData.presence) === "away" ? Style.space(2) : 0
            border.color: Model.presenceColor(line.modelData.presence, root.palette)
          }

          Text {
            id: title
            width: parent.width - (bareDot.visible ? bareDot.width + parent.spacing : 0)
                   - (badge.visible ? badge.width + parent.spacing : 0)
            text: String(line.modelData.title || "")
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: line.inert ? root.dim : root.fg
            font.family: root.fontFamily
            font.pixelSize: line.isHeading ? Style.font.caption : Style.font.body
            font.bold: line.isHeading || line.modelData.unread === true || line.selected
            font.capitalization: line.isHeading ? Font.AllUppercase : Font.MixedCase
            font.italic: line.isNote
          }

          // How many are waiting, when Slack has said. It does for a channel
          // and a DM alike, which the Teams plugin could never show - Graph
          // will say whether a chat is unread but not by how much.
          Rectangle {
            id: badge
            anchors.verticalCenter: title.verticalCenter
            visible: Number(line.modelData.unreadCount || 0) > 1
            width: count.implicitWidth + Style.spacing.sm
            height: count.implicitHeight + Style.spacing.xxs
            radius: height / 2
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)

            Text {
              id: count
              anchors.centerIn: parent
              text: String(line.modelData.unreadCount || 0)
              textFormat: Text.PlainText
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }

        Text {
          width: parent.width
          visible: !line.inert && String(line.modelData.subtitle || "") !== ""
          text: String(line.modelData.subtitle || "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          maximumLineCount: 1
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        id: stamp
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.top: parent.top
        anchors.topMargin: root.rowPadding
        visible: !line.inert && String(line.modelData.when || "") !== ""
        text: Model.whenLabel(line.modelData.when, new Date())
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: !line.inert
        enabled: !line.inert
        cursorShape: line.inert ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: {
          root.cursorIndex = line.pickIndex
          root.picked(line.modelData)
        }
      }
    }
  }
}
