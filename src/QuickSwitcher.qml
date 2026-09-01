import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Jump to anything: a conversation you are in, a channel you are not, or a
// person you have never messaged.
//
// This is the one thing everybody who uses Slack has in their fingers, and the
// reason it is worth having here rather than a "new message" dialog: what you
// want is nearly always somewhere you have already been, and typing three
// letters of it should be the whole interaction. The rows say what Enter will
// do - open, join, or start a DM - because those are three different things
// and a switcher that silently joined a channel would be a surprise.
Item {
  id: root

  property var service: null
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int cursorIndex: 0

  readonly property var rows: service ? service.switcherRows : []

  signal closed()

  function focusInput() { field.forceActiveFocus() }

  function step(delta) {
    if (rows.length === 0) return
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + delta))
  }

  function activate() {
    if (cursorIndex < 0 || cursorIndex >= rows.length) return
    var row = rows[cursorIndex]
    root.closed()
    if (service) service.jumpTo(row)
  }

  // Typing changes what is on offer, so the cursor cannot stay where it was:
  // the third row of one list is not the third row of the next.
  onRowsChanged: cursorIndex = 0

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.96)

    MouseArea { anchors.fill: parent; onClicked: root.closed() }

    // A backing item rather than a bare Column: it swallows the clicks that
    // would otherwise reach the scrim and dismiss the card.
    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Math.min(Style.space(90), root.height * 0.12)
      width: card.width
      height: card.height

      MouseArea { anchors.fill: parent }

      Column {
        id: card
        width: Math.min(Style.space(520), root.width - Style.spacing.huge * 2)
        spacing: Style.spacing.md

        Text {
          width: parent.width
          text: "Jump to"
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        TextField {
          id: field
          width: parent.width
          placeholderText: "A channel, or somebody's name"
          foreground: root.fg
          accent: root.accent
          // Looked up as you type, but not on every keystroke: the helper
          // filters lists it has cached, and asking it four times a second to
          // filter the same two thousand rows is four times the work for the
          // same answer.
          onTextChanged: lookupDebounce.restart()
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.closed(); event.accepted = true }
            else if (event.key === Qt.Key_Down) { root.step(1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.step(-1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.activate(); event.accepted = true
            }
            // Ctrl-n and Ctrl-p, for hands that never leave the home row.
            else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
              root.step(1); event.accepted = true
            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_P) {
              root.step(-1); event.accepted = true
            }
          }
        }

        Timer {
          id: lookupDebounce
          interval: 220
          onTriggered: if (root.service) root.service.lookUp(field.text)
        }

        Row {
          spacing: Style.spacing.sm
          visible: !!root.service && (root.service.directoryLoading || root.service.joining
                                      || root.service.jumpError !== ""
                                      || root.service.directoryError !== "")

          Spinner {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!root.service && (root.service.directoryLoading || root.service.joining)
            color: root.accent
            dotSize: Style.space(4)
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: card.width * 0.8
            visible: text !== ""
            text: !root.service ? ""
              : (root.service.jumpError !== "" ? root.service.jumpError : root.service.directoryError)
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xxs

          Repeater {
            model: root.rows

            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool cursored: index === root.cursorIndex

              width: card.width
              implicitHeight: label.implicitHeight + Style.spacing.sm * 2
              radius: Style.space(5)
              color: cursored || pointer.containsMouse
                ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12) : "transparent"

              Avatar {
                id: rowFace
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                size: Math.max(Style.space(18), Style.font.body * 1.4)
                glyph: modelData.channelKind === "channel" ? "#" : ""
                path: String(modelData.avatar || "")
                name: String(modelData.title || "")
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
              }

              Column {
                id: label
                anchors.left: rowFace.right
                anchors.leftMargin: Style.spacing.md
                anchors.right: verb.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  text: String(modelData.title || "")
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: modelData.unread === true
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: String(modelData.subtitle || "")
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: Qt.darker(root.fg, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // What Enter does here, said before it does it.
              Text {
                id: verb
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                visible: modelData.action !== "open"
                text: modelData.action === "join" ? "join" : "message"
                textFormat: Text.PlainText
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: pointer
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.cursorIndex = index; root.activate() }
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.rows.length === 0
          text: !!root.service && root.service.directoryLoading ? "Looking…" : "Nothing matches"
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          text: "↑↓ to choose · Enter to open · Esc to close"
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
