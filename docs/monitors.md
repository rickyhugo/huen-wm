# Monitor routing

## Modes

| Mode | Configuration | Behavior |
|---|---|---|
| Independent | No `workspace_monitors`. The default. | Each display has its own active workspace from the full workspace set. Selectors and `previous` are per display. |
| Owner | `workspace_monitors` and no workspace has `monitor`. | Every workspace is on one owner display. The other displays are empty. |
| Global | `workspace_monitors` and at least one workspace has `monitor`, or a runtime home splits the set. | Each workspace is on exactly one display. Each display shows one of its workspaces, or nothing. |

Owner mode is global mode in which every workspace resolves to the same display. All global rules apply to it. "Global routing" in this document means owner or global mode.

## Configuration

`workspace_monitors` is an optional, ordered list of monitor classes. The accepted values are `external` and `built-in`. The list cannot be empty or contain duplicates. Lua tables with metatables, sparse entries, named entries, or non-string values are invalid.

```lua
return {
	workspaces = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '10' },
	workspace_monitors = { 'external', 'built-in' },
	mouse_follows_monitor = false,
}
```

### Per-workspace monitor

A `workspaces` entry is a name string or a table with `name` and an optional `monitor`. `monitor` is one monitor selector or an ordered list of 1 to 4 selectors. Only `built-in`, `external`, and `name:NAME` are accepted. `name:` matches the display name that `monitors` reports. Duplicate names resolve to the lowest display identity.

```lua
return {
	workspace_monitors = { 'external', 'built-in' },
	workspaces = {
		{ name = '1', monitor = { 'name:DELL U2725QE', 'external' } },
		'2',
		{ name = '6', monitor = 'built-in' },
	},
}
```

Directional and cyclic selectors (`left`, `right`, `up`, `down`, `next`, `previous`) are rejected with `RelativeMonitorSelector`. They are relative to the selected display, so a placement that uses them would change with focus. Other errors:

| Error | Cause |
|---|---|
| `MonitorRequiresGlobalWorkspaces` | `monitor` without `workspace_monitors`. |
| `EmptyWorkspaceMonitors` | `monitor = {}`. |
| `TooManyWorkspaceMonitors` | More than 4 entries. |
| `DuplicateMonitor` | The same selector twice. |
| `UnknownMonitor` | An unknown class, for example `builtin`. |
| `InvalidMonitorName` | `name:` without a name, or a name longer than 127 bytes. |

`mouse_follows_monitor` accepts a boolean and defaults to `false`. The built-in classification comes from `CGDisplayIsBuiltin`, not the display name.

### Placement

Each workspace is placed on the first available display of:

