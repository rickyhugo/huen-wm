# Workspace runtime review fixes

These fixes preserve the native placement contract while adding workspace controls.
The source base is `da15c07`.
The earlier native run used that frozen base.

## Placement scope and stale windows

`PlacementTransaction.Scope` represents one display, a display pair, or all displays.
The native frame snapshot remains indexed by window identity.
Entries outside the scope stay null.
Both commit and reverse rollback skip null entries.
Logical rollback still restores the complete layout store, window intent, display intent, and selected display.
The runtime applies these edits on its main thread.

All eight transaction entry points now pass an explicit scope.

| Caller | Scope |
| --- | --- |
| `pollPointer` group, drop, and resize | Display resolved from the edit's node |
| `commitRouting` owner migration and send | All displays, retaining its destination validation and full routing snapshot |
| `focusWorkspace` hidden or parked target reveal | Requested display |
| `commitWorkspace` | Workspace destination display |
| Layout command | Active display |
| Tile move and group commands | Focused window's display |
| Managed fullscreen command | Focused window's display |
| Swap command | Both source and target displays |

Before any placement write, `begin` rejects native fullscreen on an affected display.
It also rejects a stale window that is onscreen or still owned through parking.
It then excludes safely unavailable windows through the unchanged `externallyEligible` predicate.
That predicate still rejects stale observations.
Fresh native frame reads remain mandatory for every included window.

Static tracing of the two reported scenarios gives these results.
These are source deductions, not native observations.

1. Window A remains onscreen in workspace 1 after an AX timeout marks its observation stale.
   A switch to workspace 2 includes A's display.
   `begin` returns `StaleWindowBlocksPlacement` before the caller changes the active workspace or writes geometry.
   The same rejection applies to stale parked windows whose recovery ownership remains active.
2. Display A contains a native fullscreen window and parked window P.
   A workspace, group, layout, focus reveal, or pointer edit on display B excludes every window on A before checking fullscreen or staleness.
   Its snapshot entries for A stay null.
   Neither commit nor rollback writes native geometry on A.
   A cross-display swap involving A still rejects because A is affected.

Commit failures still roll back through the failed attempt itself with `index + 1`.
An unsuccessful reverse write retains parking ownership and its recovery frame.
The managed fullscreen reveal error now also restores logical state before returning.
`verifiedFrame` and its native readback checks are unchanged.

## Runtime ratios

`Store.importSnapshot` accepts finite root ratios strictly between zero and one.
This matches the session validator and runtime point-resize ratios outside the configuration range.
Binary split validation already uses the same open interval and remains unchanged.
Zero, one, nonfinite values, and invalid topology still fail import.
Configuration ratios and persisted default ratios retain their inclusive 0.1 through 0.9 bounds.

## Pointer support

`Controls.publish` excludes non-dwindle workspaces before publishing any tile, header, or boundary hit.
Master layouts therefore publish no gesture targets.
In `native/input.m`, a mouse-down without a matching hit returns the original event before capture starts.
Global `status.mouse.availability` describes input capability, not support for gestures in every layout.
Modified drag and resize are supported only in eligible dwindle workspaces.

## Floating session coordinates

`continuity.Screen.full_bounds` replaces its ambiguous `frame` field.
`sessionScreens` supplies the native full display bounds.
Freeze subtracts that full-display origin and restore adds the destination full-display origin.
Dock and menu-bar changes therefore do not change the coordinate origin.
The runtime still bounds restored floating geometry to the current usable frame with the configured gap.
Tiling areas and rule geometry continue to use their existing usable-frame semantics.

## Checks and remaining verification

The following commands passed in the isolated runtime worktree.

```sh
zig fmt --check src/main.zig src/layout.zig src/pointer.zig src/continuity.zig
zig build
mise run check
zig build -Doptimize=ReleaseSafe
git diff --check
```

Each source commit also passed the installed formatting, naming, and Conventional Commit hooks.
The diff received a local deslop review.
No tests, fake IPC, headless CLI, GUI, fixture, installed application, or personal configuration were run or changed.
The fix worker spawned no agents.
A fresh independent Sol reviewer subsequently checked `da15c07..cd0edf4`, including all eight transaction callers and downstream placement paths.
That review confirmed all five fixes and found no P1 or P2 defects.

Native verification remains open for stale AX failures, rollback rejection, and fullscreen isolation across physical displays.
Combined native acceptance confirms modified master-left passthrough.
Master-right passthrough, extreme-ratio restart restoration, and floating restoration across Dock or menu-bar changes remain unverified.
See [workspace controls verification](workspace-controls-verification.md) for final-artifact evidence.
