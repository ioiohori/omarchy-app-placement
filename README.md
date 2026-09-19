# Quarter Launcher for Omarchy

A checklist launcher for [Omarchy](https://omarchy.org/). Tick the apps you
want, press Enter, and each one opens **floating**, on an **empty workspace**,
docked to the **right quarter** of the screen (1/3, 1/2 and the left side are
one Tab away). The ticked set is remembered, so your usual "side column" apps
are a single keypress next time.

![Quarter Launcher overlay](preview.png)

## Install

```bash
omarchy plugin add https://github.com/ioiohori/omarchy-quarter-launcher.git --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + Q", "Quarter launcher", "omarchy-shell shell toggle ioiohori.quarter-launcher")
```

Optionally add the bar button next to the Omarchy menu:

```bash
omarchy bar add ioiohori.quarter-launcher --section left
```

## Use

| Key | Action |
|-----|--------|
| type | filter the list (name, description, keywords, id) |
| `Space` / click | tick or untick the highlighted app |
| `Enter` / double-click | launch every ticked app (or the highlighted one when nothing is ticked) |
| `Tab` | cycle width: 1/4 → 1/3 → 1/2 |
| `Shift+Tab` | switch side: right ↔ left |
| `Ctrl+D` | clear all ticks |
| `Esc` | clear the filter, then close |

Each launched app gets its own empty workspace: Hyprland picks the first empty
workspace on the focused monitor when the window maps, so launching three apps
gives three workspaces, each with one window in the side column.

## Scripting

The overlay also answers shell IPC, so keybinds and scripts can skip the UI:

```bash
# Launch desktop-entry ids with the current width/side.
omarchy-shell shell call ioiohori.quarter-launcher launch '["Alacritty","org.gnome.Nautilus"]'

# Where the next window would go, as monitor-relative logical pixels.
omarchy-shell shell call ioiohori.quarter-launcher geometry ''

# Open with a one-off layout.
omarchy-shell shell summon ioiohori.quarter-launcher '{"fraction":0.5,"side":"left"}'
```

## How it works

The plugin runs inside the long-lived `omarchy-shell` (Quickshell) process as
an `overlay` plugin, so opening it is an IPC call, not a cold start. Apps come
from Quickshell's `DesktopEntries`, minus `NoDisplay` entries and Omarchy's
`launcher.hides` list, and launch through the same
`uwsm-app -- gtk-launch <id>.desktop` path the built-in menu uses.

Placement uses Hyprland's Lua dispatcher with window rules attached to the
exec, so the very first window the app maps is floated, moved to an empty
workspace and sized before it is ever shown:

```lua
hl.dsp.exec_cmd("uwsm-app -- gtk-launch 'Alacritty.desktop'",
  { float = true, workspace = "emptym", size = { 384, 934 }, move = { 1152, 26 } })
```

Geometry is computed from `hyprctl monitors -j` (logical size minus the
reserved area, so the bar is respected). State lives in
`~/.local/state/omarchy/quarter-launcher.json`.

### Known limits

- Single-instance apps that forward to an already running process (a second
  Chrome window, for example) open a window the exec rules cannot reach; it
  follows that app's normal placement.
- Apps whose first window is a splash screen get the rules applied to the
  splash, not the main window.

## Development

```bash
git clone https://github.com/ioiohori/omarchy-quarter-launcher.git \
  ~/.config/omarchy/plugins/ioiohori.quarter-launcher
omarchy plugin validate ~/.config/omarchy/plugins/ioiohori.quarter-launcher
node tests/launcher.test.js      # pure-logic tests (search, geometry, dispatcher string)
omarchy restart shell            # the plugin is keepLoaded, so QML edits need a restart
```

Requires Omarchy 4.x (Hyprland with the Lua config, Quickshell 0.3).

## 日本語

チェックリスト式のランチャーです。アプリにチェックを入れて Enter を押すと、
それぞれが **floating** で **空のワークスペース** に、画面の **右 1/4** に
寄せて開きます(Tab で 1/3・1/2、Shift+Tab で左右を切替)。チェックした
組み合わせは記憶されます。

- インストール: `omarchy plugin add https://github.com/ioiohori/omarchy-quarter-launcher.git --enable`
- キー割り当て: `o.bind("SUPER + SHIFT + Q", "Quarter launcher", "omarchy-shell shell toggle ioiohori.quarter-launcher")`
- 配置の仕組み: Hyprland の `hl.dsp.exec_cmd` にウィンドウルール(float / workspace=emptym / size / move)を付けて起動するので、最初のウィンドウが表示される前に位置とサイズが決まります。

## License

MIT
