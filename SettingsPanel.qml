import QtQuick
import qs.Ui
import qs.Commons

// Inline settings form -- probe cadence, the compact-row toggle, and (as a
// nested expandable sub-section, not a separate top-level popup link)
// Export/Import. No shared "gear icon -> inline settings" component exists
// anywhere in this shell to copy (confirmed) -- same inline-expand shape as
// every other panel in this plugin (BookmarkForm, ExportImportPanel).
Item {
  id: root

  property var settingsStoreRef: null
  property var bookmarkStoreRef: null
  property bool exportImportOpen: false

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  onVisibleChanged: {
    if (visible && root.settingsStoreRef) {
      probeIntervalField.value = root.settingsStoreRef.probeIntervalSec
      popupIntervalField.value = root.settingsStoreRef.popupProbeIntervalSec
    }
    if (!visible) root.exportImportOpen = false
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    Row {
      spacing: Style.spacing.controlGap

      NumberField {
        id: probeIntervalField
        label: "Background probe (sec)"
        value: root.settingsStoreRef ? root.settingsStoreRef.probeIntervalSec : 60
        from: 5
        to: 3600
        fieldWidth: Style.space(90)
        onModified: function(value) { if (root.settingsStoreRef) root.settingsStoreRef.setProbeIntervalSec(value) }
      }

      NumberField {
        id: popupIntervalField
        label: "Popup probe (sec)"
        value: root.settingsStoreRef ? root.settingsStoreRef.popupProbeIntervalSec : 20
        from: 5
        to: 3600
        fieldWidth: Style.space(90)
        onModified: function(value) { if (root.settingsStoreRef) root.settingsStoreRef.setPopupProbeIntervalSec(value) }
      }
    }

    Row {
      spacing: Style.spacing.controlGap

      Rectangle {
        id: compactCheckbox
        width: Style.space(16)
        height: Style.space(16)
        radius: Style.space(3)
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor
        color: (root.settingsStoreRef && root.settingsStoreRef.compactRows) ? Color.accent : "transparent"
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.settingsStoreRef) root.settingsStoreRef.setCompactRows(!root.settingsStoreRef.compactRows)
        }
      }

      Text {
        text: "Compact rows"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      text: (root.exportImportOpen ? "▾" : "▸") + " Export/Import"
      color: root.exportImportOpen ? Color.accent : Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.exportImportOpen = !root.exportImportOpen
      }
    }

    ExportImportPanel {
      visible: root.exportImportOpen
      width: parent.width
      bookmarkStoreRef: root.bookmarkStoreRef
    }
  }
}
