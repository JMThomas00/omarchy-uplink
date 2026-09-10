.pragma library
.import "SshConfigParser.js" as SshConfigParser

// Locates and edits a PLAIN (non-sentinel-owned) "Host <alias>" block in
// raw ~/.ssh/config text -- a hand-authored entry this plugin discovered
// but did not create, as opposed to SshConfigBlockWriter.js's sentinel-
// delimited bookmark blocks, which this plugin fully owns and freely
// re-renders. A plain block can contain ANY directives in ANY order/
// formatting the user chose, so every function here is deliberately
// narrow: it touches only the exact "Host <alias>" line (rename) or the
// block's own line range (delete), and NEVER re-renders/reformats any
// other line the way SshConfigBlockWriter.renderBlock does for its own
// blocks. Line classification (what counts as a "Host"/"Match" line, how
// comments are stripped) is imported from SshConfigParser.js rather than
// reimplemented here -- classification drift between the two would mean a
// row visibly on screen (because parseHostAliases matched a line) could
// fail to be found here (because this file classified the same line
// differently), silently no-oping or erroring on a row the user can
// clearly see.

function _lines(text) {
  return String(text || "").split("\n")
}

// Finds the line-index range [startLine, endLine) for the block whose
// Host line contains `alias` as one of its space-separated tokens (exact
// match). endLine excludes any trailing blank lines OR comment-only lines
// between this block's last real directive and the next top-level
// Host/Match line (or EOF) -- not just blank lines. A comment-only line
// right before the next Host line can't reliably be attributed to either
// block (it might be a trailing note on THIS one, or a leading note for
// the NEXT one -- concretely, this is exactly what a following plugin-
// owned sentinel block's own "# >>> ssh-dashboard bookmark:... >>>" BEGIN
// marker looks like from this function's perspective), so both are
// excluded symmetrically -- mirrors this same file's own delete-time
// policy of never claiming a line it can't attribute with confidence.
// Reuses SshConfigParser.stripComment (a line that strips down to "" is
// either blank or comment-only either way) rather than a separate check.
// Returns null if no Host line contains `alias`. `multiAlias` is true
// when the matched Host line has more than one token -- callers must
// refuse to rename/delete in that case, since which token to touch (and
// whether removing the whole block would silently break the OTHER alias
// on that line) is ambiguous.
function findHostBlockLines(text, alias) {
  var lines = _lines(text)
  var startLine = -1
  var tokens = null
  for (var i = 0; i < lines.length; i++) {
    var t = SshConfigParser.hostLineTokens(lines[i])
    if (!t) continue
    if (t.indexOf(alias) !== -1) { startLine = i; tokens = t; break }
  }
  if (startLine === -1) return null

  var endLine = lines.length
  for (var j = startLine + 1; j < lines.length; j++) {
    if (SshConfigParser.hostLineTokens(lines[j]) || SshConfigParser.isMatchLine(lines[j])) { endLine = j; break }
  }
  while (endLine > startLine + 1 && SshConfigParser.stripComment(lines[endLine - 1]).length === 0) endLine--

  return { startLine: startLine, endLine: endLine, multiAlias: tokens.length > 1 }
}

// True if this block already has its own explicit HostName directive
// anywhere in its range (comment-stripped, case-insensitive) -- scans the
// WHOLE block, not just the line right after Host, so a HostName a few
// lines down (or a commented-out one, which correctly does NOT count) is
// handled correctly.
function blockHasHostName(text, startLine, endLine) {
  var lines = _lines(text)
  for (var i = startLine; i < endLine; i++) {
    if (/^HostName\s+/i.test(SshConfigParser.stripComment(lines[i]))) return true
  }
  return false
}

