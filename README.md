# Uplink for Omarchy

Live reachability, uptime, and one-click terminal launch for every host in
your `~/.ssh/config` -- right from the bar. Save your own bookmarked
connections too, right alongside them.

## Features

- **Reads your real `~/.ssh/config`.** No separate host list to maintain --
  every non-wildcard `Host` entry shows up automatically, resolved through
  `ssh -G` itself so `Include`, `Match`, and your own defaults all apply
  exactly as a manual `ssh <alias>` would.
- **Bookmark a connection by label + host/IP** -- click "+ Add" under
  Bookmarks, give it a name and a host, and it shows up immediately with
  the same live status dot, uptime, and Connect button as everything else.
  Edit or delete any bookmark you've added from its row.
- **A status dot per host** -- grey while checking, green as soon as a real
  SSH server answers (checked via its own protocol banner, no login
  required, so this is accurate whether the host uses password or key
  auth), red when it's unreachable.
- **Live uptime, when this machine has passwordless key access** -- fetched
  non-interactively, never blocks or hangs on a password prompt. A host
  that needs a password just shows "--" for uptime instead of freezing the
  UI or dragging the status dot down -- the dot only ever reflects whether
  SSH itself is actually up.
- **One-click connect** -- opens a real terminal already running
  `ssh <alias>`, using whatever terminal you've actually got configured.
- **Bar icon alerts** the instant any host goes down, even with the popup
  closed -- with a small count badge showing how many.
- **Live latency**, in ms, measured off the same banner probe that drives
  the status dot -- no extra connection needed.
- **Bookmark groups, notes, and an emoji icon per host** -- organize
  bookmarks by group (with autocomplete chips for groups you've already
  used), leave yourself a note on any host, and pin a quick visual glyph
  next to its name.
- **A "currently connected" indicator** -- shows when a host has a live
  `ssh` session open, whether you started it from this widget's Connect
  button or a terminal you opened by hand.
- **Wake-on-LAN** -- save a MAC address on a bookmark and wake a sleeping
  host with one click (needs `wakeonlan` installed; the button just won't
  show if it isn't).
- **Export/import your bookmarks** as a plain JSON file.
- **Configurable probe cadence and a compact row mode**, both in a small
  in-popup settings panel.
- **Theme-native** status colors, matching the active Omarchy theme's own
  palette.
- **Bar-aware popup placement**, matching how native Omarchy plugins behave:
  centered on screen if the icon sits in the center of the bar, edge-aligned
  if it's been moved to the left or right section.

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
  dot, resolved `user@hostname:port`, and last-known uptime.
- **Click Connect** on any host to open a terminal already running
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
- **MAC address** (under "▸ Advanced" in the form) enables the Wake button
  for that host once it's down -- requires `wakeonlan` installed
  (`sudo pacman -S wakeonlan`); the button simply doesn't appear otherwise.

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

Each host is probed in two stages:

1. **An SSH banner grab** against the host's resolved hostname/port
   (`timeout N bash -c 'exec 3<>/dev/tcp/<host>/<port> && dd bs=64 count=1 <&3'`),
   checking the response starts with `SSH-`. No authentication attempted --
   every SSH server sends this identification string immediately on
   connect, before any login happens (RFC 4253), so this confirms a real
   sshd is actually listening regardless of how you'd authenticate to it.
   The round-trip time of this same probe is what the latency column shows.
   Cheap enough to run every 60 seconds even with the popup closed; this
   alone drives the status dot and the bar icon's alert state.
2. **A non-interactive `ssh ... uptime`** (`-o BatchMode=yes`), only
   attempted once the banner is confirmed and only while the popup is open.
   `BatchMode=yes` is what keeps this from ever hanging on a password
   prompt -- a host that needs one just fails fast, leaving uptime at "--".
   This no longer affects the status dot at all -- a password-only host
   (no passwordless key from this machine) shows green just like a
   key-auth one, it simply won't have a live uptime line.

The "currently connected" indicator works differently -- while the popup
is open, one `pgrep` call per tick lists every running `ssh` process, and
each host's alias is matched against it as an exact word, not a substring
(so a host named `db` can never light up just because `db-replica` is
connected) -- this is also why it catches a session you started by hand in
a plain terminal, not only one launched via this widget's own Connect
button.

Both `ssh` and the banner probe are trusted system binaries invoked
directly -- no wrapper, no bundled dependency.

**A known limitation:** hosts defined only inside a file reached via an
`Include` directive (rather than directly in `~/.ssh/config` itself) aren't
enumerated by this plugin's host list yet -- a small note appears in the
popup when this applies. Everything else about how a host resolves (the
Include'd file's own settings) still applies correctly once a host *is*
listed, since resolution itself goes through `ssh -G`.

## License

[MIT](LICENSE)
