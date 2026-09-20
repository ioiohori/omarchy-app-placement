import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "Placement.js" as Placement

// App Placement overlay: every desktop app in a table with two checkbox
// columns, Floating and 1/4 Right. Ticks are saved immediately and turned
// into Hyprland window rules, so the app opens that way from any launcher.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "ioiohori.app-placement"
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string statePath: stateHome + "/omarchy/app-placement.json"
  // Omarchy re-requires every file in this directory on `hyprctl reload`.
  readonly property string rulesPath: stateHome + "/omarchy/toggles/hypr/app-placement.lua"

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property int selectedColumn: 0   // 0 = Floating, 1 = 1/4 Right
  property bool cursorActive: true

  property var apps: ({})          // id -> { float, quarter }
  property bool stateLoaded: false
  property var hiddenIds: ({})
  property var monitorCache: []
  property string lastRules: ""
  property string status: ""
  property bool statusIsError: false
  property int configuredCount: 0

  // Shares the [menu] surface tokens so themes that style the menu style this.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int columnHeaderHeight: Style.space(24)
  property int rowHeight: Math.max(Style.space(40), Style.font.subtitle + Style.font.caption + Style.spacing.md)
  property int iconSize: Style.space(24)
  property int checkSize: Style.space(18)
  property int toggleColumnWidth: Style.space(92)
  property int cardWidth: Math.min(Style.space(640), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(660), panel.height - Style.gapsOut * 2)

  // ---- lifecycle -----------------------------------------------------------

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.selectedColumn = 0
    root.cursorActive = true
    root.refreshMonitors()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function ping() { return "ok" }

  // `omarchy-shell shell call <id> set '{"id":"org.gnome.Nautilus","float":true,"quarter":true}'`
  function set(json) {
    var payload = null
    try { payload = JSON.parse(json || "{}") } catch (e) { return "bad json" }
    var id = String((payload && payload.id) || "").trim()
    if (!id) return "missing id"
    var next = ({})
    for (var key in root.apps) next[key] = root.apps[key]
    var conf = { float: payload.float === true, quarter: payload.quarter === true }
    if (conf.quarter) conf.float = true
    if (conf.float || conf.quarter) next[id] = conf
    else delete next[id]
    root.setApps(next)
    root.saveNow()
    return "ok"
  }

  // `omarchy-shell shell call <id> regenerate ''` rewrites the rules for the
  // current monitor layout (handy from a monitor hook).
  function regenerate() {
    root.refreshMonitors()
    root.saveNow()
    return "ok"
  }

  function geometry() {
    return JSON.stringify(Placement.geometry(Placement.pickMonitor(root.monitorCache)))
  }

  // ---- state ---------------------------------------------------------------

  function applyState(raw) {
    var parsed = null
    try { parsed = JSON.parse(raw || "{}") } catch (e) { parsed = null }
    root.apps = Placement.normalizeState(parsed).apps
    root.stateLoaded = true
    root.updateConfiguredCount()
    if (root.opened) root.rebuildDisplay()
  }

  function setApps(next) {
    root.apps = next
    root.updateConfiguredCount()
    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      var conf = next[row.appId] || { float: false, quarter: false }
      if (row.isFloat !== (conf.float === true)) displayModel.setProperty(i, "isFloat", conf.float === true)
      if (row.isQuarter !== (conf.quarter === true)) displayModel.setProperty(i, "isQuarter", conf.quarter === true)
    }
  }

  function updateConfiguredCount() {
    root.configuredCount = Object.keys(root.apps).length
  }

  function saveNow() {
    if (!root.stateLoaded) return
    stateFile.setText(Placement.serializeState({ apps: root.apps }))
    root.writeRules()
  }

  // Rows for the rules come from the full app list, not the filtered view.
  function configuredRows() {
    var values = []
    try { values = DesktopEntries.applications.values || [] } catch (e) { values = [] }
    var rows = Placement.sortedEntries(values, "", ({}), root.apps)
    var out = []
    for (var i = 0; i < rows.length; i++) if (rows[i].configured) out.push(rows[i])
    return out
  }

  function writeRules() {
    var monitor = Placement.pickMonitor(root.monitorCache)
    var text = Placement.luaRules(root.configuredRows(), Placement.geometry(monitor), monitor ? monitor.name : "")
    if (text === root.lastRules) return
    root.lastRules = text
    rulesFile.setText(text)
    reloadTimer.restart()
  }

  function loadHides(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = lines[i].trim()
      if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
      if (id.length > 0) next[id] = true
    }
    root.hiddenIds = next
    if (root.opened) root.rebuildDisplay()
  }

  function refreshMonitors() {
    if (!monitorProbe.running) monitorProbe.running = true
  }

  function loadMonitors(raw) {
    var before = JSON.stringify(Placement.geometry(Placement.pickMonitor(root.monitorCache)))
    try {
      var list = JSON.parse(raw || "[]")
      if (Array.isArray(list)) root.monitorCache = list
    } catch (e) {
    }
    // Monitor layout changed since the rules were written: refresh them.
    var after = JSON.stringify(Placement.geometry(Placement.pickMonitor(root.monitorCache)))
    if (root.stateLoaded && root.lastRules !== "" && before !== after) root.writeRules()
  }

  // ---- list ----------------------------------------------------------------

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length > 0) {
      if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
      if (value.charAt(0) === "/") return Util.fileUrl(value)
      var themed = Quickshell.iconPath(value, true)
      if (themed.length > 0) return themed
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  function rebuildDisplay() {
    var values = []
    try { values = DesktopEntries.applications.values || [] } catch (e) { values = [] }
    var rows = Placement.sortedEntries(values, root.filterText, root.hiddenIds, root.apps)

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      displayModel.append({
        appId: rows[i].id,
        name: rows[i].name,
        classText: rows[i].candidates.join(" | "),
        icon: String(entry.icon || ""),
        isFloat: rows[i].float,
        isQuarter: rows[i].quarter
      })
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0
    cursorActive = displayModel.count > 0

    Qt.callLater(function() {
      if (displayModel.count > 0) list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay()
  }

  function move(delta) {
    if (displayModel.count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = Math.max(0, Math.min(displayModel.count - 1, selectedIndex + delta))
    }
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function pageSize() {
    return Math.max(1, Math.floor(list.height / root.rowHeight))
  }

  function toggleCell(index, column) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.selectedIndex = index
    root.selectedColumn = column
    root.cursorActive = true
    root.setApps(Placement.toggled(root.apps, row.appId, column === 1 ? "quarter" : "float"))
    saveDebounce.restart()
  }

  function clearAll() {
    root.setApps(({}))
    saveDebounce.restart()
  }

  // ---- plumbing ------------------------------------------------------------

  ListModel { id: displayModel }

  Timer {
    id: saveDebounce
    interval: 300
    onTriggered: root.saveNow()
  }

  // Coalesce rule writes before asking Hyprland to reload.
  Timer {
    id: reloadTimer
    interval: 250
    onTriggered: if (!reloadProc.running) reloadProc.running = true
  }

  Process {
    id: reloadProc
    command: ["bash", "-c", "hyprctl reload >/dev/null && hyprctl configerrors"]
    stdout: StdioCollector {
      onStreamFinished: {
        var errors = String(text || "").trim()
        root.statusIsError = errors.length > 0
        root.status = errors.length > 0 ? errors : ("Rules applied · " + root.configuredCount + " app" + (root.configuredCount === 1 ? "" : "s"))
      }
    }
  }

  Process {
    id: monitorProbe
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector { onStreamFinished: root.loadMonitors(text) }
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: root.applyState("{}")
  }

  FileView {
    id: rulesFile
    path: root.rulesPath
    atomicWrites: true
    printErrors: false
    onLoaded: root.lastRules = text()
    onLoadFailed: root.lastRules = ""
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadHides(text())
    onFileChanged: root.loadHides(text())
    onLoadFailed: root.loadHides("")
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (root.opened) root.rebuildDisplay() }
  }

  Component.onCompleted: root.refreshMonitors()

  // ---- UI ------------------------------------------------------------------

  component CheckCell: Item {
    id: cell
    property bool checked: false
    property bool hasCursor: false
    signal clicked()

    width: root.toggleColumnWidth
    height: root.rowHeight

    Rectangle {
      anchors.centerIn: parent
      width: root.checkSize + Style.spacing.md
      height: root.checkSize + Style.spacing.md
      radius: Math.min(root.cornerRadius, Style.space(6))
      color: cell.hasCursor ? Util.alpha(root.accent, 0.18) : "transparent"

      Rectangle {
        anchors.centerIn: parent
        width: root.checkSize
        height: root.checkSize
        radius: Math.min(root.cornerRadius, Style.space(4))
        color: cell.checked ? root.accent : "transparent"
        border.width: Math.max(1, Style.space(1.5))
        border.color: cell.checked ? root.accent : Util.alpha(root.foreground, cell.hasCursor ? 0.9 : 0.5)

        Text {
          anchors.centerIn: parent
          visible: cell.checked
          text: "✓"
          color: root.background
          font.family: root.fontFamily
          font.pixelSize: root.checkSize * 0.8
          font.bold: true
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: cell.clicked()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-app-placement"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
          } else if (event.key === Qt.Key_Backspace) {
            if (ctrl) root.setFilter("")
            else if (root.filterText) root.setFilter(root.filterText.slice(0, -1))
          } else if (event.key === Qt.Key_Up) {
            root.move(-1)
          } else if (event.key === Qt.Key_Down) {
            root.move(1)
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
            root.selectedColumn = 0
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
            root.selectedColumn = 1
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-root.pageSize())
          } else if (event.key === Qt.Key_PageDown) {
            root.move(root.pageSize())
          } else if (event.key === Qt.Key_Home) {
            root.move(-displayModel.count)
          } else if (event.key === Qt.Key_End) {
            root.move(displayModel.count)
          } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.toggleCell(root.selectedIndex, root.selectedColumn)
          } else if (ctrl && event.key === Qt.Key_D) {
            root.clearAll()
          } else if (!ctrl && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Header: search text + configured count.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: countLabel.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "App placement — search…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: countLabel
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.configuredCount > 0 ? root.configuredCount + " configured" : ""
            color: root.selectedText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // Column headers.
        Item {
          width: parent.width
          height: root.columnHeaderHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: "Application"
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
              model: ["Floating", "1/4 Right"]
              delegate: Item {
                required property int index
                required property string modelData
                width: root.toggleColumnWidth
                height: root.columnHeaderHeight
                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: modelData
                  color: root.cursorActive && root.selectedColumn === index ? root.selectedText : root.foreground
                  opacity: root.cursorActive && root.selectedColumn === index ? 1 : 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // App table.
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.columnHeaderHeight - footer.height - hint.height - root.contentSpacing * 4

          ListView {
            id: list
            anchors.fill: parent
            model: displayModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: false

            delegate: Rectangle {
              id: row
              required property int index
              required property string appId
              required property string name
              required property string classText
              required property string icon
              required property bool isFloat
              required property bool isQuarter

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: list.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
                onClicked: root.toggleCell(row.index, root.selectedColumn)
              }

              Row {
                anchors.left: parent.left
                anchors.right: toggles.left
                anchors.leftMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md

                Image {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.iconSize
                  height: root.iconSize
                  sourceSize.width: root.iconSize
                  sourceSize.height: root.iconSize
                  asynchronous: true
                  fillMode: Image.PreserveAspectFit
                  source: root.iconSource(row.icon)
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - root.iconSize - Style.spacing.md
                  spacing: 0

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: row.name
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: row.classText
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              Row {
                id: toggles
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter

                CheckCell {
                  checked: row.isFloat
                  hasCursor: row.hasCursor && root.selectedColumn === 0
                  onClicked: root.toggleCell(row.index, 0)
                }

                CheckCell {
                  checked: row.isQuarter
                  hasCursor: row.hasCursor && root.selectedColumn === 1
                  onClicked: root.toggleCell(row.index, 1)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }

        // Footer: status + clear + done.
        Item {
          id: footer
          width: parent.width
          height: Math.max(doneButton.implicitHeight, statusText.implicitHeight)

          Text {
            id: statusText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: buttons.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.status
            color: root.statusIsError ? Color.urgent : root.foreground
            opacity: root.statusIsError ? 1 : 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            id: buttons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Button {
              text: "Clear all"
              bordered: true
              visible: root.configuredCount > 0
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.clearAll()
            }

            Button {
              id: doneButton
              text: "Done"
              bordered: true
              selected: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.dismiss()
            }
          }
        }

        Text {
          id: hint
          textFormat: Text.PlainText
          width: parent.width
          text: "Type to search · ↑↓ app · ←→ column · Space toggles · 1/4 Right implies Floating · Ctrl+D clear · Esc close. Changes apply immediately."
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
