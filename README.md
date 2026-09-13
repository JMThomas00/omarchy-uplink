# Uplink for Omarchy

Live reachability and one-click SSH/RDP launch for every host in your
`~/.ssh/config` -- right from the bar. Save your own bookmarked
connections too, right alongside them.

## Features

- **Reads your real `~/.ssh/config`.** No separate host list to maintain --
  every non-wildcard `Host` entry shows up automatically, resolved through
  `ssh -G` itself so `Include`, `Match`, and your own defaults all apply
  exactly as a manual `ssh <alias>` would.
- **Bookmark a connection by label + host/IP** -- click "+ Add" under
  Bookmarks, give it a name and a host, and it shows up immediately with
  the same live status dot and SSH button as everything else. Edit or
  delete any bookmark you've added from its row.
- **A status dot per host** -- grey while checking, green as soon as it's
  reachable, red when it's not. For an SSH-primary host this checks the
  real SSH protocol banner (no login required, so it's accurate whether
  the host uses password or key auth); for an RDP-primary bookmark it
  checks the RDP port instead, since a Windows RDP-only box may not run
  SSH at all.
- **One-click connect** -- opens a real terminal already running
  `ssh <alias>`, using whatever terminal you've actually got configured.
- **Browse files** -- a small 📁 button opens the host's filesystem in
  GNOME Files over SFTP, reusing the same SSH access (no extra password
  prompt beyond what SSH itself needs). Needs `nautilus` installed; the
  button just doesn't appear otherwise.
- **Bar icon alerts** the instant any host goes down, even with the popup
  closed -- with a small count badge showing how many.
- **Live latency**, in ms, measured off the same banner probe that drives
  the status dot -- no extra connection needed.
- **Bookmark groups, notes, and an emoji icon per host** -- organize
  bookmarks by group (with autocomplete chips for groups you've already
  used), leave yourself a note on any host, and pin a quick visual glyph
  next to its name.
- **A "currently connected" indicator** -- shows when a host has a live
  `ssh` session open, whether you started it from this widget's SSH
  button or a terminal you opened by hand.
- **Ping** -- a one-click ICMP reachability check, separate from the SSH
  status dot. Useful for a host that's on the network but doesn't run SSH
  (a Windows RDP-only box, for instance) -- the result (round-trip time,
  or "timeout") shows right in the button for a few seconds.
- **Remote Desktop (RDP)**, via `xfreerdp3` -- set a bookmark's protocol to
  RDP and an "RDP" button appears next to SSH. Needs `freerdp`
  installed (`sudo pacman -S freerdp`); the button just doesn't appear
  otherwise. See its own section below.
- **Export/import your bookmarks** as a plain JSON file.
- **Configurable probe cadence and a compact row mode**, both in a small
  in-popup settings panel.
- **Theme-native** status colors, matching the active Omarchy theme's own
  palette.
- **Bar-aware popup placement**, matching how native Omarchy plugins behave:
  centered on screen if the icon sits in the center of the bar, edge-aligned
  if it's been moved to the left or right section.

## Requirements

Everything below except `openssh` is either already part of a stock
Omarchy install or a fully optional integration this plugin detects on
its own -- the corresponding button/feature simply doesn't appear if the
tool it needs isn't installed, with one deliberate exception (see below).

| Tool | Needed for | On a stock Omarchy install? |
|---|---|---|
| `openssh` (`ssh`) | Everything -- this is the plugin's core feature | **Not included by default.** Not in Omarchy's own base package list, and nothing else Omarchy installs pulls it in either. Install with `sudo pacman -S openssh`. |
| `nautilus` | Browse (SFTP) button | Yes -- ships with Omarchy already. |
| `sshpass` | Non-interactive login for a bookmark with a stored SSH password (optional even among optional features -- SSH still works without it, just prompts interactively) | No -- `sudo pacman -S sshpass` |
| `freerdp` (provides `xfreerdp3`) | RDP button, and its audio/video | No -- `sudo pacman -S freerdp` |

Get every feature working in one shot (`nautilus` is included too, in
case you're on a non-stock setup that's missing it):

```bash
sudo pacman -S --needed openssh sshpass freerdp nautilus
```

**The `openssh` exception:** every other tool above degrades gracefully
-- its one feature is simply unavailable, dimmed, or hidden, with
everything else working normally. `openssh` doesn't get that treatment,
since it's not "one feature" but the plugin's entire reason to exist --
instead, a clear red banner appears at the top of the popup if it's
missing ("openssh not found..."), rather than silently leaving every
host stuck on "checking" forever with no visible explanation.

## Installation

```bash
omarchy plugin add https://github.com/JMThomas00/omarchy-uplink.git --enable
```

Or manually:

```bash
git clone https://github.com/JMThomas00/omarchy-uplink.git \
  ~/.config/omarchy/plugins/uplink
omarchy plugin enable jmthomas00.uplink center
```

Move it around the bar with `omarchy bar move jmthomas00.uplink --section <left|center|right>`.

## Removal

