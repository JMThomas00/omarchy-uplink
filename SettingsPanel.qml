import QtQuick
import qs.Ui
import qs.Commons

// Inline settings form -- probe cadence and the compact-row toggle. No
// shared "gear icon -> inline settings" component exists anywhere in this
// shell to copy (confirmed) -- same inline-expand shape as every other
// panel in this plugin (BookmarkForm, ExportImportPanel).
Item {
  id: root

  property var settingsStoreRef: null

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  onVisibleChanged: if (visible && root.settingsStoreRef) {
    probeIntervalField.value = root.settingsStoreRef.probeIntervalSec
    popupIntervalField.value = root.settingsStoreRef.popupProbeIntervalSec
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
  }
}
