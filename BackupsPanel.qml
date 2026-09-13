import QtQuick
import qs.Ui
import qs.Commons

// Inline restore UI for BookmarkStore's rolling ~/.ssh/config backups
// (~/.config/uplink/backups/config.<epoch>.bak, already written and pruned
// to 15 by BookmarkStore itself -- this panel is purely a reader/trigger,
// same division of responsibility ExportImportPanel already has with its
// own store).
Item {
  id: root

  property var bookmarkStoreRef: null
  property string statusText: ""
  // Two-click confirm, same idiom as HostRow's own delete button --
  // per-panel rather than per-row since only one restore can be in flight
  // at a time and a stray click elsewhere (or the panel closing) should
  // always reset it.
  property string confirmingFilename: ""

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  onVisibleChanged: {
    root.statusText = ""
    root.confirmingFilename = ""
    confirmTimer.stop()
    if (visible && root.bookmarkStoreRef) root.bookmarkStoreRef.refreshBackups()
  }

  Timer {
    id: confirmTimer
    interval: 3000
    repeat: false
    onTriggered: root.confirmingFilename = ""
  }

  function _restoreClicked(filename) {
    if (root.confirmingFilename === filename) {
      root.confirmingFilename = ""
      confirmTimer.stop()
      if (root.bookmarkStoreRef) root.bookmarkStoreRef.restoreBackup(filename)
      root.statusText = "Restored. The config this replaced was itself backed up first, so this can be undone the same way."
    } else {
      root.confirmingFilename = filename
      confirmTimer.restart()
    }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    Text {
      width: parent.width
      visible: !root.bookmarkStoreRef || root.bookmarkStoreRef.backupsList.length === 0
      text: "No backups yet -- one is made automatically on every config change."
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.bookmarkStoreRef ? root.bookmarkStoreRef.backupsList : []

      Row {
        id: backupRow
        required property var modelData
        width: column.width
        spacing: Style.spacing.controlGap

        Text {
          width: backupRow.width - restoreButton.width - Style.spacing.controlGap
          text: backupRow.modelData.label
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          anchors.verticalCenter: parent.verticalCenter
        }

        Rectangle {
          id: restoreButton
          width: root.confirmingFilename === backupRow.modelData.filename ? Style.space(80) : Style.space(66)
          height: Style.space(24)
          radius: Style.cornerRadius
          color: root.confirmingFilename === backupRow.modelData.filename ? Color.urgent : (restoreArea.containsMouse ? Color.accent : Style.normalFill)
          border.width: Style.normalBorderWidth
          border.color: Style.normalBorderColor

          Text {
            anchors.centerIn: parent
            text: root.confirmingFilename === backupRow.modelData.filename ? "Confirm?" : "Restore"
            color: (root.confirmingFilename === backupRow.modelData.filename || restoreArea.containsMouse) ? Color.background : Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: restoreArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root._restoreClicked(backupRow.modelData.filename)
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: root.statusText !== ""
      text: root.statusText
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }
}
