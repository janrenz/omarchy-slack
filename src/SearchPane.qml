import QtQuick
// Before qs.Ui deliberately: both declare a TextField, and the last import
// wins - which has to be the shell's, so this looks like the rest of Omarchy.
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Slack's own message search, which is the one thing a plugin that polls
// cannot do for itself: the workspace's history is on Slack's side and only
// Slack can look through it.
//
// A result opens the conversation anchored at that message, rather than at the
// newest one - jumping to a search hit and landing on today's chatter is the
// thing that makes people give up and go back to the browser.
Item {
  id: root

  property var service: null
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int cursorIndex: 0

  readonly property var rows: service ? service.searchResults : []

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
    if (service) service.openById(row.channel, row.channelName, row.channelKind, row.ts)
  }

  onRowsChanged: cursorIndex = 0

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.97)

    MouseArea { anchors.fill: parent; onClicked: root.closed() }

    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Math.min(Style.space(70), root.height * 0.1)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.spacing.xxl
      width: Math.min(Style.space(640), root.width - Style.spacing.huge * 2)

      MouseArea { anchors.fill: parent }

      Column {
        id: card
        anchors.fill: parent
        spacing: Style.spacing.md

        Text {
          width: parent.width
          text: "Search messages"
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        TextField {
          id: field
          width: parent.width
          placeholderText: "Words, or from:@someone in:#channel"
          foreground: root.fg
          accent: root.accent
          // On Enter, not as you type. Search is a real query on Slack's side
          // and it is rate-limited to one a minute per token on some plans;
          // firing one per keystroke would spend that on nothing.
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.closed(); event.accepted = true }
            else if (event.key === Qt.Key_Down) { root.step(1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.step(-1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.rows.length > 0 && field.text === (root.service ? root.service.searchQuery : ""))
                root.activate()
              else if (root.service) root.service.searchMessages(field.text)
              event.accepted = true
            }
          }
        }

        Row {
          spacing: Style.spacing.sm
          visible: !!root.service && (root.service.searching || root.service.searchError !== "")

          Spinner {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!root.service && root.service.searching
            color: root.accent
            dotSize: Style.space(4)
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: card.width * 0.9
            visible: text !== ""
            text: root.service ? root.service.searchError : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          visible: !!root.service && !root.service.searching && root.service.searchQuery !== ""
                   && root.rows.length === 0 && root.service.searchError === ""
          text: "Nothing found for “" + (root.service ? root.service.searchQuery : "") + "”"
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ScrollView {
          width: parent.width
          height: card.height - y
          clip: true

          Column {
            width: card.width
            spacing: Style.spacing.xxs

            Repeater {
              model: root.rows

              delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool cursored: index === root.cursorIndex

                width: card.width
                implicitHeight: hit.implicitHeight + Style.spacing.md * 2
                radius: Style.space(5)
                color: cursored || pointer.containsMouse
                  ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12) : "transparent"

                Column {
                  id: hit
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.margins: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xxs

                  Row {
                    width: parent.width
                    spacing: Style.spacing.sm

                    Text {
                      text: String(modelData.channelName || "")
                      textFormat: Text.PlainText
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Text {
                      text: String(modelData.from || "")
                      textFormat: Text.PlainText
                      color: Qt.darker(root.fg, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      text: Model.whenLabel(modelData.when, new Date())
                      textFormat: Text.PlainText
                      color: Qt.darker(root.fg, 1.6)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: parent.width
                    text: String(modelData.text || "")
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
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
        }
      }
    }
  }
}
