# Workspaces

## Monitors

Monitors select workspaces independently by default. Optional `workspace_monitors = { "external", "built-in" }` routes all workspaces to a preferred owner. A workspace `monitor` field splits workspaces across displays, and `move-workspace-to-monitor` moves one at runtime. `mouse_follows_monitor = true` enables lazy pointer centering after monitor selection. Disconnected-display migration preserves workspace numbers. See [monitor routing](monitors.md) for migration and rollback behavior.

## Focus

Returning to a workspace restores its last eligible focused window, with managed fullscreen taking priority. Set `workspace_back_and_forth = true` to make selecting the current workspace return to the previous one. Closed, minimized, or unavailable windows do not receive focus.

When an application takes focus for a window on a hidden workspace, as when a link opens in a browser there, the workspace does not change. The window becomes urgent, the menu marks its workspace with a dot, and `focus urgent` goes to it. Set `focus_on_activate = true` to follow such a window to its workspace instead. A window rule can set `focus_on_activate` for its windows. See [activation requests](commands.md#activation-requests).

## Parking

Workspaces use reversible corner parking through public Accessibility APIs. macOS requires a narrow edge of parked windows to remain visible. They do not hide applications or minimize windows into the Dock. User-minimized and native-fullscreen windows are not moved. A native fullscreen window conservatively blocks its display.

With Screen Recording permission, a nonactivating display snapshot covers a workspace transaction. Source parking and destination placement are read back before focus changes and the snapshot fades. Rejected placements trigger rollback. This is not an atomic compositor operation. Apps may constrain geometry or reject parking, and status reports the last transition error. Public on-screen window metadata is a conservative native-space safety hint, not a private Space identifier.

## Recovery

`restore`, also named `recover`, attempts to restore geometry recorded during this live session and suspends tiling until restart. An incomplete restore returns an error with an `outstanding` count. Unminimize affected windows or leave native fullscreen, then retry `restore`. `stop`, `quit`, SIGINT, and SIGTERM attempt restoration before exiting and log outstanding failures.

`restore` returns windows retained by the current process. After SIGKILL or a crash, the next start returns parked windows of still-running applications to their pre-parking frames from a parking journal. It does not recover workspace membership. Applications that a reboot ends cannot be recovered. Do not rely on this build for unattended workspace parking. See [runtime details](runtime.md).
