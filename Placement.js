// Pure helpers for App Placement: app-list filtering, window-class guessing,
// geometry and the generated Hyprland Lua rules. No QML imports, so
// `node tests/placement.test.js` can exercise everything here.

var FRACTION = 0.25          // width of the side column
var SIDE = "right"

// Exec names that say nothing about the window class.
var GENERIC_EXECS = {
  "sh": true, "bash": true, "zsh": true, "env": true, "flatpak": true, "snap": true,
  "systemd-run": true, "xdg-open": true, "gtk-launch": true, "uwsm-app": true, "uwsm": true,
  "python": true, "python3": true, "node": true, "electron": true, "java": true, "wine": true,
  "omarchy-launch-webapp": true, "omarchy-launch-or-focus-webapp": true,
  "omarchy-launch-or-focus": true, "omarchy-launch-tui": true, "omarchy-launch-or-focus-tui": true,
  "xdg-terminal-exec": true, "libreoffice": true
}

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

function basename(path) {
  var value = String(path || "")
  var slash = value.lastIndexOf("/")
  return slash >= 0 ? value.slice(slash + 1) : value
}

// First real program in an Exec line: skip VAR=value prefixes and the
// wrappers in GENERIC_EXECS (env, flatpak, systemd-run …).
function execProgram(entry) {
  var argv = []
  try {
    if (entry && entry.command && typeof entry.command.length === "number") {
      for (var i = 0; i < entry.command.length; i++) argv.push(String(entry.command[i]))
    }
  } catch (e) {
  }
  if (argv.length === 0 && entry && entry.execString) argv = String(entry.execString).split(/\s+/)
  for (var j = 0; j < argv.length; j++) {
    var token = argv[j]
    if (!token || token.indexOf("=") > 0 || token.charAt(0) === "-" || token.charAt(0) === "@") continue
    if (token.indexOf("://") >= 0) continue   // URL argument of a web-app launcher
    var name = basename(token)
    if (GENERIC_EXECS[name.toLowerCase()]) continue
    return name
  }
  return ""
}

// Window-class guesses for an entry, most reliable first: StartupWMClass,
// the desktop id (reverse-DNS ids are usually the Wayland app id) and the
// executable name. Duplicates removed, order kept.
function classCandidates(entry) {
  var out = []
  var seen = {}
  function add(value) {
    var v = String(value || "").trim()
    if (!v || v.charAt(0) === "@" || seen[v]) return
    seen[v] = true
    out.push(v)
  }
  add(entry && entry.startupClass)
  add(entry && entry.id)
  add(execProgram(entry))
  return out
}

function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&")
}

// Anchored alternation, e.g. ^(org\.gnome\.Nautilus|nautilus)$
function classPattern(candidates) {
  var parts = []
  for (var i = 0; i < candidates.length; i++) parts.push(escapeRegex(candidates[i]))
  return parts.length ? "^(" + parts.join("|") + ")$" : ""
}

// Returns [{ entry, id, name, candidates, float, quarter }] sorted for display.
// With no query, configured apps come first so the active set is on top.
function sortedEntries(values, query, hiddenIds, apps) {
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
    var conf = apps && apps[id] ? apps[id] : {}
    rows.push({
      entry: entry, id: id, name: name, candidates: classCandidates(entry),
      float: conf.float === true, quarter: conf.quarter === true,
      configured: conf.float === true || conf.quarter === true,
      score: s, key: name.toLowerCase()
    })
  }
  rows.sort(function(a, b) {
    if (!q && a.configured !== b.configured) return a.configured ? -1 : 1
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

// The side column: FRACTION of the usable width, full usable height, hugging
// SIDE. Monitor-relative pixels, which is what Hyprland's move rule wants.
function geometry(monitor) {
  var area = usableArea(monitor)
  var w = Math.max(1, Math.round(area.width * FRACTION))
  var x = SIDE === "left" ? area.x : area.x + area.width - w
  return { x: x, y: area.y, width: w, height: area.height }
}

// Pick the monitor the rules should be sized for: the focused one.
function pickMonitor(list) {
  var rows = Array.isArray(list) ? list : []
  for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].focused === true) return rows[i]
  return rows.length ? rows[0] : null
}

