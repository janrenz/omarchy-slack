import QtQuick
import qs.Commons
import qs.Ui

// A button that also says which key does the same thing.
//
// Omarchy is keyboard-first, and the fastest way to learn a key is to read it
// off the thing you were about to click. ? lists every binding, but a list is
// something you go and look at; this is the one that catches somebody who was
// already reaching for the mouse.
//
// The key is drawn dim, next to the label rather than in place of it: it is a
// second way to do the same thing, not part of the button's name. A `danger`
// action hands down its accent foreground, so the key there dims from the
// accent and stays recognisably part of the same button.
//
// Only set `keyText` where the key actually works. The reading pane is drawn
// both in the window and in the bar's popup, and the popup takes far fewer
// letters - a hint there would be a promise the popup cannot keep.
Button {
  id: root

  property string keyText: ""
  property color keyColor: Qt.darker(root.foreground, 1.55)

  readonly property bool showsKey: keyText !== "" && text !== ""

  // Room for the key, and the label moved off centre to leave it.
  //
  // Button sizes itself from `horizontalPadding * 2` but indents its contents
  // from `leftPadding`, which defaults to the same value - so widening the
  // padding alone reserves the width and then spends all of it keeping the
  // label centred, which is how the key ended up printed hard against it
  // (FlagF, Deletex). The two are therefore set apart: the padding pair buys
  // the width, and leftPadding puts the label back where an ordinary button's
  // sits, so what the extra width buys is the gap before the key.
  //
  // Left-aligned only while a key is showing; without one this is an ordinary
  // centred button and has to stay indistinguishable from its neighbours.
  readonly property real keyGap: Style.spacing.controlGap * 2

  horizontalPadding: Style.spacing.controlPaddingX
                     + (showsKey ? (keyLabel.implicitWidth + keyGap) / 2 : 0)
  leftAlign: showsKey
  leftPadding: showsKey ? Style.spacing.controlPaddingX : horizontalPadding

  Text {
    id: keyLabel
    visible: root.showsKey
    text: root.keyText
    textFormat: Text.PlainText
    color: root.keyColor
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    anchors.verticalCenter: parent.verticalCenter
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.controlPaddingX + root.borderRight
  }
}
