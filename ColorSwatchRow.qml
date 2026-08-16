pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// On-air colour picker: a few preset swatches plus a free-form hex field.
// The row is a single panel cursor target; left/right while it holds the
// cursor walks `highlightIndex` through the presets and Enter applies it,
// which is why the swatch ring derives from `highlightIndex`/`selected` and
// never from mouse hover (CursorSurface contract).
CursorSurface {
  id: root

  property var presets: ["#ff0000", "#ff6a00", "#a020f0"]
  property string selected: "#ff0000"
  property int highlightIndex: -1
  property string fontFamily: Style.font.family

  // The panel blocks its key catcher while the hex field has focus, so
  // typing "j"/"k" edits text instead of moving the cursor.
  readonly property bool editing: hexField.activeFocus

  signal picked(string hex)
  signal hoveredRow
  // The owner drives `highlightIndex`, so hover reports upward instead of
  // assigning to it (that would overwrite the owner's binding).
  signal hoveredSwatch(int index)

  function commit(value) {
    var hex = String(value || "").trim().toLowerCase()
    if (hex.indexOf("#") !== 0) hex = "#" + hex
    if (!/^#[0-9a-f]{6}$/.test(hex)) {
      hexField.text = root.selected
      return
    }
    if (hex === String(root.selected).toLowerCase()) return
    root.picked(hex)
  }

  function applyHighlighted() {
    if (root.highlightIndex < 0 || root.highlightIndex >= root.presets.length) return
    root.commit(String(root.presets[root.highlightIndex]))
  }

  implicitHeight: layout.implicitHeight + Style.spacing.rowPaddingX

  onSelectedChanged: if (!hexField.activeFocus) hexField.text = root.selected

  RowLayout {
    id: layout
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(8)

    Repeater {
      model: root.presets

      BorderSurface {
        id: swatch
        required property var modelData
        required property int index

        readonly property string hex: String(swatch.modelData)
        readonly property bool ringed: root.highlightIndex === swatch.index
          || root.selected.toLowerCase() === swatch.hex.toLowerCase()

        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.space(22)
        implicitHeight: Style.space(22)
        radius: Style.cornerRadius > 0 ? implicitHeight / 2 : 0
        color: swatch.hex
        borderSpec: swatch.ringed
          ? Border.controlSpec("selected", root.foreground, root.accent)
          : Border.controlSpec("normal", root.foreground, root.accent)

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.hoveredSwatch(swatch.index)
          onClicked: root.commit(swatch.hex)
        }
      }
    }

    TextField {
      id: hexField
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      text: root.selected
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      placeholderText: "#rrggbb"
      onAccepted: root.commit(hexField.text)
      onHoveredChanged: if (hexField.hovered) root.hoveredRow()
      onActiveFocusChanged: if (!hexField.activeFocus) root.commit(hexField.text)
    }
  }
}
