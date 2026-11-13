# AeroSpace preset

[`config/aerospace.lua`](../config/aerospace.lua) preserves the numbered-workspace
workflow with Huen WM commands. It does not install itself or change AeroSpace.
The user configuration lives at `~/.config/huen-wm/config.lua`.
Build, installation, and permissions use the [existing setup](../README.md#run-deliberately).

## Bindings

Alt means Option. Key names refer to physical ANSI positions.
The preset has 37 main bindings and six resize-mode bindings.

| Keys | Action |
| --- | --- |
| Alt+H/J/K/L | Focus left/down/up/right, with wrap on the current display and workspace. |
| Alt+Shift+H/J/K/L | Swap in that direction. |
| Alt+1 through 9, Alt+0 | Select workspace 1 through 10. |
| Alt+Shift+1 through 9, Alt+Shift+0 | Send the window to workspace 1 through 10 without following it. |
| Alt+Return | Request a new Ghostty instance. |
| Alt+B | Request a new Google Chrome instance. |
| Alt+Shift+Q | Close, then request normal app termination if no windows remain. |
| Alt+F | Toggle managed fullscreen. |
| Alt+E | Toggle the nearest binary split orientation. |
| Alt+Shift+Space | Toggle floating. |
| Alt+Shift+C | Reload the configuration. |
| Alt+Shift+S | Run `"$HOME/Applications/Flameshot.app/Contents/MacOS/flameshot" gui`. |
| Alt+R | Enter resize mode. |
| Resize H/J/K/L | Change width -50, height +50, height -50, or width +50 points. |
| Resize Return or Escape | Return to main mode. |

## Defaults and differences

Ten workspaces remain configured even when empty. Slack routes to workspace 3.
All workspaces prefer one external monitor, with the built-in display as fallback.
Monitor selection moves the pointer to the monitor center only when outside it.
The status bar shows the workspace name. Gaps are 10 points.
The preset inherits the default 0.12-second motion duration.

Dwindle is a binary split tree, not AeroSpace's container layout.
Alt+E changes the focused leaf's parent axis, not an AeroSpace container's layout.
A single tiled window has no split to toggle.
Swap selects by window geometry, not AeroSpace tree navigation.
It approximates tiling movement without using `move`, which forces floating.
Swapping with a floating window can change tiling membership.
Managed fullscreen does not create a macOS Space.
New-instance launch requests do not guarantee a new window.
Flameshot must exist at the quoted path. The preset does not install applications.
See [commands](commands.md), [layout](layout.md), and [monitor routing](monitors.md).

## Login startup

Startup remains opt-in through the [login helper](login-startup.md).
The preset does not enable it. AeroSpace's existing autostart can conflict.
Do not enable both managers at login or run them against the same windows.
