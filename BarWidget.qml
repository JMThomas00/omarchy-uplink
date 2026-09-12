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

// Uplink -- live reachability and one-click terminal launch for every host
// in ~/.ssh/config.
//
// One-shot Process on a Timer per host, mirroring Linecast's own shape
// rather than Waveform's reactive-service pattern (there is no
// PipeWire-style live service here to bind to): an SSH banner grab
// (`timeout N bash -c 'exec 3<>/dev/tcp/H/P && dd bs=64 count=1 <&3'`),
// checking the response starts with "SSH-". No auth attempted, so it works
// identically regardless of the host's auth method -- confirmed live: a
// plain TCP connect (the original v1 design) can't tell a real sshd apart
// from anything else listening on that port. The banner is what an SSH
// client itself relies on (RFC 4253: the server sends its identification
// string immediately on connect, before any auth happens), so checking for
// it is the accurate, auth-independent signal for "yes, a real SSH server
// is answering here." `dd`, not `head -c N`, is what actually reads it
// correctly -- see _runTcpProbe for why (a server with a short banner that
// then waits for the client's own, e.g. Forgejo's embedded Go SSH server,
// made `head -c 64` hang for the full probe timeout with zero output every
// time, misreporting a live host as down).
//
// A second stage (a non-interactive `ssh -o BatchMode=yes ... uptime`, a
// purely cosmetic uptime bonus for hosts with passwordless key access)
// existed here through v2.4.x -- removed once the uptime display itself
// was removed from HostRow.qml, since a background probe running purely
// to compute a value nothing shows anymore was pure waste (one extra `ssh`
// process spawned per host, every popup-open probe tick, for zero
// observable benefit).
// `ssh` and `bash`/`timeout` are trusted system binaries invoked directly
// via Process, exactly like Waveform calls `pw-cli` directly -- unlike
// Linecast's ptyrun.py, no verification wrapper is needed here.
BarWidget {
  id: root
  moduleName: "jmthomas00.uplink"

  readonly property string home: Quickshell.env("HOME")

  // ------------------------------------------------------------------ hosts
  //
  // { alias, hostname, port, user, status, lastCheckedAt }
  // status: "checking" | "up" | "down"
  //   checking -- not yet probed this session / probe in flight
  //   up       -- the banner probe confirmed a real SSH server -- independent
  //               of auth method, so this is accurate for both key- and
  //               password-auth hosts.
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
  onBookmarkLabelsChanged: { root._retagHostSources(); root._syncMissingBookmarkRows() }

  function _retagHostSources() {
    root.hosts = root.hosts.map(function(h) {
      var source = root.bookmarkLabels.indexOf(h.alias) !== -1 ? "bookmark" : "config"
      if (h.source === source) return h
      return Object.assign({}, h, { source: source })
    })
  }

  // Same race class as _retagHostSources above, for the OTHER half of
  // _onSshConfigChanged's job: that function's configMissing-synthesis loop
  // (a bookmark whose Host block was hand-deleted, so its alias never
  // reaches ssh -G at all) only ever runs in reaction to a ~/.ssh/config
  // file event. If bookmarkStore.bookmarks finishes loading AFTER
  // sshConfigFile's own first onLoaded, a bookmark whose block was ALREADY
  // missing before this session even started never gets its one
  // synthesized row -- it's simply absent from root.hosts, so it shows
  // "checking" forever (never probed, since _probeAll only iterates
  // root.hosts) instead of the intended "config entry missing" warning,
  // until some UNRELATED future ~/.ssh/config edit happens to re-trigger
  // _onSshConfigChanged. Guarded on root.hosts.length > 0 (mirrors
  // _applyCachedState's own identical guard) -- if ~/.ssh/config hasn't
  // loaded at all yet, _onSshConfigChanged is still to come and will
  // compute the correct state for every bookmark itself; running this
  // first would incorrectly flag every bookmark as configMissing for one
  // frame.
  function _syncMissingBookmarkRows() {
    if (root.hosts.length === 0) return
    var existingAliases = {}
    for (var i = 0; i < root.hosts.length; i++) existingAliases[root.hosts[i].alias] = true
    var additions = []
    var bookmarks = bookmarkStore.bookmarks
    for (var b = 0; b < bookmarks.length; b++) {
      var bm = bookmarks[b]
      if (existingAliases[bm.label]) continue
      additions.push({
        alias: bm.label,
        hostname: bm.hostname,
        port: bm.port,
        user: bm.user,
        status: "down",
        lastCheckedAt: Date.now(),
        source: "bookmark",
        configMissing: true
      })
    }
    if (additions.length > 0) root.hosts = root.hosts.concat(additions)
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
    // happily TCP-probe the bookmark's raw fields and silently
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
    // Kick an immediate first check as soon as a host resolves, rather
    // than waiting for the next timer tick.
    root._runTcpProbe(alias)
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
      property string capturedText: ""
      // Set at createObject() time (see _runTcpProbe) -- onExited is baked
      // into this Component template itself, so it can't close over a
      // local variable from the calling function the way a fresh closure
      // could; it can only read properties living on the proc instance,
      // exactly like hostAlias/capturedText already do.
      property double startedAtMs: 0
      // True for a bookmark whose primary protocol is RDP, not SSH -- see
      // _runTcpProbe's own comment on why this changes both the command
      // AND what counts as "confirmed" below.
      property bool isRdpProbe: false
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: proc.capturedText = text
      }
      onExited: function(exitCode, exitStatus) {
        root._applyBannerResult(proc.hostAlias, exitCode, proc.capturedText, proc.isRdpProbe, Date.now() - proc.startedAtMs)
        proc.destroy()
      }
    }
  }

  function _runTcpProbe(alias) {
    var host = root._hostByAlias(alias)
    if (!host || !host.hostname) return
    // A bookmark whose primary protocol is RDP needs a different probe
    // entirely -- reported live: Sequoia (an RDP-only Windows box, no
    // SSH server at all) stayed permanently red despite RDP working fine
    // and ping succeeding, because this probe always tested the SSH port
    // for an "SSH-" banner regardless of which protocol the bookmark
    // actually uses. `host.port` here is still always the SSH port (the
    // ~/.ssh/config block is written unconditionally regardless of
    // protocol, so Connect/Browse keep working either way) -- only the
    // STATUS PROBE itself needs to target rdpPort instead for these.
    var bookmark = bookmarkStore.bookmarks.filter(function(b) { return b.label === alias })[0]
    var isRdpPrimary = !!(bookmark && bookmark.protocol === "rdp")
    var cmd
    if (isRdpPrimary) {
      // RDP speaks a binary negotiation, not a readable text identification
      // string the way SSH's "SSH-2.0-..." banner is -- parsing a real RDP
      // handshake response just to confirm "is this actually RDP" would be
      // real complexity for a status dot. A plain TCP-connect-succeeds
      // check is the same simplification this file's own header comment
      // describes as the ORIGINAL v1 design for SSH, before that was
      // refined specifically to distinguish a real sshd from any other
      // listener -- accepted here since something else squatting on the
      // RDP-specific port is a much rarer false positive in practice than
      // on a commonly-multiplexed port like SSH's.
      var rdpPort = (bookmark.rdpPort || "3389")
      cmd = ["timeout", "3", "bash", "-c", "echo > /dev/tcp/" + host.hostname + "/" + rdpPort]
    } else {
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
      cmd = ["timeout", "3", "bash", "-c",
        "exec 3<>/dev/tcp/" + host.hostname + "/" + host.port + " && dd bs=64 count=1 <&3 2>/dev/null"]
    }
    var proc = bannerProbeComponent.createObject(root, { command: cmd, hostAlias: alias, startedAtMs: Date.now(), isRdpProbe: isRdpPrimary })
    proc.running = true
  }

  function _applyBannerResult(alias, exitCode, raw, isRdpProbe, elapsedMs) {
    var now = Date.now()
    // An RDP probe only ever checked "did the TCP connect succeed" (no
    // banner to inspect) -- exit code alone is the full signal there.
    var confirmed = isRdpProbe ? (exitCode === 0) : (exitCode === 0 && String(raw || "").indexOf("SSH-") === 0)
    // Captured BEFORE _patchHost mutates root.hosts below -- _hostByAlias
    // reads root.hosts, so this MUST run first or it'd see the just-applied
    // new status instead of the real previous one.
    var prevHost = root._hostByAlias(alias)
    var prevStatus = prevHost ? prevHost.status : "checking"
    var newStatus = confirmed ? "up" : "down"
    if (!confirmed) {
      // latencyMs explicitly cleared here (not left as-is) so a stale
      // last-known value can't linger and be read by anything that
      // doesn't also gate on status === "up".
      root._patchHost(alias, { status: "down", lastCheckedAt: now, latencyMs: null })
    } else {
      root._patchHost(alias, { status: "up", lastCheckedAt: now, latencyMs: elapsedMs })
    }
    root._maybeNotifyStatusChange(alias, prevStatus, newStatus)
  }

  // No early return above (unlike the original shape this replaced) --
  // deliberately restructured so this always runs regardless of which
  // branch fired; the earlier version's `if (!confirmed) { ...; return }`
  // would have made a down-transition notification unreachable dead code
  // if appended naively after it.
  function _maybeNotifyStatusChange(alias, prevStatus, newStatus) {
    if (!settingsStore.notifyStatusChanges) return
    // Suppresses a notification burst when every host does its first-ever
    // classification (shell/plugin startup) -- only a REAL transition
    // between two already-known states counts.
    if (prevStatus !== "up" && prevStatus !== "down") return
    if (prevStatus === newStatus) return
    var omarchyPath = Quickshell.env("OMARCHY_PATH")
    if (newStatus === "down") {
      Quickshell.execDetached([omarchyPath + "/bin/omarchy-notification-send", "-u", "critical", "--app-name", "Uplink", alias + " is down", "SSH host became unreachable"])
    } else {
      Quickshell.execDetached([omarchyPath + "/bin/omarchy-notification-send", "-u", "normal", "--app-name", "Uplink", alias + " is back up", "SSH host is reachable again"])
    }
  }

  function _probeAll() {
    for (var i = 0; i < root.hosts.length; i++) {
      var h = root.hosts[i]
      if (h.hostname && !h.configMissing) root._runTcpProbe(h.alias)
    }
  }

  // Background: cheap sweep, always running -- drives anyHostDown/the bar
  // icon even while the popup has never been opened. Interval is
  // settings-driven; don't rely on the reactive `interval:` binding alone to
  // apply a change mid-countdown deterministically (Qt's own Timer semantics
  // for that case aren't established anywhere in this codebase) -- the
  // explicit `Connections` block below restarts both timers immediately
  // whenever the setting actually changes.
  Timer {
    id: backgroundProbeTimer
    interval: settingsStore.probeIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root._probeAll()
  }

  // Popup-open: same sweep, just on a tighter cadence -- mirrors Waveform's
  // `running: root.opened` split for its own more expensive theme poll.
  Timer {
    id: fullSweepTimer
    interval: settingsStore.popupProbeIntervalSec * 1000
    running: root.opened
    repeat: true
    onTriggered: root._probeAll()
  }

  Connections {
    target: settingsStore
    function onProbeIntervalSecChanged() { backgroundProbeTimer.restart() }
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
  // regardless of host count, instead of stacking a 3rd per-host probe on
  // top of the existing banner one already running on this cadence.
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
      // This plugin's OWN _resolveAlias also spawns something starting with
      // "ssh ": `ssh -G <alias>`. That would otherwise false-positive this
      // host as "connected" whenever a pgrep snapshot lands mid-probe --
      // confirmed this is the actual root cause of the previously-unresolved
      // "wrong host shows connected" artifact, not a rendering fluke. `-G`
      // is unique to that call; connectToHost's own `omarchy-launch-terminal
      // ssh <alias>` has neither, so a real interactive session is
      // unaffected. Accepted limitation: a bookmark literally labeled "-G"
      // would be wrongly excluded here too -- pathological, not worth
      // defending against.
      if (tokens.indexOf("-G") !== -1) continue
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

  // --------------------------------------------------------------- sshpass
  //
  // Same optional-dependency shape as Wake-on-LAN/Browse. A stored SSH
  // password (2026-09-12) is fed to `ssh` non-interactively via `sshpass`
  // -- plain `ssh` has no CLI flag for a password at all (deliberately, by
  // design). Without sshpass installed, connectToHost falls back to
  // plain `ssh <alias>` even when a password is stored, same as it always
  // has -- the terminal just prompts interactively like before.
  property bool sshpassAvailable: true

  Process {
    id: sshpassCheckProc
    command: []
    onExited: function(exitCode) { root.sshpassAvailable = exitCode === 0 }
  }

  function _checkSshpass() {
    if (sshpassCheckProc.running) return
    sshpassCheckProc.command = ["which", "sshpass"]
    sshpassCheckProc.running = true
  }

  // ------------------------------------------------------------------ RDP
  //
  // Same optional-dependency shape as Wake-on-LAN/Browse above. Switched
  // from Remmina to xfreerdp3 directly (2026-09-12) -- Remmina's own
  // connection-window embedding needs GtkSocket/XEmbed (X11-only, doesn't
  // exist under Wayland; workaround was GDK_BACKEND=x11) and its RDP/VNC
  // plugins are separate optional systemdeps (`freerdp`/`gtk-vnc`) on top
  // of the `remmina` package itself -- xfreerdp3 (part of `freerdp`,
  // already required either way) sidesteps all of that: it's not a GTK
  // app, opens its own plain window, no embedding involved. `xfreerdp3` is
  // this system's actual binary name (FreeRDP 3.x's own convention, not
  // `xfreerdp`) -- confirmed via `pacman -Ql freerdp`. VNC has no
  // equivalent here (xfreerdp doesn't speak VNC) and is deliberately
  // hidden from BookmarkForm's protocol selector until a dedicated VNC
  // client is chosen -- see that file's own comment.
  property bool remoteDesktopAvailable: true

  Process {
    id: remoteDesktopCheckProc
    command: []
    onExited: function(exitCode) { root.remoteDesktopAvailable = exitCode === 0 }
  }

  function _checkRemoteDesktop() {
    if (remoteDesktopCheckProc.running) return
    remoteDesktopCheckProc.command = ["which", "xfreerdp3"]
    remoteDesktopCheckProc.running = true
  }

  Component { id: remoteDesktopProcComponent; Process {} }

  // Only "rdp" is wired up; "vnc" can't reach here while it's hidden from
  // the protocol selector, but this no-ops rather than misbehaving if a
  // pre-existing bookmark somehow still carries protocol: "vnc".
  //
  // Routed through omarchy-launch-terminal, same as connectToHost's own
  // ssh launch -- NOT a bare detached Process. Confirmed live this is
  // required, not just tidy: unlike Remmina's GTK plugin (its own proper
  // login form), the standalone xfreerdp3 CLI client has no graphical
  // credential prompt at all -- Domain/Username/Password entry for NLA
  // authentication is read from the controlling terminal
  // (client_cli_read_string), and a detached launch with no TTY fails
  // immediately ("tcgetattr() failed with Inappropriate ioctl for device",
  // "NLA begin failed") rather than opening anything. A real terminal
  // fixes this the same way it already does for SSH: briefly shows the
  // Domain/Username/Password prompt, then xfreerdp3 opens its own separate
  // window for the actual remote desktop session once authenticated.
  function launchRemoteDesktop(protocol, hostname, rdpPort, rdpUser, rdpPassword) {
    if (!hostname || protocol !== "rdp") return
    var vArg = "/v:" + hostname + (rdpPort && rdpPort !== "3389" ? ":" + rdpPort : "")
    var args = ["xfreerdp3", vArg,
      // tofu (trust-on-first-use): accepts the cert on first connect,
      // denies on a later mismatch -- not /cert:ignore. Confirmed live
      // this alone is silently handled with no interactive prompt either
      // way, so it doesn't need the terminal the credential prompt does.
      "/cert:tofu",
      // Without these, xfreerdp3 defaults to a small fixed-size window
      // (reported live: the actual remote desktop rendered tiny in a
      // corner of the screen). +f is real fullscreen, with its own
      // documented toggle (Ctrl+Alt+Enter) rather than trapping the user
      // in it; /dynamic-resolution means toggling out to a resizable
      // window and resizing it live-resizes the remote session too,
      // instead of just scaling/black-bars. (A fixed 1920x1080 was tried
      // as a live diagnostic for Sequoia's black-screen-with-cursor-only
      // symptom -- ruled OUT as the cause: identical black screen at a
      // completely standard resolution. See DEV_TESTING.md -- this looks
      // like a server-side Windows/GPU RDS issue, not a client resolution
      // mismatch, so reverted to the normal fullscreen behavior.)
      "+f", "/dynamic-resolution",
      // Forces NTLM, skipping xfreerdp3's own default Kerberos attempt
      // entirely. A UPN-style rdpUser (a Microsoft Account login like
      // "j.m.thomas@comcast.net", not a real domain-joined AD account)
      // has no actual Kerberos realm behind its email domain -- confirmed
      // live against two separate real Windows boxes (RedOak, Sequoia)
      // via /log-level:INFO: xfreerdp3 always tries Kerberos first,
      // fails with "Cannot find KDC for realm COMCAST.NET" (a DNS SRV
      // lookup for a realm that was never going to exist), THEN falls
      // back to NTLM and connects fine regardless -- so this was never a
      // real auth failure, just wasted, DNS-latency-dependent time on
      // every single connection. That latency dependency is exactly the
      // kind of thing that can vary run to run (cold vs. cached negative
      // DNS lookup) -- plausible root cause for a real reported symptom
      // (Sequoia's RDP window opening then closing after a few seconds on
      // one attempt, connecting fine on the next). Skipping Kerberos
      // outright removes that variability rather than just tolerating it.
      "/auth-pkg-list:none,ntlm",
      // Without this, the RDPSND audio-redirection channel is never
      // requested at all -- reported live: video played fine (the GPU/
      // rendering fix above unblocked that) but with zero audio, on a
      // bookmark that had never passed any sound-related flag. Bare
      // `/sound` (no sub-options) lets xfreerdp3 auto-pick a working
      // local backend rather than hardcoding one -- this machine could be
      // PipeWire or PulseAudio depending on setup, and xfreerdp3 already
      // knows how to probe for whichever is actually running.
      "/sound"]
    // Without /u:, xfreerdp3 silently defaults to the LOCAL LINUX
    // username (logged as "No user name set. - Using login name: <linux
    // user>") and only prompts for Domain/Password -- never for username,
    // so there's no way to correct it interactively. Confirmed live this
    // is exactly what broke a real connection attempt: every login
    // silently failed until rdpUser was actually set on the bookmark.
    if (rdpUser) args.push("/u:" + rdpUser)
    var command
    if (rdpPassword) {
      // A stored password means xfreerdp3 can authenticate fully non-
      // interactively -- no terminal needed at all anymore, so this skips
      // omarchy-launch-terminal entirely and the RDP session window IS
      // the xfreerdp3 process (not wrapped in anything else). That's also
      // what makes "closed when the session ends" just fall out for free:
      // closing that window (Super+W or any other way), the remote
      // machine shutting down, or the connection dropping all directly
      // end this one process -- there's no separate terminal left
      // lingering to clean up.
      args.push("/p:" + rdpPassword)
      command = args
    } else {
      // No stored password -- still needs the terminal for the
      // interactive Domain/Password prompt (xfreerdp3's CLI client has no
      // graphical credential prompt at all; see the DEV_TESTING.md entry
      // on this).
      command = ["/usr/share/omarchy/bin/omarchy-launch-terminal"].concat(args)
    }
    var proc = remoteDesktopProcComponent.createObject(root, { command: command })
    proc.exited.connect(function() { proc.destroy() })
    proc.running = true
  }

  // ------------------------------------------------------------------ ping
  //
  // Deliberately NOT gated behind an availability check the way xfreerdp3/
  // sshpass/wakeonlan/nautilus are above -- `ping` (iputils) is a base
  // system utility on every mainstream Linux distro including this one,
  // same trust level as ssh/bash/timeout per this file's own header
  // comment. A one-shot, user-requested ICMP echo test, entirely separate
  // from the periodic SSH banner probe -- and, unlike Connect, built from
  // host.hostname directly rather than the ssh config alias, so it still
  // works on a configMissing row (the bookmark's own known-good hostname
  // is untouched by a hand-deleted ~/.ssh/config block; only the alias's
  // Host block is gone).
  Component {
    id: pingProcComponent
    Process {
      id: proc
      property string hostAlias: ""
      property string capturedText: ""
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: proc.capturedText = text
      }
      onExited: function(exitCode, exitStatus) {
        root._applyPingResult(proc.hostAlias, proc.capturedText)
        proc.destroy()
      }
    }
  }

  function pingHost(alias) {
    var host = root._hostByAlias(alias)
    if (!host || !host.hostname) return
    root._patchHost(alias, { pingStatus: "pending" })
    // `timeout 4` guards against a slow/hanging DNS lookup for a hostname
    // target -- `-W 2` only bounds the wait for a reply AFTER the ping
    // itself gets a packet out, not the resolution step before it. Same
    // defensive-wrapping convention as the banner probe's own
    // `timeout 3 bash -c ...`.
    var cmd = ["timeout", "4", "ping", "-c", "1", "-W", "2", host.hostname]
    var proc = pingProcComponent.createObject(root, { command: cmd, hostAlias: alias })
    proc.running = true
  }

  // Matches latencyText's own `Math.round(ms) + "ms"` formatting for
  // consistency. Any non-match (timeout, unreachable, unknown host) folds
  // into a single "timeout" result -- same "one simple state, not a
  // granular taxonomy of failure reasons" preference already used for the
  // up/down SSH status.
  function _applyPingResult(alias, raw) {
    var m = String(raw || "").match(/time=([\d.]+)\s*ms/)
    var result = m ? Math.round(parseFloat(m[1])) + "ms" : "timeout"
    root._patchHost(alias, { pingStatus: result })
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
      doc.hosts[h.alias] = { hostname: h.hostname, port: h.port, user: h.user, status: h.status, lastCheckedAt: h.lastCheckedAt }
    }
    stateFile.setText(JSON.stringify(doc))
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
  }

  Component.onCompleted: { mkdirProc.running = true; root._checkWakeonlan(); root._checkFileManager(); root._checkRemoteDesktop(); root._checkSshpass() }

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

  onOpenedChanged: {
    if (root.opened) { themeColorsFile.reload(); root._probeAll(); root._pollConnected(); root._checkWakeonlan(); root._checkFileManager(); root._checkRemoteDesktop(); root._checkSshpass() }
    else if (contentLoader.item) contentLoader.item.selectedRowKey = ""
  }

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
    // Looked up by alias, not threaded through connectRequested's own
    // signal chain -- connectRequested is shared by BOTH bookmark and
    // plain ~/.ssh/config rows (which never have a stored password at
    // all), so finding the bookmark here (if any) keeps that signal's
    // signature untouched. Still always launches IN a terminal, unlike
    // RDP -- unlike a GUI remote-desktop session, an SSH shell session
    // visibly living in a terminal is the whole point, stored password or
    // not.
    var bookmark = bookmarkStore.bookmarks.filter(function(b) { return b.label === alias })[0]
    var sshCommand = (bookmark && bookmark.password && root.sshpassAvailable)
      ? ["sshpass", "-p", bookmark.password, "ssh", alias]
      : ["ssh", alias]
    var proc = launchProcComponent.createObject(root, {
      command: ["/usr/share/omarchy/bin/omarchy-launch-terminal"].concat(sshCommand)
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
    contentWidth: panel.fittedContentWidth(Style.space(570))
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
      onMoveRequested: function(dx, dy) { if (contentLoader.item) contentLoader.item.handleMove(dy) }
      // Deliberately only activateRequested, not also returnRequested --
      // PanelKeyCatcher's own Keys.onPressed fires BOTH signals for Enter
      // (Space fires only activateRequested), so wiring both here would
      // launch two terminals per Enter press.
      onActivateRequested: function() { if (contentLoader.item) contentLoader.item.handleActivate() }
      onDeleteRequested: function() { if (contentLoader.item) contentLoader.item.handleDeleteKey() }

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
          remoteDesktopAvailable: root.remoteDesktopAvailable
          onConnectRequested: function(alias) { root.connectToHost(alias) }
          onWakeRequested: function(mac) { root.wakeHost(mac) }
          onBrowseRequested: function(uri) { root.openFileManager(uri) }
          onRemoteDesktopRequested: function(protocol, hostname, port, user, password) { root.launchRemoteDesktop(protocol, hostname, port, user, password) }
          onPingRequested: function(alias) { root.pingHost(alias) }
        }
      }
    }
  }
}