```bash
omarchy plugin remove jmthomas00.uplink
```

Or manually:

```bash
omarchy plugin disable jmthomas00.uplink
rm -rf ~/.config/omarchy/plugins/uplink
```

This plugin's own cache of last-known host status
(`~/.local/state/uplink/`), your saved bookmarks and settings
(`~/.config/uplink/bookmarks.json`, `~/.config/uplink/settings.json`)
all live outside the plugin directory, so `rm -rf` on the plugin folder
alone won't clean any of it up -- delete it by hand if you uninstall
manually and want a completely clean slate. **Your bookmarks' `Host`
entries in `~/.ssh/config` are NOT removed by uninstalling the plugin** --
they're real config entries at that point, by design (see Bookmarks
below); delete them yourself from `~/.ssh/config` if you no longer want
them, or use each bookmark's delete button before uninstalling.

## Usage

- **Click the icon** to open the dashboard. Every host from
  `~/.ssh/config` is listed under "From ~/.ssh/config", with its status
  dot and resolved `user@hostname:port`.
- **Click SSH** on any host to open a terminal already running
  `ssh <alias>` into it.
- Editing `~/.ssh/config` (adding, removing, or renaming a `Host` entry)
  picks up live -- no restart needed.
- **Rename or delete a "From ~/.ssh/config" entry** with its own pencil/×
  icons, same as a bookmark -- but deliberately more limited: only the
  alias itself is editable this way, since a hand-authored entry can carry
  directives (`IdentityFile`, `ProxyJump`, whatever else you've written)
  this plugin doesn't try to understand or reproduce. Renaming touches
  only the `Host` line; if the entry had no explicit `HostName` (i.e. the
  alias itself was the connection target), one is added automatically so
  the real target is never lost, no matter what you rename it to.
  Everything else in the block -- `IdentityFile`, `Port`, comments, your
  own formatting -- is left completely untouched. A `Host` line that
  defines more than one alias (`Host a b`) is left alone; rename/delete it
  directly in `~/.ssh/config` instead. Deleting uses the same two-click
  "Confirm?" pattern as a bookmark.

### Bookmarks

- **"+ Add"** under Bookmarks opens a small form: a label (becomes the
  `ssh` alias, so keep it a plain name like `Juniper` -- letters, digits,
  `.`, `_`, `-` only), a host/IP, and optionally a port (default 22) and
  user.
- Saving a bookmark writes a real `Host` block into your `~/.ssh/config`,
  clearly marked with `# >>> ssh-dashboard bookmark:... >>>` /
  `# <<< ... <<<` comments (yes, still "ssh-dashboard" -- this plugin's
  original name, kept internally on purpose so bookmarks saved before the
  rename to Uplink keep matching their own block; it's never shown
  anywhere in the UI) so this plugin can find and manage it later without
  touching anything else in the file -- meaning **`ssh Juniper` works from
  any terminal**, not just from this widget.
- The pencil icon on a bookmark's row edits it (including renaming its
  alias); the × requires two clicks (first click arms it -- it turns red
  and its label changes to "Confirm?" so it's obvious a second click is
  needed -- second click within 5 seconds actually deletes) since deleting
  also removes the real `~/.ssh/config` entry.
- The very first time this plugin writes to `~/.ssh/config`, it makes a
  one-time backup at `~/.ssh/config.pre-uplink.bak`.
- If you delete a bookmark's `Host` block by hand (bypassing the plugin),
  its row shows "config entry missing" -- edit and re-save the bookmark
  through the UI to restore it.
- **Group** a bookmark by typing (or clicking a suggestion chip for) a
  group name in the add/edit form -- bookmarks with no group stay under
  the plain "Bookmarks" header, grouped ones get their own labeled
  sub-section, each with a count.
- **Icon** and **Notes** are optional -- the icon (a short emoji) shows
  right next to the host's name; notes stay hidden behind a small 📝
  indicator you click to expand, so the row itself stays compact.

### Remote Desktop (RDP)

- Set a bookmark's **Connect via** to **RDP** in the add/edit form to
  reveal an RDP-specific **Port** (default 3389) and **User** field --
  deliberately separate from the SSH Port/User above, since they're two
  independent services on two different ports by default, and an RDP
  username (a real Windows account, e.g. a Microsoft-account login like
  `you@example.com`) isn't shaped like a valid SSH username.
- **Stored password** (optional, next to RDP User): with one saved, the
  RDP button connects silently in the background -- no terminal window,
  no prompt -- and closes cleanly whenever the session ends (you close
  it, the remote machine shuts down, or the connection drops), since the
  RDP window itself is the only thing that was ever running. Without a
  stored password, it opens in a terminal instead, for an interactive
  Domain/Username/Password prompt.
- **Plaintext storage, by design, not an oversight** -- like the SSH
  password field, a stored RDP password lives in
  `~/.config/uplink/bookmarks.json` as plaintext (permission-hardened to
  `600`, but not encrypted -- anything running as your own user can still
  read it). Only use this if you're comfortable with that tradeoff on
  your own machine. **Export deliberately excludes both password fields
  by default** -- check "Include stored passwords" in Export/Import if
  you actually want them in an exported file, since that file gets
  copied around with none of `bookmarks.json`'s own permission hardening.
