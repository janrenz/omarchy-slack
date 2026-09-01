import QtQuick
import qs.Commons
import qs.Ui

// The reactions on one message, and the picker for adding one.
//
// A chip is a toggle, not a label: it says how many people reacted and whether
// you are one of them, and clicking it adds or removes yours. That is why the
// helper counts them per emoji and marks `mine` rather than handing over the
// raw per-person list Slack returns.
//
// Slack takes any emoji its workspace knows, including the ones somebody
// uploaded, so a chip may carry a name where the character would be - there is
// no character for a picture that lives in one workspace. Both draw; the name
// is at least honest about what was sent.
//
// What is deliberately NOT here is the button that opens the picker. This row
// has no height at all on a message nobody has reacted to, and a row that
// grows when the pointer arrives pushes every message below it down the
// transcript. So the button lives on the message line, which always has
// height, and only sets `picking` here.
Flow {
  id: root

  property var reactions: []
  // The emoji the picker offers, from slack.py. A shortlist rather than a
  // limit: Slack would take any name, and nine can be numbered and reached
  // without leaving the home row.
  property var choices: []
  property bool busy: false
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Open only while somebody is choosing, so a transcript is not a wall of
  // identical emoji rows. Driven from the message row: at most one picker is
  // open across the whole transcript, and both the keyboard and the mouse open
  // it, so the row is the one place that can know which.
  property bool picking: false

  // Number the choices, for picking them by number rather than by pointer.
  property bool numbered: false

  // The name, not the character: Slack's API speaks names, and a custom emoji
  // has no character to send.
  signal toggled(string name)

  // Who reacted, as one line: "You and Ana", "Ana, Priya and 3 more". slack.py
  // sends the names it could resolve, which for a much-reacted message is
  // fewer than the count, so the tail is counted off the count rather than off
  // the length of the list.
  function reactorLine(who, count) {
    var names = []
    for (var i = 0; i < (who || []).length; i++) {
      var name = String(who[i] || "")
      if (name !== "" && names.indexOf(name) === -1) names.push(name)
    }
    var total = Math.max(Number(count || 0), names.length)
    if (names.length === 0) return total === 1 ? "One person" : (total + " people")
    var shown = names.slice(0, 3)
    var rest = total - shown.length
    if (rest > 0) return shown.join(", ") + " and " + rest + " more"
    if (shown.length === 1) return shown[0]
    return shown.slice(0, shown.length - 1).join(", ") + " and " + shown[shown.length - 1]
  }

  // What was sent, as Slack speaks it. A workspace's own emoji has no
  // character, and the name is the only thing that identifies it either way.
  function emojiLabel(name) {
    var text = String(name || "")
    return text === "" ? "that" : (":" + text.split("::")[0] + ":")
  }

  spacing: Style.spacing.xs

  Repeater {
    model: root.reactions

    delegate: Rectangle {
      id: chipItem
      required property var modelData
      readonly property bool mine: modelData.mine === true

      // A chip has room for a character and a number, which leaves out both
      // who reacted and what the emoji is called. Under the pointer there is
      // room for all of it, including what a click would do - the one thing a
      // toggle that looks like a label has to say out loud.
      readonly property string hoverLine:
        root.reactorLine(modelData.who, modelData.count)
        + " reacted with " + root.emojiLabel(modelData.name)
        + (mine ? " · click to take yours off" : " · click to add yours")

      implicitWidth: chip.implicitWidth + Style.spacing.md
      implicitHeight: chip.implicitHeight + Style.spacing.xs * 2
      radius: height / 2
      color: mine ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                  : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
      border.width: mine ? Style.space(1) : 0
      border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55)

      Row {
        id: chip
        anchors.centerIn: parent
        spacing: Style.spacing.xxs

        Text {
          text: String(modelData.emoji || "")
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: Number(modelData.count || 0) > 1
          text: String(modelData.count || 0)
          textFormat: Text.PlainText
          color: parent.parent.mine ? root.accent : Qt.darker(root.fg, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        id: chipHover
        anchors.fill: parent
        hoverEnabled: true
        enabled: !root.busy
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(String(modelData.name))

        PanelToolTip {
          visible: chipHover.containsMouse
          text: chipItem.hoverLine
        }
      }
    }
  }

  // The choices, inline rather than in a popup: a popup over a scrolling
  // transcript has to be positioned, and this only ever holds nine things.
  Repeater {
    model: root.picking ? root.choices : []

    delegate: Rectangle {
      required property var modelData
      required property int index
      implicitWidth: face.implicitWidth + Style.spacing.md
      implicitHeight: face.implicitHeight + Style.spacing.xs * 2
      radius: height / 2
      color: pick.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.2)
                                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)

      Row {
        id: face
        anchors.centerIn: parent
        spacing: Style.spacing.xxs

        // The key that picks this one. Shown rather than left to be
        // discovered: a shortcut nobody can see is a shortcut nobody has.
        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.numbered && parent.parent.index < 9
          text: String(parent.parent.index + 1)
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          text: String(modelData.emoji || "")
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        id: pick
        anchors.fill: parent
        hoverEnabled: true
        enabled: !root.busy
        cursorShape: Qt.PointingHandCursor
        // Only the choice is reported. Closing the picker belongs to whoever
        // opened it, which is the message row.
        onClicked: root.toggled(String(modelData.name))

        PanelToolTip {
          visible: pick.containsMouse
          text: "React with " + root.emojiLabel(modelData.name)
        }
      }
    }
  }
}
