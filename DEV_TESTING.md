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
  the local default-realm lookup entirely.
  **Update (2026-09-12): `/auth-pkg-list:none,ntlm` WAS eventually added**
  to `launchRemoteDesktop`, once a SECOND real bookmark (Sequoia, same
  `user@comcast.net`-style login as RedOak, different physical Windows
  box) hit a live, reported symptom -- "RDP window opens, then closes
  after a few seconds" -- that didn't reproduce on a manual retest
  moments later. Root-caused via `/log-level:INFO`: even with a correct
  UPN, xfreerdp3 STILL tries Kerberos first (using the email domain,
  e.g. "COMCAST.NET", as the realm), fails with the identical `Cannot
  find KDC for realm` error every time (a Microsoft-account UPN has no
  real Kerberos infrastructure behind its email domain either), THEN
  falls back to NTLM and connects fine regardless -- confirmed via two
  back-to-back manual `nohup`+`/log-level:INFO` runs (not through the
  plugin) that both stayed connected (checked via `hyprctl clients`
  showing a live `xfreerdp` window, `ps` showing the process still
  running well past when it "should" have closed). That Kerberos-then-
  fallback dance depends on a DNS SRV lookup for a realm that will never
  resolve -- cold vs. already-negatively-cached DNS is exactly the kind
  of timing variance that could push a slow first attempt past some
  internal FreeRDP timeout on one run and not the next, which lines up
  with "failed once, can't reproduce" better than any credentials/
  network explanation. Verified the fix directly: reproduced the bookmark's
  EXACT real launch (through a temporary debug hook calling
  `root.launchRemoteDesktop` with Sequoia's real fields, not just a
  manual argv guess) both with and without the flag -- without it, the
  Kerberos error appears and the connection takes longer to settle;
  with `/auth-pkg-list:none,ntlm` added, the Kerberos attempt (and its
  DNS dependency) never happens at all, connecting in well under a
  second every time across three separate manual test runs. No
  regression risk identified: this only forces the SAME auth mechanism
  (NTLM) that every prior connection was already silently falling back
  to anyway, just without the wasted attempt first.
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

**Export no longer includes stored passwords by default (2026-09-12) --
the plaintext-in-bookmarks.json tradeoff (chmod 600 there) must not
silently extend to a second, unhardened file:**
- `ExportImportPanel.qml` gets a new `includePasswords` bool, defaulting
  `false` and reset to `false` every time the panel (re)opens -- NOT
  persisted to SettingsStore, same "a sensitive toggle must not silently
  stick on" reasoning as BookmarkForm's password-reveal flags. A checkbox
  next to it ("Include stored passwords") uses the exact same
  Rectangle+MouseArea idiom as SettingsPanel's `compactCheckbox`/
  `notifyCheckbox`.
- `_writeExport` now maps each bookmark through `Object.assign({}, b)` and
  `delete`s `password`/`rdpPassword` from the copy before serializing,
  unless `includePasswords` is true -- an omitted key, not a blanked one,
  so a careless re-import can't mistake an empty string for "no password"
  and silently clobber a real one already on that alias.
- The export file also gets the same `chmod 600` treatment as
  `bookmarks.json`/`~/.ssh/config` (a new `exportChmodProc`), applied
  regardless of `includePasswords` -- even a passwords-excluded export
  still lists every hostname/user bookmarked.
