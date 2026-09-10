.pragma library

// Sentinel-delimited block management for bookmark entries this plugin
// writes into the user's own ~/.ssh/config. Every function here is pure
// (operates on a raw text string, returns a new one) so it can be unit
// tested in isolation from BookmarkStore.qml's FileView/queue plumbing --
// this is byte-level text surgery on a file the user hand-maintains, and a
// subtly-wrong blank-line/anchoring rule is exactly the kind of bug that
// looks correct in a quick manual check and corrupts formatting on the
// tenth add/delete cycle.
//
// Markers are matched by the FULL LITERAL id string, never a bare
// substring search on the id alone -- so one id can never accidentally
// match inside another (e.g. "bm_1" must not match inside "bm_10").
//
// The literal "ssh-dashboard" text below is INTENTIONALLY left as-is even
// though the plugin itself was renamed to Uplink -- this string is purely
// an internal marker never shown to the user, and changing it would mean
// every bookmark saved before the rename (real ones, already sitting in
// the user's real ~/.ssh/config) would stop matching its own block on the
// next edit, silently orphaning the old marker while appending a
// duplicate under the new one. Not worth the risk on a file this
// sensitive for a purely cosmetic rename -- see the plugin's rename notes
// in memory/commit history for the full reasoning.

function beginMarker(id) {
  return "# >>> ssh-dashboard bookmark:" + id + " >>>"
}

function endMarker(id) {
  return "# <<< ssh-dashboard bookmark:" + id + " <<<"
}

// { hostname, port, user } -- port omitted if "22"/22/blank, user omitted
// if blank. Values are expected to already be validated by the caller
// (BookmarkStore.validateFields) against a strict allow-list -- this
// function does not re-validate, it only renders.
function renderBlock(bookmark) {
  var lines = [beginMarker(bookmark.id), "Host " + bookmark.label, "    HostName " + bookmark.hostname]
  var port = String(bookmark.port || "").trim()
  if (port && port !== "22") lines.push("    Port " + port)
  var user = String(bookmark.user || "").trim()
  if (user) lines.push("    User " + user)
  lines.push(endMarker(bookmark.id))
  return lines.join("\n")
}

// Finds this id's begin/end marker positions in `text`. Returns
// { beginIdx, endIdx } (endIdx is the index right after the end marker's
// last character) if both markers are found in order, or null otherwise
// (covers: neither found, or a corrupted begin-with-no-matching-end).
function findBlock(text, id) {
  var begin = beginMarker(id)
  var end = endMarker(id)
  var beginIdx = text.indexOf(begin)
  if (beginIdx === -1) return null
  var endIdx = text.indexOf(end, beginIdx)
  if (endIdx === -1) return null // corrupted marker -- caller decides how to handle
  return { beginIdx: beginIdx, endIdx: endIdx + end.length }
}

// True if `id`'s begin marker is present but no matching end marker can be
// found anywhere after it -- the "hand-corrupted" case callers should
// surface rather than silently duplicate over.
function hasOrphanedBeginMarker(text, id) {
  var begin = beginMarker(id)
  var end = endMarker(id)
  var beginIdx = text.indexOf(begin)
  if (beginIdx === -1) return false
  return text.indexOf(end, beginIdx) === -1
}

// Normalizes trailing whitespace to exactly one newline (or none for an
// empty string), so repeated appends never produce an inconsistent run of
// blank lines regardless of whether the file was empty or already ended
// cleanly.
function _normalizeTrailingNewline(text) {
  if (text.length === 0) return ""
  return text.replace(/\s*$/, "\n")
}

// Replaces this id's block in place if found (preserving its position and
// everything else in the file byte-for-byte); otherwise appends a fresh
// block at the end. Does NOT repair an orphaned begin-with-no-end marker --
// that case is surfaced separately via hasOrphanedBeginMarker so the caller
// (BookmarkStore) can log/flag it rather than this function silently
// leaving the orphan behind while also appending a duplicate.
function upsertBlock(rawText, bookmark) {
  var text = String(rawText || "")
  var rendered = renderBlock(bookmark)
  var found = findBlock(text, bookmark.id)
  if (found) {
    return text.slice(0, found.beginIdx) + rendered + text.slice(found.endIdx)
  }
  var normalized = _normalizeTrailingNewline(text)
  var sep = normalized.length > 0 ? "\n" : ""
  return normalized + sep + rendered + "\n"
}

// Removes this id's block plus exactly one leading blank line (never more,
// so two adjacent managed blocks don't lose the blank line separating them
// from each other or from surrounding content). No-op (returns text
// unchanged) if the block isn't found, orphaned-begin included -- deletion
// of an unresolvable id is handled by the caller as "already gone."
function removeBlock(rawText, id) {
  var text = String(rawText || "")
  var found = findBlock(text, id)
  if (!found) return text
  var start = found.beginIdx
  // Eat exactly one leading blank line (a run of "\n\n" immediately before
  // the block), not every blank line back to the previous content.
  if (text.slice(0, start).endsWith("\n\n")) start -= 1
  var end = found.endIdx
  // Eat the single trailing newline right after the block, if present, so
  // removal doesn't leave a stray blank line where the block used to be.
  if (text[end] === "\n") end += 1
  return text.slice(0, start) + text.slice(end)
}
