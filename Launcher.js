// Pure helpers for Quarter Launcher: app-list filtering, window geometry and
// the Hyprland dispatcher string. No QML imports, so `node tests/launcher.test.js`
// can exercise everything here.

var FRACTIONS = [
  { value: 0.25, label: "1/4" },
  { value: 1 / 3, label: "1/3" },
  { value: 0.5, label: "1/2" }
]

var SIDES = ["right", "left"]

// Which empty workspace Hyprland should open the window on.
// "emptym" = the first empty workspace on the monitor that has focus, so the
// window lands where the user is looking even with several monitors.
var EMPTY_WORKSPACE = "emptym"

function entryName(entry) {
  return String((entry && entry.name) || (entry && entry.id) || "")
}

function entrySubtext(entry) {
  return String((entry && entry.genericName) || (entry && entry.comment) || "")
}

function keywordText(entry) {
  try {
    if (entry && entry.keywords && typeof entry.keywords.join === "function") return entry.keywords.join(" ")
  } catch (e) {
  }
  return ""
}

function searchText(entry) {
  if (!entry) return ""
  return [entry.name, entry.genericName, entry.comment, keywordText(entry), entry.id].join(" ").toLowerCase()
}

// Higher is better; -1 means "does not match". Every whitespace-separated
// term has to appear somewhere; the score then prefers name-prefix hits.
function score(entry, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return 0
  var haystack = searchText(entry)
  var terms = q.split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (terms[i] && haystack.indexOf(terms[i]) < 0) return -1
  }
  var name = entryName(entry).toLowerCase()
  var at = name.indexOf(q)
  if (at === 0) return 10000 - name.length
  if (at > 0) return 8000 - at * 10 - name.length
  var id = String((entry && entry.id) || "").toLowerCase()
  var idAt = id.indexOf(q)
  if (idAt === 0) return 7000 - id.length
  return 5000 - haystack.indexOf(terms[0])
}

// Returns [{ entry, checked }] sorted for display. With no query the checked
// apps come first so the launch set is always at the top of the list.
function sortedEntries(values, query, hiddenIds, checked) {
  var q = String(query || "").trim()
  var rows = []
  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    if (!entry || entry.noDisplay) continue
    var id = String(entry.id || "")
    if (!id || (hiddenIds && hiddenIds[id] === true)) continue
    var name = entryName(entry)
    if (!name) continue
    var s = score(entry, q)
    if (s < 0) continue
    rows.push({ entry: entry, id: id, checked: !!(checked && checked[id] === true), score: s, key: name.toLowerCase() })
  }
  rows.sort(function(a, b) {
    if (!q && a.checked !== b.checked) return a.checked ? -1 : 1
    if (q && a.score !== b.score) return b.score - a.score
    if (a.key < b.key) return -1
    if (a.key > b.key) return 1
    return 0
  })
  return rows
}

// Logical (scaled) monitor geometry from a `hyprctl monitors -j` object.
// `reserved` is [left, top, right, bottom] in logical pixels, e.g. the bar.
function usableArea(monitor) {
  var m = monitor || {}
  var scale = Number(m.scale) > 0 ? Number(m.scale) : 1
  var width = Math.round(Number(m.width || 0) / scale)
  var height = Math.round(Number(m.height || 0) / scale)
  var r = Array.isArray(m.reserved) && m.reserved.length === 4 ? m.reserved : [0, 0, 0, 0]
  return {
    x: Number(r[0]) || 0,
    y: Number(r[1]) || 0,
    width: Math.max(1, width - (Number(r[0]) || 0) - (Number(r[2]) || 0)),
    height: Math.max(1, height - (Number(r[1]) || 0) - (Number(r[3]) || 0))
  }
}

