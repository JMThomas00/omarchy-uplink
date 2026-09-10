import QtQuick
import Quickshell
import Quickshell.Io

// Owns ~/.config/uplink/settings.json -- probe cadence and the
// compact-row toggle. Peer to BookmarkStore.qml, same
// FileView/debounced-save/mkdirProc trio.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: root.home + "/.config/uplink"
  readonly property string settingsPath: root.configDir + "/settings.json"

  readonly property int defaultProbeIntervalSec: 60
  readonly property int defaultPopupProbeIntervalSec: 20

  property int probeIntervalSec: root.defaultProbeIntervalSec
  property int popupProbeIntervalSec: root.defaultPopupProbeIntervalSec
  property bool compactRows: false

  property bool loaded: false

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root._applyLoaded(text())
    onLoadFailed: root._applyLoaded("")
  }

  function _clampInterval(value, fallback) {
    var n = Number(value)
    if (!isFinite(n) || n < 5) return fallback
    return Math.round(Math.min(n, 3600))
  }

  function _applyLoaded(raw) {
    if (root.loaded) return
    root.loaded = true
    try {
      var doc = JSON.parse(raw || "{}")
      root.probeIntervalSec = root._clampInterval(doc.probeIntervalSec, root.defaultProbeIntervalSec)
      root.popupProbeIntervalSec = root._clampInterval(doc.popupProbeIntervalSec, root.defaultPopupProbeIntervalSec)
      root.compactRows = !!doc.compactRows
    } catch (e) {
      root.probeIntervalSec = root.defaultProbeIntervalSec
      root.popupProbeIntervalSec = root.defaultPopupProbeIntervalSec
      root.compactRows = false
    }
  }

  Timer {
    id: saveTimer
    interval: 300
    repeat: false
    onTriggered: settingsFile.setText(JSON.stringify({
      probeIntervalSec: root.probeIntervalSec,
      popupProbeIntervalSec: root.popupProbeIntervalSec,
      compactRows: root.compactRows
    }))
  }

  function _scheduleSave() {
    if (!root.loaded) return
    saveTimer.restart()
  }

  function setProbeIntervalSec(value) {
    root.probeIntervalSec = root._clampInterval(value, root.probeIntervalSec)
    root._scheduleSave()
  }

  function setPopupProbeIntervalSec(value) {
    root.popupProbeIntervalSec = root._clampInterval(value, root.popupProbeIntervalSec)
    root._scheduleSave()
  }

  function setCompactRows(value) {
    root.compactRows = !!value
    root._scheduleSave()
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir]
    onExited: settingsFile.reload()
  }

  Component.onCompleted: mkdirProc.running = true
}