- The status dot for an RDP-protocol bookmark checks the **RDP port**,
  not SSH -- so a Windows box with no SSH server at all still shows
  correctly green/red based on whether RDP itself is actually reachable.

#### Troubleshooting: black screen with only a moving cursor

**Symptom:** the RDP window opens and connects (you can move the mouse,
and it may even show a Windows "loading" cursor animation), but the
desktop or login screen itself never renders -- just solid black.

**Cause:** this is a well-known Windows issue on machines with a
discrete/dedicated GPU (NVIDIA or AMD) driving real physical monitors --
confirmed live on exactly this kind of machine (three real monitors, a
mixed 4K/2K setup). Windows tries to hand the Remote Desktop session off
to that same GPU for hardware-accelerated rendering, and on many driver
versions that handoff hangs silently. The cursor still renders because
it's drawn through a separate, independent channel that doesn't depend
on the same GPU compositing path as the desktop image -- which is
exactly why you can see it move (and even see its loading-spinner state)
while everything else stays black.

**Fix** -- on the Windows machine itself (not this plugin), disable
hardware-accelerated rendering for Remote Desktop sessions specifically:

- **Windows 11 Pro/Enterprise/Education:** open `gpedit.msc` →
  Computer Configuration → Administrative Templates → Windows Components
  → Remote Desktop Services → Remote Desktop Session Host → Remote
  Session Environment → set **"Use hardware graphics adapters for all
  Remote Desktop Services sessions"** to **Disabled**. Reboot.
- **Windows 11 Home** (no `gpedit.msc`): the same setting via registry --
  open `regedit`, go to
  `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp`,
  add a new **DWORD (32-bit)** value named `fEnableWddmDriver` set to
  `0`. Reboot.
- Worth updating the GPU driver at the same time -- some driver versions
  have specific known bugs here.

This is a one-time fix per machine; it doesn't need repeating after the
first successful connection.

### Settings

Click the **⚙** icon in the top-right of the popup for:
- Background and popup-open probe intervals (seconds), and a compact-row
  toggle that hides the second line (subtitle, latency, notes indicator)
  for a denser list.
- **Export/Import** (behind its own "▸ Export/Import" expander within
  Settings) -- writes/reads your bookmarks as plain JSON (default path
  `~/uplink-bookmarks-export.json`, editable). Import is additive -- it
  never replaces your existing bookmarks, and reuses the exact same
  validation as adding one by hand, so an imported entry that collides
  with an existing label (or fails validation) is skipped, not fatal to
  the rest of the import; you'll get a one-line summary either way.

## How it works, briefly

Each host gets one lightweight, non-interactive TCP probe -- no auth
attempted, so it works identically regardless of the host's actual login
method:

- **SSH-primary hosts** (the default): a banner grab against the host's
  resolved hostname/port
  (`timeout N bash -c 'exec 3<>/dev/tcp/<host>/<port> && dd bs=64 count=1 <&3'`),
  checking the response starts with `SSH-`. Every SSH server sends this
  identification string immediately on connect, before any login happens
  (RFC 4253), so this confirms a real sshd is actually listening --
  a plain TCP connect alone can't tell that apart from anything else
  answering on the port.
- **RDP-primary bookmarks**: a plain TCP connect to the RDP port instead
  (RDP's binary handshake has no readable banner to check the way SSH's
  does), since a Windows RDP-only box may not run SSH at all.

The round-trip time of this probe is what the latency column shows.
Cheap enough to run every 60 seconds even with the popup closed; this
alone drives the status dot and the bar icon's alert state.

The "currently connected" indicator works differently -- while the popup
is open, one `pgrep` call per tick lists every running `ssh` process, and
each host's alias is matched against it as an exact word, not a substring
(so a host named `db` can never light up just because `db-replica` is
connected) -- this is also why it catches a session you started by hand in
a plain terminal, not only one launched via this widget's own SSH
button.

Both `ssh` and the banner probe are trusted system binaries invoked
directly -- no wrapper, no bundled dependency.

**A known limitation:** hosts defined only inside a file reached via an
`Include` directive (rather than directly in `~/.ssh/config` itself) aren't
enumerated by this plugin's host list yet -- a small note appears in the
popup when this applies. Everything else about how a host resolves (the
Include'd file's own settings) still applies correctly once a host *is*
listed, since resolution itself goes through `ssh -G`.

**Another:** Browse only works against a host whose `sshd` actually offers
the SFTP subsystem -- a restricted, command-only SSH endpoint (this
plugin's own `git.lab.t-share.cc` example entry, a Forgejo instance's
embedded git-only server, is a real one) will authenticate fine but then
refuse the SFTP request itself; GNOME Files shows this as its own "don't
have permission to access the requested location" error. Nothing this
plugin can do about that -- it's the remote server's own restriction.

## License

[MIT](LICENSE)
