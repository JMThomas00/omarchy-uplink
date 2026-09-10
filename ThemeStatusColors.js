.pragma library

// Maps this plugin's status states onto the active Omarchy theme's real
// named hues -- confirmed (see the plan doc / Waveform's ThemePaletteGen.js)
// that every shipped theme's colors.toml uses a named ANSI-style key set
// (red/green/yellow/... ), never a numeric color0..15 scheme, and that the
// shell's own live Color singleton only exposes foreground/background/
// accent/urgent/muted -- no hue keys -- so a status dot genuinely needs this
// separate file-level read, same as Waveform's per-channel palette does.
//
// Same line-matching approach as Color.qml's own loadColors / Waveform's
// ThemePaletteGen.extractByKeys.
function extractHexByKey(raw) {
  var found = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (!m) continue
    found[m[1]] = m[2]
  }
  return found
}

// Returns { up, down, checking } hex strings (or null for any key not found
// in this theme -- BarWidget.qml falls back to a Color.* palette role for
// anything null, same fallback discipline Waveform uses when its own theme
// read comes back sparse).
function statusColors(raw) {
  var found = extractHexByKey(raw)
  return {
    up: found.green || null,
    down: found.red || null,
    checking: found.muted || null
  }
}
