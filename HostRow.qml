import QtQuick
import qs.Commons

// One host's row in the popup. Peer to Waveform's ChannelColumn.qml in
// spirit, much simpler.
//
// Two-line layout (dot/star/icon/label/latency/buttons on line 1,
// subtitle/notes-indicator/connected-indicator on line 2, collapsed to
// line 1 only in compact mode) -- built from `Row`s for every
// variable-membership cluster (the button row, the latency stats row, the
// indicator row) rather than a manual `anchors.right: x.left` chain, so a
// compact-mode-hidden field (latency) doesn't leave a dead gap the way raw
// anchors would without extra width-zeroing logic. Phase 2's review
// already flagged the original one-line anchor chain as being at its
// practical limit before this row grew this much further.
//
// Every row-1 button/star slot (Wake, favorite, RDP) is ALWAYS rendered at
// a fixed size now, dimmed+disabled rather than hidden when inapplicable
// to that particular row (see remoteDesktopApplicable's own comment on
// why) -- reported live: hiding them instead shifted every OTHER button
// sideways depending on that row's own data, so "Connect" landed in a
// different horizontal position on almost every row. The exception is a
// missing SYSTEM dependency (remoteDesktopAvailable/wakeonlanAvailable/
// fileManagerAvailable) -- those still hide their button/row entirely,
// uniformly across every row, which never causes misalignment since it's
// the same for all of them.
//
// `editable` rows (bookmarks and plain ~/.ssh/config hosts alike) show
// Edit/Delete; only a real bookmark (bookmarkId !== "") has a MAC/
// favorite/protocol to make Wake/star/RDP meaningfully applicable, but
// the slots themselves still render (dimmed) on a config-host row too, to
// keep every row's layout identical.
Column {
  id: root

  // { alias, hostname, port, user, status, lastCheckedAt,
  //   latencyMs, connected, mac, group, notes, icon }
  // (mac/group/notes/icon only ever present on a bookmark-sourced host --
  // see HostList._displayHostForBookmark, which merges the bookmark's own
  // fields onto the live/synthesized probe object.)
  property var host: null
  property color dotColor: Color.muted
  property bool editable: false
  property bool compact: false
  property bool wakeonlanAvailable: true
  property bool fileManagerAvailable: true
  property bool remoteDesktopAvailable: true
  // Only meaningful when editable -- the bookmark's own stable id (distinct
  // from `host.alias`, which is the user-chosen, renameable label).
  property string bookmarkId: ""

  // Keyboard-nav highlight + delete-confirm trigger, driven by HostList's
  // key-based selection (see its own header comment on why key-, not
  // index-based). `deleteKeySeq` is bound to the SAME shared counter on
  // every row (not gated to 0 when unselected) and only ever monotonically
  // increases -- deliberately, so the guard below can check "is this row
  // currently selected" at the moment of a genuine new 'x' press, rather
  // than "did my own deleteKeySeq value change," which would also go
  // true/false whenever selection itself moves and falsely re-trigger a
  // stale not-yet-confirmed delete on a row that's merely being reselected
  // (confirmed this exact false-positive when first wiring this: gating
  // deleteKeySeq to 0-while-unselected made 0->N look identical whether N
  // came from a real keypress or from reselecting a row after some OTHER
  // row's 'x' press had already bumped the shared counter).
  property bool selected: false
  property int deleteKeySeq: 0
  onDeleteKeySeqChanged: {
    if (!root.selected) return
    if (root.deleteConfirming) {
      root.deleteConfirming = false
      deleteConfirmTimer.stop()
      root.deleteRequested(root.bookmarkId)
    } else {
      root.deleteConfirming = true
      deleteConfirmTimer.restart()
    }
  }

  signal connectRequested(string alias)
  signal editRequested(string bookmarkId)
  signal deleteRequested(string bookmarkId)
  signal wakeRequested(string mac)
  signal browseRequested(string uri)
  signal favoriteRequested(string bookmarkId)
  signal remoteDesktopRequested(string protocol, string hostname, string port, string user, string password)

  width: Style.space(510)
  spacing: Style.spacing.xxs

  readonly property string notes: root.host && root.host.notes ? root.host.notes : ""
  property bool notesExpanded: false

  readonly property string subtitle: {
    // This used to be surfaced via the now-removed uptime Text (it
    // reused that slot for the message, not an actual uptime value) --
    // moved here so a hand-deleted bookmark block still has a visible,
    // discoverable indicator now that slot is gone entirely.
    if (root.host && root.host.configMissing) return "config entry missing — edit to restore"
    if (!root.host || !root.host.hostname) return "resolving…"
    var userPart = root.host.user ? root.host.user + "@" : ""
    var portPart = root.host.port && root.host.port !== "22" ? ":" + root.host.port : ""
    return userPart + root.host.hostname + portPart
  }

  readonly property string labelText: (root.host && root.host.icon ? root.host.icon + " " : "") + (root.host ? root.host.alias : "")
  readonly property string latencyText: {
    if (!root.host || root.host.status !== "up") return "—"
    var ms = root.host.latencyMs
    return (ms === null || ms === undefined) ? "—" : Math.round(ms) + "ms"
  }
  readonly property bool showWake: root.editable && root.host && !!root.host.mac && root.wakeonlanAvailable && root.host.status === "down"

  // Deliberately NOT gated by `editable` -- unlike Wake/Edit/Delete (all
  // bookmark-only write actions), browsing is read-only and equally
  // useful on a plain ~/.ssh/config row.
  readonly property string sftpUri: {
    if (!root.host || !root.host.hostname) return ""
    var userPart = root.host.user ? encodeURIComponent(root.host.user) + "@" : ""
    var portPart = root.host.port && root.host.port !== "22" ? ":" + root.host.port : ""
    return "sftp://" + userPart + encodeURIComponent(root.host.hostname) + portPart + "/"
  }
  readonly property bool showBrowse: root.fileManagerAvailable && root.sftpUri !== ""

  // `host.protocol` only ever exists on a bookmark-sourced merge object
  // (HostList._displayHostForBookmark) -- a plain ~/.ssh/config row's host
  // has no protocol field at all, so the `host.protocol &&` guard alone
  // (not just `!== "ssh"`) is what correctly keeps this false there
  // (undefined !== "ssh" would otherwise be true). Connect (SSH via
  // terminal) stays available and unchanged for every row regardless of
  // this -- this is a SEPARATE button, not a replacement, so a user who
  // wants terminal access to an RDP-primary host still can.
  //
  // Split into two properties, deliberately -- `remoteDesktopAvailable`
  // (is xfreerdp3 even installed) gates whether the button SLOT renders
  // at all, matching the established graceful-degradation convention for
  // a missing system dependency (same as Wake-on-LAN/Browse): every row
  // hides it together, uniformly, so this alone never causes misalignment
  // between rows. `remoteDesktopApplicable` (does THIS row have a
  // non-ssh protocol configured) instead just dims an always-present
  // button -- reported live: hiding per-row-inapplicable buttons entirely
  // (the original design) shifted every OTHER button in the row sideways
  // depending on which host had a MAC/RDP set, so "Connect" landed in a
  // different horizontal position on almost every row. A fixed-size slot
  // that's merely disabled+dimmed when inapplicable keeps every row's
  // buttons in identical positions regardless of that row's own data.
  readonly property bool remoteDesktopApplicable: root.editable && root.host && !!root.host.protocol && root.host.protocol !== "ssh"

  // Two-click delete confirm: first click arms it (icon fills urgent-red)
  // for a few seconds; a second click within that window actually deletes;
  // otherwise it silently reverts. No modal, but enough friction for an
  // action that also removes a real ~/.ssh/config entry.
  property bool deleteConfirming: false

  Timer {
    id: deleteConfirmTimer
    interval: 5000
    repeat: false
    onTriggered: root.deleteConfirming = false
  }

  // -------------------------------------------------------------------- row 1

  Item {
    width: root.width
    height: Style.space(22)

    // Selection highlight -- a child of THIS Item, not a direct child of
    // root (a Column): Qt Quick positioners (Column/Row/Grid) explicitly
    // disallow anchors on their own direct children (a runtime warning,
    // "will not function"), so this lives one level down instead, where
    // anchoring freely is fine. Only spans row 1's height rather than the
    // whole multi-row HostRow -- compact mode hides rows 2/3 entirely
    // anyway, so this covers the full visible row for compact users, and
    // still clearly marks the primary line otherwise.
    Rectangle {
      anchors.fill: parent
      z: -1
      visible: root.selected
      radius: Style.cornerRadius
      color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
    }

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
        width: root.deleteConfirming ? Style.space(64) : Style.space(20)
        height: Style.space(20)
        radius: Style.cornerRadius
        color: root.deleteConfirming ? Color.urgent : (deleteArea.containsMouse ? Style.hoverFill : "transparent")

        Behavior on width {
          NumberAnimation { duration: 160 }
        }

        Text {
          anchors.centerIn: parent
          text: root.deleteConfirming ? "Confirm?" : "✕"
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
        id: browseButton
        visible: root.showBrowse
        width: Style.space(20)
        height: Style.space(20)
        radius: Style.cornerRadius
        color: browseArea.containsMouse ? Style.hoverFill : "transparent"

        Text {
          anchors.centerIn: parent
          text: "📁"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: browseArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.browseRequested(root.sftpUri)
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

      // visible still gates on remoteDesktopAvailable (the system
      // dependency) -- if xfreerdp3 genuinely isn't installed, every row
      // hides this together, which never causes misalignment since it's
      // uniform. Only per-row applicability (remoteDesktopApplicable)
      // dims it instead of hiding it -- see that property's own comment.
      Rectangle {
        id: remoteDesktopButton
        visible: root.remoteDesktopAvailable
        width: Style.space(46)
        height: Style.space(22)
        radius: Style.cornerRadius
        opacity: root.remoteDesktopApplicable ? 1.0 : 0.35
        color: (root.remoteDesktopApplicable && remoteDesktopArea.containsMouse) ? Style.hoverFill : "transparent"
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor

        Text {
          anchors.centerIn: parent
          text: (root.host && root.host.protocol && root.host.protocol !== "ssh") ? root.host.protocol.toUpperCase() : "RDP"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: remoteDesktopArea
          anchors.fill: parent
          enabled: root.remoteDesktopApplicable
          hoverEnabled: root.remoteDesktopApplicable
          cursorShape: root.remoteDesktopApplicable ? Qt.PointingHandCursor : Qt.ArrowCursor
          // rdpPort/rdpUser, NOT host.port/host.user -- those are the SSH
          // port/user (written into ~/.ssh/config), independent fields
          // from their RDP-specific counterparts (see BookmarkForm's own
          // comment on why one shared field can't represent both services
          // on the same host -- a real Windows account name like "Jordan
          // Thomas" also isn't valid in the SSH `user` field's charset).
          onClicked: if (root.host) root.remoteDesktopRequested(root.host.protocol, root.host.hostname, root.host.rdpPort, root.host.rdpUser, root.host.rdpPassword)
        }
      }

      // Wake lives last, deliberately separated from Edit/Delete/Browse/
      // Connect/RDP -- it's the button used least often (only relevant for
      // a down, MAC-equipped host), so it sits at the far edge rather than
      // crowding the frequently-used cluster. Always rendered at a fixed
      // size, dimmed+disabled (not hidden) when this row has no MAC/isn't
      // down -- see remoteDesktopApplicable's own comment above on why: a
      // hidden-vs-shown button shifts every OTHER button in the row
      // sideways depending on that row's own data, which is exactly the
      // misalignment this fixes.
      Rectangle {
        id: wakeButton
        width: Style.space(52)
        height: Style.space(22)
        radius: Style.cornerRadius
        opacity: root.showWake ? 1.0 : 0.35
        color: (root.showWake && wakeArea.containsMouse) ? Style.hoverFill : "transparent"
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
          enabled: root.showWake
          hoverEnabled: root.showWake
          cursorShape: root.showWake ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: root.wakeRequested(root.host.mac)
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
    }

    // Favorite toggle -- always rendered (fixed layout, see this file's
    // own header comment), dimmed+disabled for a plain ~/.ssh/config row
    // (bookmarkId === ""), which has no favorite field at all. Gated on
    // bookmarkId, NOT editable -- a plain config-host row is ALSO
    // editable: true (it supports rename/delete via its own narrower
    // path), so editable alone doesn't mean "is a bookmark." bookmarkId
    // is only ever non-empty for an actual bookmark-sourced row.
    // Deliberately NOT added to buttonRow: that row's own header comment
    // already flags it as "at its practical limit," and this spot (next
    // to the label) is both free and a conventional place for a favorite
    // star to live.
    Text {
      id: favStar
      anchors.left: dot.right
      anchors.leftMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      opacity: root.bookmarkId !== "" ? 1.0 : 0.35
      text: (root.host && root.host.favorite) ? "★" : "☆"
      color: (root.host && root.host.favorite) ? Color.accent : Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.body

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        enabled: root.bookmarkId !== ""
        hoverEnabled: root.bookmarkId !== ""
        cursorShape: root.bookmarkId !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.favoriteRequested(root.bookmarkId)
      }
    }

    Text {
      anchors.left: favStar.right
      anchors.leftMargin: Style.spacing.controlGap
      anchors.right: statsRow.left
      anchors.rightMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelText
      // Urgent-colored regardless of compact mode -- unlike the fuller
      // "config entry missing" message in subtitle (row 2), which is
      // hidden in compact mode along with the rest of that row, this is
      // the one indicator of that state guaranteed visible either way.
      color: (root.host && root.host.configMissing) ? Color.urgent : Color.foreground
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
