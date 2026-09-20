// Run with: node tests/placement.test.js
const assert = require("assert")
const P = require("../Placement.js")

// Geometry: 1920x1200 @ 1.25 with a 26px top bar → logical 1536x960, usable 1536x934.
const mon = { name: "eDP-1", width: 1920, height: 1200, scale: 1.25, reserved: [0, 26, 0, 0], focused: true }
assert.deepStrictEqual(P.geometry(mon), { x: 1152, y: 26, width: 384, height: 934 })
assert.deepStrictEqual(P.geometry({}), { x: 0, y: 0, width: 1, height: 1 })
assert.strictEqual(P.pickMonitor([{ name: "a" }, mon]).name, "eDP-1")
assert.strictEqual(P.pickMonitor([]), null)

// Class guessing.
const nautilus = { id: "org.gnome.Nautilus", name: "Files", command: ["nautilus", "--new-window"] }
assert.deepStrictEqual(P.classCandidates(nautilus), ["org.gnome.Nautilus", "nautilus"])
const chromium = { id: "chromium", name: "Chromium", startupClass: "@@startup_wm_class", command: ["chromium"] }
assert.deepStrictEqual(P.classCandidates(chromium), ["chromium"])
const godot = { id: "org.godotengine.Godot", name: "Godot", startupClass: "Godot", command: ["/usr/bin/godot", "--editor"] }
assert.deepStrictEqual(P.classCandidates(godot), ["Godot", "org.godotengine.Godot", "godot"])
const webapp = { id: "Gmail", name: "Gmail", command: ["omarchy-launch-webapp", "https://mail.google.com"] }
assert.deepStrictEqual(P.classCandidates(webapp), ["Gmail"])
const env = { id: "x", name: "X", execString: "env FOO=1 /opt/x/bin/x-app --flag" }
assert.strictEqual(P.execProgram(env), "x-app")
const scoped = { id: "org.nickvision.tubeconverter", name: "Parabolic", command: ["systemd-run", "--user", "--scope", "parabolic"] }
assert.deepStrictEqual(P.classCandidates(scoped), ["org.nickvision.tubeconverter", "parabolic"])
assert.strictEqual(P.classPattern(["org.gnome.Nautilus", "nautilus"]), "^(org\\.gnome\\.Nautilus|nautilus)$")
assert.strictEqual(P.classPattern([]), "")

// Generated Lua.
const rows = [
  { id: "org.gnome.Nautilus", name: "Files", candidates: ["org.gnome.Nautilus", "nautilus"], float: true, quarter: true },
  { id: "foot", name: "Foot", candidates: ["foot"], float: true, quarter: false },
  { id: "code", name: "Code", candidates: ["Code"], float: false, quarter: false, emptyws: true },
  { id: "all", name: "All", candidates: ["all"], float: true, quarter: true, emptyws: true },
  { id: "skip", name: "Skip", candidates: ["skip"], float: false, quarter: false }
]
const lua = P.luaRules(rows, P.geometry(mon), "eDP-1")
const has = (s) => assert.ok(lua.indexOf(s) >= 0, "missing: " + s + "\n" + lua)
has('hl.window_rule({ match = { class = "^(org\\\\.gnome\\\\.Nautilus|nautilus)$", float = false }, float = true, size = { 384, 934 }, move = { 1152, 26 } })')
has('hl.window_rule({ match = { class = "^(foot)$", float = false }, float = true })')
has('hl.window_rule({ match = { class = "^(Code)$", float = false }, workspace = "emptym" })')
has('hl.window_rule({ match = { class = "^(all)$", float = false }, workspace = "emptym", float = true, size = { 384, 934 }, move = { 1152, 26 } })')
has("-- Code (code): empty workspace")
has("-- All (all): empty workspace, floating, 1/4 right")
assert.ok(lua.indexOf("skip") < 0)
assert.ok(P.luaRules([], P.geometry(mon), "").indexOf("No apps configured") > 0)

// State + toggles.
let apps = P.normalizeState({ apps: { a: { float: true }, b: { quarter: true }, c: { float: false }, d: { emptyws: true } } }).apps
assert.deepStrictEqual(apps, {
  a: { float: true, quarter: false, emptyws: false },
  b: { float: true, quarter: true, emptyws: false },
  d: { float: false, quarter: false, emptyws: true }
})
apps = P.toggled(apps, "a", "quarter")
assert.deepStrictEqual(apps.a, { float: true, quarter: true, emptyws: false })
apps = P.toggled(apps, "a", "emptyws")
assert.deepStrictEqual(apps.a, { float: true, quarter: true, emptyws: true })
apps = P.toggled(apps, "a", "float")
assert.deepStrictEqual(apps.a, { float: false, quarter: false, emptyws: true })  // unticking float clears quarter, keeps empty ws
apps = P.toggled(apps, "a", "emptyws")
assert.strictEqual(apps.a, undefined)          // nothing left → dropped
apps = P.toggled(apps, "z", "quarter")
assert.deepStrictEqual(apps.z, { float: true, quarter: true, emptyws: false })  // quarter implies float
assert.strictEqual(P.normalizeState(null).version, 1)
assert.deepStrictEqual(JSON.parse(P.serializeState({ apps: apps })).apps.z, { float: true, quarter: true, emptyws: false })

// Search + ordering: alphabetical by name, configured or not.
const list = [nautilus, godot, chromium, { id: "hidden", name: "Hidden", noDisplay: true }]
let out = P.sortedEntries(list, "", {}, { chromium: { emptyws: true } })
assert.deepStrictEqual(out.map(r => r.id), ["chromium", "org.gnome.Nautilus", "org.godotengine.Godot"]) // Chromium, Files, Godot
assert.strictEqual(out[0].emptyws, true)
out = P.sortedEntries(list, "", {}, { "org.godotengine.Godot": { float: true } })
assert.deepStrictEqual(out.map(r => r.id), ["chromium", "org.gnome.Nautilus", "org.godotengine.Godot"]) // still alphabetical
out = P.sortedEntries(list, "god", { chromium: true }, {})
assert.deepStrictEqual(out.map(r => r.id), ["org.godotengine.Godot"])

console.log("placement.test.js: all assertions passed")
