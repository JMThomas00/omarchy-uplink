import QtQuick
import qs.Ui
import qs.Commons

// Minimal inline rename form for a plain (non-bookmark) ~/.ssh/config
// entry -- deliberately NOT BookmarkForm.qml. Only the alias itself is
// editable this way (see BookmarkStore.renameConfigHost /
// SshConfigHostEditor.js for why: a plain host can carry directives like
// IdentityFile this plugin doesn't model, so nothing about it beyond the
// Host line's own alias is ever touched). Same interaction pattern as
// BookmarkForm: focus on become-visible, Enter submits, Escape cancels.
Item {
  id: root

  property var bookmarkStore: null
  property string targetAlias: ""

  signal saved()
  signal cancelled()

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  property string errorText: ""

  function _submit() {
    if (!root.bookmarkStore) return
    var error = root.bookmarkStore.renameConfigHost(root.targetAlias, aliasField.text)
    if (error) {
      root.errorText = error
      return
    }
    root.errorText = ""
    root.saved()
  }

  onVisibleChanged: if (visible) {
    aliasField.text = root.targetAlias
    root.errorText = ""
    Qt.callLater(function() { aliasField.forceActiveFocus(); aliasField.selectAll() })
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    Text {
      text: "Rename \"" + root.targetAlias + "\""
      color: Qt.darker(Color.foreground, 1.2)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    TextField {
      id: aliasField
      width: parent.width
      placeholderText: "New alias"
      verticalPadding: Style.spacing.controlPaddingY
      onAccepted: root._submit()
      Keys.onEscapePressed: root.cancelled()
    }

    Text {
      width: parent.width
      visible: root.errorText !== ""
      text: root.errorText
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.spacing.controlGap

      Rectangle {
        width: Style.space(66)
        height: Style.space(24)
        radius: Style.cornerRadius
        color: saveArea.containsMouse ? Color.accent : Style.normalFill
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor

        Text {
          anchors.centerIn: parent
          text: "Save"
          color: saveArea.containsMouse ? Color.background : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: saveArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root._submit()
        }
      }

      Rectangle {
        width: Style.space(66)
        height: Style.space(24)
        radius: Style.cornerRadius
        color: cancelArea.containsMouse ? Style.hoverFill : "transparent"
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor

        Text {
          anchors.centerIn: parent
          text: "Cancel"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: cancelArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.cancelled()
        }
      }
    }
  }
}
