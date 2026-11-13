# Layout control reference

## Runtime state

Each display and workspace has its own runtime layout, ratio, dwindle tree, and
optional managed fullscreen window. Commands do not change config defaults.
State lasts for the current process, not across restarts.

A reload preserves runtime intent for matching workspace names, including reordered
names. Duplicate names match in occurrence order. A changed layout or ratio default
resets the affected tree, runtime layout, ratio, and fullscreen selection.
Renamed or removed workspaces lose their old layout state.

## Dwindle

Leaves contain stable window identities. Each branch stores an axis, ratio, two
children, and a parent link. New windows split the focused leaf in their destination
tree when that leaf exists. Otherwise, insertion splits the last leaf.
The longer dimension selects the insertion axis.
The first split uses the workspace ratio. Later splits start at one half.

Closing a window or making it floating removes its leaf and collapses its parent.
Returning a floating window to tiling inserts a new leaf.
Minimized windows retain their leaves but occupy no layout space.
Native fullscreen, stale, and unparked offscreen windows also omit geometry without
losing their leaves. Parked workspaces retain their topology and ratios.

`swap DIRECTION` exchanges leaf identities and window membership.
Directional selection uses window geometry, not AeroSpace tree navigation.
Swapping with a floating window can remove and reinsert a tiled leaf.
This is not AeroSpace's exact tree movement model.

`split horizontal` makes the focused leaf's parent divide width.
`split vertical` makes that parent divide height.
`split toggle` changes that parent's axis.
A single tiled window returns `NoSplit`.
Master layout returns `SplitRequiresDwindle`.

## Resizing

`resize DELTA` preserves the ratio command.
The finite delta is between -0.5 and 0.5.
The resulting ratio is between 0.1 and 0.9.
In dwindle, this changes the root split.
In master, this changes the width of the master column.

`resize width DELTA` and `resize height DELTA` use logical points.
The finite delta is between -10000 and 10000.
A positive delta grows the focused window along the requested axis.
The response includes `applied_delta`, which can differ from the requested delta.

In dwindle, point resizing changes the nearest ancestor with the requested axis and
two participating children. Intervening perpendicular splits preserve the requested
dimension, so the returned delta describes the focused leaf's dimension change.
Hidden siblings do not absorb the resize.
The clamp accounts for gaps, nested ratios, and the 80-point minimum of every
participating leaf.
An unavailable axis, a single window, or an infeasible minimum returns an applied
delta of zero.

Master retains its column and equal-height stack.
Point resizing supports width for either column.
Height returns `MasterHeightResizeUnsupported`, rather than changing an unrelated
ratio. Floating and managed fullscreen windows return `WindowNotTiled`.

## Managed fullscreen

`fullscreen` toggles the focused window's managed fullscreen selection.
There is at most one selection per display and workspace.
Its target is the display's visible frame without the layout gap.
The command does not request native macOS fullscreen or create a Space.

The underlying tile and floating geometry remain intact.
Other windows remain managed underneath the selected window.
The selection is raised on toggle and when its workspace becomes active.
Ordinary focus commands can still raise another window.
Minimizing the selected window retains its selection until it returns.
Closing it, sending it to another workspace, or swapping it clears the selection.
Changing layout defaults also clears the selection.

`move` and `toggle-floating` return `ManagedFullscreenActive` while the focused
window has managed fullscreen selected.
Rejected fullscreen geometry clears the selection and retains the underlying
layout. Per-window placement errors report the rejection.

`windows` reports `managed_fullscreen` independently of `fullscreen`.
The latter remains the observed native fullscreen state.
Native fullscreen still blocks workspace parking on its display.

## Bounds and recovery

The runtime tracks at most 1024 windows and 32 displays.
The shared dwindle pool has 2047 nodes.
Each display supports the configured maximum of 10 workspaces.
Node exhaustion returns `LayoutCapacityExceeded` without replacing an existing
node. These bounds accommodate all 1024 tracked windows in one tree.

A disconnected display's windows keep their workspace numbers on a surviving
display. Whole-workspace migration preserves the tree, runtime layout, ratio,
and fullscreen selection unless destination state collides.
Destination state wins, except empty default state yields to incoming state.
Colliding source trees are released and their members join the destination tree.
See [monitor routing](monitors.md) for owner selection and rollback behavior.

Geometry projection does not change membership based on the active workspace.
A rejected workspace switch therefore does not discard the parked workspace's tree.
A failed send restores the previous tree state as well as window membership.
The existing parking readback and rollback checks still control workspace commits.

Tiles smaller than 80 points recover as floating windows during reconciliation.
Projection during a tentative workspace commit does not apply this fallback.
Application placement failures remain visible in the per-window error fields.
