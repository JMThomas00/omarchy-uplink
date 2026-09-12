# Dev testing workflow

This plugin has no unit-test framework (none exists for Quickshell/QML in
this shell), so verification is live: temporary debug IPC hooks, real key/
process checks, and screenshots. Several real bugs (a false-positive
"connected" indicator, a form that wouldn't close, popup overflow, an edit
form loading blank) were only found this way, not by reading the QML.

**Never ship a debug hook.** Add it, exercise it, remove it before
committing -- the same discipline this plugin's `IpcHandler` block has
always followed. It should read exactly this between sessions:

```qml
IpcHandler {
  target: "jmthomas00.uplink"

  function open(): void { root.openPanel() }
  function close(): void { root.closePanel() }
  function toggle(): void { root.togglePanel() }
}
```

## Temporary debug hook template

Add a function directly to that `IpcHandler` block, matching whatever
you're testing, e.g.:

```qml
function debugEdit(id: string): void {
  if (contentLoader.item) contentLoader.item.openEditForm(id)
}
```

Call it with:

```
qs -p /usr/share/omarchy/shell ipc call jmthomas00.uplink debugEdit bm_xxxxx
```

Any in-scope object is reachable this way -- `bookmarkStore.*`,
`settingsStore.*`, `root._privateFunction(...)`, `contentLoader.item.*` (the
live `HostList` instance) are all fair game for a debug hook, since it's
deleted before the change ships.

## Standard validate-and-check loop

After every change:

```
omarchy plugin validate ~/.config/omarchy/plugins/uplink
omarchy restart shell
journalctl --user -t omarchy-shell --since "-1min" --no-pager | grep -iE "warn|error"
```

Two lines are known-benign and unrelated to this plugin -- don't chase them:
- `LyricsPlugin.qml`/`resumeIntent` (a different plugin, `omaspotify`)
- `qt.qpa.services`/portal registration (fires on every restart regardless)

For a screenshot: `omarchy capture screenshot fullscreen save <path>`, then
Read the saved file. For real keyboard input (not just calling a handler
function directly, which skips whatever `PanelKeyCatcher` itself does):
`wtype <char>` or `wtype -k <KeyName>` (e.g. `wtype -k Return`,
`wtype -k Escape`) -- this is real Wayland input and requires the popup to
actually have keyboard focus (`qs ... ipc call jmthomas00.uplink open`
first). Don't run a screenshot capture *between* two key presses that need
to land in the same focus session -- confirmed live this can steal focus
and silently swallow the second keypress.

## Regression checklist

Run through relevant sections after touching the matching area.

**BookmarkForm / HostList (edit flow):**
- Click edit on an existing bookmark -- Label/Host/Port/User/Icon/Group/
  Favorite/Protocol all populate immediately, not just after closing and
  reopening the popup.
- Cancel, then edit the same (or another) bookmark again *without* closing
  the popup -- still populates correctly.
- Edit a bookmark's group to a brand-new group name and Save -- the form
  actually closes.
- A bookmark list tall enough to exceed the popup's height cap scrolls
  internally instead of rendering past the border.

**Connected indicator (R1):**
- Open the popup with several hosts probing; across a few
  `popupProbeIntervalSec` ticks, confirm no host flashes "connected"
  without a real `ssh <alias>` session actually open in a terminal.

**Keyboard navigation (R2):**
- j/k/arrows move selection across a group boundary into the "From
  ~/.ssh/config" section.
- Enter and Space each connect exactly once (not twice -- watch
  `hyprctl clients` count before/after).
- 'x' 'x' two-stage-deletes a selected bookmark; does nothing on a selected
  config-host row.
- Escape still closes the popup mid-navigation.

**External-edit resync (R3):**
- Hand-edit a bookmark's `Port` line in `~/.ssh/config` while the shell is
  running; reopen that bookmark's Edit form -- shows the new port, not
  stale. Saving afterward doesn't revert the hand-edit.

**Rolling backups (R4):**
- After several bookmark edits, `~/.config/uplink/backups/` accumulates
  numbered snapshots and prunes to the newest 15.
- `~/.ssh/config.pre-uplink.bak` (the one-time snapshot) stays untouched.

