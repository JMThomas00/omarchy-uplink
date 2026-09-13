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
  // Rolling per-write backups, kept OUTSIDE ~/.ssh/ (unlike the one-time
  // snapshot above) so they don't clutter a directory the user hand-
  // maintains -- pruned to the newest N in _pruneBackups.
  readonly property string backupsDir: root.configDir + "/backups"
  readonly property int _maxBackups: 15

  property var bookmarks: [] // [{id, label, hostname, port, user, group, notes, icon}]
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
  // entry saved before group/notes/icon existed loads with those keys
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
      group: b.group || "",
      notes: b.notes || "",
      icon: b.icon || "",
      favorite: !!b.favorite,
      protocol: (b.protocol === "rdp" || b.protocol === "vnc") ? b.protocol : "ssh",
      // Independent of `port` (the SSH port, written into ~/.ssh/config) --
      // deliberately, see BookmarkForm's own comment on why one shared port
      // field can't represent both SSH and RDP on the same host. JSON-only,
      // like group/notes/icon.
      rdpPort: b.rdpPort || "3389",
      // Independent of `user` for the same reason, plus a real, distinct
      // constraint: `user` is validated against _userRe (no spaces --
      // `@` IS allowed, for a UPN-style OpenSSH-for-Windows login like
      // "j.m.thomas@comcast.net") since it's written into ~/.ssh/config,
      // but a real Windows DISPLAY name can still be "Jordan Thomas" (a
      // space, which would always break the ssh_config `User` line's
      // single-token format) -- reusing `user` for RDP would either
      // reject that outright or, worse, let a space-containing value slip
      // into the SSH config write path.
      rdpUser: b.rdpUser || "",
      // Plaintext, by explicit user request (2026-09-12) -- this file gets
      // chmod 600 the same as ~/.ssh/config already does (see
      // bookmarksChmodTimer below), but that's permission hardening, not
      // encryption; anything running as this user can still read it.
      // Deliberately NOT trimmed (unlike every other text field here) --
      // a real password could legitimately have leading/trailing
      // whitespace, and silently stripping it would corrupt it.
      password: b.password || "",
      rdpPassword: b.rdpPassword || ""
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
    // Covers the case sshConfigWriter's FileView already finished its own
    // first load (and ran _syncBookmarkFieldsFromConfig against it) BEFORE
    // this independently-async load populated root.bookmarks -- the exact
    // same race class BarWidget.qml already had to solve once for its own
    // bookmarkLabels/hosts ordering. Without this, a bookmark hand-edited
    // in ~/.ssh/config before this session even started would never get
    // its one chance to self-heal, since every later call only fires on a
    // genuine NEW external change.
    root._syncBookmarkFieldsFromConfig(root._sshConfigText)
  }

  Timer {
    id: bookmarksSaveTimer
    interval: 300
    repeat: false
    onTriggered: {
      bookmarksFile.setText(JSON.stringify({ bookmarks: root.bookmarks }))
      bookmarksChmodTimer.restart()
    }
  }

  function _scheduleSave() {
    if (!root.bookmarksLoaded) return
    bookmarksSaveTimer.restart()
  }

  // bookmarks.json can now hold plaintext passwords (2026-09-12) -- locked
  // to 600 after every write, same as ~/.ssh/config already gets, plus
  // once at startup (Component.onCompleted below) to remediate a file
  // that already existed with looser permissions from before this field
  // was added. This is permission hardening, not encryption -- anything
  // running as this user can still read the file.
  Process {
    id: bookmarksChmodProc
    command: ["chmod", "600", root.bookmarksPath]
  }

  Timer {
    id: bookmarksChmodTimer
    interval: 200
    repeat: false
    onTriggered: bookmarksChmodProc.running = true
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir, root.backupsDir]
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
    onLoaded: if (root._acceptExternalSync) { var t = text(); root._sshConfigText = t; root._syncBookmarkFieldsFromConfig(t) }
    onLoadFailed: if (root._acceptExternalSync) root._sshConfigText = ""
  }

  // Re-syncs a bookmark's OWN hostname/port/user from its real
  // ~/.ssh/config block whenever that text changes externally (this
  // function is only ever reached through the _acceptExternalSync gate
  // above, or via _applyLoadedBookmarks' one-time catch-up call, so it can
  // never race this plugin's own writes). Without this, hand-editing a
  // bookmark's Port line updates the live PROBED display just fine
  // (BarWidget resolves every alias fresh via `ssh -G` on every config
  // change) but the bookmark's own JSON silently stayed stale forever --
  // reopening Edit showed the old port, and Save would silently revert the
  // hand-edit back to it. Deliberately does not touch `label`: a hand-
  // renamed Host line is the existing, separately-handled "config entry
  // missing" recovery path (the alias vanishes from ssh -G entirely), not
  // this one.
  function _syncBookmarkFieldsFromConfig(text) {
    var changed = false
    root.bookmarks = root.bookmarks.map(function(b) {
      var found = SshConfigBlockWriter.findBlock(text, b.id)
      if (!found) return b
      var parsed = SshConfigBlockWriter.parseBlockFields(text.slice(found.beginIdx, found.endIdx))
      if (parsed.hostname === b.hostname && parsed.port === b.port && parsed.user === b.user) return b
      changed = true
      return Object.assign({}, b, { hostname: parsed.hostname, port: parsed.port, user: parsed.user })
    })
    if (changed) root._scheduleSave()
  }

  Timer {
    id: externalSyncGuardTimer
    interval: 500
    repeat: false
    onTriggered: root._acceptExternalSync = true
  }

  // Backup-then-write is queued and strictly serialized (never "fire a
  // backup Process, then immediately write") -- the backup's `cp` is async,
  // so without a queue, two rapid writes could each back up already-stale
  // content or interleave with each other. _sshConfigText itself still
  // updates synchronously here (unchanged from before), preserving this
  // file's existing guarantee that a second rapid call always sees the
  // first's update already applied -- only the actual on-disk write+backup
  // is deferred and ordered.
  property var _pendingWrites: []
  property bool _writeInFlight: false

  function _writeConfigText(newText) {
    root._sshConfigText = newText
    root._acceptExternalSync = false
    root._pendingWrites.push(newText)
    root._processWriteQueue()
  }

  function _processWriteQueue() {
    if (root._writeInFlight || root._pendingWrites.length === 0) return
    root._writeInFlight = true
    rollingBackupProc.command = ["cp", "-p", root.sshConfigPath, root.backupsDir + "/config." + Date.now() + ".bak"]
    rollingBackupProc.running = true
  }

  // Best-effort: exit code ignored (a brand-new install with no pre-
  // existing ~/.ssh/config yet makes `cp` fail harmlessly, same as the
  // one-time backupProc below already tolerates). The actual write, and
  // the timers that gate reacting to it, only fire once this backup
  // attempt has finished -- not at enqueue time -- so the 500ms external-
  // sync suppression window starts when the write actually lands, not
  // before.
  Process {
    id: rollingBackupProc
    command: []
    onExited: {
      var newText = root._pendingWrites.shift()
      sshConfigWriter.setText(newText)
      chmodTimer.restart()
      externalSyncGuardTimer.restart()
      root._pruneBackups()
      root._writeInFlight = false
      root._processWriteQueue()
    }
  }

  Process {
    id: pruneListProc
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._applyPrune(text) }
  }

  function _pruneBackups() {
    pruneListProc.command = ["ls", "-1", root.backupsDir]
    pruneListProc.running = true
  }

  function _applyPrune(raw) {
    var names = String(raw || "").split("\n").filter(function(n) { return /^config\.\d+\.bak$/.test(n) })
    // Numeric sort on the embedded ms-epoch timestamp, not lexical --
    // fixed digit count for centuries so this is unambiguous either way,
    // but explicit numeric comparison costs nothing and documents intent.
    names.sort(function(a, b) { return Number(a.match(/\d+/)[0]) - Number(b.match(/\d+/)[0]) })
    if (names.length <= root._maxBackups) return
    var toDelete = names.slice(0, names.length - root._maxBackups).map(function(n) { return root.backupsDir + "/" + n })
    pruneRmProc.command = ["rm", "-f"].concat(toDelete)
    pruneRmProc.running = true
  }

  Process { id: pruneRmProc; command: [] }

  // One-time safety backup, idempotent via `cp -n` (no-clobber -- copies
  // only if the destination doesn't already exist). Run once at startup
  // rather than per-write: every real write happens after the popup is
  // interactive, which is always after Component.onCompleted has run.
  // Deliberately left untouched by the rolling backup above -- this
  // remains the one snapshot of "before this plugin ever touched
  // anything," never overwritten.
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
    bookmarksChmodProc.running = true
  }

  // ------------------------------------------------------------------ validation

  readonly property var _labelRe: /^[A-Za-z0-9._-]+$/
  readonly property var _hostRe: /^[A-Za-z0-9.:_-]+$/
  // Includes "@" (unlike _labelRe/_hostRe) -- a real Windows OpenSSH-for-
  // Windows account can legitimately be a UPN-style Microsoft-account
  // login (e.g. "j.m.thomas@comcast.net"), confirmed live: RedOak genuinely
  // runs "SSH-2.0-OpenSSH_for_Windows_9.5" (not just RDP), but its SSH
  // `User` field had no way to ever hold that login -- the field silently
  // stayed blank, and Browse (SFTP) then authenticated as this machine's
  // own local Linux username instead of prompting for the right one. `@`
  // is completely inert in ssh_config's `User` directive (a single
  // whitespace-delimited token, never shell-interpreted), so allowing it
  // adds no injection surface -- still no spaces/newlines, which would
  // actually break the directive's own single-line format.
  readonly property var _userRe: /^[A-Za-z0-9._@-]+$/
  // group/notes/icon are JSON-only -- never written into ~/.ssh/config
  // (see SshConfigBlockWriter.renderBlock, which only ever reads
  // id/label/hostname/port/user) -- so they don't need the strict
  // injection-safety allow-list above. Still validated for basic data
  // hygiene: no embedded newlines (breaks single-line Text rendering) and
  // a length cap against UI breakage.
  readonly property var _noNewlineRe: /[\r\n]/

  // Returns an error string to show inline in the form, or "" if fields
  // are valid. Checked against _sshConfigText (never a fresh disk read --
  // see the header comment on why that matters).
  function validateFields(fields, excludeId) {
    var label = String((fields && fields.label) || "").trim()
    var hostname = String((fields && fields.hostname) || "").trim()
    var user = String((fields && fields.user) || "").trim()
    var port = fields ? fields.port : undefined
    var group = String((fields && fields.group) || "").trim()
    var notes = String((fields && fields.notes) || "").trim()
    var icon = String((fields && fields.icon) || "").trim()

    if (!label) return "Label is required."
    if (!root._labelRe.test(label)) return "Label may only contain letters, digits, '.', '_', '-' (no spaces or wildcards)."
    if (!hostname) return "Host/IP is required."
    if (!root._hostRe.test(hostname)) return "Host/IP may only contain letters, digits, '.', ':', '_', '-'."
    if (user && !root._userRe.test(user)) return "User may only contain letters, digits, '.', '_', '@', '-'."
    if (port !== undefined && port !== null && port !== "") {
      var portNum = Number(port)
      if (!isFinite(portNum) || portNum < 1 || portNum > 65535) return "Port must be between 1 and 65535."
    }
    var rdpPort = fields ? fields.rdpPort : undefined
    if (rdpPort !== undefined && rdpPort !== null && rdpPort !== "") {
      var rdpPortNum = Number(rdpPort)
      if (!isFinite(rdpPortNum) || rdpPortNum < 1 || rdpPortNum > 65535) return "RDP Port must be between 1 and 65535."
    }
    // No _userRe check here, deliberately -- see _fieldsToBookmark's own
    // comment on why a real Windows account name (e.g. "Jordan Thomas")
    // needs a looser rule than the SSH `user` field. Same basic hygiene as
    // notes/group instead: no embedded newlines, length cap.
    var rdpUser = String((fields && fields.rdpUser) || "").trim()
    if (rdpUser && (root._noNewlineRe.test(rdpUser) || rdpUser.length > 200)) return "RDP User must be a single line, under 200 characters."
    // No charset restriction beyond this (unlike user/rdpUser) -- these
    // never get shell-interpreted (sshpass/xfreerdp3 are always invoked
    // via a plain argv array, never a shell string, so there's no
    // injection surface from special characters), only embedded newlines
    // would actually break anything (single-line UI rendering).
    var password = String((fields && fields.password) || "")
    if (password && (root._noNewlineRe.test(password) || password.length > 200)) return "Password must be a single line, under 200 characters."
    var rdpPassword = String((fields && fields.rdpPassword) || "")
    if (rdpPassword && (root._noNewlineRe.test(rdpPassword) || rdpPassword.length > 200)) return "RDP Password must be a single line, under 200 characters."
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
      group: String(fields.group || "").trim(),
      notes: String(fields.notes || "").trim(),
      icon: String(fields.icon || "").trim(),
      favorite: !!fields.favorite,
      protocol: (fields.protocol === "rdp" || fields.protocol === "vnc") ? fields.protocol : "ssh",
      rdpPort: String(fields.rdpPort || 3389),
      // .trim() only -- deliberately NOT run through _userRe (see
      // _normalizeBookmark's comment): a real Windows account name can
      // contain a space ("Jordan Thomas"), which _userRe's SSH-username
      // shape would reject.
      rdpUser: String(fields.rdpUser || "").trim(),
      // No .trim() -- see _normalizeBookmark's own comment.
      password: String(fields.password || ""),
      rdpPassword: String(fields.rdpPassword || "")
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

  // Favorite is JSON-only, like group/notes/icon -- never written into
  // ~/.ssh/config, so this deliberately doesn't touch _writeBookmarkBlock
  // at all (unlike updateBookmark, which always re-renders the block).
  function setFavorite(id, value) {
    var found = false
    root.bookmarks = root.bookmarks.map(function(b) {
      if (b.id !== id) return b
      found = true
      return Object.assign({}, b, { favorite: !!value })
    })
    if (found) root._scheduleSave()
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