// Indentation to use for an injected HostName line: sniffed from another
// directive line already in this block, so the inserted line doesn't look
// foreign next to the user's own formatting. Falls back to 4 spaces,
// matching SshConfigBlockWriter.renderBlock's own convention.
function _sniffIndent(text, startLine, endLine) {
  var lines = _lines(text)
  for (var i = startLine + 1; i < endLine; i++) {
    if (SshConfigParser.stripComment(lines[i]).length === 0) continue
    var m = lines[i].match(/^(\s+)\S/)
    if (m) return m[1]
  }
  return "    "
}

// Renames a plain Host block's alias, touching ONLY the "Host" line's
// alias token (preserving the line's own leading whitespace, trailing
// comment, and everything else about it) -- plus inserting a new
// "HostName <oldAlias>" line immediately after it, IF AND ONLY IF the
// block doesn't already have one, so the real connection target is never
// lost even if `newAlias` isn't itself a resolvable hostname. Every other
// line in the block is left byte-for-byte untouched. Returns the new full
// text, or null if `oldAlias` isn't found or the matched Host line has
// more than one alias token (caller should call findHostBlockLines
// directly first to distinguish these two cases for its own error
// message).
function renameHostBlock(text, oldAlias, newAlias) {
  var found = findHostBlockLines(text, oldAlias)
  if (!found || found.multiAlias) return null

  var lines = _lines(text)
  var hostLine = lines[found.startLine]
  var commentIdx = hostLine.indexOf("#")
  var codePart = commentIdx === -1 ? hostLine : hostLine.substring(0, commentIdx)
  var commentPart = commentIdx === -1 ? "" : hostLine.substring(commentIdx)
  var newCodePart = codePart.replace(/(^\s*Host\s+)(\S+)(\s*)$/i, function(m, pre, token, post) {
    return pre + newAlias + post
  })

  var newLines = lines.slice()
  newLines[found.startLine] = newCodePart + commentPart
  if (!blockHasHostName(text, found.startLine, found.endLine)) {
    var indent = _sniffIndent(text, found.startLine, found.endLine)
    newLines.splice(found.startLine + 1, 0, indent + "HostName " + oldAlias)
  }
  return newLines.join("\n")
}

// Removes a plain Host block's own line range entirely. Deliberately does
// NOT touch anything before the "Host" line itself, not even an
// immediately-preceding comment -- there's no reliable way to know
// whether such a comment belongs to this block or to the file in
// general, and leaving a possibly-orphaned comment behind is a far safer
// failure mode than deleting something that might not belong to this
// block.
//
// Blank-line handling: eats exactly one blank line immediately BEFORE the
// block (mirrors SshConfigBlockWriter.removeBlock's own "eat exactly one
// leading blank line, never more" rule) and otherwise leaves surrounding
// spacing untouched -- since findHostBlockLines already excludes any
// trailing blank lines from the block's own range, a blank line
// genuinely AFTER the block (at `lines[endLine]`) is never part of what
// gets removed here, and naturally survives as the separator to whatever
// follows. (Earlier draft of this function also tried to eat a trailing
// blank line the way the character-offset sentinel version does -- traced
// by hand against a concrete blockA/blank/blockX/blank/blockC example and
// confirmed that double-eats at line-array granularity, collapsing two
// blank-line separators down to zero instead of the required one. The
// character-based version's trailing eat is consuming the END MARKER
// line's own newline terminator, which has no equivalent once you're
// already operating at line-array granularity -- `lines.slice(endLine)`
// implicitly starts exactly at the next line with nothing further to eat.)
//
// Returns the new full text, or the original text unchanged if `alias`
// isn't found or the matched Host line has more than one alias token
// (caller should call findHostBlockLines directly first to distinguish
// these two cases and decide whether to log a warning).
function removeHostBlock(text, alias) {
  var found = findHostBlockLines(text, alias)
  if (!found || found.multiAlias) return text

  var lines = _lines(text)
  var start = found.startLine
  if (start > 0 && lines[start - 1].trim() === "") start -= 1
  var newLines = lines.slice(0, start).concat(lines.slice(found.endLine))
  return newLines.join("\n")
}