**Collapsible groups (F1):**
- Collapse a group, close and reopen the whole popup -- collapse state
  persisted.

**Favorites (F2):**
- Star a bookmark in a group with others -- sorts to the top of *that*
  group only, no duplication, others keep relative order.
- Confirm the star does NOT appear on plain `~/.ssh/config` rows (gate is
  `bookmarkId !== ""`, not `editable` -- config-host rows are `editable`
  too, for their own narrower rename/delete path).

**Status notifications (F3):**
- Enable "Notify on status change" -- no notification burst right when you
  enable it or on the next shell restart (first classification is
  suppressed). A genuine down->up or up->down transition afterward does
  notify.

**RDP via xfreerdp3 (F4) -- verified live end-to-end 2026-09-12 against a
real Windows host, reached its certificate-accept prompt. Originally built
against Remmina, switched to xfreerdp3 the same day (the user didn't like
Remmina) -- history kept here since the underlying gotchas (missing
`freerdp`, GtkSocket/Wayland) are still real and would resurface with any
GTK-embedding remote-desktop client, not just Remmina:**
- `launchRemoteDesktop` in BarWidget.qml builds `xfreerdp3 /v:host[:port]
  /cert:tofu [/u:user]` -- no GTK, no window embedding, no Wayland-specific
  workaround needed for the actual remote-desktop window (confirmed:
  xfreerdp3 opens its own plain window natively, unlike Remmina).
- **Must launch through `omarchy-launch-terminal`, NOT a bare detached
  Process** -- confirmed live this is required, not optional. Unlike
  Remmina's GTK plugin (its own proper login form), the standalone
  xfreerdp3 CLI client has no graphical credential prompt at all:
  Domain/Password for NLA auth is read from the controlling terminal
  (`client_cli_read_string`), and a detached launch with no TTY fails
  immediately (`tcgetattr() failed with Inappropriate ioctl for device`,
  `NLA begin failed`) rather than opening anything or even hanging.
  Routing through `omarchy-launch-terminal` (same as `connectToHost`'s own
  ssh launch) fixes this exactly the way it already does for SSH: a
  terminal briefly shows the Domain/Password prompt, then xfreerdp3 opens
  its own separate window for the actual session once authenticated.
- **The terminal prompt asks for Domain and Password ONLY -- never
  Username.** If no `/u:` is passed, xfreerdp3 silently defaults to the
  LOCAL LINUX username (logged as `No user name set. - Using login name:
  <linux user>`) and just proceeds to prompt for what's still missing.
  There's no way to correct this interactively -- confirmed live this
  broke a real connection attempt (RedOak, Windows account "Jordan
  Thomas"): every login silently failed with a correct password because
  it was authenticating as the wrong (Linux) username the whole time, and
  the failure looked identical to a generic connection error from the
  outside. Always pass `/u:` when the bookmark has a username set; the
  quickest way to spot this class of bug in the future is checking the
  terminal's own log lines for "No user name set," not just "it doesn't
  work."
- **RDP needs its own Port AND User fields, separate from the SSH ones**
  (`rdpPort`/`rdpUser` in BookmarkStore.qml, both JSON-only) -- two
  distinct real bugs from reusing the SSH fields, both found live against
  the same real bookmark: (1) a bookmark's `port` had been left at 22 (SSH
  default) since RDP wasn't originally set up on it, and launchRemoteDesktop
  was reusing that same field, so it tried to speak RDP on port 22 instead
  of 3389 -- xfreerdp3 exited almost instantly, terminal opened and closed
  with it. (2) the SSH `user` field is validated against `_userRe`
  (POSIX-username-shaped, no spaces, since it's written into
  `~/.ssh/config`), but a real Windows account name can be "Jordan Thomas"
  -- reusing `user` for RDP would reject that outright. `rdpUser` instead
  only checks for embedded newlines and a length cap, same as notes/group.
- `/cert:tofu` (trust-on-first-use), not `/cert:ignore` -- confirmed live
  this part IS silently handled with no interactive prompt either way (a
  self-signed cert logged a WARN and connected straight through), so it
  doesn't depend on the terminal fix above. Still worth keeping explicit:
  with no `/cert:` option at all, a certificate mismatch would fall back
  to an interactive accept/deny prompt, which needs the same terminal but
  is a separate, security-relevant decision -- tofu accepts on first
  connect and denies on a later mismatch, the least-insecure option that
  still never blocks on input.
