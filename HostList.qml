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
  property bool wakeonlanAvailable: true
  property bool fileManagerAvailable: true

  signal connectRequested(string alias)
  signal wakeRequested(string mac)
  signal browseRequested(string uri)

  width: Style.space(460)
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

  // Merges a bookmark's own entered fields (including mac/group/notes/icon,
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
      status: "checking",
      uptime: ""
    }
    return Object.assign({}, base, {
      mac: bookmark.mac,
      group: bookmark.group,
      notes: bookmark.notes,
      icon: bookmark.icon
    })
  }

  function openAddForm() {
    root.formMode = "add"
    root.formEditingId = ""
    root.settingsOpen = false
    root.configRenameTarget = ""
  }

  function openEditForm(bookmarkId) {
    root.formMode = "edit"
    root.formEditingId = bookmarkId
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
    var groups = [{ name: "", bookmarks: ungrouped }]
    for (var g = 0; g < namedOrder.length; g++) {
      groups.push({ name: namedOrder[g], bookmarks: namedMap[namedOrder[g]] })
    }
    return groups
  }

  // ------------------------------------------------------------------ header

  Item {
    width: parent.width
    height: Style.space(20)

    Text {
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

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Text {
            text: (groupSection.modelData.name || "Bookmarks") + " (" + groupSection.modelData.bookmarks.length + ")"
            color: Qt.darker(Color.foreground, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

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
          visible: groupSection.modelData.name === "" && groupSection.modelData.bookmarks.length === 0
          width: parent.width
          text: "No bookmarks yet."
          color: Qt.darker(Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: groupSection.modelData.bookmarks

          delegate: HostRow {
            required property var modelData
            width: root.width
            editable: true
            compact: root.settingsStoreRef ? root.settingsStoreRef.compactRows : false
            wakeonlanAvailable: root.wakeonlanAvailable
            fileManagerAvailable: root.fileManagerAvailable
            bookmarkId: modelData.id
            host: root._displayHostForBookmark(modelData)
            dotColor: root.statusColorFor ? root.statusColorFor(host.status) : Color.muted
            onConnectRequested: function(alias) { root.connectRequested(alias) }
            onEditRequested: function(bookmarkId) { root.openEditForm(bookmarkId) }
            onDeleteRequested: function(bookmarkId) { if (root.bookmarkStoreRef) root.bookmarkStoreRef.deleteBookmark(bookmarkId) }
            onWakeRequested: function(mac) { root.wakeRequested(mac) }
            onBrowseRequested: function(uri) { root.browseRequested(uri) }
          }
        }

        BookmarkForm {
          visible: groupSection.modelData.name === "" && root.formMode !== ""
          width: root.width
          bookmarkStore: root.bookmarkStoreRef
          editingId: root.formMode === "edit" ? root.formEditingId : ""
          initialLabel: root._editingBookmark ? root._editingBookmark.label : ""
          initialHostname: root._editingBookmark ? root._editingBookmark.hostname : ""
          initialPort: root._editingBookmark ? root._editingBookmark.port : "22"
          initialUser: root._editingBookmark ? root._editingBookmark.user : ""
          initialMac: root._editingBookmark ? root._editingBookmark.mac : ""
          initialGroup: root._editingBookmark ? root._editingBookmark.group : ""
          initialNotes: root._editingBookmark ? root._editingBookmark.notes : ""
          initialIcon: root._editingBookmark ? root._editingBookmark.icon : ""
          onSaved: root.closeForm()
          onCancelled: root.closeForm()
        }
      }
    }
  }

  // --------------------------------------------------------- ~/.ssh/config

  Column {
    width: parent.width
    spacing: Style.spacing.rowGap

    readonly property var configHosts: root.hosts.filter(function(h) { return h.source === "config"; })

    Text {
      text: "From ~/.ssh/config (" + parent.configHosts.length + ")"
      color: Qt.darker(Color.foreground, 1.2)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Text {
      visible: parent.configHosts.length === 0
      width: parent.width
      text: "No hosts found in ~/.ssh/config"
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: parent.configHosts

      delegate: HostRow {
        width: root.width
        editable: true
        compact: root.settingsStoreRef ? root.settingsStoreRef.compactRows : false
        fileManagerAvailable: root.fileManagerAvailable
        host: modelData
        dotColor: root.statusColorFor ? root.statusColorFor(modelData.status) : Color.muted
        onConnectRequested: function(alias) { root.connectRequested(alias) }
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
      visible: root.sawInclude
      width: parent.width
      text: "Some hosts may be defined via Include and aren't shown — see README."
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
