import QtQuick
import qs.Commons

// Popup content: a small top header (Settings / Export-Import triggers),
// then "Bookmarks" -- split into per-group sub-sections, editable/
// deletable, with a "+ Add" trigger and inline add/edit form -- above
// "From ~/.ssh/config" (read-only, as before, auto-discovered hosts only).
//
// The Bookmarks section's grouping (`groupedBookmarks` below) is computed
// as a live declarative binding directly off `bookmarkStoreRef.bookmarks`
// -- NOT an imperative snapshot recomputed on some signal handler. This is
// the same property that avoided the original race documented below (a
// bookmark rendering in neither section for one tick because
// `bookmarkLabels`, synchronous, and `hosts`, async via the ~/.ssh/config
// resolve round trip, briefly disagreed) -- an imperative "recompute
// groups on bookmarksChanged" pattern would reintroduce that same class of
// bug in a new shape (a bookmark whose group just changed via edit
// rendering in its stale group, or neither, for one tick).
//
// The Bookmarks section's Repeaters iterate `bookmarkStoreRef.bookmarks`
// directly, NOT a filtered view of `hosts` -- `bookmarkStoreRef.bookmarks`
// updates synchronously the instant a bookmark is saved, while `hosts`
// only gains the new alias after the async ~/.ssh/config resolve round
// trip completes. Filtering `hosts` by source would make a freshly-saved
// bookmark render in neither section for that window; iterating the store
// directly means the row is always present immediately, with its live
// probe status (from `hosts`, looked up by alias) applied as soon as it
// arrives -- defaulting to a "checking" placeholder built from the
// bookmark's own entered fields until then.
Column {
  id: root

  property var bar: null
  property var hosts: []              // display snapshot from BarWidget.qml, each tagged source: "bookmark"|"config"
  // Named distinctly from the outer `BookmarkStore { id: bookmarkStore }`
  // instance in BarWidget.qml on purpose -- `HostList { bookmarkStore:
  // bookmarkStore }` would be the exact self-shadowing QML footgun
  // documented in the Waveform gotchas memory (`dragGhost: dragGhost`):
  // an object-literal property assignment's bare RHS identifier resolves
  // against the object being constructed FIRST, so it can silently bind
  // to this component's own (still-null) property of the same name
  // instead of the outer id. Confirmed hitting this exact bug live during
  // development -- the Bookmarks section rendered completely empty (no
  // rows, no "No bookmarks yet" text either, since the `root.bookmarkStore
  // &&` guard was also false) until this property was renamed. The new
  // `SettingsStore` reference below is named `settingsStoreRef` from the
  // start for the identical reason.
  property var bookmarkStoreRef: null
  property var settingsStoreRef: null
  property var statusColorFor: null   // function(status) -> color
  property bool sawInclude: false
  property bool opensshAvailable: true
  property bool fileManagerAvailable: true
  property bool remoteDesktopAvailable: true

  signal connectRequested(string alias)
  signal pingRequested(string alias)
  signal browseRequested(string uri)
  signal remoteDesktopRequested(string protocol, string hostname, string port, string user, string password)

  width: Style.space(570)
  spacing: Style.spacing.panelGap

  // "" = closed, "add" = new bookmark, "edit" = editing formEditingId
  property string formMode: ""
  property string formEditingId: ""
  property bool settingsOpen: false
  // "" = closed, else the plain ~/.ssh/config alias being renamed.
  property string configRenameTarget: ""
  readonly property bool formOpen: root.formMode !== "" || root.settingsOpen || root.configRenameTarget !== ""

  function hostForAlias(alias) {
    for (var i = 0; i < root.hosts.length; i++)
      if (root.hosts[i].alias === alias) return root.hosts[i]
    return null
  }

  // Merges a bookmark's own entered fields (including group/notes/icon,
  // which never live on a probed `hosts` entry -- those come purely from
  // ssh probing, not from bookmarks.json) with its live probe result (if
  // any has arrived yet) into the shape HostRow expects.
  function _displayHostForBookmark(bookmark) {
    var live = root.hostForAlias(bookmark.label)
    var base = live || {
      alias: bookmark.label,
      hostname: bookmark.hostname,
      port: bookmark.port,
      user: bookmark.user,
      status: "checking"
    }
    return Object.assign({}, base, {
      group: bookmark.group,
      notes: bookmark.notes,
      icon: bookmark.icon,
      favorite: bookmark.favorite,
      protocol: bookmark.protocol,
      rdpPort: bookmark.rdpPort,
      rdpUser: bookmark.rdpUser,
      password: bookmark.password,
      rdpPassword: bookmark.rdpPassword
    })
  }

  function openAddForm() {
    root.formMode = "add"
    root.formEditingId = ""
    root.settingsOpen = false
    root.configRenameTarget = ""
  }

  function openEditForm(bookmarkId) {
    // formEditingId set before formMode so _editingBookmark already
    // resolves correctly by the time formMode's change makes the form
    // visible -- belt-and-suspenders alongside BookmarkForm's own
    // Qt.callLater field-load (see its onVisibleChanged comment for why
    // that, not this ordering, is what actually fixed the blank-on-open
    // bug: the real cause was QML firing this instance's onVisibleChanged
    // before its sibling editingId/initial* bindings had caught up with
    // the same change, independent of which property HostList wrote first).
    root.formEditingId = bookmarkId
    root.formMode = "edit"
    root.settingsOpen = false
    root.configRenameTarget = ""
  }

  function closeForm() {
    root.formMode = ""
    root.formEditingId = ""
  }

  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
    root.formMode = ""
    root.configRenameTarget = ""
  }

  function openConfigRename(alias) {
    root.configRenameTarget = alias
    root.formMode = ""
    root.settingsOpen = false
  }

  function closeConfigRename() {
    root.configRenameTarget = ""
  }

  // ------------------------------------------------------------- keyboard nav
  //
  // Selection is KEY-based, not index-based: the navigable rows span two
  // structurally separate Repeaters (nested group/bookmark Repeaters below,
  // then a separate configHosts Repeater further down), both plain-JS-array
  // models with no stable per-item identity (see groupedBookmarks' own
  // header comment -- any bookmark mutation rebuilds the array from
  // scratch). Holding an index or an Item reference across a rebuild would
  // silently point at the wrong row or a destroyed one; a string key
  // survives because it's recomputed fresh from current data on every read.
  // "" = nothing selected.
  property string selectedRowKey: ""
  property int _deleteKeySeq: 0

  // Single source of truth for "which of root.hosts came from a plain
  // ~/.ssh/config entry" -- both flatRows below and the ~/.ssh/config
  // Column's own header/Repeater/count (further down this file) used to
  // each run this exact same filter independently, recomputing it twice
  // on every root.hosts change for no reason other than not sharing it.
  readonly property var configHosts: root.hosts.filter(function(h) { return h.source === "config" })

  // Built from the exact same filtering the two Repeaters below actually
  // render (groupedBookmarks + F1's per-group collapse state, then
  // configHosts + its own collapse state) -- can never drift from what's
  // on screen since it isn't a separate parallel computation.
  readonly property var flatRows: {
    var rows = []
    var groups = root.groupedBookmarks
    for (var g = 0; g < groups.length; g++) {
      var group = groups[g]
      var collapsed = root.settingsStoreRef && root.settingsStoreRef.collapsedGroups.indexOf(group.name) !== -1
      if (collapsed) continue
      for (var i = 0; i < group.bookmarks.length; i++) {
        rows.push({ key: "bm:" + group.bookmarks[i].id, alias: group.bookmarks[i].label })
      }
    }
    var configCollapsed = root.settingsStoreRef && root.settingsStoreRef.collapsedConfigHosts
    if (!configCollapsed) {
      for (var c = 0; c < root.configHosts.length; c++) {
        rows.push({ key: "cfg:" + root.configHosts[c].alias, alias: root.configHosts[c].alias })
      }
    }
    return rows
  }

  function handleMove(dy) {
    var rows = root.flatRows
    if (rows.length === 0) return
    var idx = -1
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].key === root.selectedRowKey) { idx = i; break }
    }
    if (idx === -1) {
      root.selectedRowKey = dy > 0 ? rows[0].key : rows[rows.length - 1].key
      return
    }
    var next = Math.max(0, Math.min(rows.length - 1, idx + dy))
    root.selectedRowKey = rows[next].key
  }

  function handleActivate() {
    var rows = root.flatRows
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].key === root.selectedRowKey) { root.connectRequested(rows[i].alias); return }
    }
  }

  // Config-host delete keeps its own, more careful multiAlias-safe path
  // (see the config Repeater's onDeleteRequested below) -- deliberately not
  // reachable via keyboard, only bookmark rows are.
  function handleDeleteKey() {
    if (root.selectedRowKey.indexOf("bm:") !== 0) return
    root._deleteKeySeq++
  }

  readonly property var _editingBookmark: {
    if (root.formMode !== "edit") return null
    var matches = root.bookmarkStoreRef ? root.bookmarkStoreRef.bookmarks.filter(function(b) { return b.id === root.formEditingId }) : []
    return matches.length > 0 ? matches[0] : null
  }

  // Groups bookmarks into [{name, bookmarks}], ungrouped ("") always
  // first, named groups in first-seen order after. See header comment for
  // why this must stay a plain declarative binding off
  // bookmarkStoreRef.bookmarks.
  readonly property var groupedBookmarks: {
    var list = root.bookmarkStoreRef ? root.bookmarkStoreRef.bookmarks : []
    var ungrouped = []
    var namedOrder = []
    var namedMap = {}
    for (var i = 0; i < list.length; i++) {
      var b = list[i]
      if (!b.group) { ungrouped.push(b); continue }
      if (!namedMap[b.group]) { namedMap[b.group] = []; namedOrder.push(b.group) }
      namedMap[b.group].push(b)
    }
    // Favorites sort first WITHIN each group -- no separate section, no
    // duplication. Array.prototype.sort has been spec-mandated stable
    // since ES2019, so non-favorites keep their existing relative order
    // rather than needing a manual stable-sort workaround.
    var byFavorite = function(a, b) { return (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0) }
    ungrouped.sort(byFavorite)
    var groups = [{ name: "", bookmarks: ungrouped }]
    for (var g = 0; g < namedOrder.length; g++) {
      namedMap[namedOrder[g]].sort(byFavorite)
      groups.push({ name: namedOrder[g], bookmarks: namedMap[namedOrder[g]] })
    }
    return groups
  }

  // ------------------------------------------------------------------ header

  Item {
    width: parent.width
    // Sized to the gear glyph's own implicitHeight, not a fixed spacing
    // token -- Style.space(20) (a layout-spacing token) and the glyph's
    // actual rendered size scale independently under
    // effectiveSpacingScale = spacingScale * fontScale, so on a theme/
    // config where spacingScale runs ahead of the font size, a spacing-
    // token height here reserves visibly more room than the icon needs,
    // showing up as extra dead space above "Bookmarks" (the next section
    // down, separated from this Item by the same Column's panelGap).
    height: gearText.implicitHeight

    Text {
      id: gearText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "⚙"
      color: root.settingsOpen ? Color.accent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleSettings()
      }
    }
  }

  // Unmissable, not dimmed/hidden like every other optional-dependency
  // gate in this plugin -- see BarWidget's own opensshAvailable comment
  // for why this one gets a banner instead of scattered dimmed buttons:
  // without ssh, every single row is permanently stuck on "checking"
  // with no other visible explanation anywhere in the UI.
  Rectangle {
    visible: !root.opensshAvailable
    width: parent.width
    height: sshWarningText.implicitHeight + Style.spacing.md * 2
    radius: Style.cornerRadius
    color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
    border.width: Style.normalBorderWidth
    border.color: Color.urgent

    Text {
      id: sshWarningText
      anchors.fill: parent
      anchors.margins: Style.spacing.md
      text: "⚠ openssh not found -- every host below will stay stuck on \"checking\" until it's installed. Run \"sudo pacman -S openssh\", then reopen this popup."
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  SettingsPanel {
    visible: root.settingsOpen
    width: root.width
    settingsStoreRef: root.settingsStoreRef
    bookmarkStoreRef: root.bookmarkStoreRef
  }

  // -------------------------------------------------------------- Bookmarks

  Column {
    width: parent.width
    spacing: Style.spacing.panelGap

    Repeater {
      model: root.groupedBookmarks

      delegate: Column {
        id: groupSection
        // Explicitly declared (not relied on as an implicit context
        // property) -- confirmed live this matters: with a NESTED Repeater
        // inside this same delegate (the per-bookmark one below), bare
        // `modelData` references in this outer delegate's own direct scope
        // (the header, "+ Add", "No bookmarks yet", the inner Repeater's
        // own `model:` binding) intermittently evaluated to undefined at
        // runtime, even though the identical implicit-modelData pattern
        // works fine for every OTHER (non-nested) Repeater in this same
        // file. A `required property var modelData` makes this a real,
        // unambiguous property on `groupSection` itself, sidestepping
        // whatever precedence/shadowing interaction the inner Repeater's
        // own implicit modelData was causing for its parent's scope.
        required property var modelData
        width: root.width
        spacing: Style.spacing.rowGap

        // Ungrouped ("") is collapsible too, same as any named group --
        // reuses the SAME collapsedGroups list rather than a separate
        // flag: "" is a safe, distinct sentinel here since a real group
        // name can never actually BE "" (groupField is trimmed, and an
        // empty value is exactly what makes a bookmark land in this
        // ungrouped section in the first place, per groupedBookmarks
        // above) -- so "" in the list unambiguously means "this specific
        // section," never colliding with any real group's own name.
        readonly property bool isCollapsed: root.settingsStoreRef && root.settingsStoreRef.collapsedGroups.indexOf(groupSection.modelData.name) !== -1

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Text {
            text: (groupSection.isCollapsed ? "▸ " : "▾ ") + (groupSection.modelData.name || "Bookmarks") + " (" + groupSection.modelData.bookmarks.length + ")"
            color: Qt.darker(Color.foreground, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var name = groupSection.modelData.name
                var current = root.settingsStoreRef.collapsedGroups
                var next = groupSection.isCollapsed ? current.filter(function(g) { return g !== name }) : current.concat([name])
                root.settingsStoreRef.setCollapsedGroups(next)
              }
            }
          }

          // "+ Add" stays visible regardless of the ungrouped section's own
          // collapse state, deliberately -- collapsing is a display
          // convenience, not a way to block adding a new (ungrouped-by-
          // default) bookmark. Still only ever shown on the ungrouped
          // header, same as before.
          Text {
            visible: groupSection.modelData.name === "" && root.formMode !== "add"
            text: "+ Add"
            color: addArea.containsMouse ? Color.accent : Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: addArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openAddForm()
            }
          }
        }

        Text {
          visible: !groupSection.isCollapsed && groupSection.modelData.name === "" && groupSection.modelData.bookmarks.length === 0
          width: parent.width
          text: "No bookmarks yet."
          color: Qt.darker(Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: groupSection.isCollapsed ? [] : groupSection.modelData.bookmarks

          delegate: HostRow {
            required property var modelData
            width: root.width
            editable: true
            compact: root.settingsStoreRef ? root.settingsStoreRef.compactRows : false
            fileManagerAvailable: root.fileManagerAvailable
            remoteDesktopAvailable: root.remoteDesktopAvailable
            bookmarkId: modelData.id
            host: root._displayHostForBookmark(modelData)
            dotColor: root.statusColorFor ? root.statusColorFor(host.status) : Color.muted
            // Re-evaluated fresh from current data on every rebuild, not
            // dependent on this delegate instance surviving between
            // keypresses. deleteKeySeq is the same shared counter on every
            // row -- see HostRow's own comment on why it isn't gated to 0
            // when unselected.
            selected: root.selectedRowKey === ("bm:" + modelData.id)
            deleteKeySeq: root._deleteKeySeq
            onConnectRequested: function(alias) { root.connectRequested(alias) }
            onPingRequested: function(alias) { root.pingRequested(alias) }
            onEditRequested: function(bookmarkId) { root.openEditForm(bookmarkId) }
            onDeleteRequested: function(bookmarkId) { if (root.bookmarkStoreRef) root.bookmarkStoreRef.deleteBookmark(bookmarkId) }
            onBrowseRequested: function(uri) { root.browseRequested(uri) }
            onFavoriteRequested: function(bookmarkId) { if (root.bookmarkStoreRef) root.bookmarkStoreRef.setFavorite(bookmarkId, !modelData.favorite) }
            onRemoteDesktopRequested: function(protocol, hostname, port, user, password) { root.remoteDesktopRequested(protocol, hostname, port, user, password) }
          }
        }
      }
    }

    // Deliberately a SINGLE instance living outside the group Repeater above,
    // not nested inside a per-group delegate (it used to be, gated on
    // `groupSection.modelData.name === ""`) -- `groupedBookmarks` builds a
    // brand-new array/objects on every bookmark mutation (see its own
    // comment), and Repeater has no stable identity for a plain-array model,
    // so it fully tears down and rebuilds every group delegate whenever the
    // bookmark list changes shape (e.g. a group gaining its first member).
    // A form nested inside one of those delegates got destroyed mid-save
    // whenever the edited bookmark's own group changed (reported live: after
    // editing "Juniper" to add its first-ever "Raspberry Pi" group and
    // clicking Save, the form stayed open and reset to blank instead of
    // closing) -- hoisting it here means its lifecycle no longer depends on
    // how many groups exist or which one the edited bookmark belongs to.
    BookmarkForm {
      visible: root.formMode !== ""
      width: root.width
      bookmarkStore: root.bookmarkStoreRef
      editingId: root.formMode === "edit" ? root.formEditingId : ""
      initialLabel: root._editingBookmark ? root._editingBookmark.label : ""
      initialHostname: root._editingBookmark ? root._editingBookmark.hostname : ""
      initialPort: root._editingBookmark ? root._editingBookmark.port : "22"
      initialUser: root._editingBookmark ? root._editingBookmark.user : ""
      initialGroup: root._editingBookmark ? root._editingBookmark.group : ""
      initialNotes: root._editingBookmark ? root._editingBookmark.notes : ""
      initialIcon: root._editingBookmark ? root._editingBookmark.icon : ""
      initialFavorite: root._editingBookmark ? root._editingBookmark.favorite : false
      initialProtocol: root._editingBookmark ? root._editingBookmark.protocol : "ssh"
      initialRdpPort: root._editingBookmark ? root._editingBookmark.rdpPort : "3389"
      initialRdpUser: root._editingBookmark ? root._editingBookmark.rdpUser : ""
      initialPassword: root._editingBookmark ? root._editingBookmark.password : ""
      initialRdpPassword: root._editingBookmark ? root._editingBookmark.rdpPassword : ""
      onSaved: root.closeForm()
      onCancelled: root.closeForm()
    }
  }

  // --------------------------------------------------------- ~/.ssh/config

  Column {
    id: configSection
    width: parent.width
    spacing: Style.spacing.rowGap

    // Mirrors F1's per-group collapse (groupSection.isCollapsed above) but
    // as a single bool in SettingsStore rather than a name in a list --
    // there's only ever one config-hosts section, not one per group name.
    readonly property bool isCollapsed: root.settingsStoreRef && root.settingsStoreRef.collapsedConfigHosts

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Text {
        text: (configSection.isCollapsed ? "▸ " : "▾ ") + "From ~/.ssh/config (" + root.configHosts.length + ")"
        color: Qt.darker(Color.foreground, 1.2)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.settingsStoreRef) root.settingsStoreRef.setCollapsedConfigHosts(!configSection.isCollapsed)
          }
        }
      }
    }

    Text {
      visible: !configSection.isCollapsed && root.configHosts.length === 0
      width: parent.width
      text: "No hosts found in ~/.ssh/config"
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: configSection.isCollapsed ? [] : root.configHosts

      delegate: HostRow {
        width: root.width
        editable: true
        compact: root.settingsStoreRef ? root.settingsStoreRef.compactRows : false
        fileManagerAvailable: root.fileManagerAvailable
        host: modelData
        dotColor: root.statusColorFor ? root.statusColorFor(modelData.status) : Color.muted
        selected: root.selectedRowKey === ("cfg:" + modelData.alias)
        onConnectRequested: function(alias) { root.connectRequested(alias) }
        onPingRequested: function(alias) { root.pingRequested(alias) }
        // Deliberately NOT the bookmark delegate's handlers (bookmarkId is
        // always "" here) -- rename opens the minimal alias-only form
        // below, delete goes straight to BookmarkStore's plain-host path.
        // See SshConfigHostEditor.js / BookmarkStore.renameConfigHost for
        // why only the alias is editable this way.
        onEditRequested: function() { root.openConfigRename(modelData.alias) }
        onDeleteRequested: function() { if (root.bookmarkStoreRef) root.bookmarkStoreRef.deleteConfigHost(modelData.alias) }
        onBrowseRequested: function(uri) { root.browseRequested(uri) }
      }
    }

    ConfigHostRenameForm {
      visible: root.configRenameTarget !== ""
      width: root.width
      bookmarkStore: root.bookmarkStoreRef
      targetAlias: root.configRenameTarget
      onSaved: root.closeConfigRename()
      onCancelled: root.closeConfigRename()
    }

    Text {
      visible: !configSection.isCollapsed && root.sawInclude
      width: parent.width
      text: "Some hosts may be defined via Include and aren't shown — see README."
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
