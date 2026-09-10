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
function parseHostAliases(raw) {
  var lines = String(raw || "").split("\n")
  var aliases = []
  var sawInclude = false
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/#.*/, "").trim()
    if (line.length === 0) continue
    if (/^Include\s+/i.test(line)) { sawInclude = true; continue }
    var hostMatch = line.match(/^Host\s+(.+)$/i)
    if (!hostMatch) continue
    var tokens = hostMatch[1].trim().split(/\s+/)
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
