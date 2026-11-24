# huen-wm

A tiling window manager for macOS that keeps SIP on and its hands off private APIs. You write the config in Lua, and your windows stay tidy.

- **Layouts:** dwindle splits, master layout, and tabbed or stacked groups.
- **Workspaces:** switch with a snapshot fade, per monitor or routed across monitors.
- **Keyboard first:** global hotkeys and named modes, such as a resize mode.
- **Nice extras:** a focused-window border, a menu-bar item, mouse tiling, trackpad swipes, and placement memory.
- **Safe exits:** quitting puts every window back where it was.

You need macOS 14 or later and Zig **exactly 0.17.1**. mise installs it.

## Get it running

```sh
mise trust && mise install
mise run build
mise run smoke                     # headless checks
sh scripts/bundle.sh --install     # signs and copies to ~/Applications/Huen WM.app
```

Nothing launches itself, and nothing adds a login item. The [login helper](docs/login-startup.md) does that if you want it. The app is ad-hoc signed as `dev.huen-wm`, so macOS can ask for permission again after a rebuild.

Then add a config and ask the doctor:

```sh
mkdir -p ~/.config/huen-wm
cp config/example.lua ~/.config/huen-wm/config.lua
open -n -g -a "$HOME/Applications/Huen WM.app" --args doctor
```

Grant **Accessibility** to the app in System Settings. Two permissions are optional:

- **Screen Recording** adds the workspace fade. Without it, switches are instant.
- **Input Monitoring** enables trackpad swipes, and it recovers hotkeys that macOS drops.

The manager never asks for any permission. Launch it with `open`, so macOS checks the app's permissions and not the terminal's. To save the doctor's report, add `--stdout /absolute/path/doctor.json` to `open`.

### First run: try the fixture

Let it manage only the throwaway fixture app before you give it your real windows. Never run two tiling managers on the same windows.

```sh
open -n -g -a "$HOME/Applications/Huen WM.app" --args start --app dev.huen-wm.fixture
```

Drop `--app` to manage everything. Opening the app with no arguments, for example from Raycast, Spotlight or Finder, starts it with your config.

> **Menu-bar item missing?** On macOS 26, an app started from inside another app's terminal can be filed under that app in **System Settings → Menu Bar → Allow in the Menu Bar**. Start it from Raycast, Spotlight or Finder instead.

## Drive it

Everything is a command. Bind commands to keys, or run them from a shell. Replies are JSON.

```sh
huen-wm focus left                 # or: --wrap right, last, urgent
huen-wm swap right
huen-wm workspace 2                # or: previous, occupied+1, name:Browse
huen-wm move-to-workspace 3        # send the window and follow it
huen-wm move-app com.apple.Safari 2
huen-wm group tabbed               # tabbed, stacked, split, next…
huen-wm resize width 50
huen-wm toggle-floating
huen-wm layout master
huen-wm status                     # also: windows, monitors, workspaces
huen-wm restore                    # put every window back and pause tiling
huen-wm stop                       # restore, then exit
```

`huen-wm` means the binary in `~/Applications/Huen WM.app/Contents/MacOS/`. A bare `huen-wm` prints help. The [command reference](docs/commands.md) lists every command and selector.

## Configure it

The config is a Lua table, and the manager reloads it when you save the file. A broken config is rejected, and the last good config keeps running. Each evaluation runs in a sandboxed child process.

```lua
return {
    gap = 12,
    border_color = "#9bafff",
    status_bar = { label = "index", style = "badge" },  -- a menu-bar badge like ①
    swipe = { enabled = true, fingers = 3 },
    single_window_max_width = 1800,                     -- nice on an ultrawide
    bindings = {
        { mods = "ctrl+alt", key = "h", command = "focus left" },
        { mods = "ctrl+alt", key = "1", command = "workspace 1" },
    },
}
```

Start from [`config/example.lua`](config/example.lua), which uses Control+Option with H/J/K/L. The [AeroSpace preset](docs/aerospace.md) uses Alt shortcuts. The [configuration reference](docs/configuration.md) explains every key, and [window rules](docs/window-rules.md) put apps where they belong.

## Before you trust it

- Hidden workspaces park windows in a screen corner through public Accessibility APIs. Apps can resist, and a sliver of each parked window stays visible. See [workspaces](docs/workspaces.md).
- After a crash, the next start pulls parked windows back for apps that are still running. Workspace membership is lost, and a reboot loses everything.
- Native checks pass tiling, focus, parking, reload and restore on a fixture. Physical hotkeys, borders and the fade are not verified yet. The [verification report](docs/verification-feature-completion.md) and [workspace controls report](docs/workspace-controls-verification.md) have the details.

Don't leave it parking windows unattended yet.

## More docs

[Layout](docs/layout.md) · [Monitors](docs/monitors.md) · [Mouse](docs/mouse-controls.md) · [Sessions](docs/session.md) · [Runtime](docs/runtime.md) · [Tooling](docs/tooling.md)
