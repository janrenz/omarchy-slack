import QtQuick
import qs.Commons
import qs.Ui

// A text field that says what it holds.
//
// A placeholder disappears the moment a value is typed, which would leave the
// settings form as a column of values with nothing saying what any of them are.
Column {
  id: root

  property string label: ""
  property string placeholder: ""
  property string value: ""
  property string hint: ""
  property bool password: false
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal edited(string value)

  // The field itself, so a caller that has to empty it can. The token field
  // is the one that must: what was typed there is a credential, and leaving it
  // sitting in a text field after it has been used is the one place this form
  // could leak one.
  property alias field: input

  spacing: Style.spacing.xxs

  Text {
    text: root.label
    visible: text !== ""
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  TextField {
    id: input
    width: parent.width
    text: root.value
    placeholderText: root.placeholder
    password: root.password
    foreground: root.fg
    accent: root.accent
    onTextChanged: if (text !== root.value) root.edited(text)
  }

  Text {
    width: parent.width
    text: root.hint
    visible: text !== ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
