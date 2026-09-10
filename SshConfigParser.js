.pragma library

// Enumerates real (non-wildcard) Host aliases from ~/.ssh/config. Deliberately
// does NOT resolve HostName/Port/User itself -- BarWidget.qml does that per
// alias via `ssh -G <alias>` instead. ssh's own -G output is authoritative:
// it applies Include-d files, Match blocks, and ssh's own defaults exactly as
// a real `ssh <alias>` call would, which a hand-rolled parser can't reproduce
// correctly. This file's only job is producing the *list* of aliases to ask
// -G about.
//
// KNOWN LIMITATION (v1): a Host block defined only inside a file reached via
// Include (not literally present in ~/.ssh/config itself) is not enumerated
// here, since this only scans the top-level file's own lines. Any Include
// line found sets sawInclude so BarWidget.qml can surface a small footer
// note in the popup rather than silently under-listing.

// Strips a trailing comment and surrounding whitespace from one raw line.
// Shared by every line-classification helper below AND by
// SshConfigHostEditor.js -- kept in exactly one place so a plain-host
// block's boundaries (found by SshConfigHostEditor) can never be computed
// against a different notion of "what counts as a Host line" than the one
// that put a row on screen in the first place (parseHostAliases, below).
function stripComment(line) {
  return line.replace(/#.*/, "").trim()
}

// If `line` is a top-level "Host" directive, returns its raw alias tokens
// (may be more than one -- see parseHostAliases's own dedup/filtering);
// otherwise returns null. Deliberately does NOT filter out wildcard/
// pattern tokens the way parseHostAliases's alias list does -- boundary
// detection needs to recognize a Host line as a Host line regardless of
// what its tokens look like.
function hostLineTokens(line) {
  var stripped = stripComment(line)
  if (stripped.length === 0) return null
  var m = stripped.match(/^Host\s+(.+)$/i)
  if (!m) return null
  return m[1].trim().split(/\s+/)
}

// True if `line` is a top-level "Match" directive. Match blocks never
// surface as rows (parseHostAliases only ever emits Host tokens), but they
// still terminate a preceding Host block the same way a following Host
// line does.
function isMatchLine(line) {
  return /^Match\s+/i.test(stripComment(line))
}

function parseHostAliases(raw) {
  var lines = String(raw || "").split("\n")
  var aliases = []
  var sawInclude = false
  for (var i = 0; i < lines.length; i++) {
    var stripped = stripComment(lines[i])
    if (stripped.length === 0) continue
    if (/^Include\s+/i.test(stripped)) { sawInclude = true; continue }
    var tokens = hostLineTokens(lines[i])
    if (!tokens) continue
    for (var t = 0; t < tokens.length; t++) {
      var alias = tokens[t]
      if (alias.indexOf("*") !== -1 || alias.indexOf("?") !== -1) continue // skip wildcard/pattern entries
      if (aliases.indexOf(alias) === -1) aliases.push(alias)
    }
  }
  return { aliases: aliases, sawInclude: sawInclude }
}

// Pulls hostname/port/user out of `ssh -G <alias>`'s own resolved-config
// output -- one "key value" pair per line, lowercase keys, exactly what real
// ssh would use to actually connect (Include/Match/defaults already applied).
function parseResolvedConfig(raw) {
  var lines = String(raw || "").split("\n")
  var result = { hostname: "", port: "22", user: "" }
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*(hostname|port|user)\s+(\S+)/i)
    if (!m) continue
    var key = m[1].toLowerCase()
    if (key === "hostname") result.hostname = m[2]
    else if (key === "port") result.port = m[2]
    else if (key === "user") result.user = m[2]
  }
  return result
}
