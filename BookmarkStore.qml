import QtQuick
import Quickshell
import Quickshell.Io
import "SshConfigParser.js" as SshConfigParser
import "SshConfigBlockWriter.js" as SshConfigBlockWriter
import "SshConfigHostEditor.js" as SshConfigHostEditor

// Owns bookmark persistence (~/.config/uplink/bookmarks.json) and
// the safe write-back of each bookmark into a sentinel-delimited Host
// block in ~/.ssh/config -- peer to Waveform's ChannelManager.qml (a
// dedicated Item owning persistence/lifecycle, keeping BarWidget.qml
// focused on probing/UI orchestration).
//
// Deliberately keeps its own in-memory copy of ~/.ssh/config's text
// (_sshConfigText), updated synchronously in JS immediately after every
// write this plugin issues -- so two rapid saves can't each compute
// against the same stale snapshot and have the second silently clobber
// the first's change (every bookmark mutation runs synchronously within
// one JS function call with no await/yield point, so the second of two
// rapid UI actions always sees the first's update already applied before
// it reads anything -- confirmed live by firing two addBookmark calls
// concurrently and checking neither's ~/.ssh/config block was lost).
//
// It ALSO needs to stay in sync with genuinely EXTERNAL edits (the user
// hand-editing ~/.ssh/config directly, including deleting a bookmark's own
// block -- the exact scenario the "config entry missing" recovery flow is
// for). A first version of this file seeded _sshConfigText once at startup
// and never touched it again except on this plugin's own writes -- which
// silently broke recovery: after a block was hand-deleted, _sshConfigText
// still held the OLD content (from before the deletion), so the next
// edit-and-resave computed its upsert against that stale snapshot and
// produced a write that Quickshell's own internals then silently dropped
// (confirmed live: the resave call returned no error, but the file on disk
// never gained the block back). The fix below has sshConfigWriter ALSO
// watch the file and refresh _sshConfigText on external changes, gated by
// _acceptExternalSync so it can never race this plugin's OWN in-flight
// write the same way relying on BarWidget's watched reader would have
// (see _writeConfigText).
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: root.home + "/.config/uplink"
  readonly property string bookmarksPath: root.configDir + "/bookmarks.json"
  readonly property string sshConfigPath: root.home + "/.ssh/config"
  // Renamed from .pre-ssh-dashboard.bak (this plugin's original name) --
  // the old backup file is left in place untouched (still a perfectly
  // valid backup of the pre-plugin state), this is just the path going
  // forward. `cp -n` (no-clobber) means the next startup creates a FRESH
  // backup under this new name capturing today's state, which is a more
  // useful safety net anyway.
  readonly property string sshConfigBackupPath: root.home + "/.ssh/config.pre-uplink.bak"

  property var bookmarks: [] // [{id, label, hostname, port, user, mac, group, notes, icon}]
  property bool bookmarksLoaded: false

  property string _sshConfigText: ""
  // True except for a short window right after this plugin issues its own
  // write (see _writeConfigText) -- guards against the writer FileView's
  // own watchChanges reacting to that write and racing an in-flight update.
  property bool _acceptExternalSync: true

  // -------------------------------------------------------------- bookmarks.json

  FileView {
    id: bookmarksFile
    path: root.bookmarksPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root._applyLoadedBookmarks(text())
    onLoadFailed: root._applyLoadedBookmarks("")
  }

  // Normalizes every loaded bookmark through one defaulting pass rather
  // than relying on scattered `|| ""` at every downstream read site -- an
  // entry saved before mac/group/notes/icon existed loads with those keys
  // simply absent (undefined, not ""), which would otherwise crash a bare
  // `.trim()`/`.length` call or land an old bookmark in a group literally
  // named "undefined" instead of falling into the ungrouped section.
  function _normalizeBookmark(b) {
    return {
      id: b.id,
      label: b.label,
      hostname: b.hostname,
      port: b.port,
      user: b.user || "",
      mac: b.mac || "",
      group: b.group || "",
      notes: b.notes || "",
      icon: b.icon || ""
    }
  }

  function _applyLoadedBookmarks(raw) {
    if (root.bookmarksLoaded) return
    root.bookmarksLoaded = true
    try {
      var doc = JSON.parse(raw || "{}")
      var list = Array.isArray(doc.bookmarks) ? doc.bookmarks : []
      root.bookmarks = list.map(root._normalizeBookmark)
    } catch (e) {
      root.bookmarks = []
    }
  }

  Timer {
    id: bookmarksSaveTimer
    interval: 300
    repeat: false
    onTriggered: bookmarksFile.setText(JSON.stringify({ bookmarks: root.bookmarks }))
  }

  function _scheduleSave() {
    if (!root.bookmarksLoaded) return
    bookmarksSaveTimer.restart()
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir]
    onExited: bookmarksFile.reload()
  }

  // ----------------------------------------------------------------- ~/.ssh/config

  // Same FileView does triple duty: seeds _sshConfigText at startup, is the
  // writer for every bookmark save, AND (watchChanges: true) refreshes
  // _sshConfigText when the file changes externally -- gated by
  // _acceptExternalSync so it can't race this plugin's own in-flight write
  // (see _writeConfigText). This instance watching its own writes too is
  // fine/idempotent: the resulting reload just reads back the same content
  // this plugin already applied to _sshConfigText synchronously, and is
  // ignored anyway while _acceptExternalSync is false.
  FileView {
    id: sshConfigWriter
    path: root.sshConfigPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: if (root._acceptExternalSync) root._sshConfigText = text()
    onLoadFailed: if (root._acceptExternalSync) root._sshConfigText = ""
  }

  Timer {
    id: externalSyncGuardTimer
    interval: 500
    repeat: false
    onTriggered: root._acceptExternalSync = true
  }

  function _writeConfigText(newText) {
    root._sshConfigText = newText
    root._acceptExternalSync = false
    sshConfigWriter.setText(newText)
    chmodTimer.restart()
    externalSyncGuardTimer.restart()
  }

  // One-time safety backup, idempotent via `cp -n` (no-clobber -- copies
  // only if the destination doesn't already exist). Run once at startup
  // rather than per-write: every real write happens after the popup is
  // interactive, which is always after Component.onCompleted has run.
  Process {
    id: backupProc
    command: ["cp", "-n", "-p", root.sshConfigPath, root.sshConfigBackupPath]
  }

  // Explicit chmod after every write rather than trusting the atomic
  // temp-file-plus-rename to preserve the original mode.
  Process {
    id: chmodProc
    command: ["chmod", "600", root.sshConfigPath]
  }

  Timer {
    id: chmodTimer
    interval: 200
    repeat: false
    onTriggered: chmodProc.running = true
  }

  Component.onCompleted: {
    mkdirProc.running = true
    backupProc.running = true
  }

  // ------------------------------------------------------------------ validation

  readonly property var _labelRe: /^[A-Za-z0-9._-]+$/
  readonly property var _hostRe: /^[A-Za-z0-9.:_-]+$/
  readonly property var _userRe: /^[A-Za-z0-9._-]+$/
  // mac/group/notes/icon are JSON-only -- never written into ~/.ssh/config
  // (see SshConfigBlockWriter.renderBlock, which only ever reads
  // id/label/hostname/port/user) -- so they don't need the strict
  // injection-safety allow-list above. Still validated for basic data
  // hygiene: no embedded newlines (breaks single-line Text rendering) and
  // a length cap against UI breakage.
  readonly property var _macRe: /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/
  readonly property var _noNewlineRe: /[\r\n]/

  // Returns an error string to show inline in the form, or "" if fields
  // are valid. Checked against _sshConfigText (never a fresh disk read --
  // see the header comment on why that matters).
  function validateFields(fields, excludeId) {
    var label = String((fields && fields.label) || "").trim()
    var hostname = String((fields && fields.hostname) || "").trim()
    var user = String((fields && fields.user) || "").trim()
    var port = fields ? fields.port : undefined
    var mac = String((fields && fields.mac) || "").trim()
    var group = String((fields && fields.group) || "").trim()
    var notes = String((fields && fields.notes) || "").trim()
    var icon = String((fields && fields.icon) || "").trim()

    if (!label) return "Label is required."
    if (!root._labelRe.test(label)) return "Label may only contain letters, digits, '.', '_', '-' (no spaces or wildcards)."
    if (!hostname) return "Host/IP is required."
    if (!root._hostRe.test(hostname)) return "Host/IP may only contain letters, digits, '.', ':', '_', '-'."
    if (user && !root._userRe.test(user)) return "User may only contain letters, digits, '.', '_', '-'."
    if (port !== undefined && port !== null && port !== "") {
      var portNum = Number(port)
      if (!isFinite(portNum) || portNum < 1 || portNum > 65535) return "Port must be between 1 and 65535."
    }
    if (mac && !root._macRe.test(mac)) return "MAC address must look like aa:bb:cc:dd:ee:ff."
    if (group && (root._noNewlineRe.test(group) || group.length > 200)) return "Group must be a single line, under 200 characters."
    if (notes && (root._noNewlineRe.test(notes) || notes.length > 200)) return "Notes must be a single line, under 200 characters."
    if (icon && icon.length > 4) return "Icon should be a single short emoji."

    var otherBookmarkLabels = root.bookmarks
      .filter(function(b) { return b.id !== excludeId })
      .map(function(b) { return b.label })
    if (otherBookmarkLabels.indexOf(label) !== -1) {
      return "\"" + label + "\" is already used by another bookmark."
    }

    var current = excludeId ? root.bookmarks.filter(function(b) { return b.id === excludeId })[0] : null
    var currentLabel = current ? current.label : null
    if (label !== currentLabel) {
      var parsed = SshConfigParser.parseHostAliases(root._sshConfigText)
      if (parsed.aliases.indexOf(label) !== -1) {
        return "\"" + label + "\" is already used by an existing ~/.ssh/config entry."
      }
    }
    return ""
  }

  // ------------------------------------------------------------- CRUD

  function _generateId() {
    return "bm_" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  }

  function _fieldsToBookmark(id, fields) {
    return {
      id: id,
      label: String(fields.label).trim(),
      hostname: String(fields.hostname).trim(),
      port: String(fields.port || 22),
      user: String(fields.user || "").trim(),
      mac: String(fields.mac || "").trim(),
      group: String(fields.group || "").trim(),
      notes: String(fields.notes || "").trim(),
      icon: String(fields.icon || "").trim()
    }
  }

  // Distinct group names currently in use, in first-seen order -- feeds
  // BookmarkForm's suggestion chips.
  readonly property var groupNames: {
    var seen = []
    for (var i = 0; i < root.bookmarks.length; i++) {
      var g = root.bookmarks[i].group
      if (g && seen.indexOf(g) === -1) seen.push(g)
    }
    return seen
  }

  // Writes/replaces this bookmark's block. Guards against the corrupted
  // "BEGIN with no END" case (see SshConfigBlockWriter.js) by refusing to
  // write a duplicate over an orphaned fragment -- surfaces a console
  // warning instead, since a fresh id can never already have an orphaned
  // marker (only possible on an update/delete of a pre-existing id whose
  // block was hand-corrupted).
  function _writeBookmarkBlock(bookmark) {
    if (SshConfigBlockWriter.hasOrphanedBeginMarker(root._sshConfigText, bookmark.id)) {
      console.warn("uplink: bookmark", bookmark.id, "(" + bookmark.label + ") has a corrupted block in ~/.ssh/config (BEGIN marker with no matching END) -- not writing, to avoid duplicating over it. Manually clean up ~/.ssh/config, or delete and re-add this bookmark.")
      return
    }
    root._writeConfigText(SshConfigBlockWriter.upsertBlock(root._sshConfigText, bookmark))
  }

  function _removeBookmarkBlock(id) {
    var newText = SshConfigBlockWriter.removeBlock(root._sshConfigText, id)
    if (newText === root._sshConfigText) return // already absent -- nothing to write
    root._writeConfigText(newText)
  }

  // Returns "" on success, or an error string (form should stay open and
  // display it).
  function addBookmark(fields) {
    var error = root.validateFields(fields, null)
    if (error) return error
    var bookmark = root._fieldsToBookmark(root._generateId(), fields)
    root._writeBookmarkBlock(bookmark)
    root.bookmarks = root.bookmarks.concat([bookmark])
    root._scheduleSave()
    return ""
  }

  function updateBookmark(id, fields) {
    var error = root.validateFields(fields, id)
    if (error) return error
    var target = null
    root.bookmarks = root.bookmarks.map(function(b) {
      if (b.id !== id) return b
      target = root._fieldsToBookmark(id, fields)
      return target
    })
    if (!target) return "Bookmark not found."
    root._writeBookmarkBlock(target)
    root._scheduleSave()
    return ""
  }

  function deleteBookmark(id) {
    var existed = root.bookmarks.some(function(b) { return b.id === id })
    if (!existed) return
    root.bookmarks = root.bookmarks.filter(function(b) { return b.id !== id })
    root._removeBookmarkBlock(id)
    root._scheduleSave()
  }

  // ---------------------------------------------------- plain config hosts
  //
  // Rename/delete for a hand-authored Host block from ~/.ssh/config that
  // this plugin did NOT create (as opposed to a bookmark's own sentinel-
  // delimited block, which the functions above fully own and freely
  // re-render). Deliberately narrower than the bookmark path: only the
  // alias itself is ever editable this way -- see SshConfigHostEditor.js
  // for why (never touches a directive it doesn't fully understand, like
  // IdentityFile/IdentitiesOnly/CheckHostIP, both real on this machine's
  // own git.lab.t-share.cc and Proxmox entries). No bookmarks.json
  // involvement in either function -- these aren't bookmarks, and there's
  // no "config entry missing" recovery to wire up either: unlike a
  // bookmark, a plain host has no independent tracking outside the file
  // itself, so a vanished block just drops out of BarWidget's own
  // `root.hosts` cleanly on its next ~/.ssh/config reload.

  // Returns "" on success, or an error string the rename form should show
  // inline and stay open on.
  function renameConfigHost(oldAlias, newAlias) {
    var found = SshConfigHostEditor.findHostBlockLines(root._sshConfigText, oldAlias)
    if (!found) return "Couldn't find \"" + oldAlias + "\" in ~/.ssh/config -- it may have just been edited or removed externally."
    if (found.multiAlias) return "This Host line defines multiple aliases -- rename it directly in ~/.ssh/config."

    var alias = String(newAlias || "").trim()
    if (alias === oldAlias) return "" // no-op: nothing changed, nothing to write

    if (!alias) return "Alias is required."
    if (!root._labelRe.test(alias)) return "Alias may only contain letters, digits, '.', '_', '-' (no spaces or wildcards)."

    var bookmarkLabels = root.bookmarks.map(function(b) { return b.label })
    if (bookmarkLabels.indexOf(alias) !== -1) return "\"" + alias + "\" is already used by a bookmark."

    var otherAliases = SshConfigParser.parseHostAliases(root._sshConfigText).aliases
      .filter(function(a) { return a !== oldAlias })
    if (otherAliases.indexOf(alias) !== -1) return "\"" + alias + "\" is already used by another ~/.ssh/config entry."

    var newText = SshConfigHostEditor.renameHostBlock(root._sshConfigText, oldAlias, alias)
    if (newText === null) return "Couldn't rename \"" + oldAlias + "\" -- it may have just changed externally. Try again."
    root._writeConfigText(newText)
    return ""
  }

  function deleteConfigHost(alias) {
    var found = SshConfigHostEditor.findHostBlockLines(root._sshConfigText, alias)
    if (!found) return // already gone
    if (found.multiAlias) {
      console.warn("uplink: \"" + alias + "\" shares its Host line with another alias -- not deleting, to avoid silently breaking the other one. Edit ~/.ssh/config directly.")
      return
    }
    var newText = SshConfigHostEditor.removeHostBlock(root._sshConfigText, alias)
    if (newText === root._sshConfigText) return // already absent -- nothing to write
    root._writeConfigText(newText)
  }
}
