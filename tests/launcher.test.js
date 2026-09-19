// Run with: node tests/launcher.test.js
const assert = require("assert")
const L = require("../Launcher.js")

// Geometry: 1920x1200 @ 1.25 with a 26px top bar → logical 1536x960, usable 1536x934.
const mon = { width: 1920, height: 1200, scale: 1.25, reserved: [0, 26, 0, 0] }
assert.deepStrictEqual(L.geometry(mon, 0.25, "right"), { x: 1152, y: 26, width: 384, height: 934 })
assert.deepStrictEqual(L.geometry(mon, 0.25, "left"), { x: 0, y: 26, width: 384, height: 934 })
assert.deepStrictEqual(L.geometry(mon, 0.5, "right"), { x: 768, y: 26, width: 768, height: 934 })
assert.deepStrictEqual(L.geometry({}, 0.25, "right").width, 1)

// Dispatcher string: shell-quoted id, Lua-escaped, pixel geometry.
const d = L.execDispatcher("org.telegram.desktop", L.geometry(mon, 0.25, "right"))
assert.strictEqual(d,
  'hl.dsp.exec_cmd("uwsm-app -- gtk-launch \'org.telegram.desktop.desktop\'", { float = true, workspace = "emptym", size = { 384, 934 }, move = { 1152, 26 } })')
assert.ok(L.execDispatcher("Weird \"App\" it's", { x: 0, y: 0, width: 1, height: 1 }).indexOf('\\"') > 0)

// Search + ordering.
const apps = [
  { id: "firefox", name: "Firefox", genericName: "Web Browser", keywords: ["internet"] },
  { id: "org.gnome.Nautilus", name: "Files", genericName: "File Manager" },
  { id: "hidden", name: "Hidden", noDisplay: true },
  { id: "btop", name: "btop" },
  { id: "Alacritty", name: "Alacritty", comment: "A fast terminal" }
]
const hidden = { btop: true }
let rows = L.sortedEntries(apps, "", hidden, { "org.gnome.Nautilus": true })
assert.deepStrictEqual(rows.map(r => r.id), ["org.gnome.Nautilus", "Alacritty", "firefox"])
rows = L.sortedEntries(apps, "web", hidden, {})
assert.deepStrictEqual(rows.map(r => r.id), ["firefox"])
rows = L.sortedEntries(apps, "fi", hidden, {})
assert.deepStrictEqual(rows.map(r => r.id), ["org.gnome.Nautilus", "firefox"]) // shorter prefix match first
rows = L.sortedEntries(apps, "fast term", hidden, {})
assert.deepStrictEqual(rows.map(r => r.id), ["Alacritty"])

// State round-trip.
const s = L.normalizeState({ checked: ["a", "", "b"], fraction: 0.34, side: "bogus" })
assert.deepStrictEqual(Object.keys(s.checked), ["a", "b"])
assert.strictEqual(s.fraction, 1 / 3)
assert.strictEqual(s.side, "right")
assert.strictEqual(L.normalizeState(null).fraction, 0.25)
assert.strictEqual(JSON.parse(L.serializeState(s)).fraction, 1 / 3)
assert.strictEqual(L.nextFraction(0.5, 1), 0.25)
assert.strictEqual(L.nextFraction(0.25, -1), 0.5)
assert.strictEqual(L.fractionLabel(1 / 3), "1/3")

console.log("launcher.test.js: all assertions passed")
