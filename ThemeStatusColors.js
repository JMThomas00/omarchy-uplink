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

function _hexToRgb(hex) {
  var n = parseInt(hex.slice(1), 16)
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 }
}

// Plain Euclidean RGB distance -- not a full perceptual model (CIEDE2000 et
// al.), but good enough to answer the one question that matters here: are
// these two colors close enough that a 9px dot reads as "the same color" at
// a glance. Calibrated against every theme actually shipped with Omarchy
// (measured directly from each theme's own colors.toml, not guessed): the
// four themes with a real problem here -- lumon, white, vantablack,
// hackerman, each intentionally monochromatic or near-monochromatic by
// design (Lumon's whole aesthetic is a cold blue-on-blue palette; white/
// vantablack are literal grayscale themes; hackerman's palette leans
// all-green) -- measure 25.7-33.1. Every theme with a real red/green hue
// difference measures 56.8 or higher. 45 sits in the middle of that gap
// with comfortable margin either side.
function _colorDistance(hexA, hexB) {
  var a = _hexToRgb(hexA), b = _hexToRgb(hexB)
  var dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
  return Math.sqrt(dr * dr + dg * dg + db * db)
}

var _MIN_DISTANCE = 45
// Fixed, NOT theme-derived -- deliberately not Quickshell's own Color.urgent
// (qs.Commons.Color singleton): reading that file directly confirmed
// `urgent` is itself sourced from the theme's own "red"/color1 slot, so for
// exactly the themes this needs to protect against, that "fallback" would
// be just as broken as the theme's own red. Swapped in as a PAIR, never
// individually -- a theme with a fine "up" green but a too-close "down" red
// would otherwise end up mixing one native color with one fixed color,
// which reads as a mismatched accident rather than a deliberate safe pair.
var _SAFE_UP = "#4caf50"
var _SAFE_DOWN = "#f44336"

// Returns { up, down, checking } hex strings (or null for any key not found
// in this theme -- BarWidget.qml falls back to a Color.* palette role for
// anything null, same fallback discipline Waveform uses when its own theme
// read comes back sparse).
function statusColors(raw) {
  var found = extractHexByKey(raw)
  var up = found.green || null
  var down = found.red || null
  // Guards against a theme whose "red"/"green" slots aren't different
  // enough to tell a down host from every other host's dot at a glance --
  // reported live on the shipped "lumon" theme, where a real down host
  // (Portainer) was visually identical to every reachable one. Checked
  // directly against every shipped theme's own colors.toml rather than
  // special-cased to Lumon's name -- three other themes have the identical
  // problem for the same underlying reason (an intentionally limited
  // palette), so a name-based special case would've left those just as
  // broken as before.
  if (up && down && _colorDistance(up, down) < _MIN_DISTANCE) {
    up = _SAFE_UP
    down = _SAFE_DOWN
  }
  return {
    up: up,
    down: down,
    checking: found.muted || null
  }
}
