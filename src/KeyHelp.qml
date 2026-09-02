import QtQuick
import qs.Commons
import qs.Ui

// What the keyboard does, on the keyboard.
//
// Omarchy is keyboard-first, and a shortcut nobody can find is a shortcut
// nobody has. ? brings this up from anywhere in the window.
Column {
  id: root

  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property string fontFamily: Style.font.family
  // The a key is only there when the handover setting is on, so the list must
  // not promise it either.
  property bool agentHandover: true

  // [key, what it does, which section]
  readonly property var bindings: [
    ["j / k", "Down and up: the conversations, or the messages in one", "Moving"],
    ["Enter", "Open the conversation, and follow it in", "Moving"],
    ["h", "Back to the list, leaving the conversation open", "Moving"],
    ["l", "Into the conversation, then into the message box", "Moving"],
    ["Tab / i", "Straight to the message box", "Moving"],
    ["Esc", "Back one step: box, thread, conversation, list, window", "Moving"],

    ["Page up / down", "A screenful of whatever has focus", "Scrolling"],
    ["Ctrl-d / Ctrl-u", "Half a screen", "Scrolling"],
    ["Ctrl-f / Ctrl-b", "A screen", "Scrolling"],
    ["g / G", "To the top / to the newest", "Scrolling"],

    ["t", "Open the thread on the message under the cursor", "Doing"],
    ["a", "Hand this conversation to your coding agent", "Doing"],
    ["e or +", "React to the message under the cursor", "Doing"],
    ["1 - 9", "Pick that reaction, or take yours back", "Doing"],
    ["s / o", "In a picture: save a copy / open it elsewhere", "Doing"],
    ["Shift+Enter", "Send what you have typed", "Doing"],
    ["n or Ctrl-k", "Jump to any channel or person", "Doing"],
    ["/", "Search every message", "Doing"],
    ["f", "Filter the conversations already listed", "Doing"],
    ["u", "Show only what is unread", "Doing"],
    ["m", "Mark this conversation read", "Doing"],
    ["r", "Reload this conversation", "Doing"],
    ["c", "Read this channel's canvas, and go back again", "Doing"],
    ["e", "In a canvas: write in it", "Doing"],
    [",", "Settings", "Doing"],
    ["?", "This list", "Doing"]
  ]

  spacing: Style.spacing.md

  Text {
    text: "Keyboard"
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }

  Repeater {
    model: ["Moving", "Scrolling", "Doing"]

    delegate: Column {
      required property string modelData
      spacing: Style.spacing.xs

      PanelSectionHeader { width: Style.space(440); text: parent.modelData }

      Repeater {
        model: root.bindings.filter(function(row) {
          return row[2] === modelData && (root.agentHandover || row[0] !== "a")
        })

        delegate: Row {
          required property var modelData
          spacing: Style.spacing.md

          Text {
            width: Style.space(120)
            text: modelData[0]
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignRight
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: modelData[1]
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  Text {
    text: "Esc closes this"
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.8)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
