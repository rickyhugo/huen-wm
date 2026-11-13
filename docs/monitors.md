# Monitor routing

## Configuration

`workspace_monitors` is an optional, ordered list of monitor classes. The accepted values are `external` and `built-in`. The list cannot be empty or contain duplicates. Lua tables with metatables, sparse entries, named entries, or non-string values are invalid.

```lua
return {
	workspaces = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '10' },
	workspace_monitors = { 'external', 'built-in' },
	mouse_follows_monitor = false,
}
```

Omitting `workspace_monitors` preserves independent workspaces on each monitor. With the list present, all configured workspaces share one owner monitor. This is a global preference, not a per-workspace mapping.

The first monitor class with an available display wins. Within that class, the current owner stays the owner if it remains eligible. Otherwise, the display with the lowest numeric identity wins. If neither class matches, a surviving owner remains the owner, or the lowest display identity wins. Display identities are not persistent monitor names.

`mouse_follows_monitor` accepts a boolean and defaults to `false`. The built-in classification comes from `CGDisplayIsBuiltin`, not the display name.

## Commands and focus

With global routing enabled, `workspace N` activates workspace N on its owner, even if keyboard focus is on another monitor. The command selects the destination monitor after placement succeeds. Selecting an already visible workspace also selects its monitor. An empty workspace retains that selection independently of the last focused window.

`send-to-workspace N` moves the window's display and workspace membership together. It does not activate an inactive destination workspace or change the selected monitor. Window rules with a workspace use the same owner.

A genuine observed focus change updates the selected monitor. Repeated observations of the old focused window do not undo an explicit empty-workspace selection. Directional focus selects the focused window's monitor immediately.

When mouse follow is enabled, selecting a different monitor moves the pointer to its full-bounds center only if the pointer is outside those bounds. Coordinates use the top-left global display space. Same-monitor workspace changes and background routing do not warp the pointer.

## Topology and placement

Owner changes migrate window membership without changing workspace numbers or requesting focus. A disconnected monitor's windows retain their workspace numbers on a surviving monitor. The owner retains its active workspace across migration. With no displays, routing waits and retains intent.

Topology changes cancel pending workspace scene captures. Global routing uses instant placement, not a sequence of per-monitor scene commits.

Routing snapshots window membership, geometry, parking state, floating geometry, active workspaces, and monitor selection before placement writes. Placement uses frame readback and the existing visibility and parking mechanisms. A rejected placement restores the prior state and attempts verified geometry rollback, including the failed write. A failed rollback retains recovery ownership and reports an error.

Routing fails closed when required geometry is unreadable, a window is stale, a destination is blocked by native fullscreen, or a window cannot move safely while unavailable. The current implementation snapshots and verifies all eligible managed windows, so an unrelated stale window can block routing. Failed background routing blocks normal reconciliation until routing can succeed. Minimized windows that need a different display wait until they are available.

`status` includes `selected_monitor`, `workspace_owner`, and `routing_blocked`. `monitors` includes `built_in`. With global routing enabled, `workspaces` lists each workspace only under its committed owner. Existing per-window placement errors and the status `transition_error` describe failures.

## Layout integration and verification limits

Routing snapshots the complete layout store before staging membership. Failed projection restores layouts, windows, displays, and selection without geometry writes. Failed placement rolls back all attempted writes, including the failed write, and restores the snapshots. Failed rollback retains parking recovery ownership and per-window errors.

Whole-workspace migration rekeys source roots before disconnected-display cleanup. Workspace numbers, tree structure, runtime layout, ratio, and managed-fullscreen identity survive when there is no collision. A destination root wins collisions, except an empty root with default layout, default ratio, and no fullscreen state yields to incoming state. On collision, the source tree is released and membership synchronization inserts its windows into the destination tree. With several incoming roots, root-store order is the stable tie-breaker after the destination's state. Individual sends do not migrate surviving workspace roots.

Only headless configuration validation and build checks were run for this change. Multi-display runtime behavior and pointer movement were not verified.
