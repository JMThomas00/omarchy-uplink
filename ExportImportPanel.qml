import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Inline export/import form. No native file picker exists anywhere on
// this system (confirmed: no zenity/kdialog, no Quickshell FileDialog
// type, nothing in this shell invokes the xdg-desktop-portal file chooser
// that's present at the system level) -- a plain typed path is the only
// realistic option.
Item {
  id: root

  property var bookmarkStoreRef: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string defaultPath: root.home + "/uplink-bookmarks-export.json"

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  property string statusText: ""
  property string _pendingExportPath: ""
  // Defaults OFF, and NOT persisted to SettingsStore -- reset to off every
  // time this panel (re)opens, same "don't let a sensitive toggle silently
  // stick on" reasoning as BookmarkForm's password-reveal flags. A stored
  // password is already a plaintext-in-bookmarks.json tradeoff the user
  // explicitly accepted (mitigated there only by chmod 600); export must
  // not silently extend that same plaintext exposure to a second file
  // (which may get copied elsewhere, attached, committed, etc.) unless the
  // user opts in for THIS export, every time.
  property bool includePasswords: false

  onVisibleChanged: if (visible) {
    exportPathField.text = root.defaultPath
    importPathField.text = root.defaultPath
    root.statusText = ""
    root.includePasswords = false
  }

  FileView {
    id: exportFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: importFile
    watchChanges: false
    printErrors: false
    onLoaded: root._applyImport(text())
    onLoadFailed: root.statusText = "Could not read " + importFile.path
  }

  // Export's typed path might name a non-existent parent directory (the
  // default, directly in $HOME, never does) -- mkdir -p first rather than
  // let FileView.setText silently fail the way bookmarksFile/stateFile
  // would without their own paired mkdirProc.
  Process {
    id: exportMkdirProc
    command: []
    onExited: root._writeExport(root._pendingExportPath)
  }

  // Same permission hardening bookmarks.json and ~/.ssh/config already get
  // -- applied regardless of includePasswords, since even a
  // passwords-excluded export still lists every hostname/user this person
  // has bookmarked.
  Process {
    id: exportChmodProc
    command: []
  }

  function doExport() {
    var path = (exportPathField.text || "").trim() || root.defaultPath
    root._pendingExportPath = path
    var slashIdx = path.lastIndexOf("/")
    var dir = slashIdx > 0 ? path.substring(0, slashIdx) : ""
    if (dir) {
      exportMkdirProc.command = ["mkdir", "-p", dir]
      exportMkdirProc.running = true
    } else {
      root._writeExport(path)
    }
  }

  function _writeExport(path) {
    var bookmarks = root.bookmarkStoreRef ? root.bookmarkStoreRef.bookmarks : []
    // Stripped by default, not just blanked -- an omitted key can't round-
    // trip back in via a careless re-import the way an empty string could
    // be mistaken for "no password" and then get silently overwritten.
    var toWrite = bookmarks
    if (!root.includePasswords) {
      toWrite = bookmarks.map(function(b) {
        var copy = Object.assign({}, b)
        delete copy.password
        delete copy.rdpPassword
        return copy
      })
    }
    exportFile.path = path
    exportFile.setText(JSON.stringify({ bookmarks: toWrite }, null, 2))
    exportChmodProc.command = ["chmod", "600", path]
    exportChmodProc.running = true
    root.statusText = "Exported " + bookmarks.length + " bookmark(s) to " + path +
      (root.includePasswords ? " (including stored passwords)" : " (passwords excluded)")
  }

  function doImport() {
    var path = (importPathField.text || "").trim() || root.defaultPath
    root.statusText = "Importing…"
    importFile.path = path
    importFile.reload()
  }

  // Additive/merge, never a wholesale replace -- each entry goes through
  // the SAME validated addBookmark() pipeline a manual add uses (charset/
  // collision checks, ~/.ssh/config block write-back included), so an
  // entry that fails validation (e.g. a label collision) is skipped, not
  // fatal to the rest of the import.
  function _applyImport(raw) {
    var imported = 0
    var skipped = 0
    var firstError = ""
    try {
      var doc = JSON.parse(raw || "{}")
      var list = Array.isArray(doc.bookmarks) ? doc.bookmarks : []
      for (var i = 0; i < list.length; i++) {
        var b = list[i] || {}
        var error = root.bookmarkStoreRef ? root.bookmarkStoreRef.addBookmark(b) : "No bookmark store."
        if (error) {
          skipped++
          if (!firstError) firstError = (b.label || "?") + ": " + error
        } else {
          imported++
        }
      }
    } catch (e) {
      root.statusText = "Import failed: file isn't valid JSON."
      return
    }
    var summary = "Imported " + imported + ", skipped " + skipped
    if (firstError) summary += " (" + firstError + (skipped > 1 ? "; " + (skipped - 1) + " more" : "") + ")"
    root.statusText = summary
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    TextField {
      id: exportPathField
      width: parent.width
      placeholderText: root.defaultPath
      verticalPadding: Style.spacing.controlPaddingY
      onAccepted: root.doExport()
    }

    Row {
      spacing: Style.spacing.controlGap

      Rectangle {
        id: includePasswordsCheckbox
        width: Style.space(16)
        height: Style.space(16)
        radius: Style.space(3)
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor
        color: root.includePasswords ? Color.accent : "transparent"
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.includePasswords = !root.includePasswords
        }
      }

      Text {
        text: "Include stored passwords"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Row {
      spacing: Style.spacing.controlGap

      Rectangle {
        width: Style.space(66)
        height: Style.space(24)
        radius: Style.cornerRadius
        color: exportArea.containsMouse ? Color.accent : Style.normalFill
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor

        Text {
          anchors.centerIn: parent
          text: "Export"
          color: exportArea.containsMouse ? Color.background : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: exportArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.doExport()
        }
      }
    }

    TextField {
      id: importPathField
      width: parent.width
      placeholderText: root.defaultPath
      verticalPadding: Style.spacing.controlPaddingY
      onAccepted: root.doImport()
    }

    Row {
      spacing: Style.spacing.controlGap

      Rectangle {
        width: Style.space(66)
        height: Style.space(24)
        radius: Style.cornerRadius
        color: importArea.containsMouse ? Color.accent : Style.normalFill
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderColor

        Text {
          anchors.centerIn: parent
          text: "Import"
          color: importArea.containsMouse ? Color.background : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: importArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.doImport()
        }
      }
    }

    Text {
      width: parent.width
      visible: root.statusText !== ""
      text: root.statusText
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }
}
