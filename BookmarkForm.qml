import QtQuick
import qs.Ui
import qs.Commons

// Inline add/edit form for a bookmark -- not a separate popup, lives
// directly inside HostList.qml's Bookmarks section. Field wiring follows
// the Wi-Fi passphrase prompt pattern in the built-in network panel
// (/usr/share/omarchy/shell/plugins/panels/network/Panel.qml): focus on
// become-visible, Enter submits, Escape cancels.
Item {
  id: root

  property var bookmarkStore: null
  // Empty editingId = add mode; non-empty = editing that bookmark (fields
  // pre-filled by the caller via initial* props before this becomes visible).
  property string editingId: ""
  property string initialLabel: ""
  property string initialHostname: ""
  property string initialPort: "22"
  property string initialUser: ""
  property string initialMac: ""
  property string initialGroup: ""
  property string initialNotes: ""
  property string initialIcon: ""

  signal saved()
  signal cancelled()

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  property bool advancedOpen: false

  function _submit() {
    var fields = {
      label: labelField.text,
      hostname: hostField.text,
      port: portField.value,
      user: userField.text,
      group: groupField.text,
      icon: iconField.text,
      mac: macField.text,
      notes: notesField.text
    }
    var error = root.editingId
      ? root.bookmarkStore.updateBookmark(root.editingId, fields)
      : root.bookmarkStore.addBookmark(fields)
    if (error) {
      root.errorText = error
      return
    }
    root.errorText = ""
    root.saved()
  }

  property string errorText: ""

  readonly property var groupSuggestions: root.bookmarkStore ? root.bookmarkStore.groupNames : []

  onVisibleChanged: if (visible) {
    labelField.text = root.initialLabel
    hostField.text = root.initialHostname
    portField.value = Number(root.initialPort) || 22
    userField.text = root.initialUser
    groupField.text = root.initialGroup
    iconField.text = root.initialIcon
    macField.text = root.initialMac
    notesField.text = root.initialNotes
    root.advancedOpen = root.initialMac !== "" || root.initialNotes !== ""
    root.errorText = ""
    Qt.callLater(function() { labelField.forceActiveFocus() })
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    TextField {
      id: labelField
      width: parent.width
      placeholderText: "Label (e.g. Juniper)"
      verticalPadding: Style.spacing.controlPaddingY
      onAccepted: root._submit()
      Keys.onEscapePressed: root.cancelled()
    }

    TextField {
      id: hostField
      width: parent.width
      placeholderText: "Host / IP (e.g. 192.168.1.9)"
      verticalPadding: Style.spacing.controlPaddingY
      onAccepted: root._submit()
      Keys.onEscapePressed: root.cancelled()
    }

    Row {
      spacing: Style.spacing.controlGap

      NumberField {
        id: portField
        label: "Port"
        value: 22
        from: 1
        to: 65535
        fieldWidth: Style.space(80)
        field.Keys.onReturnPressed: root._submit()
      }

      TextField {
        id: userField
        anchors.bottom: parent.bottom
        width: Style.space(180)
        placeholderText: "User (optional)"
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: root._submit()
        Keys.onEscapePressed: root.cancelled()
      }
    }

    Row {
      spacing: Style.spacing.controlGap

      TextField {
        id: iconField
        width: Style.space(60)
        placeholderText: "🥧"
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: root._submit()
        Keys.onEscapePressed: root.cancelled()
      }

      TextField {
        id: groupField
        width: Style.space(232)
        placeholderText: "Group (optional)"
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: root._submit()
        Keys.onEscapePressed: root.cancelled()
      }
    }

    Flow {
      width: parent.width
      spacing: Style.spacing.xxs
      visible: root.groupSuggestions.length > 0

      Repeater {
        model: root.groupSuggestions

        delegate: Text {
          text: modelData
          color: chipArea.containsMouse ? Color.accent : Qt.darker(Color.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption

          MouseArea {
            id: chipArea
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: groupField.text = modelData
          }
        }
      }
    }

    Text {
      text: root.advancedOpen ? "▾ Advanced" : "▸ Advanced"
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.advancedOpen = !root.advancedOpen
      }
    }

    Column {
      visible: root.advancedOpen
      width: parent.width
      spacing: Style.spacing.md

      TextField {
        id: macField
        width: parent.width
        placeholderText: "MAC address (optional, for Wake-on-LAN)"
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: root._submit()
        Keys.onEscapePressed: root.cancelled()
      }

      TextField {
        id: notesField
        width: parent.width
        placeholderText: "Notes (optional)"
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: root._submit()
        Keys.onEscapePressed: root.cancelled()
      }
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
