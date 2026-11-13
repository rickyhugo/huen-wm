# huen-wm

A native macOS tiling window manager with persistent dwindle splits, master layout, Lua configuration, keyboard modes, focused-window borders, workspace snapshots, and an optional menu-bar item. Requires macOS 14 or later and Zig **exactly 0.17.0**. SIP stays enabled.

Headless smoke checks cover configuration and CLI boundaries. Native fixture checks pass tiling, focus, movement, workspace parking and return, automatic reload, and original-frame restoration. Global hotkeys, border appearance, and scene appearance remain unverified.

## Build

```sh
mise trust
mise install
mise run build
sh scripts/smoke.sh
sh scripts/bundle.sh
```

The signed development app is `zig-out/Huen WM.app`. The bundle script does not launch it. Run `sh scripts/bundle.sh --install` explicitly to copy it to `~/Applications/Huen WM.app`. Nothing installs a launch agent or login item. Ad-hoc signing keeps a stable bundle identifier, `dev.huen-wm`, but macOS may require renewed permission after rebuilding.

To enable startup separately, use the [opt-in login helper](docs/login-startup.md).

Lua 5.5.1 is compiled from checked-in, checksum-recorded upstream source. The mise Lua pin is for tooling, not a runtime dependency. `mise run check` uses hk quick hooks for formatting, names, and Lua syntax.

## Run deliberately

```sh
mkdir -p ~/.config/huen-wm
cp config/example.lua ~/.config/huen-wm/config.lua
open -n -g -a "$HOME/Applications/Huen WM.app" --args doctor
```

Grant Accessibility to the installed app manually in System Settings. Launch through `open` so macOS checks the app's permissions rather than the terminal's permission context. `doctor` never prompts. Use `open --stdout /absolute/path/doctor.json` to save its output. Screen Recording is optional. Without it, workspace changes are instant and tiling still works.

First native check should manage only the disposable fixture. Do not run another tiling manager against the same windows.

```sh
open -n -g -a "$HOME/Applications/Huen WM.app" --args start --app dev.huen-wm.fixture
```

`open` returns after launch. A direct executable invocation runs in the foreground but can have a different permission context. Omitting `--app` opts into managing all eligible applications. `--config PATH` selects another Lua file. The installed app falls back to its bundled example when the user configuration does not exist.

## Control

Use the installed binary path in place of `huen-wm` below, or add its executable directory to `PATH`.

```sh
huen-wm status
huen-wm windows
huen-wm monitors
huen-wm workspaces
huen-wm focus left
huen-wm focus --wrap right
huen-wm swap right
huen-wm move down
huen-wm resize 0.05
huen-wm resize width 50
huen-wm split toggle
huen-wm fullscreen
huen-wm toggle-floating
huen-wm layout master
huen-wm workspace 2
huen-wm send-to-workspace 3
huen-wm reload
huen-wm restore
huen-wm stop
```

Lists and command results are JSON. Workspace indices start at one. `resize` changes the split ratio. `move` makes the focused window floating and moves it 40 points from its current frame. `restore`, also named `recover`, attempts to restore geometry recorded during this live session and suspends tiling until restart. An incomplete restore returns an error with an `outstanding` count. Unminimize affected windows or leave native fullscreen, then retry `restore`. `stop`, `quit`, SIGINT, and SIGTERM attempt restoration before exiting and log outstanding failures.

`resize width DELTA` and `resize height DELTA` resize the focused tile in logical points. `split` changes its nearest binary split. Managed `fullscreen` fills the visible display without creating a macOS Space and preserves the underlying layout. See [layout controls](docs/layout.md).

Named modes replace bindings transactionally. Application commands support bundle-ID launch, explicit shell execution, close, and conditional normal termination. See [commands and modes](docs/commands.md).

The example binds Control+Option+H/J/K/L to directional focus. Names identify physical ANSI key positions, independent of the active input layout. Add Shift to swap. Control+Option+1 through 5 selects workspaces. Add Shift to send the focused window. Control+Option+Space toggles floating. Plus/minus changes the split ratio. Control+Option+R reloads.

## Configuration

Lua must return a table. `config/example.lua` provides basic settings. The [AeroSpace preset](docs/aerospace.md) adds Alt shortcuts, ten workspaces, resize mode, application actions, and external-monitor preference. Each evaluation runs in a fresh child of the same executable. Invalid fields, types, commands, duplicate bindings, and hotkey collisions reject the reload. Consumed tables cannot have metatables. Collections must be dense arrays without extra keys. The previous configuration and hotkeys stay active on failure. File changes trigger reload automatically. Rules match an exact bundle ID and set `floating` or a numbered `workspace` on first discovery.

`status_bar = { enabled = true, label = "name" }` is the default, including when omitted. Labels accept `name`, `index`, or `index_and_name`. Combined labels omit a name equal to its index. The menu-bar title shows the active monitor's committed workspace, shortened to 24 Unicode characters. Its tooltip includes the monitor and full workspace name.

The menu offers all configured workspaces, **Reload configuration**, and **Quit**. Workspace actions use the active monitor, not the screen containing the menu bar. Pending transitions keep the old title and checkmark until placement completes. Workspace actions are disabled during transitions, without monitors, or after restore. Restore shows **Paused**. Switch failures appear in the tooltip and `status.transition_error`. Placement failures and rejected menu commands also write to stderr.

Set `enabled = false` to remove the item. A successful reload can enable it again. Invalid reloads retain the previous settings. Workspace changes no longer show a centered popup.

`reload` returns `accepted` and a `request_id` before evaluation finishes. `status.config_reload` reports the request ID, `pending`, `ready`, or `failed`, and `err_message`. A second request fails with `ConfigLoadPending` while the first request is in flight. Workspace transitions defer automatic reloads and publication of completed candidates. Restore and quit cancel pending configuration work.

`motion_duration = 0` disables movement animation and workspace snapshot capture. Durations are capped at 0.5 seconds. The supervisor uses a one-second monotonic deadline, including Lua work in native libraries. This is a rejection policy, not a startup performance guarantee. Source files are limited to 256 KiB, normalized responses to 128 KiB, and captured error output to 4 KiB. The one-million-instruction hook and 16 MiB Lua allocation cap remain secondary limits. The available libraries are base, table, string, and math. Filesystem, process, package loading, and dynamic code loading are unavailable. User `print` output is discarded and cannot alter the private response. `validate --config PATH` uses the same isolated evaluator without starting the manager.

## Workspace contract

Monitors select workspaces independently by default. Optional `workspace_monitors = { "external", "built-in" }` routes all workspaces to a preferred owner. `mouse_follows_monitor = true` enables lazy pointer centering after monitor selection. Disconnected-display migration preserves workspace numbers. See [monitor routing](docs/monitors.md) for migration and rollback behavior.

Workspaces use reversible corner parking through public Accessibility APIs. macOS requires a narrow edge of parked windows to remain visible. They do not hide applications or minimize windows into the Dock. User-minimized and native-fullscreen windows are not moved. A native fullscreen window conservatively blocks its display.

With Screen Recording permission, a nonactivating display snapshot covers a workspace transaction. Source parking and destination placement are read back before focus changes and the snapshot fades. Rejected placements trigger rollback. This is not an atomic compositor operation. Apps may constrain geometry or reject parking, and status reports the last transition error. Public on-screen window metadata is a conservative native-space safety hint, not a private Space identifier.

`restore` can recover only windows retained by the current process. SIGKILL, crashes, and reboot cannot guarantee recovery because public AX identity is not durable. Do not rely on this build for unattended workspace parking. See [runtime details](docs/runtime.md).
