import QtQuick
import qs.Commons

// One host's row in the popup. Peer to Waveform's ChannelColumn.qml in
// spirit, much simpler.
//
// Two-line layout (dot/icon/label/latency/uptime/buttons on line 1,
// subtitle/notes-indicator/connected-indicator on line 2, collapsed to
// line 1 only in compact mode) -- built from `Row`s for every
// variable-membership cluster (the button row, the latency+uptime stats
// row, the indicator row) rather than a manual `anchors.right: x.left`
// chain: a `Row` automatically excludes invisible children from layout
// and closes the gap, so a conditionally-visible button (Wake) or a
// compact-mode-hidden field (latency) doesn't leave a dead gap the way
// raw anchors would without extra width-zeroing logic. Phase 2's review
// already flagged the original one-line anchor chain as being at its
// practical limit before this row grew this much further.
//
// `editable` rows (bookmarks) additionally show Wake/edit/delete
// affordances.
Column {
  id: root

  // { alias, hostname, port, user, status, uptime, lastCheckedAt,
  //   latencyMs, connected, mac, group, notes, icon }
  // (mac/group/notes/icon only ever present on a bookmark-sourced host --
  // see HostList._displayHostForBookmark, which merges the bookmark's own
  // fields onto the live/synthesized probe object.)
  property var host: null
  property color dotColor: Color.muted
  property bool editable: false
  property bool compact: false
  property bool wakeonlanAvailable: true
  // Only meaningful when editable -- the bookmark's own stable id (distinct
  // from `host.alias`, which is the user-chosen, renameable label).
  property string bookmarkId: ""

  signal connectRequested(string alias)
  signal editRequested(string bookmarkId)
  signal deleteRequested(string bookmarkId)
  signal wakeRequested(string mac)

  width: Style.space(410)
  spacing: Style.spacing.xxs

  readonly property string notes: root.host && root.host.notes ? root.host.notes : ""
  property bool notesExpanded: false

  readonly property string subtitle: {
    if (!root.host || !root.host.hostname) return "resolving…"
    var userPart = root.host.user ? root.host.user + "@" : ""
    var portPart = root.host.port && root.host.port !== "22" ? ":" + root.host.port : ""
    return userPart + root.host.hostname + portPart
  }

  readonly property string labelText: (root.host && root.host.icon ? root.host.icon + " " : "") + (root.host ? root.host.alias : "")
  readonly property string uptimeText: root.host && root.host.uptime ? root.host.uptime : "—"
  readonly property string latencyText: {
    if (!root.host || root.host.status !== "up") return "—"
    var ms = root.host.latencyMs
    return (ms === null || ms === undefined) ? "—" : Math.round(ms) + "ms"
  }
  readonly property bool showWake: root.editable && root.host && !!root.host.mac && root.wakeonlanAvailable && root.host.status === "down"

  // Two-click delete confirm: first click arms it (icon fills urgent-red)
  // for a few seconds; a second click within that window actually deletes;
  // otherwise it silently reverts. No modal, but enough friction for an
  // action that also removes a real ~/.ssh/config entry.
  property bool deleteConfirming: false

  Timer {
    id: deleteConfirmTimer
    interval: 3000
    repeat: false
    onTriggered: root.deleteConfirming = false
  }

  // -------------------------------------------------------------------- row 1

  Item {
    width: root.width
    height: Style.space(22)

    Rectangle {
      id: dot
      width: Style.space(9)
      height: Style.space(9)
      radius: width / 2
      color: root.dotColor
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter

      Behavior on color {
        ColorAnimation { duration: 160 }
      }
    }

    Row {
      id: buttonRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Rectangle {
        id: wakeButton
        visible: root.showWake
        width: Style.space(52)
        height: Style.space(22)
        radius: Style.cornerRadius
        color: wakeArea.containsMouse ? Style.hoverFill : "transparent"
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor

        Text {
          anchors.centerIn: parent
          text: "Wake"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: wakeArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.wakeRequested(root.host.mac)
        }
      }

      Rectangle {
        id: editButton
        visible: root.editable
        width: Style.space(20)
        height: Style.space(20)
        radius: Style.cornerRadius
        color: editArea.containsMouse ? Style.hoverFill : "transparent"

        Text {
          anchors.centerIn: parent
          text: "✎"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: editArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.editRequested(root.bookmarkId)
        }
      }

      Rectangle {
        id: deleteButton
        visible: root.editable
        width: Style.space(20)
        height: Style.space(20)
        radius: Style.cornerRadius
        color: root.deleteConfirming ? Color.urgent : (deleteArea.containsMouse ? Style.hoverFill : "transparent")

        Text {
          anchors.centerIn: parent
          text: "✕"
          color: root.deleteConfirming ? Color.background : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: deleteArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.deleteConfirming) {
              root.deleteConfirming = false
              deleteConfirmTimer.stop()
              root.deleteRequested(root.bookmarkId)
            } else {
              root.deleteConfirming = true
              deleteConfirmTimer.restart()
            }
          }
        }
      }

      Rectangle {
        id: connectButton
        width: Style.space(66)
        height: Style.space(22)
        radius: Style.cornerRadius
        color: connectArea.containsMouse ? Color.accent : Style.normalFill
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor

        Text {
          anchors.centerIn: parent
          text: "Connect"
          color: connectArea.containsMouse ? Color.background : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: connectArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.host) root.connectRequested(root.host.alias)
        }
      }
    }

    Row {
      id: statsRow
      anchors.right: buttonRow.left
      anchors.rightMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        visible: !root.compact
        width: Style.space(40)
        horizontalAlignment: Text.AlignRight
        text: root.latencyText
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: Style.space(70)
        horizontalAlignment: Text.AlignRight
        text: root.uptimeText
        color: Qt.darker(Color.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }

    Text {
      anchors.left: dot.right
      anchors.leftMargin: Style.spacing.controlGap
      anchors.right: statsRow.left
      anchors.rightMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelText
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
  }

  // -------------------------------------------------------------------- row 2

  Item {
    visible: !root.compact
    width: root.width
    height: Style.space(16)

    Row {
      id: indicatorRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        visible: root.notes !== ""
        text: "📝"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(3)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.notesExpanded = !root.notesExpanded
        }
      }

      Rectangle {
        visible: !!(root.host && root.host.connected)
        width: Style.space(7)
        height: Style.space(7)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: Color.accent
      }
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: dot.width + Style.spacing.controlGap
      anchors.right: indicatorRow.left
      anchors.rightMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      text: root.subtitle
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  // -------------------------------------------------------------------- row 3

  Text {
    visible: root.notesExpanded && root.notes !== "" && !root.compact
    width: root.width
    leftPadding: dot.width + Style.spacing.controlGap
    wrapMode: Text.WordWrap
    text: root.notes
    color: Qt.darker(Color.foreground, 1.3)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
