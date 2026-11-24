# huen-wm

A native macOS tiling window manager with dwindle splits, tabbed and stacked groups, master layout, Lua configuration, keyboard modes, focused-window borders, workspace snapshots, and an optional menu-bar item. Mouse tiling and session continuity are opt-in. Requires macOS 14 or later and Zig **exactly 0.17.1**. SIP stays enabled.

Headless smoke checks cover configuration and CLI boundaries. Native fixture checks pass tiling, focus, movement, workspace parking and return, automatic reload, and original-frame restoration. Global hotkeys, border appearance, and scene appearance remain unverified.

The [feature-completion report](docs/verification-feature-completion.md) records final workflow checks, minimized-window recovery, measured responsiveness, and remaining limits.
The [workspace controls report](docs/workspace-controls-verification.md) records combined native acceptance of groups, mouse controls, restart continuity, and richer rules, with remaining limits.

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

`open` returns after launch. A direct executable invocation runs in the foreground but can have a different permission context. Omitting `--app` opts into managing all eligible applications. `--config PATH` selects another Lua file. The installed app falls back to its bundled example when the user configuration does not exist. Opening the app with no arguments, for example from Raycast, Finder, or Spotlight, starts it with the default configuration. A bare terminal invocation prints help.

## Control

Use the installed binary path in place of `huen-wm` below, or add its executable directory to `PATH`.

```sh
huen-wm status
huen-wm windows
huen-wm monitors
huen-wm workspaces
huen-wm focus left
huen-wm focus --wrap right
huen-wm focus last
huen-wm cycle next
huen-wm swap right
huen-wm swap next
huen-wm select parent
huen-wm select child
huen-wm tilemove right
huen-wm group join left
huen-wm group tabbed
huen-wm group stacked
huen-wm group next
huen-wm group split
huen-wm move down
huen-wm center
huen-wm move-by -40 0
huen-wm resize-by 40 0
huen-wm resize 0.05
huen-wm resize width 50
huen-wm split toggle
huen-wm fullscreen
huen-wm toggle-floating
huen-wm layout master
huen-wm workspace 2
huen-wm workspace previous
huen-wm workspace occupied+1
huen-wm send-to-workspace 3
huen-wm move-to-workspace name:Browse
huen-wm reload
huen-wm restore
huen-wm stop
```

Lists and command results are JSON. Workspace indices start at one. Workspace commands also accept `previous`, signed offsets, occupied offsets, `empty`, `next-empty`, and `name:` selectors. `move-to-workspace` sends the focused window and follows it. `focus last` returns to the previous window, `focus urgent` goes to a window that asked for focus on a hidden workspace, and `cycle` steps through the visible windows. `center`, `move-by`, and `resize-by` adjust floating geometry; `resize-by` also resizes tiles. `resize` changes the split ratio. `move` makes the focused window floating and moves it 40 points from its current frame. `restore`, also named `recover`, attempts to restore geometry recorded during this live session and suspends tiling until restart. An incomplete restore returns an error with an `outstanding` count. Unminimize affected windows or leave native fullscreen, then retry `restore`. `stop`, `quit`, SIGINT, and SIGTERM attempt restoration before exiting and log outstanding failures.

`resize width DELTA` and `resize height DELTA` resize the focused tile in logical points. `split` changes its nearest binary split. Managed `fullscreen` fills the visible display without creating a macOS Space and preserves the underlying layout. See [layout controls](docs/layout.md).

`select parent` and `select child` change the logical container selection without moving native focus. `tilemove` reparents that selection beside a directional neighbor. `group join` combines it with a neighbor. Groups support `tabbed`, `stacked`, `split`, `next`, and `previous`. Container edits require dwindle layout.

Named modes replace bindings transactionally. Application commands support bundle-ID launch, explicit shell execution, close, and conditional normal termination. See [commands and modes](docs/commands.md).

The example binds Control+Option+H/J/K/L to directional focus. Names identify physical ANSI key positions, independent of the active input layout. Add Shift to swap. Control+Option+1 through 5 selects workspaces. Add Shift to send the focused window. Control+Option+[ and ] step through occupied workspaces. Add Shift to move the focused window to the neighboring workspace and follow it. Control+Option+Tab focuses the previous window. Control+Option+U focuses an urgent window. Control+Option+C centers a floating window. Control+Option+Space toggles floating. Plus/minus changes the split ratio. Control+Option+R reloads.

## Configuration

Lua must return a table. `config/example.lua` provides basic settings. The [AeroSpace preset](docs/aerospace.md) adds Alt shortcuts, ten workspaces, resize mode, application actions, and external-monitor preference. Each evaluation runs in a fresh child of the same executable. Invalid fields, types, commands, duplicate bindings, and hotkey collisions reject the reload. Consumed tables cannot have metatables. Collections must be dense arrays without extra keys. The previous configuration and hotkeys stay active on failure. File changes trigger reload automatically.

[Window rules](docs/window-rules.md) match a bundle ID and an optional title, each by exact text, glob, or regular expression. They set floating state, a numbered workspace, floating geometry, or centering on first discovery. Later matching rules replace only the actions they specify.