1. its runtime home (see [runtime homes](#runtime-homes));
2. the first matching entry of its `monitor` list;
3. the first matching entry of `workspace_monitors`;
4. its current display;
5. the display with the lowest identity.

Within a matching entry, the current display stays if it still matches. Otherwise, the matching display with the lowest identity wins. Workspaces without `monitor` therefore share one owner display. Display identities are not persistent monitor names. Placement runs on every tick, after a reload, and after a display change.

When placement moves workspaces, each display that gains or loses a workspace keeps its active workspace if it is still placed there. Otherwise it shows, in order: a gained workspace that was visible before the move, a gained workspace that the display showed when it disconnected, its current workspace, or its lowest-numbered placed workspace. A display with no placed workspace stays empty.

## Commands and focus

With global routing enabled, `workspace N` activates workspace N on its display, even if keyboard focus is on another monitor. When N is already visible on another display, the command does not move it: it selects that display (a jump), and the other displays keep their workspaces. After placement succeeds, the command selects the destination monitor when it is empty or AX confirms focus on its target window. Selecting an already visible workspace uses the same focus confirmation. An empty workspace retains that selection independently of the last focused window and does not invent a focus change. `workspace previous`, relative selectors, and `focus last` jump across displays in the same way. See [workspace selectors](commands.md#workspace-selectors).

`send-to-workspace N` moves the window's display and workspace membership together. It does not activate an inactive destination workspace or change the selected monitor. If the send changes a workspace's display, that display retains its active workspace, not the send destination workspace. Window rules with a workspace use the same placement.

`focus-monitor MONITOR` selects a display in all modes. With global routing enabled, a display that has no workspace placed on it is empty, so the command selects it without a focus change. See [monitor focus](commands.md#monitor-focus).

`send-to-monitor` and `move-to-monitor` move the focused window to the target display's active workspace in all modes. With global routing enabled, an empty target display returns `NoWorkspaceOnMonitor`. `move-workspace-to-monitor` and `swap-monitor-workspaces` move whole workspaces and need global routing. See [monitor moves](commands.md#monitor-moves).

A genuine observed focus change updates the selected monitor. Repeated observations of the old focused window do not undo an explicit empty-workspace selection. Directional focus selects the target's monitor only after AX confirms focus on that target. An accepted but unverified focus request leaves monitor selection and pointer position unchanged until a genuine observed focus change.

When mouse follow is enabled, selecting a different monitor moves the pointer to its full-bounds center only if the pointer is outside those bounds. Coordinates use the top-left global display space. Same-monitor workspace changes and background routing do not warp the pointer.

## Runtime homes

`move-workspace-to-monitor` and `swap-monitor-workspaces` set a workspace's runtime home to the destination display's UUID. A home takes precedence over the workspace's `monitor` list and `workspace_monitors`, so an explicit move wins over configuration. In owner mode, a home splits the workspace set: the moved workspace stays on its home and the others keep following `workspace_monitors`.

A reload clears the homes of workspaces that have a `monitor` field, so they return to their configured displays. Workspaces without `monitor` keep their homes. A reload without `workspace_monitors` clears every home. `status.placements[].home` shows the UUID, or an empty string.

## Hotplug

When a display disconnects, each workspace on it moves to the display that [placement](#placement) picks without it. The workspace keeps its runtime home. Its windows keep their workspace numbers. A surviving display keeps its active workspace. A surviving display that was empty shows the workspace that the lost display showed. If the selected display disconnects, the first remaining display becomes selected. No focus change is requested.

When the display reconnects, every workspace whose home or configured `monitor` matches it moves back, with its windows. The reconnected display shows the workspace it showed when it disconnected, unless you showed another of its workspaces in the meantime. A display that loses its active workspace to the reconnected display shows its lowest-numbered remaining workspace, or nothing. The selection does not change.

Without global routing, a disconnected display's windows keep their workspace numbers on a surviving display. With no displays, routing waits and retains intent.

Topology changes cancel pending workspace scene captures. Cross-display migration uses instant verified placement, not a sequence of per-monitor scene commits.

## Session restart

With `session = { enabled = true }`, a clean stop saves each runtime home in the checkpoint by workspace name and display UUID. A restart with the same configuration seeds the homes before placement. A moved workspace and its windows therefore return to their moved-to display, and each display shows its saved active workspace. A home whose display is absent at restart keeps the workspace on its fallback until the display connects. Any configuration change, including a mode change, rejects the checkpoint, so homes do not cross configurations. See [session continuity](session.md).

## Status

`status` includes `selected_monitor`, `workspace_owner`, `placements`, and `routing_blocked`. `workspace_owner` is the shared display in owner mode and null when workspaces are split or global routing is off. `placements` lists each workspace's `index`, `name`, `display` (null without global routing or displays), and `home` (a display UUID, or an empty string when placement comes from configuration).

`monitors` includes `name`, `uuid`, `built_in`, `workspace`, and `selected`. `uuid` is the CoreGraphics display UUID, or null when unavailable. `workspace` is the display's active workspace number. With global routing enabled, it is null on a display that has no workspace placed on it. With global routing enabled, `workspaces` lists each workspace only under its display.

The menu-bar title follows the selected display. With global routing enabled, an empty selected display shows `—`, its tooltip shows "No workspace", and no menu workspace is checked. Independent mode is unchanged.

## Routing transactions

Owner changes migrate window membership without changing workspace numbers or requesting focus. With membership already on the unchanged owner, workspace switches retain the normal captured transition when duration is nonzero and capture is available. Capture targets the owner even when another monitor is selected.

Routing snapshots window membership, geometry, parking state, floating geometry, active workspaces, and monitor selection before placement writes. Placement uses frame readback and the existing visibility and parking mechanisms. A rejected placement restores the prior state and attempts verified geometry rollback, including the failed write. A failed rollback retains recovery ownership and reports an error.

Routing fails closed when required geometry is unreadable, a window is stale, a destination is blocked by native fullscreen, or a window cannot move safely while unavailable. The current implementation snapshots and verifies all eligible managed windows, so an unrelated stale window can block routing. Failed background routing blocks normal reconciliation until routing can succeed. Minimized windows that need a different display wait until they are available.

A valid reload publishes its configuration and resets the binding mode to `main` even if routing fails. The failure is a runtime routing error, not a configuration rejection. `routing_blocked` prevents normal reconciliation while the runtime retries routing. Existing per-window placement errors and the status `transition_error` describe failures.

Routing snapshots the complete layout store before staging membership. Failed projection restores layouts, windows, displays, and selection without geometry writes. Failed placement rolls back all attempted writes, including the failed write, and restores the snapshots. Failed rollback retains parking recovery ownership and per-window errors.

Whole-workspace migration rekeys source roots before disconnected-display cleanup. Workspace numbers, tree structure, runtime layout, ratio, and managed-fullscreen identity survive when there is no collision. A destination root wins collisions, except an empty root with default layout, default ratio, and no fullscreen state yields to incoming state. On collision, the source tree is released and membership synchronization inserts its windows into the destination tree. With several incoming roots, root-store order is the stable tie-breaker after the destination's state. Individual sends do not migrate surviving workspace roots.

## Verification

`scripts/native-smoke.py` checks owner mode (`--owner`), monitor focus (`--monitors`), split placement (`--global`), monitor moves (`--monitor-moves`), and restart continuity of runtime homes (`--global-restart`) on a built-in and an external display. Display disconnection cannot be automated. Use the [manual hotplug checklist](native-smoke.md#manual-hotplug-checklist).