function luaString(value) {
  return '"' + String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"'
}

// The generated Hyprland Lua. One rule per configured app. `float = false`
// in the match keeps it to the main window: dialogs and other parented
// toplevels are already floating when rules run, so they are left alone.
function luaRules(rows, geom, monitorName) {
  var lines = [
    "-- Generated by the App Placement plugin (ioiohori.app-placement).",
    "-- Do not edit: it is rewritten whenever a setting changes.",
    "-- Geometry: " + geom.width + "x" + geom.height + " at " + geom.x + "," + geom.y
      + (monitorName ? " on " + monitorName : "") + ".",
    ""
  ]
  var count = 0
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || (!row.float && !row.quarter)) continue
    var pattern = classPattern(row.candidates || [])
    if (!pattern) continue
    count++
    var rule = "hl.window_rule({ match = { class = " + luaString(pattern) + ", float = false }, float = true"
    if (row.quarter) {
      rule += ", size = { " + Math.round(geom.width) + ", " + Math.round(geom.height) + " }"
        + ", move = { " + Math.round(geom.x) + ", " + Math.round(geom.y) + " }"
    }
    rule += " })"
    lines.push("-- " + row.name + " (" + row.id + ")" + (row.quarter ? ": floating, 1/4 right" : ": floating"))
    lines.push(rule)
  }
  if (count === 0) lines.push("-- No apps configured.")
  return lines.join("\n") + "\n"
}

// Persisted state: { version, apps: { id: { float, quarter } } }.
// quarter implies float, and entries with nothing set are dropped.
function normalizeApp(conf) {
  var c = conf && typeof conf === "object" ? conf : {}
  var quarter = c.quarter === true
  var float = c.float === true || quarter
  return { float: float, quarter: quarter }
}

function normalizeState(raw) {
  var obj = raw && typeof raw === "object" ? raw : {}
  var apps = {}
  var src = obj.apps && typeof obj.apps === "object" ? obj.apps : {}
  for (var id in src) {
    var key = String(id || "").trim()
    if (!key) continue
    var conf = normalizeApp(src[id])
    if (conf.float || conf.quarter) apps[key] = conf
  }
  return { version: 1, apps: apps }
}

// Apply one toggle and return the new apps map (input untouched).
function toggled(apps, id, column) {
  var next = {}
  for (var key in apps) next[key] = { float: apps[key].float === true, quarter: apps[key].quarter === true }
  var cur = next[id] || { float: false, quarter: false }
  if (column === "quarter") {
    cur.quarter = !cur.quarter
    if (cur.quarter) cur.float = true
  } else {
    cur.float = !cur.float
    if (!cur.float) cur.quarter = false
  }
  if (cur.float || cur.quarter) next[id] = cur
  else delete next[id]
  return next
}

function serializeState(state) {
  var ids = Object.keys(state.apps || {}).sort()
  var apps = {}
  for (var i = 0; i < ids.length; i++) apps[ids[i]] = normalizeApp(state.apps[ids[i]])
  return JSON.stringify({ version: 1, apps: apps }, null, 2) + "\n"
}

if (typeof module !== "undefined") {
  module.exports = {
    FRACTION: FRACTION, SIDE: SIDE,
    entryName: entryName, entrySubtext: entrySubtext, score: score,
    execProgram: execProgram, classCandidates: classCandidates, classPattern: classPattern,
    sortedEntries: sortedEntries, usableArea: usableArea, geometry: geometry, pickMonitor: pickMonitor,
    luaString: luaString, luaRules: luaRules,
    normalizeState: normalizeState, toggled: toggled, serializeState: serializeState
  }
}
