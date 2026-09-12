import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "SshConfigParser.js" as SshConfigParser
import "ThemeStatusColors.js" as ThemeStatusColors

// Bookmarks (see BookmarkStore.qml) mirror themselves into real ~/.ssh/config
// Host blocks, so once saved they flow through the exact same resolve/probe/
// connect pipeline below as any auto-discovered host -- the only additions
// here are a `source` tag for UI partitioning and, for a bookmark whose
// block was hand-deleted out from under the plugin, a synthesized row (see
// _onSshConfigChanged) since a vanished alias never reaches ssh -G at all.

// Uplink -- live reachability, uptime, and one-click terminal launch for
// every host in ~/.ssh/config.
//
// Two-stage probe per host, mirroring Linecast's "one-shot Process on a
// Timer" shape rather than Waveform's reactive-service pattern (there is no
// PipeWire-style live service here to bind to):
//   Stage A -- an SSH banner grab (`timeout N bash -c 'exec 3<>/dev/tcp/H/P
//     && dd bs=64 count=1 <&3'`), checking the response starts with "SSH-".
//     This alone drives the status dot's up/down axis. No auth attempted,
//     so it works identically regardless of the host's auth method --
//     confirmed live: a plain TCP connect (the original v1 design) can't
//     tell a real sshd apart from anything else listening on that port,
//     but more importantly, gating "up" on the uptime probe below (Stage B)
//     meant any host using password auth -- no passwordless key from this
//     machine -- showed amber forever, even though the user could connect
//     to it fine interactively via Connect. The banner is what an SSH
//     client itself relies on (RFC 4253: the server sends its
//     identification string immediately on connect, before any auth
//     happens), so checking for it is the accurate, auth-independent
//     signal for "yes, a real SSH server is answering here." `dd`, not
//     `head -c N`, is what actually reads it correctly -- see _runTcpProbe
//     for why (a server with a short banner that then waits for the
//     client's own, e.g. Forgejo's embedded Go SSH server, made `head -c
//     64` hang for the full probe timeout with zero output every time,
//     misreporting a live host as down).
//   Stage B -- a non-interactive `ssh -o BatchMode=yes ... uptime`, only
//     attempted once Stage A confirms a real SSH server and only while the
//     popup is open. Purely a bonus now -- its result populates the uptime
//     text when this machine has passwordless key access, but no longer
//     gates the status color; BatchMode=yes still keeps it from ever
//     hanging on a password prompt, it just fails fast and quietly instead
//     of dragging the whole host down to a permanent "can't confirm" state.
// `ssh` and `bash`/`timeout` are trusted system binaries invoked directly
// via Process, exactly like Waveform calls `pw-cli` directly -- unlike
// Linecast's ptyrun.py, no verification wrapper is needed here.
BarWidget {
  id: root
  moduleName: "jmthomas00.uplink"

  readonly property string home: Quickshell.env("HOME")

  // ------------------------------------------------------------------ hosts
  //
  // { alias, hostname, port, user, status, uptime, lastCheckedAt }
  // status: "checking" | "up" | "down"
  //   checking -- not yet probed this session / probe in flight
  //   up       -- Stage A confirmed a real SSH banner -- independent of
  //               auth method, so this is accurate for both key- and
  //               password-auth hosts. `uptime` is a separate bonus field
  //               (Stage B, popup-open only) that's populated when this
  //               machine has passwordless key access and left at "--"
  //               otherwise -- it no longer affects status/color.
  //   down     -- Stage A failed (timeout, refused, or something answered
  //               that wasn't a real SSH server)
  property var hosts: []
  property bool sawInclude: false

  BookmarkStore { id: bookmarkStore }
  SettingsStore { id: settingsStore }

  // Plain array + indexOf, not a JS Set -- matches this codebase's
  // established convention elsewhere (no Set/Map usage in Waveform or
  // Linecast either), and sidesteps any doubt about how a Set instance
  // round-trips through a QML `property var`.
  readonly property var bookmarkLabels: bookmarkStore.bookmarks.map(function(b) { return b.label })

  // _onSshConfigChanged (below) tags each host's `source` at construction
  // time, but it's only ever CALLED in response to ~/.ssh/config itself
  // loading/changing -- it does not automatically re-run just because
  // bookmarkLabels changes afterward (an imperative function reading a
  // reactive property once is not the same as a declarative binding on
  // that property). On a fresh shell restart this is a real race, not
  // hypothetical: sshConfigFile and bookmarkStore's own bookmarksFile are
  // two independent async loads with no ordering guarantee -- if
  // sshConfigFile happens to finish first, every host (including actual
  // bookmarks) gets tagged "config" while bookmarkLabels is still empty,
  // and nothing was left to correct it afterward. Confirmed hitting this
  // live: a saved bookmark rendered correctly under Bookmarks (that
  // section reads bookmarkStore.bookmarks directly, unaffected) but ALSO
  // under "From ~/.ssh/config" (which filters root.hosts by the frozen,
  // wrong source tag) after a restart. This handler re-tags in place
  // whenever bookmarkLabels changes, independent of any config-file event.
  onBookmarkLabelsChanged: root._retagHostSources()

  function _retagHostSources() {
    root.hosts = root.hosts.map(function(h) {
      var source = root.bookmarkLabels.indexOf(h.alias) !== -1 ? "bookmark" : "config"
      if (h.source === source) return h
      return Object.assign({}, h, { source: source })
    })
  }

  readonly property bool anyHostDown: root.hosts.some(function(h) { return h.status === "down" })
  readonly property int downCount: root.hosts.filter(function(h) { return h.status === "down" }).length
  readonly property string tooltipText: {
    if (root.hosts.length === 0) return "Uplink"
    var up = root.hosts.filter(function(h) { return h.status === "up" }).length
    return up + "/" + root.hosts.length + " hosts up"
  }

  function _hostByAlias(alias) {
    for (var i = 0; i < root.hosts.length; i++)
      if (root.hosts[i].alias === alias) return root.hosts[i]
    return null
  }

  function _patchHost(alias, patch) {
    var found = false
    root.hosts = root.hosts.map(function(h) {
      if (h.alias !== alias) return h
      found = true
      return Object.assign({}, h, patch)
    })
    if (found) root._scheduleSave()
  }

  // ------------------------------------------------------------- ~/.ssh/config
  //
  // watchChanges: true is safe here (unlike colors.toml elsewhere in this
  // plugin, or a plugin's own state file per the documented Quickshell
  // hot-reload gotcha) -- ~/.ssh/config is a genuinely plain file with no
  // in-process IPC push mechanism, and it's outside this plugin's own
  // watched directory, so reloading it can never trigger a plugin-tree
  // hot-reload.
  readonly property string _sshConfigPath: root.home + "/.ssh/config"

  FileView {
    id: sshConfigFile
    path: root._sshConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root._onSshConfigChanged(text())
    onFileChanged: reload()
  }

  function _onSshConfigChanged(raw) {
    var parsed = SshConfigParser.parseHostAliases(raw)
    root.sawInclude = parsed.sawInclude
    var existingByAlias = {}
    for (var i = 0; i < root.hosts.length; i++) existingByAlias[root.hosts[i].alias] = root.hosts[i]
    // `source` is tagged HERE, at construction time, for every branch --
    // not left to a later _patchHost call. The reuse-existing branch below
    // returns a fresh object (via Object.assign) specifically so a
    // bookmark's source stays correct even when nothing else about it
    // changed this pass (e.g. its alias moved between bookmarked/plain, or
    // this is simply the first pass after bookmarkLabels itself changed).
    var next = parsed.aliases.map(function(alias) {
      var source = root.bookmarkLabels.indexOf(alias) !== -1 ? "bookmark" : "config"
      // configMissing is explicitly cleared here (not just left as-is): the
      // only place that ever sets it true is the synthesized-row loop
      // below, which only runs for aliases NOT in parsed.aliases. Reaching
      // this branch means the alias IS present, so any configMissing carried
      // over from a stale existingByAlias entry (e.g. a bookmark whose block
      // was just restored) must be cleared or the probe loops would keep
      // skipping it forever.
      if (existingByAlias[alias]) return Object.assign({}, existingByAlias[alias], { source: source, configMissing: false })
      var cached = root._cachedByAlias[alias]
      return {
        alias: alias,
        hostname: cached ? cached.hostname : "",
        port: cached ? cached.port : "22",
        user: cached ? cached.user : "",
        status: cached ? cached.status : "checking",
        uptime: cached ? cached.uptime : "",
        lastCheckedAt: cached ? cached.lastCheckedAt : 0,
        source: source
      }
    })
    // A bookmark whose Host block was removed by hand (bypassing the
    // plugin) never reaches ssh -G at all -- parseHostAliases only ever
    // emits an alias whose literal `Host <alias>` line still exists, so a
    // deleted block makes the alias vanish from `parsed.aliases` entirely
    // rather than resolve with an empty hostname. Detected here via a
    // direct diff against bookmarkStore's own list instead. `configMissing`
    // marks the row so the periodic probe loops (which would otherwise
    // happily TCP/uptime-probe the bookmark's raw fields and silently
    // overwrite this status) skip it until the block is restored.
    var presentAliases = {}
    for (var k = 0; k < parsed.aliases.length; k++) presentAliases[parsed.aliases[k]] = true
    var bookmarks = bookmarkStore.bookmarks
    for (var b = 0; b < bookmarks.length; b++) {
      var bm = bookmarks[b]
      if (presentAliases[bm.label]) continue
      next.push({
        alias: bm.label,
        hostname: bm.hostname,
        port: bm.port,
        user: bm.user,
        status: "down",
        uptime: "config entry missing — edit to restore",
        lastCheckedAt: Date.now(),
        source: "bookmark",
        configMissing: true
      })
    }
    root.hosts = next
    for (var j = 0; j < parsed.aliases.length; j++) root._resolveAlias(parsed.aliases[j])
  }

  // Resolves an alias's real hostname/port/user via `ssh -G <alias>` --
  // ssh's own fully-resolved config, so Include/Match/defaults apply for
  // free without this plugin reimplementing ssh's config semantics.
  Component {
    id: resolveProcComponent
    Process {
      id: proc
      property string hostAlias: ""
      property string capturedText: ""
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: proc.capturedText = text
      }
      onExited: function(exitCode, exitStatus) {
        root._applyResolvedHost(proc.hostAlias, proc.capturedText)
        proc.destroy()
      }
    }
  }

  function _resolveAlias(alias) {
    var proc = resolveProcComponent.createObject(root, { command: ["ssh", "-G", alias], hostAlias: alias })
    proc.running = true
  }

  function _applyResolvedHost(alias, raw) {
    var resolved = SshConfigParser.parseResolvedConfig(raw)
    if (!resolved.hostname) return
    root._patchHost(alias, { hostname: resolved.hostname, port: resolved.port, user: resolved.user })
    // Kick an immediate first check as soon as a host resolves, rather than
    // waiting for the next timer tick -- also picks up Stage B right away
    // if the popup happens to already be open.
    root._runTcpProbe(alias, root.opened)
  }

  // ------------------------------------------------------------------ probing

  // Captures stdout too (not just exit code) -- the banner grab needs the
  // actual bytes returned to confirm they look like "SSH-...", not just
  // that the connect succeeded.
  Component {
    id: bannerProbeComponent
    Process {
      id: proc
      property string hostAlias: ""
      property bool alsoUptime: false
      property string capturedText: ""
      // Set at createObject() time (see _runTcpProbe) -- onExited is baked
      // into this Component template itself, so it can't close over a
      // local variable from the calling function the way a fresh closure
      // could; it can only read properties living on the proc instance,
      // exactly like hostAlias/capturedText/alsoUptime already do.
      property double startedAtMs: 0
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: proc.capturedText = text
      }
      onExited: function(exitCode, exitStatus) {
        root._applyBannerResult(proc.hostAlias, exitCode, proc.capturedText, proc.alsoUptime, Date.now() - proc.startedAtMs)
        proc.destroy()
      }
    }
  }

  function _runTcpProbe(alias, alsoUptime) {
    var host = root._hostByAlias(alias)
    if (!host || !host.hostname) return
    // `&&` means dd only ever runs once the TCP connect itself succeeds --
    // a refused/timed-out connect leaves bash exiting non-zero with no
    // output, never reaching dd. `dd bs=64 count=1` (NOT `head -c 64`) is
    // deliberate: dd's default (no iflag=fullblock) does exactly one read()
    // syscall and returns whatever it got, while `head -c N` keeps reading
    // until it has accumulated the full N bytes or hits EOF -- confirmed
    // live this is a real distinction, not a style choice: a short banner
    // ("SSH-2.0-Go\r\n", 12 bytes, from a Forgejo instance's embedded Go SSH
    // server) sends its identification string once and then waits for the
    // client's own, so `head -c 64` never got its requested 64 bytes and
    // hung until the outer `timeout 3` killed it with zero output every
    // time -- misreporting a live, reachable SSH server as down. `dd`
    // returns as soon as that single initial packet arrives (confirmed:
    // both the 12-byte Forgejo banner and OpenSSH's ~40-byte one return in
    // well under 100ms), which is also the behaviorally correct read here:
    // a real sshd sends its identification string immediately per RFC 4253
    // and nothing else until the client replies, so one read is *all*
    // there ever is to get non-interactively -- `timeout 3` still bounds
    // the whole thing generously for a slow LAN hop.
    var cmd = ["timeout", "3", "bash", "-c",
      "exec 3<>/dev/tcp/" + host.hostname + "/" + host.port + " && dd bs=64 count=1 <&3 2>/dev/null"]
    var proc = bannerProbeComponent.createObject(root, { command: cmd, hostAlias: alias, alsoUptime: alsoUptime, startedAtMs: Date.now() })
    proc.running = true
  }

  function _applyBannerResult(alias, exitCode, raw, alsoUptime, elapsedMs) {
    var now = Date.now()
    var confirmed = exitCode === 0 && String(raw || "").indexOf("SSH-") === 0
    if (!confirmed) {
      // latencyMs explicitly cleared here (not left as-is) so a stale
      // last-known value can't linger and be read by anything that
      // doesn't also gate on status === "up".
      root._patchHost(alias, { status: "down", lastCheckedAt: now, latencyMs: null })
      return
    }
    root._patchHost(alias, { status: "up", lastCheckedAt: now, latencyMs: elapsedMs })
    if (alsoUptime) root._probeUptime(alias)
  }

  Component {
    id: uptimeProcComponent
    Process {
      id: proc
      property string hostAlias: ""
      property string capturedText: ""
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: proc.capturedText = text
      }
      onExited: function(exitCode, exitStatus) {
        root._applyUptimeResult(proc.hostAlias, exitCode, proc.capturedText)
        proc.destroy()
      }
    }
  }

  function _probeUptime(alias) {
    var host = root._hostByAlias(alias)
    if (!host) return
    // Connects via the ssh CONFIG ALIAS, not a reconstructed user@hostname
    // -p port -- deliberately, and not just for tidiness. A reconstructed
    // target bypasses `~/.ssh/config`'s per-Host directives entirely,
    // `IdentityFile` above all: confirmed live against a real host using a
    // dedicated (non-default-named) key that the alias resolves correctly
    // but a raw `user@ip -p port` connection doesn't, so this probe was
    // silently failing to authenticate for any host set up with its own
    // key file -- exactly the standard setup for a git-mirror-style host
    // (see the vault's own onboarding playbook), not an edge case. Using
    // the alias here matches connectToHost's own `ssh <alias>` exactly, so
    // "can this probe authenticate" and "can Connect authenticate" are now
    // answering the literal same question instead of two different ones.
    var cmd = [
      "timeout", "6", "ssh",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=4",
      "-o", "StrictHostKeyChecking=accept-new",
      alias, "uptime"
    ]
    var proc = uptimeProcComponent.createObject(root, { command: cmd, hostAlias: alias })
    proc.running = true
  }

  function _applyUptimeResult(alias, exitCode, raw) {
    // Purely a bonus at this point -- status is already "up" from the
    // banner check by the time this runs (Stage B is only ever kicked off
    // from _applyBannerResult after `confirmed` is true), so a failure here
    // (most commonly: this machine has no passwordless key for the host,
    // confirmed live against a password-auth-only Raspberry Pi -- exit 255,
    // "Permission denied (publickey,password)") just means no uptime text,
    // never a status change. Leaves any previously-obtained uptime text
    // alone on failure rather than clearing it back to "--", so a transient
    // hiccup doesn't regress a value that was already showing correctly.
    if (exitCode === 0) {
      root._patchHost(alias, { uptime: String(raw || "").trim(), lastCheckedAt: Date.now() })
    }
  }

  function _probeAllStageA() {
    for (var i = 0; i < root.hosts.length; i++) {
      var h = root.hosts[i]
      if (h.hostname && !h.configMissing) root._runTcpProbe(h.alias, false)
    }
  }

  function _probeAllFull() {
    for (var i = 0; i < root.hosts.length; i++) {
      var h = root.hosts[i]
      if (h.hostname && !h.configMissing) root._runTcpProbe(h.alias, true)
    }
  }

  // Background: cheap Stage-A-only sweep, always running -- drives
  // anyHostDown/the bar icon even while the popup has never been opened.
  // Interval is settings-driven; don't rely on the reactive `interval:`
  // binding alone to apply a change mid-countdown deterministically (Qt's
  // own Timer semantics for that case aren't established anywhere in this
  // codebase) -- the explicit `Connections` block below restarts both
  // timers immediately whenever the setting actually changes.
  Timer {
    id: stageATimer
    interval: settingsStore.probeIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root._probeAllStageA()
  }

  // Popup-open: full Stage A + Stage B sweep -- mirrors Waveform's
  // `running: root.opened` split for its own more expensive theme poll.
  Timer {
    id: fullSweepTimer
    interval: settingsStore.popupProbeIntervalSec * 1000
    running: root.opened
    repeat: true
    onTriggered: root._probeAllFull()
  }

  Connections {
    target: settingsStore
    function onProbeIntervalSecChanged() { stageATimer.restart() }
    function onPopupProbeIntervalSecChanged() { fullSweepTimer.restart() }
  }

  // ------------------------------------------------------ connected indicator
  //
  // One `pgrep` total per tick, not one per host -- a per-host `pgrep -f
  // "ssh <alias>"` has two real problems once the pattern is dynamic
  // (alias) rather than ScreenRecording.qml's own fixed single-target
  // precedent: (1) the label charset permits "." (a live regex
  // metacharacter) unescaped, and (2) `-f` does unanchored substring
  // search, so e.g. a bookmark "db" would cross-match inside "db-replica"'s
  // cmdline -- not hypothetical, a direct consequence of -f's matching
  // semantics. Fixed by asking for every real `ssh ...` process ONCE via
  // `pgrep -af '^ssh '` (anchored so it can't also match ssh-agent/
  // ssh-add/sshd/sshfs, whose cmdlines don't start with "ssh " followed by
  // a space), then doing an EXACT argv-token comparison in JS -- no regex
  // built from user input at all, and "db" can never match inside
  // "db-replica" since token equality isn't substring containment. This
  // also keeps the popup-open tick's process-spawn cost flat (1 process)
  // regardless of host count, instead of stacking a 4th per-host probe on
  // top of the existing banner+uptime ones already running on this cadence.
  Component {
    id: connectedPollProcComponent
    Process {
      id: proc
      property string capturedText: ""
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: proc.capturedText = text
      }
      onExited: function(exitCode, exitStatus) {
        root._applyConnectedPoll(proc.capturedText)
        proc.destroy()
      }
    }
  }

  function _pollConnected() {
    var proc = connectedPollProcComponent.createObject(root, { command: ["pgrep", "-af", "^ssh "] })
    proc.running = true
  }

  function _applyConnectedPoll(raw) {
    var lines = String(raw || "").split("\n")
    // Plain array + indexOf, not a Set -- matches this codebase's
    // established convention (see bookmarkLabels above).
    var connectedAliases = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      // pgrep -a prefixes each line with "<pid> "; drop that, then
      // tokenize the remaining cmdline on whitespace for exact-token
      // comparison against each host's alias.
      var spaceIdx = line.indexOf(" ")
      if (spaceIdx === -1) continue
      var tokens = line.slice(spaceIdx + 1).split(/\s+/)
      for (var t = 0; t < tokens.length; t++) {
        if (connectedAliases.indexOf(tokens[t]) === -1) connectedAliases.push(tokens[t])
      }
    }
    root.hosts = root.hosts.map(function(h) {
      var connected = connectedAliases.indexOf(h.alias) !== -1
      if (h.connected === connected) return h
      return Object.assign({}, h, { connected: connected })
    })
  }

  Timer {
    id: connectedPollTimer
    interval: settingsStore.popupProbeIntervalSec * 1000
    running: root.opened
    repeat: true
    onTriggered: root._pollConnected()
  }

  Connections {
    target: settingsStore
    function onPopupProbeIntervalSecChanged() { connectedPollTimer.restart() }
  }

  // -------------------------------------------------------------- Wake-on-LAN
  //
  // Mirrors Waveform's own optional-dependency pattern (_checkDependencies,
  // lspEqAvailable/cavaAvailable) rather than hand-rolling a magic-packet
  // sender -- checked via a single REUSED static Process guarded by
  // `!wakeonlanCheckProc.running`, not the per-host createObject() pattern
  // the probes above use, since this is one fixed check, not an N-host one.
  property bool wakeonlanAvailable: true

  Process {
    id: wakeonlanCheckProc
    command: []
    onExited: function(exitCode) { root.wakeonlanAvailable = exitCode === 0 }
  }

  function _checkWakeonlan() {
    if (wakeonlanCheckProc.running) return
    wakeonlanCheckProc.command = ["which", "wakeonlan"]
    wakeonlanCheckProc.running = true
  }

  Component { id: wakeProcComponent; Process {} }

  function wakeHost(mac) {
    if (!mac) return
    var proc = wakeProcComponent.createObject(root, { command: ["wakeonlan", mac] })
    proc.exited.connect(function() { proc.destroy() })
    proc.running = true
  }

  // ------------------------------------------------------- Browse (SFTP)
  //
  // Same optional-dependency shape as Wake-on-LAN above. `xdg-open
  // sftp://...` has no registered handler on this system (confirmed:
  // `gio mime x-scheme-handler/sftp` -> "No default applications") --
  // launching nautilus directly with the URI works regardless of that
  // missing MIME registration (confirmed live against a real host), so
  // that's what this checks for and calls, not a generic default-app
  // lookup.
  property bool fileManagerAvailable: true

  Process {
    id: fileManagerCheckProc
    command: []
    onExited: function(exitCode) { root.fileManagerAvailable = exitCode === 0 }
  }

  function _checkFileManager() {
    if (fileManagerCheckProc.running) return
    fileManagerCheckProc.command = ["which", "nautilus"]
    fileManagerCheckProc.running = true
  }

  Component { id: fileManagerProcComponent; Process {} }

  function openFileManager(uri) {
    if (!uri) return
    var proc = fileManagerProcComponent.createObject(root, { command: ["nautilus", uri] })
    proc.exited.connect(function() { proc.destroy() })
    proc.running = true
  }

  // ------------------------------------------------------- state/cache
  //
  // Deliberately outside ~/.config/omarchy/plugins/uplink/ (this
  // plugin's own watched source directory) -- see the documented Quickshell
  // gotcha: a debounced state write landing inside a watched plugin tree
  // fires "local plugin changed, reloading," which has previously torn down
  // and orphaned in-flight async work in Waveform. ~/.local/state/ is a
  // sibling location, structurally impossible to trigger that watcher.
  // Mirrors Waveform's ChannelManager.qml stateFile/saveTimer/mkdirProc trio.
  readonly property string stateDir: root.home + "/.local/state/uplink"
  readonly property string statePath: root.stateDir + "/status-cache.json"
  property bool cacheLoaded: false
  property var _cachedByAlias: ({})

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root._applyCachedState(text())
    onLoadFailed: root._applyCachedState("")
  }

  function _applyCachedState(raw) {
    if (root.cacheLoaded) return
    root.cacheLoaded = true
    try {
      var doc = JSON.parse(raw || "{}")
      root._cachedByAlias = doc.hosts || {}
    } catch (e) {
      root._cachedByAlias = {}
    }
    // Covers the case ~/.ssh/config already finished loading before the
    // cache did -- backfill any host currently stuck at "checking" with its
    // last-known status instead of waiting for the next probe tick.
    if (root.hosts.length > 0) {
      root.hosts = root.hosts.map(function(h) {
        if (h.status !== "checking" || !root._cachedByAlias[h.alias]) return h
        return Object.assign({}, h, root._cachedByAlias[h.alias])
      })
    }
  }

  Timer {
    id: saveTimer
    interval: 500
    repeat: false
    onTriggered: root._saveCache()
  }

  function _scheduleSave() {
    if (!root.cacheLoaded) return
    saveTimer.restart()
  }

  function _saveCache() {
    var doc = { hosts: {} }
    for (var i = 0; i < root.hosts.length; i++) {
      var h = root.hosts[i]
      doc.hosts[h.alias] = { hostname: h.hostname, port: h.port, user: h.user, status: h.status, uptime: h.uptime, lastCheckedAt: h.lastCheckedAt }
    }
    stateFile.setText(JSON.stringify(doc))
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
  }

  Component.onCompleted: { mkdirProc.running = true; root._checkWakeonlan(); root._checkFileManager() }

  // --------------------------------------------------------------- theming
  //
  // Same discipline as Waveform's own theme read: NOT watchChanges: true
  // (confirmed elsewhere in this codebase that `omarchy theme set` pushes
  // theme data via in-process IPC straight into the already-running shell,
  // never rewriting colors.toml in a way a watched FileView usefully reacts
  // to) -- reload on a natural checkpoint (popup open) instead.
  readonly property string _themeColorsPath: root.home + "/.local/state/omarchy/current/theme/colors.toml"
  property var _statusColorsHex: ({})

  FileView {
    id: themeColorsFile
    path: root._themeColorsPath
    watchChanges: false
    printErrors: false
    onLoaded: root._statusColorsHex = ThemeStatusColors.statusColors(text())
  }

  function colorForStatus(status) {
    var hex = root._statusColorsHex[status]
    if (hex) return Qt.color(hex)
    if (status === "up") return Color.accent
    if (status === "down") return Color.urgent
    // Covers "checking" and any leftover "degraded" value from a
    // status-cache.json written before that state was retired -- a fresh
    // probe corrects it within one tick either way.
    return Color.muted
  }

  onOpenedChanged: if (root.opened) { themeColorsFile.reload(); root._probeAllFull(); root._pollConnected(); root._checkWakeonlan(); root._checkFileManager() }

  // ---------------------------------------------------------- terminal launch
  //
  // Routed through omarchy-launch-terminal (the same binary `omarchy launch
  // terminal` uses) rather than hardcoding a specific emulator -- it already
  // resolves whatever terminal the user has actually configured via
  // xdg-terminal-exec. Uses the alias, not the resolved hostname, so the
  // real terminal session re-applies the user's full ~/.ssh/config entry
  // (IdentityFile, IdentitiesOnly, etc.) exactly as a manual `ssh <alias>`
  // would -- this plugin's own probes never need to duplicate those options.
  Component { id: launchProcComponent; Process {} }

  function connectToHost(alias) {
    var proc = launchProcComponent.createObject(root, {
      command: ["/usr/share/omarchy/bin/omarchy-launch-terminal", "ssh", alias]
    })
    proc.exited.connect(function() { proc.destroy() })
    proc.running = true
  }

  // ------------------------------------------------------------- panel/bar

  function openPanel() { panel.open = true }
  function closePanel() { panel.open = false }
  function togglePanel() { panel.open ? closePanel() : openPanel() }

  // Bar-widget contract for hotkey/summon routing (Bar.findPanelWidget wants
  // open/close/opened on the bar-widget root) -- same contract Waveform and
  // Linecast both implement.
  readonly property bool opened: panel.open
  function open() { openPanel() }
  function close() { closePanel() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd Font Font Awesome "server" glyph (nf-fa-server, U+F233).
    text: ""
    fontSize: Style.font.body
    horizontalMargin: 8
    tooltipText: root.tooltipText
    active: root.anyHostDown
    useActiveColor: true
    onPressed: root.togglePanel()

    // No badge-count precedent exists anywhere in this shell (built-in
    // widgets are boolean visible/hidden, never a rendered count) --
    // original UI, not a reused component. WidgetButton itself has no
    // clip: true, so this isn't self-clipped, but whether the bar's own
    // widget-slot container clips isn't confirmed from reading QML alone
    // -- verified visually via screenshot during implementation.
    Rectangle {
      id: downBadge
      visible: root.downCount > 0
      width: Math.max(Style.space(12), badgeText.implicitWidth + Style.space(4))
      height: Style.space(12)
      radius: height / 2
      color: root.colorForStatus("down")
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: -Style.space(2)
      anchors.topMargin: -Style.space(2)

      Text {
        id: badgeText
        anchors.centerIn: parent
        text: String(root.downCount)
        color: Color.background
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  IpcHandler {
    target: "jmthomas00.uplink"

    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function toggle(): void { root.togglePanel() }
  }

  // Which bar section (left/center/right) this widget's own icon currently
  // sits in -- copied verbatim from Waveform/Linecast's identical fix for
  // "popup always centers regardless of bar position."
  function _currentBarSection() {
    var layout = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    if (!layout) return "center"
    var sections = ["left", "center", "right"]
    for (var i = 0; i < sections.length; i++) {
      var list = layout[sections[i]]
      if (!Array.isArray(list)) continue
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].id === root.moduleName) return sections[i]
      }
    }
    return "center"
  }
  readonly property string barSection: root._currentBarSection()

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    centerOnBar: root.barSection === "center"
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(
      contentLoader.item ? contentLoader.item.implicitHeight : Style.space(120),
      Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the bookmark add/edit form is open, its own TextField/
      // NumberField instances own keyboard input (Enter submits, Escape
      // cancels, wired in BookmarkForm.qml) -- this must NOT also try to
      // interpret those same keys as list navigation. Mirrors the built-in
      // Wi-Fi passphrase panel's own shipped pattern (a plain state flag),
      // not the "activeFocus" approach PanelKeyCatcher.qml's own header
      // comment suggests as an example.
      blocked: contentLoader.item ? contentLoader.item.formOpen : false
      onCloseRequested: root.closePanel()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // The popup's own height caps at Style.space(560) (see contentHeight
      // above) or the screen's available space, whichever is smaller --
      // but the Bookmarks/config content below has no upper bound of its
      // own (more bookmarks, more groups, the inline edit form, ssh config
      // hosts). Without this Flickable, content taller than that cap just
      // rendered straight past the card's border with nothing to clip or
      // scroll it (reported live: editing a bookmark into a new group,
      // with the form's validation error showing, pushed the "From
      // ~/.ssh/config" section and even the form's own Save/Cancel row
      // below the visible card). Keys.priority: Keys.BeforeItem on the
      // PanelKeyCatcher above (see its own header comment) means this
      // Flickable's drag/wheel scrolling can't steal j/k/arrow list
      // navigation from it either.
      Flickable {
        id: contentFlick
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: contentLoader.item ? contentLoader.item.implicitHeight : 0
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Loader {
          id: contentLoader
          width: parent.width
          sourceComponent: hostListComponent
        }
      }

      Component {
        id: hostListComponent
        HostList {
          bar: root.bar
          hosts: root.hosts
          bookmarkStoreRef: bookmarkStore
          settingsStoreRef: settingsStore
          sawInclude: root.sawInclude
          statusColorFor: root.colorForStatus
          wakeonlanAvailable: root.wakeonlanAvailable
          fileManagerAvailable: root.fileManagerAvailable
          onConnectRequested: function(alias) { root.connectToHost(alias) }
          onWakeRequested: function(mac) { root.wakeHost(mac) }
          onBrowseRequested: function(uri) { root.openFileManager(uri) }
        }
      }
    }
  }
}