`floating_size = { width = 0.5, height = 0.5 }` sets the size, as fractions of the usable display area from `0.1` to `1`, of a window that `toggle-floating` floats for the first time. It floats centered. A window that floated before returns to its last floating frame.

`single_window_max_width = 1800` limits the width, in points, of a window that is the only tiled window on its display. It is centered horizontally. The value is at least `400`, and absent or `0` means no limit. A larger learned application minimum wins. Managed fullscreen ignores the limit.

`border_width` and `border_color` style the focused-window border. Set `border_single_window = false` to hide it when the focused window is the only visible window on its workspace. Minimized windows and hidden group members do not count.

Set `mouse = { enabled = true, mods = "ctrl+alt" }` to enable mouse tiling. Hold Control+Option and drag a tile with the left button to rearrange it, or drag a shared boundary with the right button to resize it. Changes commit on release. On a floating window, the left button moves it and the right button resizes it from the nearest corner, as in Hyprland. Escape or modifier loss cancels. These gestures require eligible dwindle tiles. See [mouse controls](docs/mouse-controls.md).

Set `session = { enabled = true }` to save logical layout after clean original-frame restoration. A normal manager restart can restore uniquely identified windows while their applications remain open. Missing or ambiguous public identities remain unmatched. This does not restore arbitrary application relaunches or reboots. See [session continuity](docs/session.md).

`status_bar = { enabled = true, label = "name" }` is the default, including when omitted. Labels accept `name`, `index`, or `index_and_name`. Combined labels omit a name equal to its index. The menu-bar title shows the active monitor's committed workspace, shortened to 24 Unicode characters. With `workspace_monitors`, a monitor without a placed workspace shows `—`. Its tooltip includes the monitor and full workspace name.

The menu offers all configured workspaces, **Reload configuration**, and **Quit**. Workspace actions use the active monitor, not the screen containing the menu bar. Pending transitions keep the old title and checkmark until placement completes. Workspace actions are disabled during transitions, without monitors, or after restore. Restore shows **Paused**. Switch failures appear in the tooltip and `status.transition_error`. Placement failures and rejected menu commands also write to stderr.

Set `enabled = false` to remove the item. A successful reload can enable it again. Invalid reloads retain the previous settings. Workspace changes no longer show a centered popup.

`reload` returns `accepted` and a `request_id` before evaluation finishes. `status.config_reload` reports the request ID, `pending`, `ready`, or `failed`, and `err_message`. A second request fails with `ConfigLoadPending` while the first request is in flight. Workspace transitions defer automatic reloads and publication of completed candidates. Restore and quit cancel pending configuration work.

`motion_duration = 0` disables movement animation and workspace snapshot capture. Durations are capped at 0.5 seconds. The supervisor uses a one-second monotonic deadline, including Lua work in native libraries. This is a rejection policy, not a startup performance guarantee. Source files are limited to 256 KiB, normalized responses to 128 KiB, and captured error output to 4 KiB. The one-million-instruction hook and 16 MiB Lua allocation cap remain secondary limits. The available libraries are base, table, string, and math. Filesystem, process, package loading, and dynamic code loading are unavailable. User `print` output is discarded and cannot alter the private response. `validate --config PATH` uses the same isolated evaluator without starting the manager.

## Workspace contract

Monitors select workspaces independently by default. Optional `workspace_monitors = { "external", "built-in" }` routes all workspaces to a preferred owner. A workspace `monitor` field splits workspaces across displays, and `move-workspace-to-monitor` moves one at runtime. `mouse_follows_monitor = true` enables lazy pointer centering after monitor selection. Disconnected-display migration preserves workspace numbers. See [monitor routing](docs/monitors.md) for migration and rollback behavior.

Returning to a workspace restores its last eligible focused window, with managed fullscreen taking priority. Set `workspace_back_and_forth = true` to make selecting the current workspace return to the previous one. Closed, minimized, or unavailable windows do not receive focus.

When an application takes focus for a window on a hidden workspace, as when a link opens in a browser there, the workspace does not change. The window becomes urgent, the menu marks its workspace with a dot, and `focus urgent` goes to it. Set `focus_on_activate = true` to follow such a window to its workspace instead. A window rule can set `focus_on_activate` for its windows. See [activation requests](docs/commands.md#activation-requests).

Workspaces use reversible corner parking through public Accessibility APIs. macOS requires a narrow edge of parked windows to remain visible. They do not hide applications or minimize windows into the Dock. User-minimized and native-fullscreen windows are not moved. A native fullscreen window conservatively blocks its display.

With Screen Recording permission, a nonactivating display snapshot covers a workspace transaction. Source parking and destination placement are read back before focus changes and the snapshot fades. Rejected placements trigger rollback. This is not an atomic compositor operation. Apps may constrain geometry or reject parking, and status reports the last transition error. Public on-screen window metadata is a conservative native-space safety hint, not a private Space identifier.

`restore` returns windows retained by the current process. After SIGKILL or a crash, the next start returns parked windows of still-running applications to their pre-parking frames from a parking journal. It does not recover workspace membership. Applications that a reboot ends cannot be recovered. Do not rely on this build for unattended workspace parking. See [runtime details](docs/runtime.md).
