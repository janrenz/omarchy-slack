import QtQuick
import qs.Commons
import qs.Ui

// Placeholder conversation rows, shaped like the real ones and breathing
// gently, for the wait before the first fetch answers.
//
// Rows rather than a spinner alone: they hold the sidebar at the width and
// height it is about to have, so nothing jumps when the real list arrives -
// and they say what is coming, which a bare spinner does not.
Column {
  id: root

  property int rows: 7
  property color fg: Color.foreground
  property int period: 1400

  spacing: Style.spacing.md

  // One animation driving every row, so they breathe together instead of
  // drifting apart the way per-row animations do.
  property real pulse: 1.0
  SequentialAnimation on pulse {
    running: root.visible
    loops: Animation.Infinite
    NumberAnimation { to: 0.45; duration: root.period / 2; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 1.0; duration: root.period / 2; easing.type: Easing.InOutQuad }
  }

  function wash(alpha) {
    return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, alpha * root.pulse)
  }

  Repeater {
    model: root.rows

    delegate: Column {
      required property int index
      width: parent ? parent.width : 0
      spacing: Style.spacing.xs

      // Widths vary the way names and messages do; a column of identical bars
      // reads as a broken layout rather than as loading.
      readonly property real titleWidth: [0.52, 0.38, 0.61, 0.44, 0.57, 0.35, 0.49][index % 7]
      readonly property real bodyWidth: [0.86, 0.72, 0.91, 0.64, 0.80, 0.88, 0.70][index % 7]

      Rectangle {
        width: parent.width * parent.titleWidth
        height: Style.font.body
        radius: Style.space(3)
        color: root.wash(0.16)
      }

      Rectangle {
        width: parent.width * parent.bodyWidth
        height: Style.font.caption
        radius: Style.space(3)
        color: root.wash(0.09)
      }
    }
  }
}
