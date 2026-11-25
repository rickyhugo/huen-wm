# Configuration reference

The manager reads `~/.config/huen-wm/config.lua`. `--config PATH` selects another file. The installed app falls back to its bundled example when the user configuration does not exist.

## Evaluation

Lua must return a table. `config/example.lua` provides basic settings. The [AeroSpace preset](aerospace.md) adds Alt shortcuts, ten workspaces, resize mode, application actions, and external-monitor preference.

Each evaluation runs in a fresh child of the same executable. Invalid fields, types, commands, duplicate bindings, and hotkey collisions reject the reload. Consumed tables cannot have metatables. Collections must be dense arrays without extra keys. The previous configuration and hotkeys stay active on failure. File changes trigger reload automatically.

`reload` returns `accepted` and a `request_id` before evaluation finishes. `status.config_reload` reports the request ID, `pending`, `ready`, or `failed`, and `err_message`. A second request fails with `ConfigLoadPending` while the first request is in flight. Workspace transitions defer automatic reloads and publication of completed candidates. Restore and quit cancel pending configuration work.

## Limits and sandbox

The supervisor uses a one-second monotonic deadline, including Lua work in native libraries. This is a rejection policy, not a startup performance guarantee. Source files are limited to 256 KiB, normalized responses to 128 KiB, and captured error output to 4 KiB. The one-million-instruction hook and 16 MiB Lua allocation cap remain secondary limits.

The available libraries are base, table, string, and math. Filesystem, process, package loading, and dynamic code loading are unavailable. User `print` output is discarded and cannot alter the private response. `validate --config PATH` uses the same isolated evaluator without starting the manager.

## Bindings

Binding names identify physical ANSI key positions, independent of the active input layout. Named modes replace bindings transactionally. See [commands and modes](commands.md).

The example binds:

| Keys | Action |
| --- | --- |
| Control+Option+H/J/K/L | Focus in a direction. Add Shift to swap. |
| Control+Option+1…5 | Select a workspace. Add Shift to send the focused window. |
| Control+Option+[ and ] | Step through occupied workspaces. Add Shift to move the focused window and follow it. |
| Control+Option+Tab | Focus the previous window. |
| Control+Option+U | Focus an urgent window. |
| Control+Option+C | Center a floating window. |
| Control+Option+Space | Toggle floating. |
| Control+Option+Plus/Minus | Change the split ratio. |
| Control+Option+R | Reload. |

## Window rules and floating

[Window rules](window-rules.md) match a bundle ID and an optional title, each by exact text, glob, or regular expression. They set floating state, a numbered workspace, floating geometry, or centering on first discovery. Later matching rules replace only the actions they specify.

`floating_size = { width = 0.5, height = 0.5 }` sets the size, as fractions of the usable display area from `0.1` to `1`, of a window that `toggle-floating` floats for the first time. It floats centered. A window that floated before returns to its last floating frame.

`single_window_max_width = 1800` limits the width, in points, of a window that is the only tiled window on its display. It is centered horizontally. The value is at least `400`, and absent or `0` means no limit. A larger learned application minimum wins. Managed fullscreen ignores the limit.

## Borders and motion

`border_width` and `border_color` style the focused-window border. Set `border_single_window = false` to hide it when the focused window is the only visible window on its workspace. Minimized windows and hidden group members do not count. [Window rules](window-rules.md) can hide the border or change its width and color for matching windows.

`motion_duration = 0` disables movement animation and workspace snapshot capture. Durations are capped at 0.5 seconds.

## Mouse and trackpad

Set `mouse = { enabled = true, mods = "ctrl+alt" }` to enable mouse tiling. Hold Control+Option and drag a tile with the left button to rearrange it, or drag a shared boundary with the right button to resize it. Changes commit on release. On a floating window, the left button moves it and the right button resizes it from the nearest corner, as in Hyprland. Escape or modifier loss cancels. These gestures require eligible dwindle tiles. See [mouse controls](mouse-controls.md).

Set `swipe = { enabled = true, fingers = 3 }` to switch workspaces with a trackpad swipe. `fingers` is 3 or 4. Moving the fingers left runs `workspace occupied+1` on the display under the pointer, and moving them right runs `workspace occupied-1`. One swipe switches once, and the next switch needs the fingers to lift first. A swipe with a mouse button held does nothing. Swipes need Input Monitoring permission, which the manager never requests. Turn off the macOS gesture that uses the same number of fingers in System Settings, Trackpad, More Gestures, or both act on the same swipe.

## Sessions and placement memory

Set `session = { enabled = true }` to save logical layout after clean original-frame restoration. A normal manager restart can restore uniquely identified windows while their applications remain open. Missing or ambiguous public identities remain unmatched. This does not restore arbitrary application relaunches or reboots. See [session continuity](session.md).

`placement_memory = true` is the default. When an application quits, the manager remembers the workspace and floating state of each of its windows for 30 seconds. A window that the relaunched application opens returns to its remembered workspace. A clean manager exit also stores each window's placement, and the next start applies it for 60 seconds. A rule with a workspace takes priority. Set `placement_memory = false` to remember, store, and apply nothing. `status.placement_memory` reports the number of unexpired entries and the number of windows placed from memory. See [placement memory](session.md#placement-memory).

## Workspaces and monitors

`workspace_monitors`, a workspace's `monitor` field, `mouse_follows_monitor`, `workspace_back_and_forth`, and `focus_on_activate` are described in [workspaces](workspaces.md) and [monitor routing](monitors.md).

## Menu-bar item

`status_bar = { enabled = true, label = "name", style = "text" }` is the default, including when omitted.

- `label` accepts `name`, `index`, or `index_and_name`. Combined labels omit a name equal to its index.
- `style = "badge"` draws the title as text cut out of a filled rounded box, like a numbered macOS symbol. The box is a template image, so it is dark in light mode and light in dark mode. `style = "text"` is the default.
- `enabled = false` removes the item. A successful reload can enable it again. Invalid reloads retain the previous settings.

The title shows the active monitor's committed workspace, shortened to 24 Unicode characters. With `workspace_monitors`, a monitor without a placed workspace shows `—`. The tooltip includes the monitor and full workspace name.

The menu offers all configured workspaces, **Reload configuration**, and **Quit**. Workspace actions use the active monitor, not the screen containing the menu bar. Pending transitions keep the old title and checkmark until placement completes. Workspace actions are disabled during transitions, without monitors, or after restore. Restore shows **Paused**. Switch failures appear in the tooltip and `status.transition_error`. Placement failures and rejected menu commands also write to stderr. Workspace changes do not show a centered popup.
