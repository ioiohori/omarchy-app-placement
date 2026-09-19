import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "Launcher.js" as Launcher

// Quarter Launcher overlay: a searchable checklist of desktop apps. Enter
// launches every ticked app floating on an empty workspace, docked to one
// side of the screen (1/4 wide by default). The ticked set is remembered.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "ioiohori.quarter-launcher"
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/quarter-launcher.json"

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: true

  // Persisted state (see Launcher.normalizeState).
  property var checked: ({})
  property real fraction: 0.25
  property string side: "right"
  property bool stateLoaded: false

  property var hiddenIds: ({})
  property int checkedCount: 0

  // Latest `hyprctl monitors -j` rows. Quickshell's HyprlandMonitor does not
  // always carry the reserved area (the bar), and the geometry needs it.
  property var monitorCache: []

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
  property int rowHeight: Math.max(Style.space(40), Style.font.subtitle + Style.font.caption + Style.spacing.md)
  property int iconSize: Style.space(24)
  property int checkSize: Style.space(18)
  property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)

  // ---- lifecycle -----------------------------------------------------------

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fraction !== undefined) root.fraction = Launcher.nearestFraction(payload.fraction)
    if (payload.side !== undefined) root.side = Launcher.normalizeSide(payload.side)

    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
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

  // `omarchy-shell shell call <id> geometry ''` — handy when checking a monitor.
  function geometry() {
    return JSON.stringify(Launcher.geometry(root.monitorInfo(), root.fraction, root.side))
  }

  // `omarchy-shell shell call <id> launch '["Alacritty","org.gnome.Nautilus"]'`
  // launches desktop ids with the current layout, no UI involved. A plain
  // space- or comma-separated list works too.
  function launch(idsJson) {
    var ids = []
    try { ids = JSON.parse(idsJson || "[]") } catch (e) { ids = String(idsJson || "").split(/[\s,]+/) }
    if (!Array.isArray(ids)) ids = [ids]
    var clean = []
    for (var i = 0; i < ids.length; i++) {
      var id = String(ids[i] || "").trim()
      if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
      if (id) clean.push(id)
    }
    if (clean.length === 0) return "no ids"
    root.launchApps(clean)
    root.refreshMonitors()
    return "ok"
  }

  // ---- state ---------------------------------------------------------------

  function applyState(raw) {
    var parsed = null
    try { parsed = JSON.parse(raw || "{}") } catch (e) { parsed = null }
    var state = Launcher.normalizeState(parsed)
    root.checked = state.checked
    root.fraction = state.fraction
    root.side = state.side
    root.stateLoaded = true
    root.updateCheckedCount()
    if (root.opened) root.rebuildDisplay()
  }

  function saveState() {
    if (!root.stateLoaded) return
    stateFile.setText(Launcher.serializeState({ checked: root.checked, fraction: root.fraction, side: root.side }))
  }

  function updateCheckedCount() {
    root.checkedCount = Object.keys(root.checked).length
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
    var rows = Launcher.sortedEntries(values, root.filterText, root.hiddenIds, root.checked)

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      displayModel.append({
        appId: rows[i].id,
        name: Launcher.entryName(entry),
        subtext: Launcher.entrySubtext(entry),
        icon: String(entry.icon || ""),
        isChecked: rows[i].checked
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

  function toggleIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    var next = ({})
    for (var key in root.checked) next[key] = true
    if (next[row.appId] === true) delete next[row.appId]
    else next[row.appId] = true
    root.checked = next
    displayModel.setProperty(index, "isChecked", next[row.appId] === true)
    root.updateCheckedCount()
    saveDebounce.restart()
  }

  function clearChecked() {
    root.checked = ({})
    for (var i = 0; i < displayModel.count; i++) displayModel.setProperty(i, "isChecked", false)
    root.updateCheckedCount()
    saveDebounce.restart()
  }

  function setFraction(value) {
    root.fraction = Launcher.nearestFraction(value)
    saveDebounce.restart()
  }

  function setSide(value) {
    root.side = Launcher.normalizeSide(value)
    saveDebounce.restart()
  }

  // ---- launching -----------------------------------------------------------

  function refreshMonitors() {
    if (!monitorProbe.running) monitorProbe.running = true
  }

  function loadMonitors(raw) {
    try {
      var list = JSON.parse(raw || "[]")
      if (Array.isArray(list)) root.monitorCache = list
    } catch (e) {
    }
  }

  function monitorInfo() {
    var monitor = Hyprland.focusedMonitor
    var ipc = monitor && monitor.lastIpcObject ? monitor.lastIpcObject : null
    if (ipc && ipc.width && Array.isArray(ipc.reserved)) return ipc
    var name = monitor ? String(monitor.name || "") : ""
    var fallback = null
    for (var i = 0; i < root.monitorCache.length; i++) {
      var row = root.monitorCache[i]
      if (!row) continue
      if (name && row.name === name) return row
      if (row.focused === true) fallback = row
    }
    if (fallback) return fallback
    if (root.monitorCache.length > 0) return root.monitorCache[0]
    if (monitor) return { width: monitor.width, height: monitor.height, scale: monitor.scale, reserved: [0, 0, 0, 0] }
    return { width: 1920, height: 1080, scale: 1, reserved: [0, 0, 0, 0] }
  }

  // Ids to launch: every ticked app that still exists, or — when nothing is
  // ticked — just the app under the cursor, so Enter always does something.
  function launchIds() {
    var ids = []
    var seen = ({})
    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (root.checked[row.appId] === true && !seen[row.appId]) { ids.push(row.appId); seen[row.appId] = true }
    }
    if (ids.length === 0 && root.cursorActive && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count)
      ids.push(displayModel.get(root.selectedIndex).appId)
    return ids
  }

  function launchApps(ids) {
    var geom = Launcher.geometry(root.monitorInfo(), root.fraction, root.side)
    for (var i = 0; i < ids.length; i++) {
      Hyprland.dispatch(Launcher.execDispatcher(ids[i], geom, Launcher.EMPTY_WORKSPACE))
    }
  }

  function launchChecked() {
    var ids = root.launchIds()
    if (ids.length === 0) return
    root.launchApps(ids)
    root.dismiss()
  }

  // ---- plumbing ------------------------------------------------------------

  ListModel { id: displayModel }

  Process {
    id: monitorProbe
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector { onStreamFinished: root.loadMonitors(text) }
  }

  Component.onCompleted: root.refreshMonitors()

  Timer {
    id: saveDebounce
    interval: 300
    onTriggered: root.saveState()
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

  // ---- UI ------------------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-quarter-launcher"
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
          var shift = (event.modifiers & Qt.ShiftModifier) !== 0
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
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-root.pageSize())
          } else if (event.key === Qt.Key_PageDown) {
            root.move(root.pageSize())
          } else if (event.key === Qt.Key_Home) {
            root.move(-displayModel.count)
          } else if (event.key === Qt.Key_End) {
            root.move(displayModel.count)
          } else if (event.key === Qt.Key_Space) {
            if (root.cursorActive) root.toggleIndex(root.selectedIndex)
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            if (event.key === Qt.Key_Backtab || shift) root.setSide(root.side === "right" ? "left" : "right")
            else root.setFraction(Launcher.nextFraction(root.fraction, 1))
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.launchChecked()
          } else if (ctrl && (event.key === Qt.Key_D || event.key === Qt.Key_U)) {
            root.clearChecked()
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

        // Header: search text + ticked count.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: countLabel.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search apps…"
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
            text: root.checkedCount > 0 ? root.checkedCount + " ticked" : ""
            color: root.selectedText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // App list.
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - footer.height - hint.height - root.contentSpacing * 3

          ListView {
            id: list
            anchors.fill: parent
            model: displayModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: false

            delegate: Rectangle {
              required property int index
              required property string appId
              required property string name
              required property string subtext
              required property string icon
              required property bool isChecked

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: list.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.md
                anchors.rightMargin: Style.spacing.md
                spacing: Style.spacing.md

                // Checkbox.
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.checkSize
                  height: root.checkSize
                  radius: Math.min(root.cornerRadius, Style.space(4))
                  color: isChecked ? root.accent : "transparent"
                  border.width: Math.max(1, Style.space(1.5))
                  border.color: isChecked ? root.accent : Util.alpha(root.foreground, 0.5)

                  Text {
                    anchors.centerIn: parent
                    visible: isChecked
                    text: "✓"
                    color: root.background
                    font.family: root.fontFamily
                    font.pixelSize: root.checkSize * 0.8
                    font.bold: true
                  }
                }

                Image {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.iconSize
                  height: root.iconSize
                  sourceSize.width: root.iconSize
                  sourceSize.height: root.iconSize
                  asynchronous: true
                  fillMode: Image.PreserveAspectFit
                  source: root.iconSource(icon)
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - root.checkSize - root.iconSize - Style.spacing.md * 2
                  spacing: 0

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: name
                    color: hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    visible: subtext.length > 0
                    text: subtext
                    color: root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = index
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = index
                  root.toggleIndex(index)
                }
                onDoubleClicked: {
                  root.selectedIndex = index
                  root.launchChecked()
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

        // Footer: width + side choice, clear, launch.
        Item {
          id: footer
          width: parent.width
          height: Math.max(launchButton.implicitHeight, fractionRow.implicitHeight)

          Row {
            id: fractionRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Repeater {
              model: Launcher.FRACTIONS
              delegate: Button {
                required property var modelData
                text: modelData.label
                bordered: true
                selected: Math.abs(root.fraction - modelData.value) < 1e-6
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.setFraction(modelData.value)
              }
            }

            Item { width: Style.spacing.md; height: 1 }

            Button {
              text: "󰧀 Left"
              bordered: true
              selected: root.side === "left"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setSide("left")
            }

            Button {
              text: "Right 󰧂"
              bordered: true
              selected: root.side === "right"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setSide("right")
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Button {
              text: "Clear"
              bordered: true
              visible: root.checkedCount > 0
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.clearChecked()
            }

            Button {
              id: launchButton
              text: root.checkedCount > 0 ? "Launch " + root.checkedCount + " 󰌑" : "Launch 󰌑"
              bordered: true
              selected: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.launchChecked()
            }
          }
        }

        Text {
          id: hint
          textFormat: Text.PlainText
          width: parent.width
          text: "Type to search · Space tick · Enter launch ticked (or highlighted) · Tab width · Shift+Tab side · Ctrl+D clear · Esc close"
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