- Verified the strip transform in isolation first via `node -e`
  (confirmed both keys fully absent from the mapped copy, and the
  original array's objects untouched -- `Object.assign` shallow-copies,
  it doesn't mutate). Then verified the real Process/FileView path live:
  since neither `ydotool` (uinput permission) nor a from-scratch
  `ydotoold` start could get real clicks working on this machine, drove
  the full flow through three chained temporary debug hooks (an alias
  exposing `SettingsPanel`'s instance off `HostList`, another exposing
  `ExportImportPanel`'s instance off that, and a `debugExportTo(path,
  includePasswords)` IPC function calling `_writeExport` directly) to
  export the real live bookmark set twice -- once default (confirmed
  zero `password`/`rdpPassword` keys anywhere in the file) and once with
  the checkbox true (confirmed RedOak's actual stored `rdpPassword`
  appeared verbatim, proving the toggle gates the real secret, not a
  placeholder) -- both files came back `-rw-------`. Deleted both
  real-password-containing scratch files with `shred -u` (falling back to
  `rm -f`) rather than a plain `rm`, and fully reverted all three chained
  debug hooks afterward -- confirmed via `grep -n debug` across the
  three touched files coming back empty.
- One real mid-task mistake, caught immediately: an `Edit` intended to
  delete two now-redundant debug IPC functions was written with a
  duplicate-old-string collision and briefly left a duplicated `open()`
  function inside the same `IpcHandler` block (`omarchy plugin validate`
  would have caught the resulting duplicate-property-style error on
  reload regardless, but it was caught by inspection first) -- fixed by
  re-reading the block and replacing it exactly rather than patching
  around the mistake.

**Bug-squashing pass (2026-09-12) -- two real bugs found by a full,
deliberate re-read of every file, both fixed and live-verified:**

- **Connect stayed live on a `configMissing` row.** `connectToHost` runs
  `ssh <alias>`, which depends entirely on `<alias>` still having a Host
  block in `~/.ssh/config` -- exactly what's GONE for a configMissing row
  (its block was hand-deleted out from under the plugin). Clicking Connect
  there would have ssh try to resolve the literal alias string as a
  hostname instead of the bookmark's own still-known real hostname,
  producing a confusing failure with no explanation. Browse/Wake/RDP are
  unaffected -- all three are built directly from `host.hostname`/`mac`/
  `rdpPort`/`rdpUser`, never from the alias -- so only Connect needed
  gating. Fixed in `HostRow.qml` with a new `connectApplicable` property
  (`!(host && host.configMissing)`), applied via the exact same
  opacity+enabled/hoverEnabled/cursorShape idiom already used for Wake/RDP
  dimming, so it stays visually consistent with the rest of the row
  instead of introducing a new pattern.
- **Startup race: a bookmark whose block was ALREADY missing before the
  session started could get permanently stuck.** `_onSshConfigChanged`'s
  configMissing-synthesis loop only ever runs in reaction to a
  `~/.ssh/config` file event -- if `bookmarkStore.bookmarks` finished
  loading AFTER `sshConfigFile`'s own first `onLoaded` (a real, unordered
  async race between two independent FileViews, already the exact root
  cause behind `_retagHostSources`'s own existence earlier this session),
  that bookmark's alias would simply be absent from `root.hosts` --
  showing "checking" forever (never probed, since `_probeAll` only
  iterates `root.hosts`) instead of the intended warning, until some
  UNRELATED future `~/.ssh/config` edit happened to re-trigger the real
  detection logic. Fixed with a new `_syncMissingBookmarkRows()` in
  `BarWidget.qml`, called alongside `_retagHostSources()` from the same
  `onBookmarkLabelsChanged` handler -- mirrors that function's own
  dual-entry-point fix for the identical race class. Guarded on
  `root.hosts.length > 0` (same guard `_applyCachedState` already uses)
  so it never fires before `~/.ssh/config` has loaded at all, which would
  otherwise flag every bookmark as configMissing for one frame.
- Verified both together live: added a real bookmark
  (`ZZDebugConfigMissing`, hostname `203.0.113.1` -- TEST-NET-3, safe/
  non-routable so no accidental probe traffic), then used a temporary
  `debugSimulateHandDelete` hook (calling `BookmarkStore._removeBookmarkBlock`
  directly, NOT `deleteBookmark`, so only the `~/.ssh/config` block
  vanished while the bookmark's own JSON entry stayed -- an accurate
  simulation of a real hand-delete) to reproduce the exact scenario
  without hand-editing the real config file. Screenshot (cropped/zoomed
  2x for a clear before/after comparison) confirmed the row rendered with
  a red label, red status dot, and a visibly dimmed/dotted-outline Connect
  button next to Juniper's normal, crisp one. Cleaned up via the normal
  `deleteBookmark` path afterward, confirmed zero remaining references to
  the test label in either `~/.ssh/config` or `bookmarks.json`, then fully
  reverted all three temporary debug functions (two in `BarWidget.qml`,
  one in `BookmarkStore.qml`) -- confirmed via `grep -rn debug` across
  every `.qml` file coming back empty.

**Optimization/performance pass (2026-09-12), immediately after the
bug-squashing pass above -- same full re-read, different lens:**

- **Applied:** `HostList.qml` had TWO independent `root.hosts.filter(h =>
  h.source === "config")` passes -- one inside `flatRows`, one as the
  `~/.ssh/config` Column's own `configHosts` property -- recomputing the
  identical filter twice on every `root.hosts` change. Hoisted into one
  shared `readonly property var configHosts` on the root Column,
  referenced from both places. Zero behavior change, one array pass
  instead of two.
- **Applied:** `HostRow.qml`'s two-click delete-confirm logic was
  duplicated verbatim between `onDeleteKeySeqChanged` (the keyboard path)
  and the delete button's own `onClicked` (the mouse path) -- not a
  performance issue, but the same duplicate-logic risk this codebase
  otherwise takes care to avoid. Extracted into a shared
  `_triggerDeleteConfirm()`, called from both entry points after each
  keeps its own distinct applicability guard (keyboard: only the selected
  row; mouse: any row) -- confirmed this guard difference is why the two
  couldn't just be merged into one signal handler instead.
- **Considered, NOT applied -- flagged instead:** `BarWidget.qml`'s
  `contentLoader` (`Loader { sourceComponent: hostListComponent }`, no
  `active:` binding) stays instantiated for the plugin's entire lifetime
  once first opened -- `KeyboardPanel` only hides the window
  (`visible: open || card.opacity > 0 || ...`), it never tears down its
  content tree. Since the background probe timer keeps mutating
  `root.hosts` on its own cadence specifically so the bar icon/badge stay
  accurate while the popup is closed (by design, see that timer's own
  comment), the entire `HostList` tree -- `groupedBookmarks`, `flatRows`,
  every nested `HostRow` delegate's dozen-plus bound properties --
  recomputes on every such tick EVEN WHILE the popup is closed and
  invisible. Gating `contentLoader.active` on `root.opened` would fix
  this, but `KeyboardPanel`'s card fades out over 140ms AFTER `open`
  flips false (`visible` intentionally lags `open` for the animation) --
  naively tying `active` to `open` would destroy the content instantly,
  so the card would visibly fade out over an already-blank hole instead
  of its actual last-rendered state. Fixing that correctly needs either a
  ~140ms-delayed deactivation or a signal from `KeyboardPanel` itself for
  "fully closed, animation included," neither of which this file can see
  from the outside. At this plugin's realistic scale (single-digit to
  low-tens of hosts/bookmarks), the wasted recompute is genuinely
  sub-millisecond and happens at most once per `probeIntervalSec` (60s
  default) -- not worth the regression risk of a visible glitch on a
  daily-driver popup for an unmeasurable saving. Left untouched;
  reconsider only if this plugin's typical host count grows by an order
  of magnitude or more.
- **Considered, NOT applied -- correctness-load-bearing, not accidental
  waste:** `_onSshConfigChanged` re-resolves EVERY alias (`ssh -G`) and
  re-probes every host on EVERY `~/.ssh/config` change, including this
  plugin's own writes for a single unrelated bookmark -- looks like
  obvious redundant work at first glance. It isn't: `BookmarkStore.qml`'s
  own header comment on `_syncBookmarkFieldsFromConfig` explicitly
  depends on this blanket re-resolve to pick up a hand-edited Port/
  HostName for a PLAIN (non-bookmark) `~/.ssh/config` host, which has no
  other sync mechanism at all. Skipping re-resolution for
  already-known aliases would silently break live-updating a hand-edited
  plain host's port/hostname. Left untouched.

**Ping button added (2026-09-12), in front of Connect on every row:**
- A one-shot `timeout 4 ping -c 1 -W 2 <hostname>` per click, entirely
  separate from the periodic SSH banner probe -- tests basic ICMP
  reachability, not "is a real sshd answering." No availability-gate
  property (unlike xfreerdp3/sshpass/wakeonlan/nautilus above) -- `ping`
  is a base-install utility on every mainstream Linux distro, same trust
  tier as `ssh`/`bash`/`timeout` themselves per this file's own header
  comment.
- Built from `host.hostname` directly, like Browse/Wake/RDP -- NOT the
  ssh config alias, like Connect -- so `pingApplicable` only requires a
  known hostname, deliberately NOT gated on `configMissing` the way
  `connectApplicable` is: a hand-deleted ~/.ssh/config block breaks
  alias-based resolution (Connect's problem), but the bookmark's own
  hostname stays known and pingable regardless.
- Result parsing: `/time=([\d.]+)\s*ms/` against stdout, rounded to match
  `latencyText`'s own `Math.round(ms) + "ms"` convention; any non-match
  (timeout, unreachable, DNS failure) folds into one "timeout" label --
  same "simple state over granular taxonomy" preference already used for
  up/down SSH status. Deliberately checked the regex requires the `=`
  (only present on a real per-reply line, e.g. "time=0.123 ms") so it
  can't false-positive-match the summary line's unrelated "time 0ms"
  (elapsed wall-clock time for the whole run, not round-trip time) --
  confirmed by hand against real `ping` output for both a live host (a
  "64 bytes from ... time=0.123 ms" reply line) and an unreachable one
  (TEST-NET-3 203.0.113.1 -- "100% packet loss", no time= line at all).
- Result lives on the shared `host` object (`BarWidget.pingHost` /
  `_applyPingResult`, via the same `_patchHost` every other probe already
  uses) -- NOT local row state, so it survives this delegate being
  rebuilt by an unrelated bookmark edit, same as `status`/`latencyMs`
  already do. Never written to `status-cache.json` (`_saveCache` only
  ever picks specific fields, `pingStatus` isn't one of them) -- purely
  transient, resets to unset on every shell restart. What IS local row
  state is how long to keep SHOWING a landed result before reverting the
  button label back to "Ping" -- `host` is a plain JS object, not a
  QtObject, so its own fields can't fire QML change signals directly.
  `HostRow.onHostChanged` (fires whenever `host` itself is reassigned,
  which happens on every `root.hosts` update for ANY reason) compares
  against a locally-tracked last-seen value to detect an actual
  `pingStatus` transition specifically, then shows it
  for 4 seconds (`pingResultTimer`, same shape as `deleteConfirmTimer`)
  before the button label reverts to "Ping". The always-passes-through-
  "pending"-first state sequence means two identical results in a row
  (e.g. "12ms" twice) still each get their own fresh 4-second window,
  confirmed by reasoning through the exact three-state sequence
  ("12ms" -> "pending" -> "12ms" is two real changes, not a no-op).
- Verified live end-to-end via a temporary `debugPing(alias)` IPC hook
  (`ydotoold` still can't reach `/dev/uinput` on this machine for a real
  click, same blocker as earlier this session): pinged a real live host
  (Mulberry, 192.168.1.10) and confirmed via `console.log` that
  `_hostByAlias(alias).pingStatus` landed as `"1ms"`/`"2ms"` on separate
  runs; also confirmed via screenshot that ONLY the pinged row's button
  showed the live numeric result while every other row's button still
  read "Ping" (per-row state isolation, not a global flag). One real,
  useful discovery from this test: a bookmark already showing DOWN (red
  dot, SSH banner probe failing) still answered ICMP ping successfully --
  a live example of exactly the diagnostic distinction ("is the box even
  on the network" vs "is sshd answering") this button exists to provide.
  Reverted the temporary debug hook afterward -- confirmed via
  `grep -rn debug` across every `.qml` file coming back empty.

**xfreerdp3 now forced to NTLM-only (2026-09-12)** -- see the updated
"stock krb5.conf" entry above for the full root-cause story (a SECOND
real bookmark, Sequoia, hit a live "RDP opens then closes" symptom that
turned out to be the SAME Kerberos-then-NTLM-fallback dance RedOak
already had, just with worse DNS-lookup timing on one attempt). Fix:
`/auth-pkg-list:none,ntlm` added to `launchRemoteDesktop`'s args,
unconditionally for every RDP launch. Verified via three separate manual
`nohup`+`/log-level:INFO` runs against the real host (no flag: Kerberos
error then eventual NTLM connect; `/auth-pkg-list:!kerberos`: did NOT
actually suppress the Kerberos attempt, same error still appeared --
`/auth-pkg-list:none,ntlm` is the form that actually works) plus one
final run through a temporary `debugLaunchRDP(alias)` hook calling the
real, already-fixed `root.launchRemoteDesktop` with Sequoia's actual
bookmark fields -- confirmed via `pgrep`/`ps`/`hyprctl clients` that the
real shipped code path now connects in under a second with zero
Kerberos-related log lines. Hook reverted afterward.

**Status probe now protocol-aware (2026-09-12)** -- reported live:
Sequoia (RDP-only, confirmed zero response on port 22 via a direct
`/dev/tcp` connect test -- not refused, just silent, consistent with no
OpenSSH Server installed) stayed permanently red/"down" despite RDP
working fine and Ping succeeding, because `_runTcpProbe` always tested
the SSH port for an "SSH-" banner regardless of the bookmark's actual
primary protocol. Fixed: `_runTcpProbe` now looks up the alias's
bookmark and, if `protocol === "rdp"`, probes `rdpPort` with a plain
TCP-connect-succeeds check instead of the SSH banner grab (RDP's binary
handshake has no readable text banner to inspect the way SSH's
"SSH-2.0-..." string does -- parsing a real RDP negotiation response
just for a status dot would be real complexity for little practical
gain, so this deliberately accepts the same simplification this file's
own header comment describes as the original pre-banner SSH design,
justified here by the RDP port being a much less commonly
squatted/multiplexed port than SSH's). `host.port` (the SSH port) is
completely untouched by this -- it's still written into ~/.ssh/config
unconditionally regardless of protocol, so Connect/Browse/the
~/.ssh/config Host block are all unaffected; only the status-dot PROBE
itself branches. `bannerProbeComponent`'s Process gained an `isRdpProbe`
bool threaded through to `_applyBannerResult`, which now only requires
`exitCode === 0` (no banner match) when `isRdpProbe` is true. Verified
live: opened the popup after this change and confirmed via screenshot
that both Sequoia AND RedOak (the plugin's only two `protocol: "rdp"`
bookmarks) now show green, matching their actual RDP reachability,
while every SSH-protocol bookmark's dot is unaffected.

**RESOLVED: RDP black-screen-with-cursor-only on Sequoia (2026-09-12)** --
follow-up to the NTLM fix above, which turned out NOT to be this
symptom's actual cause. Real sequence of what happened, recorded in full
since it's a good example of chasing the wrong lead first:
- The NTLM fix was real and worth keeping (removes a genuinely wasted,
  DNS-latency-dependent Kerberos attempt on every connection), but it did
  NOT fix the actual reported problem -- after shipping it, the user
  reported the RDP window still showed nothing.
- First wrong lead: assumed the earlier "opens then closes" description
  meant the process/window was dying on its own. Live testing (`ps`,
  `hyprctl clients`, both through manual `nohup` runs AND through a
  temporary `debugLaunchRDP` hook calling the real `launchRemoteDesktop`)
  repeatedly showed the process staying alive and "connected" for
  30+ seconds without self-terminating -- the user then clarified THEY
  were the one closing it each time, assuming a black window meant
  failure. Important process lesson: `hyprctl clients` showing a mapped,
  "connected" window is NOT the same as confirming anything is actually
  RENDERING inside it -- this file's own screenshot tool consistently
  came back 100% solid black for this specific window even when a human
  looking at the real screen saw partial content (a bordered window, dim
  wallpaper bleed-through), meaning the screenshot tool could not be
  trusted to verify this window's content at all. Don't repeat this
  mistake -- for a window whose content matters, get the user's own eyes
  on it rather than trusting an automated screenshot that might be
  silently failing to capture it.
- Second wrong lead: given the user mentioned Sequoia has three physical
  monitors (a 4K center + two mismatched 2K sides), hypothesized a
  resolution-negotiation mismatch against `+f`/`/dynamic-resolution`
  (which requests a resolution matching the LOCAL 3000x2000 display).
  Tested by temporarily swapping to a fixed, completely standard
  `/w:1920 /h:1080` and having the user check the real button --
  identical black screen. Ruled out cleanly: reverted immediately.
- **Actual cause, found via one more precise detail from the user**: "I
  can see the mouse cursor, complete with the Windows loading animation
  (spinning circle), but nothing else renders." A persistent BUSY/LOADING
  cursor (not just a static arrow) that never resolves is the specific,
  well-documented signature of a Windows Remote Desktop Session Host
  trying (and hanging) to hand off session rendering to a discrete GPU
  for hardware acceleration -- the RDP cursor channel is independent of
  the desktop-image compositing path, so it keeps working (and keeps
  showing Windows' own "I'm busy" cursor state) even while the actual
  desktop bitmap never gets delivered. This is a SERVER-SIDE Windows/GPU
  driver issue, not anything under this plugin's or xfreerdp3's control
  from the client side -- explains why RedOak (presumably no discrete
  GPU driving physical monitors) never hit this while Sequoia (three real
  monitors, almost certainly a dGPU) did every time, and why no client
  flag combination (NTLM forcing, fixed resolution, `-gfx`) ever changed
  the outcome, since none of them touch server-side session rendering.
- **Confirmed fixed** by the user directly on Sequoia (Windows 11 Pro):
  `gpedit.msc` → Computer Configuration → Administrative Templates →
  Windows Components → Remote Desktop Services → Remote Desktop Session
  Host → Remote Session Environment → "Use hardware graphics adapters for
  all Remote Desktop Services sessions" → Disabled, then reboot. (Home
  edition equivalent, untested but standard: same setting via the
  `fEnableWddmDriver` DWORD under
  `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp`.)
  No plugin code change was the actual fix here -- documented in
  README.md's own new "Remote Desktop (RDP)" section (with a
  Troubleshooting subsection) rather than only here, since this is
  something a future user could easily hit again on their own hardware
  and would look for in the user-facing docs, not this dev-only file.

**Audio redirection added (2026-09-12)** -- reported live immediately
after the GPU fix above: video played fine once rendering was unblocked,
but with zero audio. Root cause: `launchRemoteDesktop` never passed any
sound-related flag at all, so the RDPSND audio-redirection channel was
never requested in the first place -- not a bug in any negotiation, just
a missing flag. Fixed: bare `/sound` (no sub-options) added to the args,
letting xfreerdp3 auto-probe for a working local backend rather than
this plugin hardcoding one. Confirmed via `ldd $(which xfreerdp3) | grep
pulse` that this build is linked against libpulse, and `pactl info`
that a working PulseAudio-compatible server (PipeWire's pulse layer) is
actually running on this machine -- so the backend `/sound` needs is
present. No error/warning lines appeared for `/sound` in a manual
`/log-level:INFO` test run. Actual audio output itself needs the user's
own ears to confirm (not something this file's tooling can verify) --
pending live confirmation. **Confirmed working live** by the user on
both RedOak and Sequoia.

**Panel widened again, 510 -> 570 (2026-09-12)** -- same three spots as
the earlier 460->510 widening (`HostList.qml` width, `BarWidget.qml`'s
`contentWidth`, `HostRow.qml`'s unused fallback width), prompted by the
Ping button pushing the row back to feeling crowded. Verified via
screenshot -- all four buttons (Ping/Connect/RDP/Wake) plus edit/delete/
browse icons have comfortable spacing with room to spare.

**Ungrouped "Bookmarks" section made collapsible (2026-09-12)**,
completing what F1 deliberately left out (its own comment called
ungrouped "never collapsible... has no name to show collapsed"). Turned
out to be a very small change: `groupSection.isCollapsed` and
`flatRows`' own equivalent check both had a `group.name !== "" &&` guard
specifically excluding the ungrouped section from the SAME
`collapsedGroups` list every named group already uses -- removing that
guard is the whole fix, since `""` is already a safe, unambiguous
sentinel value in that list (a real group name can never actually BE ""
-- `groupField` is trimmed, and an empty value is exactly what routes a
bookmark into the ungrouped section to begin with, per
`groupedBookmarks`'s own logic). No new SettingsStore field needed,
unlike `collapsedConfigHosts` (that one needed a dedicated bool since
there's only ever one config-hosts section, not a name-keyed list of
them). Also: the header's ▸/▾ arrow prefix and its MouseArea's
`enabled:` were both previously gated on `name !== ""` too (only named
groups got an arrow or a clickable header at all) -- removed both
gates so the ungrouped header now always shows an arrow and always
toggles. "+ Add" and "No bookmarks yet." keep their own independent
visibility rules (+Add always shown regardless of collapse state,
deliberately -- collapsing is a display convenience, not a way to block
adding a new bookmark; "No bookmarks yet." now also hides while
collapsed, matching the config-hosts section's identical treatment of
its own "No hosts found" message). Verified live via a temporary
`debugToggleUngroupedCollapse` IPC hook (toggling `""` in and out of
`collapsedGroups` directly, since real click simulation is still
unavailable in this environment) -- confirmed via screenshot that
collapsing hides Sequoia's row while keeping "+ Add" visible and shows
`▸ Bookmarks (1)`, and that toggling back shows `▾ Bookmarks (1)` with
the row restored. Hook reverted afterward.

**`openssh` availability check + warning banner added (2026-09-12)** --
prompted by a direct question about this plugin's real dependency
footprint on a fresh Omarchy install. Investigated by reading
`/usr/share/omarchy/install/omarchy-base.packages` and
`omarchy-other.packages` directly (the actual manifests Omarchy's own
installer pacstraps from) rather than assuming from what's installed on
this already-customized dev machine -- found `nautilus` IS in the base
list (Browse works out of the box, contrary to an earlier assumption),
`iputils`/`procps-ng`/`which`/coreutils are all guaranteed via the
`base`/`base-devel` meta-packages Omarchy always installs (confirmed via
`pacman -Si base`'s own Depends On list, plus `-Si which`'s "Required
By: base-devel"), but **`openssh` is in neither list, and isn't a
dependency of anything else Omarchy installs either** (checked via
`pacman -Si openssh`'s own "Required By" list -- git doesn't depend on
it, nor does anything else in the base set). This is a real, previously
unaddressed gap: every OTHER optional tool in this file
(wakeonlan/nautilus/sshpass/xfreerdp3) already has a `which`-based
availability check gating its one feature, but `ssh` itself never did,
despite being the plugin's entire core function.
- Fixed with the exact same pattern as the other three (`opensshAvailable`
  bool, `opensshCheckProc`, `_checkOpenssh()`, wired into
  `Component.onCompleted` and `onOpenedChanged`) -- but surfaced
  differently in `HostList.qml`: not a dimmed button (there's no single
  button to dim -- missing `ssh` means `_resolveAlias`'s `ssh -G` never
  even starts, so `host.hostname` never populates, so `_runTcpProbe`'s
  own `if (!host.hostname) return` guard silently skips every single
  host, forever, with zero indication anywhere why). Instead, a
  Color.urgent-bordered banner Rectangle at the very top of the popup
  (above Settings, above Bookmarks) -- unmissable, and explains exactly
  what's wrong and the fix (`sudo pacman -S openssh`) rather than leaving
  a wall of permanently-grey "checking" dots to puzzle over.
- Verified live: confirmed the normal case (ssh actually installed) shows
  no banner via screenshot; then, since ssh genuinely can't be
  uninstalled from this dev machine without breaking everything else,
  used a temporary `debugForceSshMissing()` IPC hook to set
  `opensshAvailable = false` directly (timed carefully -- called only
  AFTER the popup's own real `_checkOpenssh()` call from `onOpenedChanged`
  had already completed and set it back to `true`, since nothing else
  re-triggers that check while the popup stays open) and confirmed via a
  second screenshot that the banner renders correctly, full text visible,
  correctly styled. Hook reverted afterward.
- Documented comprehensively in a new README.md "Requirements" section
  (a table of every tool this plugin ever shells out to, whether it's in
  Omarchy's base install, and the exact install command for whichever
  aren't) -- this belongs in the user-facing doc, not just here, since
  it's the kind of thing someone evaluating or troubleshooting the
  plugin would actually go looking for.

**SECURITY FIX: command injection in `_runTcpProbe`'s bash -c strings
(2026-09-12)**, found during a pre-marketplace-submission audit modeled
directly on the review findings that stalled `omarchy-linecast`'s own
submission (see that plugin's marketplace memory/notes -- subprocess
safety was one of its actual blocking rounds). Both the SSH-banner and
RDP branches built their `bash -c` script via plain string concatenation
(`"exec 3<>/dev/tcp/" + host.hostname + "/" + host.port + " && ..."`).
`host.hostname`/`host.port` for a BOOKMARK are charset-restricted
(`BookmarkStore._hostRe`), so not exploitable through the plugin's own
UI -- but a PLAIN (non-bookmark) `~/.ssh/config` host's hostname/port come
straight from `ssh -G`'s raw resolved output via `parseResolvedConfig`'s
regex, which only excludes whitespace, not shell metacharacters. A
realistic path to an attacker-controlled `HostName`/`Port` value existing
in a real user's `~/.ssh/config` is a compromised or malicious dotfiles
sync, not just a self-inflicted hand-edit -- exactly the kind of
"trusted input turns out not to always be trusted" finding a marketplace
security reviewer would flag on principle, string-concat-into-a-shell
regardless of current reachability.
- Fixed by passing `host.hostname`/port as bash POSITIONAL PARAMETERS
  (`bash -c 'script using "$1"/"$2"' _ hostval portval`) instead of
  splicing them into the script string -- bash performs ordinary
  parameter expansion on `"$1"`/`"$2"`, substituting the literal VALUE
  without re-parsing it as code, so even a value containing
  `$(...)`/backticks/`;` lands as inert text.
- Verified the fix does what it's supposed to, both directions: (1) a
  normal real hostname/port still connects exactly as before -- opened
  the popup after the fix and confirmed every real bookmark's status dot
  still resolves correctly (all green); (2) a deliberately malicious test
  value (`127.0.0.1; touch .../pwned_marker #`) run through the exact
  same positional-parameter pattern via a manual `bash -c` reproduction
  does NOT execute the injected `touch` -- confirmed the marker file was
  never created, and the attempt instead fails as an invalid `/dev/tcp/`
  target (the same failure mode a harmless typo would produce), both
  before writing the real fix and re-confirmed by reasoning through
  bash's own parameter-expansion semantics (a parameter's substituted
  value is never re-scanned for further expansion/execution).