- `remoteDesktopAvailable` checks `which xfreerdp3` specifically -- this
  system's actual FreeRDP 3.x binary name, confirmed via `pacman -Ql
  freerdp` (NOT `xfreerdp`, the older FreeRDP 2.x name). A machine on
  FreeRDP 2.x would need this changed back to `xfreerdp`.
- VNC has no equivalent right now -- deliberately hidden from
  BookmarkForm's protocol selector (`["ssh", "rdp"]`, "vnc" removed) since
  xfreerdp doesn't speak VNC and no replacement VNC client has been chosen.
  BookmarkStore's schema still accepts a stored `protocol: "vnc"` value
  untouched (so an old bookmark doesn't silently lose it), `
  launchRemoteDesktop` just no-ops if it's ever reached with anything other
  than `"rdp"`.
- Set a bookmark's protocol to RDP, fill in BOTH RDP Port (if not 3389)
  AND RDP User (if the target needs one), confirm the "RDP" button appears
  next to Connect, and clicking it launches and actually connects --
  really log in, not just reach the Domain/Password prompt, since a wrong
  username still reaches that prompt and still fails silently after.
- Confirm the button is absent again if `freerdp` is ever uninstalled
  (graceful degradation, same as Wake-on-LAN/Browse).
- **A stock `/etc/krb5.conf` can break NLA auth for a username with no
  domain/UPN suffix** -- this machine's krb5.conf is the unmodified
  package default (`default_realm = ATHENA.MIT.EDU`, a real MIT domain,
  never configured for actual use). Confirmed live: xfreerdp3's NLA
  implementation tried Kerberos first for a bare username, silently used
  that bogus default realm (`krb5_init_creds_get (Client 'X@ATHENA.MIT.EDU'
  not found in Kerberos database)`), and failed before ever trying NTLM
  against the real target -- this looks IDENTICAL to a wrong-password
  failure from the terminal output alone (same generic
  `ERRCONNECT_LOGON_FAILURE`), so don't assume the credentials are wrong
  just because login fails. The actual fix that worked here wasn't a
  plugin change at all: using the account's full UPN-style login
  (`user@realdomain.tld`, matching what the Windows box's own account is
  actually named -- confirmed live with a `user@comcast.net`-style
  Microsoft-account login) rather than a bare local username sidesteps
  the local default-realm lookup entirely. Forcing `/auth-pkg-list:
  none,ntlm` also works around it (confirmed via manual testing) but was
  NOT added to `launchRemoteDesktop` -- the UPN fix alone already unblocked
  the one real bookmark that needed it, and layering on an auth-mechanism
  change that wasn't needed risked breaking a connection that had just
  started working. Revisit only if a FUTURE bookmark with a genuinely bare
  local username (no @domain) hits this same failure.
- **`xfreerdp3` defaults to a small fixed-size window** -- reported live,
  the actual remote desktop rendered tiny in a corner of the screen after
  a successful login. `launchRemoteDesktop` now passes `+f` (real
  fullscreen, own documented toggle: Ctrl+Alt+Enter) and
  `/dynamic-resolution` (so toggling out to a window and resizing it
  live-resizes the remote session instead of just scaling/black-bars).

**Historical, Remmina-specific, kept for context (no longer applicable
since the switch to xfreerdp3, but the class of bug is worth remembering
for any future GTK-based remote-desktop integration):**
- `remmina` alone was NOT enough -- `freerdp`/`gtk-vnc` are *optional*
  dependencies of the `remmina` package, not pulled in automatically.
  Without them the plugin `.so` is present but fails to load, and
  Remmina's error ("Install the RDP protocol plugin first") reads like a
  missing Remmina plugin but is actually a missing system library.
  `remmina --version` lists every plugin load failure and the exact
  missing `.so` -- more useful than `which remmina` for this class of bug.
- Remmina's connection-window embedding needs `GtkSocket`/`XEmbed`,
  X11-only, so a plain launch on Wayland threw "GtkSocket feature is not
  available in a Wayland session." Remmina's own documented fix was
  `GDK_BACKEND=x11`. xfreerdp3 sidesteps this whole class of bug by not
  using GTK embedding at all.
- Remmina enforces single-instance: a second `remmina -c ...` call while
  one is already running gets forwarded to the EXISTING window instead of
  opening fresh -- a stale error dialog from before a fix landed could
  make a naive retest look like the fix didn't work. (xfreerdp3 has no
  such single-instance behavior -- each launch is a fresh, independent
  process, so this specific gotcha doesn't apply anymore either.)

**Row layout (F4 risk -- checked during the same session this was built):**
- A down, bookmarked, MAC-equipped, non-SSH-protocol host can show all six
  buttons at once in `buttonRow` (Wake + Edit + Delete-confirming + Browse
  + Connect + the remote-desktop button). Verified live (temporarily
  forcing wakeonlanAvailable/remoteDesktopAvailable true, since neither
  binary was installed on this machine at the time) -- the row does NOT
  overflow `Style.space(410)` or wrap; the label's own `elide:
  Text.ElideRight` just truncates more aggressively to make room, which is
  the existing, intended graceful behavior for a crowded row. Re-check
  this if more buttons are ever added to `buttonRow`, since the margin
  before actual
  overflow wasn't measured, just confirmed non-zero.

**Stored passwords (SSH `password` + RDP `rdpPassword`, added 2026-09-12,
by explicit user request) -- plaintext in bookmarks.json, not encrypted:**
- `bookmarks.json` is now chmod 600 after every write (`bookmarksChmodTimer`
  in BookmarkStore.qml), plus once at startup to remediate a file that
  already existed with looser permissions from before this field existed.
  Confirmed live: was 644, is 600 after this change.
- Neither password field is `.trim()`-ed (unlike every other text field in
  this store) -- a real password could legitimately have leading/trailing
  whitespace; stripping it would silently corrupt it.
- SSH: `connectToHost` looks up the bookmark by alias itself (not threaded
  through `connectRequested`'s signal, which is shared with plain
  ~/.ssh/config rows that never have a stored password) and uses `sshpass
  -p <password> ssh <alias>` when both a password is stored AND
  `sshpassAvailable` (same optional-dependency pattern as everything
  else) -- otherwise falls back to plain `ssh <alias>`, unchanged from
  before this feature existed. Still always launches in a visible
  terminal, unlike RDP -- an SSH shell living in a terminal is the point.
  Verified live: confirmed the exact argv (`sshpass -p testpw123 ssh
  Mesquite`) via `pgrep -af`, killed it before any real auth attempt
  completed rather than risk it against a real password.
- RDP: a stored `rdpPassword` makes `launchRemoteDesktop` skip
  `omarchy-launch-terminal` ENTIRELY and launch `xfreerdp3` directly
  (detached, `/p:<password>` added to its args) -- no terminal at all, so
  "closed when the session ends" (Super+W, remote shutdown, or connection
  loss) falls out for free, since the RDP window IS the xfreerdp3 process
  now, nothing else lingers. Without a stored password, behavior is
  unchanged (terminal-wrapped interactive Domain/Password prompt).
- Password field UI (both SSH and RDP) is a `TextField` with `password:
  !revealed` bound to a local `xRevealed` bool, plus a 👁/🙈 toggle Text
  next to it (`Style.font.body`, same MouseArea-margin-expansion idiom as
  every other icon toggle in this file). Both `xRevealed` flags reset to
  `false` every time the form (re)opens, in `_loadFields` -- a password
  left revealed while editing one bookmark must not still show in plain
  text when immediately switching to edit a different one. Verified live:
  set a real value, confirmed masked dots on open, toggled the eye,
  confirmed plaintext reveal, matching the actual stored value exactly.

**Uptime-probe backend removed (2026-09-12), after the uptime display
itself was removed from HostRow.qml as part of the row-alignment cleanup:**
- Once nothing renders `host.uptime`, the second-stage probe that computed
  it (`_probeUptime`, `_applyUptimeResult`, `uptimeProcComponent`, the
  `alsoUptime` param threaded through `_applyBannerResult`/`_runTcpProbe`/
  the popup-open sweep) was pure waste -- one extra `ssh -o BatchMode=yes`
  process spawned per host, every popup-open probe tick, for zero
  observable output. Deleted entirely rather than left dead.
- `_probeAllStageA`/`_probeAllFull` were identical once the `alsoUptime`
  arg they differed on was gone -- consolidated into one `_probeAll()`
  shared by both the background timer (renamed `backgroundProbeTimer`,
  was `stageATimer`) and the popup-open `fullSweepTimer`.
- `_applyConnectedPoll`'s `pgrep` exclusion dropped the `BatchMode=yes`
  token check (it existed only to exclude `_probeUptime`'s own spawned
  `ssh` process from false-positiving as a real connected session) --
  `-G` alone remains, still excluding `_resolveAlias`'s probe.
- `uptime` removed from: the `hosts` array shape, `_saveCache`'s
  status-cache.json write, `HostList._displayHostForBookmark`'s `base`
  fallback object. Left in place (correctly): the "config entry missing"
  message, which had been proactively moved off the uptime Text's slot
  into `subtitle` (plus the row-1 label turning `Color.urgent`) during the
  prior UI-cleanup turn, before this backend removal even started --
  verified live here that it's still structurally intact (nothing in this
  removal touches `subtitle` or `configMissing`).
- Verified live: `omarchy plugin validate` clean, no new warnings/errors
  in `journalctl` after restart, popup screenshot confirms rows still
  render aligned with no leftover uptime text and no layout shift.

**Widened popup + Wake moved to row end (2026-09-12), user-reported
crowding once the RDP button/wider layout landed:**
- Panel width bumped 460 -> 510 in three places that all have to move
  together: `HostList.qml`'s own `width:`, `BarWidget.qml`'s
  `contentWidth: panel.fittedContentWidth(...)`, and `HostRow.qml`'s
  fallback `width:` (unused in practice -- every real delegate overrides
  it with `width: root.width` -- but bumped anyway so it isn't a stale
  trap for the next person reading it as if it mattered).
- Wake moved from first to last in `buttonRow` -- Row lays out children in
  declaration order, so this was a pure cut-paste of the Rectangle block
  to after the RDP button, no anchor/positioner changes needed. Reasoning
  recorded inline: Wake is the least-frequently-used action (only
  meaningful for a down, MAC-equipped host), so it sits at the far edge
  away from the Edit/Delete/Browse/Connect/RDP cluster.
- Verified live via popup screenshot: wider panel, Wake now trailing RDP
  on every row, no misalignment reintroduced.

**Config-hosts section made collapsible (2026-09-12), extending F1's
per-group collapse to the "From ~/.ssh/config" section:**
- New `SettingsStore.collapsedConfigHosts` bool (+ `setCollapsedConfigHosts`),
  exact mirror of `compactRows`'s shape -- a plain bool, not a list like
  `collapsedGroups`, since there's only ever one config-hosts section (not
  one per group name).
- `HostList.qml`'s `~/.ssh/config` Column got an `id: configSection` and
  `isCollapsed` property, a ▸/▾-prefixed clickable header (same
  Row+Text+MouseArea idiom as `groupSection`'s header), and its Repeater's
  `model:` gated the same way F1 gates the bookmark Repeater
  (`isCollapsed ? [] : configHosts`). The "No hosts found"/"Some hosts may
  be defined via Include" notes are also hidden while collapsed, so a
  collapsed section shows nothing but its own header.
- `flatRows` (keyboard nav) updated to skip config-host rows entirely when
  `collapsedConfigHosts` is true -- same treatment F1 already gives a
  collapsed bookmark group, so j/k navigation can't land on a row that
  isn't actually visible.
- Verified live: since `ydotoold` isn't running on this machine (real
  click simulation via `ydotool` failed with "failed to connect socket"),
  used a temporary debug IPC function
  (`debugToggleConfigCollapse` calling `settingsStore.setCollapsedConfigHosts`
  directly) to toggle the state and screenshot both the collapsed (header
  only, panel shrinks) and re-expanded (rows back) states -- removed
  before finishing, per this file's own standing convention.