// Where the window goes: a full-height column `fraction` wide, hugging the
// requested side of the usable area. Coordinates are monitor-relative, which
// is what Hyprland's `move` window rule expects.
function geometry(monitor, fraction, side) {
  var area = usableArea(monitor)
  var f = Number(fraction) > 0 && Number(fraction) <= 1 ? Number(fraction) : 0.25
  var w = Math.max(1, Math.round(area.width * f))
  var x = side === "left" ? area.x : area.x + area.width - w
  return { x: x, y: area.y, width: w, height: area.height }
}

function shellQuote(value) {
  return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
}

function luaString(value) {
  return '"' + String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"'
}

// The shell command that starts a desktop entry. Same path the Omarchy menu
// uses: uwsm-app puts the app under app-graphical.slice, gtk-launch resolves
// the .desktop id (including ids with spaces or reverse-DNS names).
function launchCommand(desktopId) {
  // DesktopEntries ids never carry the suffix, and gtk-launch needs it even
  // for ids that happen to end in ".desktop" (org.telegram.desktop).
  return "uwsm-app -- gtk-launch " + shellQuote(String(desktopId || "") + ".desktop")
}

// Hyprland Lua dispatcher: exec with window rules attached, so the very first
// window the app maps is floated, sent to an empty workspace and placed.
function execDispatcher(desktopId, geom, workspace) {
  var ws = workspace || EMPTY_WORKSPACE
  return "hl.dsp.exec_cmd(" + luaString(launchCommand(desktopId)) + ", { float = true, workspace = "
    + luaString(ws) + ", size = { " + Math.round(geom.width) + ", " + Math.round(geom.height)
    + " }, move = { " + Math.round(geom.x) + ", " + Math.round(geom.y) + " } })"
}

function nearestFraction(value) {
  var v = Number(value)
  if (!(v > 0)) return FRACTIONS[0].value
  var best = FRACTIONS[0].value
  for (var i = 1; i < FRACTIONS.length; i++) {
    if (Math.abs(FRACTIONS[i].value - v) < Math.abs(best - v)) best = FRACTIONS[i].value
  }
  return best
}

function fractionLabel(value) {
  for (var i = 0; i < FRACTIONS.length; i++) {
    if (Math.abs(FRACTIONS[i].value - Number(value)) < 1e-6) return FRACTIONS[i].label
  }
  return String(value)
}

function nextFraction(value, delta) {
  var index = 0
  for (var i = 0; i < FRACTIONS.length; i++) {
    if (Math.abs(FRACTIONS[i].value - Number(value)) < 1e-6) index = i
  }
  var n = FRACTIONS.length
  return FRACTIONS[((index + (delta || 1)) % n + n) % n].value
}

function normalizeSide(value) {
  return value === "left" ? "left" : "right"
}

// Persisted state: the checked set plus the last layout choice.
function normalizeState(raw) {
  var obj = raw && typeof raw === "object" ? raw : {}
  var checked = {}
  var list = Array.isArray(obj.checked) ? obj.checked : []
  for (var i = 0; i < list.length; i++) {
    var id = String(list[i] || "").trim()
    if (id) checked[id] = true
  }
  return {
    version: 1,
    checked: checked,
    fraction: nearestFraction(obj.fraction),
    side: normalizeSide(obj.side)
  }
}

function serializeState(state) {
  var ids = Object.keys(state.checked || {}).sort()
  return JSON.stringify({ version: 1, checked: ids, fraction: state.fraction, side: state.side }, null, 2) + "\n"
}

if (typeof module !== "undefined") {
  module.exports = {
    FRACTIONS: FRACTIONS,
    SIDES: SIDES,
    EMPTY_WORKSPACE: EMPTY_WORKSPACE,
    entryName: entryName,
    entrySubtext: entrySubtext,
    score: score,
    sortedEntries: sortedEntries,
    usableArea: usableArea,
    geometry: geometry,
    shellQuote: shellQuote,
    luaString: luaString,
    launchCommand: launchCommand,
    execDispatcher: execDispatcher,
    nearestFraction: nearestFraction,
    fractionLabel: fractionLabel,
    nextFraction: nextFraction,
    normalizeState: normalizeState,
    serializeState: serializeState
  }
}
