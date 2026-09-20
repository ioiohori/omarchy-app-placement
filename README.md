# App Placement for Omarchy

Per-app window placement settings for [Omarchy](https://omarchy.org/). Open
the panel, find an app, tick **Floating** and/or **1/4 Right**, done: from then
on that app opens floating, docked to the right quarter of the screen, no
matter how you launch it (menu, keybind, terminal, another app).

![App Placement overlay](preview.png)

It is a settings panel, not a launcher. The ticks become Hyprland window
rules, so the compositor places the window before it is first shown: no
flash of a tiled window, no per-launch flags.

## Install

```bash
omarchy plugin add https://github.com/ioiohori/omarchy-app-placement.git --enable
```

Bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + Q", "App placement settings", "omarchy-shell shell toggle ioiohori.app-placement")
```

`omarchy plugin enable` also puts a button on the bar (next to the Omarchy
menu). Move or remove it with `omarchy bar move` / `omarchy bar` like any widget.

## Use

| Key | Action |
|-----|--------|
| type | filter the list (name, description, keywords, id) |
| `↑` `↓` | move between apps |
| `←` `→` | move between the Floating and 1/4 Right columns |
| `Space` / `Enter` / click | toggle the highlighted checkbox |
| `Ctrl+D` | clear every setting |
| `Esc` | clear the filter, then close |

Rules:

- **Floating** opens the app's main window floating (Hyprland centers it).
- **1/4 Right** opens it floating in a full-height column a quarter of the
  screen wide, against the right edge, below the bar. Ticking it also ticks
  Floating; unticking Floating clears both.
- Changes apply immediately. The status line shows `Rules applied` or the
  `hyprctl configerrors` output if Hyprland rejected the file.
- Dialogs and other child windows of the app are left alone.

## Scripting

```bash
# Set one app without the UI.
omarchy-shell shell call ioiohori.app-placement set '{"id":"org.gnome.Nautilus","float":true,"quarter":true}'
# Clear it.
omarchy-shell shell call ioiohori.app-placement set '{"id":"org.gnome.Nautilus"}'
# Recompute the geometry for the current monitor and rewrite the rules
# (for example from a monitor hook).
omarchy-shell shell call ioiohori.app-placement regenerate ''
```

## How it works

- Apps come from Quickshell's `DesktopEntries`, minus `NoDisplay` entries and
  Omarchy's `launcher.hides` list.
- The window class is guessed from `StartupWMClass`, the desktop id and the
  executable name; all candidates are matched (`^(org\.gnome\.Nautilus|nautilus)$`)
  and shown under the app name so you can see what will be matched.
- Settings live in `~/.local/state/omarchy/app-placement.json`. On every
  change the plugin writes `~/.local/state/omarchy/toggles/hypr/app-placement.lua`
  and runs `hyprctl reload`. Omarchy re-requires that directory on every
  reload, so nothing in `~/.config/hypr` needs editing, and the file is
  loaded after your own config, so these rules win on conflict.
- The generated rule looks like this:

  ```lua
  hl.window_rule({ match = { class = "^(org\\.gnome\\.Nautilus|nautilus)$", float = false },
    float = true, size = { 384, 934 }, move = { 1152, 26 } })
  ```

  `float = false` in the match restricts it to the main window: Hyprland
  already treats parented toplevels (dialogs) as floating before rules run.
  The size and position are pixels for the focused monitor (logical size
  minus the reserved area, so the bar is respected), recomputed whenever a
  setting is saved or the panel is opened on a changed layout. Hyprland's
  `%` and `monitor_w` forms were tested and either ignored or overlapped the
  bar, hence pixels.

### Known limits

- Apps whose window class cannot be guessed from the desktop entry (some
  Chrome web apps, wrappers) will not match. Check the grey class line under
  the app name; add a `StartupWMClass=` to a local copy of the `.desktop`
  file if needed.
- With several monitors the column is sized for the focused monitor at save
  time. Call `regenerate` from a monitor hook if you switch often.

## Development

```bash
git clone https://github.com/ioiohori/omarchy-app-placement.git ~/.config/omarchy/plugins/ioiohori.app-placement
omarchy plugin validate ~/.config/omarchy/plugins/ioiohori.app-placement
node tests/placement.test.js     # pure logic: class guessing, geometry, generated Lua, state
omarchy restart shell            # keepLoaded plugin: QML edits need a restart
```

Requires Omarchy 4.x (Hyprland with the Lua config, Quickshell 0.3).

## 日本語

アプリごとのウィンドウ配置を設定するパネルです(ランチャーではありません)。
一覧からアプリを探して **Floating** / **1/4 Right** にチェックを入れると、
そのアプリはどこから起動しても floating で、画面右 1/4 の縦長カラムに開きます。

- インストール: `omarchy plugin add https://github.com/ioiohori/omarchy-app-placement.git --enable`
- キー割り当て: `o.bind("SUPER + SHIFT + Q", "App placement settings", "omarchy-shell shell toggle ioiohori.app-placement")`
- 仕組み: チェック内容から `~/.local/state/omarchy/toggles/hypr/app-placement.lua` に Hyprland のウィンドウルールを生成し `hyprctl reload` します。Omarchy がこのディレクトリを reload のたびに読み直すので、hyprland.lua の編集は不要です。
- 1/4 Right にチェックすると Floating も自動で入ります。ダイアログ等の子ウィンドウには適用されません。

## License

MIT
