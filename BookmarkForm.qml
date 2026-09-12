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
  property bool initialFavorite: false
  property string initialProtocol: "ssh"
  property string initialRdpPort: "3389"
  property string initialRdpUser: ""
  property string initialPassword: ""
  property string initialRdpPassword: ""

  signal saved()
  signal cancelled()

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  property bool advancedOpen: false
  property bool favoriteValue: false
  property string protocolValue: "ssh"
  property bool passwordRevealed: false
  property bool rdpPasswordRevealed: false

  function _submit() {
    var fields = {
      label: labelField.text,
      hostname: hostField.text,
      port: portField.value,
      user: userField.text,
      group: groupField.text,
      icon: iconField.text,
      mac: macField.text,
      notes: notesField.text,
      favorite: root.favoriteValue,
      protocol: root.protocolValue,
      rdpPort: rdpPortField.value,
      rdpUser: rdpUserField.text,
      password: passwordField.text,
      rdpPassword: rdpPasswordField.text
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

  // Deferred via Qt.callLater rather than copied directly in reaction to
  // `visible` -- confirmed live (temporary console.warn tracing) that when
  // this form is a single persistent instance (hoisted out of the group
  // Repeater, see HostList.qml) rather than freshly constructed per open,
  // QML fires this object's OWN onVisibleChanged/onXChanged handlers in
  // property-DECLARATION order as `root.formMode`/`formEditingId` change in
  // HostList: `visible` is declared first at the instantiation site, so its
  // changed-handler ran and read `editingId`/`initialLabel` BEFORE their own
  // bindings (declared later) had been re-evaluated against the new
  // formMode/formEditingId -- copying blank values into the fields even
  // though root.initialLabel etc were already correct microseconds later.
  // A freshly-constructed instance never hit this (construction evaluates
  // every property's binding once, up front, with no notification-order
  // dependency), which is why this only ever showed up after hoisting this
  // into one stable, reused instance -- and why closing/reopening the whole
  // popup (destroying and recreating this instance) used to appear to
  // "fix" it. Qt.callLater runs after the current synchronous notification
  // cascade fully settles, so by the time this reads initial*, every
  // sibling property on this same instance is guaranteed current.
  onVisibleChanged: if (visible) Qt.callLater(root._loadFields)

  function _loadFields() {
    if (!root.visible) return
    labelField.text = root.initialLabel
    hostField.text = root.initialHostname
    portField.value = Number(root.initialPort) || 22
    userField.text = root.initialUser
    groupField.text = root.initialGroup
    iconField.text = root.initialIcon
    macField.text = root.initialMac
    notesField.text = root.initialNotes
    root.favoriteValue = root.initialFavorite
    root.protocolValue = root.initialProtocol || "ssh"
    rdpPortField.value = Number(root.initialRdpPort) || 3389
    rdpUserField.text = root.initialRdpUser
    passwordField.text = root.initialPassword
    rdpPasswordField.text = root.initialRdpPassword
    // Reset to hidden every time the form (re)opens -- a password left
    // revealed from editing one bookmark shouldn't still show in plain
    // text when switching straight to editing a different one.
    root.passwordRevealed = false
    root.rdpPasswordRevealed = false
    root.advancedOpen = root.initialMac !== "" || root.initialNotes !== ""
    root.errorText = ""
    labelField.forceActiveFocus()
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

    Text {
      text: root.favoriteValue ? "★ Favorite" : "☆ Favorite"
      color: root.favoriteValue ? Color.accent : Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.favoriteValue = !root.favoriteValue
      }
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

    // Plaintext storage, by explicit user request -- see BookmarkStore's
    // own comment on `password`. Fed to `ssh` via `sshpass` at connect
    // time (BarWidget.connectToHost), never written into ~/.ssh/config.
    Row {
      spacing: Style.spacing.controlGap

      TextField {
        id: passwordField
        width: Style.space(232)
        password: !root.passwordRevealed
        placeholderText: "Password (optional)"
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: root._submit()
        Keys.onEscapePressed: root.cancelled()
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.passwordRevealed ? "🙈" : "👁"
        color: Qt.darker(Color.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.body

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(3)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.passwordRevealed = !root.passwordRevealed
        }
      }
    }

    Column {
      spacing: Style.spacing.md

      Text {
        text: "Connect via"
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      // No prior segmented-control precedent anywhere in this shell's
      // first-party panels to reuse -- built from the same Rectangle+Text+
      // MouseArea idiom already used for Save/Cancel below. The underlying
      // ~/.ssh/config Host block is written unconditionally regardless of
      // this choice (SFTP Browse and `ssh <label>` keep working either
      // way) -- this only decides which button HostRow shows for one-click
      // connect.
      //
      // "vnc" deliberately left out of this list (2026-09-12) -- RDP now
      // launches via xfreerdp3 directly (see BarWidget.launchRemoteDesktop),
      // dropping the Remmina dependency, but xfreerdp doesn't speak VNC and
      // no replacement VNC client has been chosen yet. BookmarkStore's own
      // schema/validation still accepts "vnc" as a stored value (untouched,
      // so a bookmark saved before this change doesn't lose its setting) --
      // this is purely hiding the option from the picker until there's
      // somewhere for it to actually go.
      Row {
        spacing: Style.spacing.controlGap

        Repeater {
          model: ["ssh", "rdp"]

          delegate: Rectangle {
            required property string modelData
            width: Style.space(50)
            height: Style.space(24)
            radius: Style.cornerRadius
            color: root.protocolValue === modelData ? Color.accent : (protoArea.containsMouse ? Style.hoverFill : Style.normalFill)
            border.width: Style.normalBorderWidth
            border.color: Style.normalBorderColor

            Text {
              anchors.centerIn: parent
              text: modelData.toUpperCase()
              color: root.protocolValue === modelData ? Color.background : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: protoArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.protocolValue = modelData
            }
          }
        }
      }

      // Separate from the SSH `Port` field above -- deliberately, not an
      // oversight. Reported live: an existing bookmark's Port had been left
      // at its SSH default (22, from before RDP was even an option on this
      // bookmark), and launchRemoteDesktop was reusing that SAME field for
      // the RDP connection, so it tried to speak RDP on port 22 -- nothing
      // there, xfreerdp3 exited almost instantly, terminal opened and
      // closed with it. A Windows host's SSH port (if it even runs one) and
      // its RDP port are two independent services on two different ports by
      // default (22 vs 3389); one shared field can't represent both. This
      // field is JSON-only, like mac/group/notes/icon -- never written into
      // ~/.ssh/config (that block's own Port line still comes from the SSH
      // `Port` field above, unaffected).
      Row {
        visible: root.protocolValue === "rdp"
        spacing: Style.spacing.controlGap

        NumberField {
          id: rdpPortField
          label: "RDP Port"
          value: 3389
          from: 1
          to: 65535
          fieldWidth: Style.space(80)
          field.Keys.onReturnPressed: root._submit()
        }

        // NOT the SSH `User` field above -- deliberately, not just for the
        // port-style split. Reported live: a real Windows account name
        // ("Jordan Thomas") has a space in it, which the SSH `user` field's
        // own validation (POSIX-username-shaped, no spaces, since it's
        // written into ~/.ssh/config) would reject outright. Also
        // JSON-only, never touches ~/.ssh/config.
        TextField {
          id: rdpUserField
          anchors.bottom: parent.bottom
          width: Style.space(180)
          placeholderText: "Windows username"
          verticalPadding: Style.spacing.controlPaddingY
          onAccepted: root._submit()
          Keys.onEscapePressed: root.cancelled()
        }
      }

      // Plaintext storage, by explicit user request -- see BookmarkStore's
      // own comment on `rdpPassword`. When set, launchRemoteDesktop skips
      // the interactive terminal prompt entirely and authenticates
      // non-interactively -- see its own comment for why that also means
      // no terminal window at all for RDP anymore.
      Row {
        visible: root.protocolValue === "rdp"
        spacing: Style.spacing.controlGap

        TextField {
          id: rdpPasswordField
          width: Style.space(232)
          password: !root.rdpPasswordRevealed
          placeholderText: "Password (optional)"
          verticalPadding: Style.spacing.controlPaddingY
          onAccepted: root._submit()
          Keys.onEscapePressed: root.cancelled()
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.rdpPasswordRevealed ? "🙈" : "👁"
          color: Qt.darker(Color.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.body

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.rdpPasswordRevealed = !root.rdpPasswordRevealed
          }
        }
      }
    }

    Row {
      spacing: Style.spacing.controlGap

      Column {
        spacing: Style.spacing.md

        Text {
          text: "Icon"
          color: Qt.darker(Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        TextField {
          id: iconField
          width: Style.space(60)
          placeholderText: "Optional"
          verticalPadding: Style.spacing.controlPaddingY
          onAccepted: root._submit()
          Keys.onEscapePressed: root.cancelled()
        }
      }

      TextField {
        id: groupField
        anchors.bottom: parent.bottom
        width: Style.space(232)
        placeholderText: "Group (optional)"
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: root._submit()
        Keys.onEscapePressed: root.cancelled()
      }
    }

    Flow {
      width: parent.width
      // controlGap, not xxs -- xxs renders at effectively zero width on at
      // least one real theme (confirmed live: adjacent chip labels like
      // "Raspberry Pi" and "T-Share Lab" ran together with no visible gap
      // at all, reading as one garbled word). These are plain Text
      // delegates with no padding of their own, so legibility here depends
      // entirely on Flow's own inter-item spacing -- controlGap is the
      // same token already used for the Port/User and Icon/Group rows
      // above, comfortably non-zero regardless of theme.
      spacing: Style.spacing.controlGap
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