- Broader audit performed at the same time, all clean: grepped for every
  other `bash -c`/`eval`/`Function(` use in the codebase (none found
  beyond these two, now-fixed spots); confirmed no `sudo`/`pkexec`/`doas`
  anywhere in the plugin's own code (the one `sudo` string in the whole
  codebase is user-facing instructional text in the openssh-missing
  banner, telling the USER to run it themselves); confirmed every
  `~/.ssh/config` CONTENT write is tied to an explicit user action
  (Add/Edit/Delete a bookmark, Rename/Delete a plain host) with a
  one-time pre-write backup plus rolling per-write backups, never a
  silent/unprompted overwrite; confirmed the real Windows password shared
  earlier this session for live debugging never made it into git history
  at any point (`git log --all -p | grep <password>` came back empty --
  it only ever lived in `~/.config/uplink/bookmarks.json`, outside the
  git-tracked plugin directory entirely, exactly as designed).

**SSH `User` field now allows `@` (2026-09-12)** -- reported live: Browse
(SFTP) on RedOak prompted "Enter password for gh0st on 192.168.1.22"
instead of asking for the real Windows account. Root cause: `sftpUri`
builds its `userPart` from the bookmark's SSH `user` field, which was
blank -- not an oversight in the sftpUri logic itself, but because
`_userRe` (`^[A-Za-z0-9._-]+$`) had no way to ever ACCEPT
"j.m.thomas@comcast.net" in the first place, so the field could only ever
be saved empty for this bookmark. First checked whether this was even
worth fixing (SFTP is fundamentally SSH-dependent, and RedOak's primary
protocol is RDP) by re-running this file's own banner-probe technique
by hand against 192.168.1.22:22 -- confirmed a genuine, real
`SSH-2.0-OpenSSH_for_Windows_9.5` server, not just RDP, so a correct SSH
`User` value really would make Browse work, not just relocate the same
dead end. Fixed by adding `@` to `_userRe` (now
`^[A-Za-z0-9._@-]+$`) -- still excludes spaces/newlines (would break
`~/.ssh/config`'s single-token `User` line), but a UPN-style Microsoft-
account login is otherwise completely inert in that context, no
injection surface added. This is the same accommodation `rdpUser` was
already given for the exact same underlying reason (a real Windows
account isn't shaped like a POSIX username) -- it just hadn't been
extended to the SSH `user` field itself until this real bookmark
happened to need both fields correctly populated at once.
- Verified live end-to-end via a temporary `debugSetSshUser(alias, user)`
  hook calling the real `bookmarkStore.updateBookmark` (passing every
  existing field explicitly, not just `user`, so `rdpPassword` etc. don't
  get silently defaulted away by `_fieldsToBookmark`'s own missing-field
  defaults): confirmed `""` (success) returned, confirmed both
  `bookmarks.json` and the live `~/.ssh/config` `Host RedOak` block's
  `User` line updated to `j.m.thomas@comcast.net`, and confirmed by hand
  that the resulting `sftpUri` correctly URL-encodes to
  `sftp://j.m.thomas%40comcast.net@192.168.1.22/` (the `@` inside the
  username percent-encoded so it can't be confused with the URI's own
  user@host delimiter). Actually opening Browse and confirming the
  credential prompt now asks for the right account needs the user's own
  follow-up click. Hook reverted afterward.

**Port fields showed a thousands-separator comma (2026-09-12)** --
reported live: RDP Port defaulted to "3,389" in the edit form. Root
cause is Qt Quick Controls' own `SpinBox` default `textFromValue`
(`Number(value).toLocaleString(locale, 'f', 0)`), which locale-formats
with grouping separators for any value >= 1000 -- SSH Port's own default
(22) never showed it only because it's under 1000, not because it was
actually unaffected; a custom SSH port >= 1000 would have shown the
identical bug. The shared `NumberField` component (`qs.Ui`) that both
Port fields use doesn't override this, and it isn't this plugin's own
file to edit -- it lives in `/usr/share/omarchy/shell/Ui/NumberField.qml`,
outside this repo entirely. Fixed from within `BookmarkForm.qml` instead:
`NumberField` exposes its underlying `SpinBox` via a `field` alias
(already used for `field.Keys.onReturnPressed`), and `textFromValue`/
`valueFromText` are ordinary function-valued properties on that SpinBox,
overridable via the same grouped-property syntax
(`field.textFromValue: function(value, locale) { ... }`) without
touching the shared component's file at all. New implementation just
does plain `String(value)` (no locale formatting at all -- a port number
is never a "quantity" that benefits from digit grouping) and a
comma-stripping `parseInt` for the reverse direction, applied to both
`portField` and `rdpPortField` identically. Verified: `omarchy plugin
validate` clean; the exact function bodies confirmed via `node -e`
outside the plugin (`textFromValue(3389)` -> `"3389"`,
`valueFromText("3,389")` -> `3389`, still handles a value someone pastes
in with a stray comma); the SSH Port field's own screenshot showed a
clean "22" post-fix (already true before too, since it's under 1000 --
included for completeness, not proof on its own). The RDP Port field's
own rendered text wasn't independently reconfirmed via screenshot after
attaching the same override (the popup's scroll position made it awkward
to frame in this pass, and it's the identical function object on an
identical component instance) -- if it still shows a comma in practice,
that would mean the grouped-property override itself isn't taking
effect, not that the fix logic is wrong, and should be reported back.
**Confirmed fixed** by the user directly (no comma on either field).

**"Connect" button relabeled to "SSH" (2026-09-12)** -- purely a label
change (`HostRow.qml`'s button `Text`, plus every README mention that
names the button specifically), requested for clarity now that the row
has three protocol-specific action buttons (Ping/SSH/RDP) instead of one
generic "Connect" -- disambiguates which protocol each button actually
uses at a glance. No signal/function/id renamed (`connectRequested`,
`connectToHost`, `connectButton`/`connectArea` all untouched) -- this is
UI text only, not a behavior or API change, so renaming the internal
plumbing to match would have been unnecessary churn. README's own
"Connect via" wording (the SSH/RDP protocol selector in the add/edit
form) is a DIFFERENT UI element and was deliberately left alone -- only
updated the mentions that name the row's own action button. Verified
live via screenshot: button reads "SSH", correctly positioned between
Ping and RDP.

**Wake-on-LAN removed entirely (2026-09-12)**, `mac` bookmark field
included -- while setting up to test it, found `wakeonlan` wasn't even
installed on this machine and no bookmark had a MAC address set, so a
real test needed installing yet another optional dependency just to
exercise a feature nobody had actually used yet. Decided to drop it
rather than chase that setup, keeping the plugin's dependency footprint
smaller. Removed completely, not just hidden, matching this plugin's own
established practice (see the earlier uptime-probe removal entry above)
of not leaving dead code/fields behind once a feature's gone:
- `BarWidget.qml`: the whole "Wake-on-LAN" section
  (`wakeonlanAvailable`, `wakeonlanCheckProc`, `_checkWakeonlan()`,
  `wakeProcComponent`, `wakeHost(mac)`), its `Component.onCompleted`/
  `onOpenedChanged` wiring, and the `HostList` property/signal wiring.
- `HostList.qml`: `wakeonlanAvailable` property, `wakeRequested` signal,
  `mac` out of `_displayHostForBookmark`'s merge, the delegate wiring,
  and `initialMac` off the `BookmarkForm` instantiation.
- `HostRow.qml`: `wakeonlanAvailable` property, `wakeRequested` signal,
  `showWake`, and the entire `wakeButton` Rectangle -- buttonRow now
  ends at RDP.
- `BookmarkStore.qml`: `mac` out of the bookmark shape entirely
  (`_normalizeBookmark`, `_fieldsToBookmark`, `validateFields`), plus the
  now-unused `_macRe` regex.
- `BookmarkForm.qml`: `initialMac` prop, the `macField` TextField (was
  the first item under "▸ Advanced", which now holds only Notes),
  `_loadFields`/`_submit`'s own references to it, and the
  `advancedOpen` auto-expand check (now keyed on notes alone).
- `README.md`: the Wake-on-LAN feature bullet, its `wakeonlan`
  Requirements-table row, its mention in the one-shot install command,
  and the MAC-address bookmark-field bullet.
- Existing bookmarks with a leftover `mac: ""` key in `bookmarks.json`
  (all of them, in practice, since it was always empty) are left as-is
  rather than proactively rewritten -- harmless dead data that
  self-corrects the next time each bookmark is normally saved again
  (`_fieldsToBookmark` no longer emits the key at all).
- Verified live: `omarchy plugin validate` clean, no warnings on reload,
  a full `grep -rn -i "wakeonlan|wakeRequested|wakeHost|showWake|\bmac\b"`
  across every `.qml`/`.js` file came back with only two stale prose
  comment mentions (fixed in the same pass, not functional code), popup
  screenshot confirmed no dead gap where the Wake button used to sit
  (buttonRow simply ends one item shorter now), and the edit form opened
  cleanly with no `macField`-related errors. Version bumped to 3.0.0 --
  a removed user-facing feature/field warrants a major bump, unlike the
  incremental additions/fixes this session had been using 2.x.x for.

**Cleanup/bug/perf pass (2026-09-12)** -- a full fresh re-read of every
`.qml` file (the `.js` files hadn't changed since their own earlier
review this session, so skipped), specifically looking for leftover
references from all the churn today (Ping, RDP protocol-awareness, the
openssh check, the SSH `@` allowance, Connect->SSH, Wake-on-LAN removal)
and any real bugs/perf issues, not just a repeat of the earlier
bug-squashing/optimization passes already documented above.
- **Applied (real, measurable waste, now fixed):** `pingHost`/
  `_applyPingResult` both called `_patchHost` to set `pingStatus`, and
  `_patchHost` unconditionally scheduled a debounced `status-cache.json`
  write on every call -- for a field `_saveCache`'s own object literal
  never includes at all. A single Ping click (which always passes through
  "pending" before landing on a real result -- two separate patches)
  could cause two real, pointless disk writes, since a ping's round trip
  is often slower than the 500ms save-debounce window, so the two patches
  don't collapse into one write. Fixed by adding a `skipSave` third
  argument to `_patchHost`, passed `true` from both ping call sites.
  Verified live: recorded `status-cache.json`'s mtime, triggered a real
  ping via a temporary `debugPing(alias)` hook, confirmed the mtime was
  IDENTICAL afterward (first attempt caught residual restart-probe
  activity as a false positive -- redid it after letting the shell fully
  settle first, which is the correct control).
- **Applied (stale/inaccurate comments, not functional bugs):**
  - `HostRow.qml` had two leftover comments still naming "Wake" among a
    list of buttons/write-actions after its removal.
  - `BarWidget.qml`'s top-of-file `hosts` shape comment was still
    describing the removed two-stage Stage-A/uptime probe design AND
    claiming `up` always means "a real SSH banner was seen" -- both wrong
    since the RDP-protocol-aware probe change; also never listed
    `source`/`configMissing`/`connected`/`pingStatus` at all. Rewritten to
    describe the actual current single-probe, protocol-aware design and
    the full field list.
  - `README.md` had SUBSTANTIAL uptime-feature documentation left over
    from before that feature was removed several turns ago in this same
    session -- a whole Features bullet, a whole numbered step in "How it
    works" describing the non-interactive `ssh ... uptime` probe that no
    longer exists, and three smaller inline mentions. This had been
    noticed and deliberately deferred earlier (out of scope for the turn
    that removed the feature) -- this cleanup-focused round was the
    right moment to finally fix it. Rewrote "How it works" to describe
    the actual current probe (one stage, protocol-aware: SSH banner vs.
    RDP plain-TCP) instead of the removed two-stage design.
- **Checked, found clean (no changes needed):** `HostList.qml`,
  `BookmarkForm.qml`, `BookmarkStore.qml`, `SettingsStore.qml`,
  `SettingsPanel.qml`, `ExportImportPanel.qml`,
  `ConfigHostRenameForm.qml` -- re-read in full, no dead code, no stale
  comments, no logic bugs found. Specifically checked and confirmed
  correct: a `configMissing` bookmark row still gets `protocol`/
  `rdpPort`/`rdpUser`/`rdpPassword`/`favorite` correctly via
  `HostList._displayHostForBookmark`'s merge (which always overlays the
  bookmark's own JSON fields regardless of the underlying `hosts` entry's
  own state), so Ping/RDP/favorite all stay fully functional on a
  configMissing row, matching the existing SSH-only gating
  (`connectApplicable`) -- not a new finding, just re-verified after the
  RDP-protocol-probe and Ping additions to make sure neither had
  silently broken that invariant.
- Version bumped to 3.0.1 (cleanup/perf, no user-facing feature change).
