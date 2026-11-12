# huen-wm

A native macOS tiling window manager with Hyprland-inspired dwindle, master layout, Lua configuration, keyboard control, focused-window borders, and workspace snapshots. Requires macOS 14 or later and Zig **exactly 0.17.0**. SIP stays enabled.

The runtime compiles. Headless smoke checks cover configuration and CLI boundaries. Actual Accessibility placement, global hotkeys, borders, and workspace scenes remain unverified on a permission-granted desktop.

## Build

```sh
mise trust
mise install
mise run build
sh scripts/smoke.sh
sh scripts/bundle.sh
```

The signed development app is `zig-out/Huen WM.app`. The bundle script does not launch it. Run `sh scripts/bundle.sh --install` explicitly to copy it to `~/Applications/Huen WM.app`. Nothing installs a launch agent or login item. Ad-hoc signing keeps a stable bundle identifier, `dev.huen-wm`, but macOS may require renewed permission after rebuilding.

Lua 5.5.1 is compiled from checked-in, checksum-recorded upstream source. The mise Lua pin is for tooling, not a runtime dependency. `mise run check` uses hk quick hooks for formatting, names, and Lua syntax.

## Run deliberately

```sh
mkdir -p ~/.config/huen-wm
cp config/example.lua ~/.config/huen-wm/config.lua
"$HOME/Applications/Huen WM.app/Contents/MacOS/huen-wm" doctor
```

Grant Accessibility to the installed app manually in System Settings. `doctor` never prompts. Screen Recording is optional. Without it, workspace changes are instant and tiling still works.

First native check should manage only the disposable fixture. Do not run another tiling manager against the same windows.

```sh
"$HOME/Applications/Huen WM.app/Contents/MacOS/huen-wm" start --app dev.huen-wm.fixture
```

`start` runs in the foreground. Omitting `--app` opts into managing all eligible applications. `--config PATH` selects another Lua file. The installed app falls back to its bundled example when the user configuration does not exist.

## Control

Use the installed binary path in place of `huen-wm` below, or add its executable directory to `PATH`.

```sh
huen-wm status
huen-wm windows
huen-wm monitors
huen-wm workspaces
huen-wm focus left
huen-wm swap right
huen-wm move down
huen-wm resize 0.05
huen-wm toggle-floating
huen-wm layout master
huen-wm workspace 2
huen-wm send-to-workspace 3
huen-wm reload
huen-wm restore
huen-wm stop
```

Lists and command results are JSON. Workspace indices start at one. `resize` changes the split ratio. `move` makes the focused window floating and moves it 40 points from its current frame. `restore`, also named `recover`, attempts to restore geometry recorded during this live session and suspends tiling until restart. An incomplete restore returns an error with an `outstanding` count. Unminimize affected windows or leave native fullscreen, then retry `restore`. `stop`, `quit`, SIGINT, and SIGTERM attempt restoration before exiting and log outstanding failures.

The example binds Control+Option+H/J/K/L to directional focus. Names identify physical ANSI key positions, independent of the active input layout. Add Shift to swap. Control+Option+1 through 5 selects workspaces. Add Shift to send the focused window. Control+Option+Space toggles floating. Plus/minus changes the split ratio. Control+Option+R reloads.

## Configuration

Lua must return a table. See `config/example.lua` for the complete schema. A fresh, bounded Lua state evaluates every reload. Invalid fields, types, commands, duplicate bindings, and hotkey collisions reject the reload. The previous configuration and hotkeys stay active. File changes trigger reload automatically. Rules match an exact bundle ID and set `floating` or a numbered `workspace` on first discovery.

`motion_duration = 0` disables movement animation and workspace snapshot capture. Durations are capped at 0.5 seconds. Configuration has a one-million-instruction budget and a 16 MiB Lua allocation cap. The available libraries are base, table, string, and math. Filesystem, process, package loading, and dynamic code loading are unavailable.

## Workspace contract

Each monitor selects its workspace independently. Workspaces use reversible offscreen parking through public Accessibility APIs. They do not hide applications or minimize windows into the Dock. User-minimized and native-fullscreen windows are not moved. A fullscreen window conservatively blocks its display. Disconnected displays migrate window intent to the first remaining display.

With Screen Recording permission, a nonactivating display snapshot covers a workspace transaction. Source parking and destination placement are read back before focus changes and the snapshot fades. Rejected placements trigger rollback. This is not an atomic compositor operation. Apps may constrain geometry or reject parking, and status reports the last transition error. Public on-screen window metadata is a conservative native-space safety hint, not a private Space identifier.

`restore` can recover only windows retained by the current process. SIGKILL, crashes, and reboot cannot guarantee recovery because public AX identity is not durable. Do not rely on this build for unattended workspace parking. See [runtime details](docs/runtime.md).
