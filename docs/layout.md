# Layout control reference

## Runtime state

Each display and workspace has its own runtime layout, ratio, dwindle tree, and
optional managed fullscreen window. Commands do not change config defaults.
State lasts for the current process unless a separate session owner exports and restores a checkpoint.

A reload preserves runtime intent for matching workspace names, including reordered
names. Duplicate names match in occurrence order. A changed layout or ratio default
resets the affected tree, runtime layout, ratio, and fullscreen selection.
Renamed or removed workspaces lose their old layout state.

## Dwindle

Leaves contain live window identities. Each binary branch stores an axis, ratio, two
children, and a parent link. Ordered groups share the same node pool.
New windows split the focused leaf in their destination
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

`tilemove DIRECTION` detaches and reparents the logically selected subtree.
The nearest visible eligible leaf outside that subtree is the target.
The score is squared forward distance plus four times squared perpendicular distance.
Identity breaks equal scores.
The direction determines the split axis and before-or-after order.
Missing targets, cycles, wrong-workspace targets, and capacity failures leave topology unchanged.

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

## Pure container model

The APIs below are implemented in `src/layout.zig`.
They do not perform native placement, parking, focus, or persistence I/O.
The runtime dispatches selection, tile movement, and group commands through these APIs.

The 2047-node pool contains leaves, binary branches, and explicit ordered groups.
Groups have at least two direct children.
Intrusive `previous` and `next` links encode group order without a per-node child array.
Any direct child can itself be a subtree.
Removal collapses singleton containers, including nested groups.

`WorkspaceLayout` retains `display`, `workspace`, `layout`, `ratio`, `root`, and `fullscreen`.
It adds `last_focused`, `selection`, and transient projection metadata.
`Node.last_child` records ancestor navigation independently from group selection.
`NodeRef` contains a pool slot and an allocation generation.
`resolve` rejects freed or reused slots with `StaleNode`.
Presentation records also carry `Store.revision` to reject obsolete geometry or topology.

The caller runs `sync` with all workspace members, including floating and unavailable windows.
`Member.active` means externally eligible, not visible within a group.
After `sync`, `arrange` refreshes visibility, geometry, and recursive minima.
The `focused` argument to `sync` guides insertion only.
It never records verified focus.

### Focus and selection APIs

| API | Contract |
| --- | --- |
| `rememberFocus(state, identity, members)` | Records externally verified eligible focus and resets logical selection to its leaf. Updates ancestor child memory. |
| `focusCandidate(state, members)` | Returns eligible managed fullscreen, remembered eligible focus, an eligible tree descendant, or an eligible floating member, in that order. |
| `forgetIdentity(identity)` | Clears focus and managed-fullscreen memory without changing topology. |
| `removeIdentity(identity)` | Clears memory, removes the leaf, and collapses containers. Useful for checkpoint pruning. |
| `selected(state, focused)` | Returns a valid logical selection, falling back to the focused or remembered leaf. |
| `select(state, focused, direction)` | Selects a parent or remembered eligible child without native focus. |
| `reveal(state, identity)` | Selects every ancestor group along the leaf's path. |
| `representative(node_ref)` | Returns a remembered eligible descendant identity for focus or header titles. |
| `labelIdentity(node_ref)` | Returns a remembered descendant identity for a title, including unavailable children. |
| `nodeForIdentity(identity)` | Returns the leaf's current generation-tagged reference. |

`rememberFocus` is for an observed external focus change or a verified native focus request.
Repeated command focus reads must not reset an unchanged logical parent selection.
Minimization retains workspace focus memory until another focus succeeds.
`sync` clears memory when an identity closes or leaves its workspace.
Memory follows identity through a swap rather than following a pool slot.
Floating members can hold focus memory without a tree leaf.

Workspace focus can target a currently hidden group descendant.
`reveal` and a new projection precede verified placement and native activation.
Only observed activation success updates `rememberFocus`.
Fullscreen activation uses the same ancestor reveal path.

### Edit APIs

| API | Contract |
| --- | --- |
| `tilemove(state, focused, direction)` | Moves the selected subtree beside the nearest directional target. |
| `editGroup(state, focused, action)` | Applies a `command.Group` action. Cycle actions return an optional focus identity. |
| `drop(state, source_ref, target_ref, placement)` | Explicit subtree edit with `left`, `right`, `up`, `down`, `join`, or leaf-only `swap`. |
| `selectGroupChild(state, group_ref, child_ref)` | Selects a direct eligible group child and returns a focus candidate. |
| `activateHeader(state, header)` | Checks the presentation revision before selecting its child. |

Edits validate workspace, ancestry, eligibility, and required capacity before mutation.
`drop` rejects both ancestor-to-descendant and descendant-to-ancestor targets.
Directional targets do not cross workspaces.
Joining an existing group appends the source and selects it.
Joining another node creates a two-child tabbed group.
Grouping a selected split preserves its two children.
Groups can acquire three or more children through subsequent joins.

`group split` preserves direct-child order in a width-split chain.
The workspace ratio applies at the workspace root.
Other new splits start at one half.
Group cycling wraps through eligible direct children.
If the selected child becomes unavailable, projection selects the next eligible child in order.

Master rejects container edits with `ContainerRequiresDwindle`.
Its projection shows every eligible leaf with the existing master-column geometry.
The dormant group topology remains available when dwindle resumes.
The pure master projection uses tree order.
An existing caller that computes master geometry separately can keep its existing window order.

### Visibility and headers

`visibility(identity)` returns `visible` with a frame, `hidden_by_group`, or `unavailable`.
`goal(identity)` returns a frame only for visible eligible leaves.
Hidden eligible leaves remain in the tree and must not receive stale goals or floating fallback.
`hiddenLeaves(state, output)` enumerates those identities for the native parking transaction.
Workspace hiding remains the external workspace owner's responsibility.

`headers(state, output)` emits copied `Header` records for visible groups.
Each record has group and direct-child references, a rectangle, selection and eligibility state, and a revision.
The caller supplies titles through `labelIdentity(header.child)` and its live identity lookup.
Tabbed mode emits one horizontal row.
Stacked mode emits one row per direct child.
Each row requests 24 points.
Header height is bounded by the selected subtree's recursive minimum so content keeps priority when space is tight.
Leaves retain the existing 80-point minimum.
Nested visible groups emit their own headers.
Unavailable direct children retain a header but cannot be selected.

### Pointer APIs

`hitTest(state, left, top, tolerance)` checks headers, shared boundaries, then visible leaves.
`boundaries(state, tolerance, output)` emits only shared binary boundaries with two visible children.
Tolerance is finite and between zero and 80 points.
Header and boundary enumeration returns `PresentationCapacityExceeded` if the output is too small.
Buffers of 2047 headers and 1023 boundaries cover the pool.

`previewResize(boundary, delta, gap)` locks the exact split and returns a clamped ratio and applied point delta.
It does not mutate the store.
`commitResize(preview, gap)` revalidates the revision, reference, axis, and clamp before mutation.
The gap is the current projection gap.

`previewDrop(state, source, target, placement, scratch)` returns the moved subtree's
projected rectangle and the original revision without changing the live store.
It applies the edit and arranges a copy with the current workspace bounds and gap.
The rectangle accounts for ancestor collapse, split ratios, gaps, and group headers.
For `join`, it covers the moved child below the target group's headers.
For `swap`, it covers the source identity's projected destination.
The caller owns a reusable `Store` scratch buffer, separate from the live store.
The method overwrites this buffer on each call and does not allocate.
Passing the live store as scratch returns `InvalidPreviewScratch`.
Pointer `join` targets an explicit group.
Center drops use leaf-only `swap`.
`commitDrop(state, preview)` rejects a changed revision before applying the explicit edit.
Commit does not require scratch storage.
`drop` also supports command joins that create a group around a leaf.

The input owner cancels previews on reload, display routing, shutdown, or transition start.
Direct external changes to public workspace fields do not themselves advance the revision.
The next `arrange` detects changed bounds, gap, or layout.
Native event handling and gesture ownership are outside this module.

### Checkpoints and native transactions

`exportSnapshot(output)` copies bounded logical state into `Snapshot`.
`importSnapshot(snapshot)` validates the entire candidate before publication.
It rejects invalid indices, cycles, shared nodes, duplicate identities, unreachable nodes, malformed sibling lists, invalid ratios, and invalid selections.
The limits are 1024 leaves, 2047 nodes, 320 roots, and workspace indices below ten.
Successful import regenerates every live node generation and clears cached eligibility and geometry.
The caller then runs `sync` and `arrange`.

Snapshot indices are local logical references, not native pointers or durable window identifiers.
A persistence owner serializes only topology, matched leaf keys, layout intent, group selection, and useful focus state.
Transient generations, frames, eligibility, visibility, and projection metadata are not a persistence format.
The owner matches identities and remaps display and workspace fields before import.
It can use a temporary store plus `removeIdentity` to prune unmatched leaves and collapse their containers.
Floating focus and fullscreen identities need the same conservative identity matching.

Pure edits do not commit native side effects.
A caller can retain a bounded `Store` copy, apply an edit, project, and commit verified placement.
On failure, the caller restores that copy while retaining any actual native recovery obligations.
Native focus runs only after placement succeeds.

The runtime shares one heap-snapshotted placement transaction across workspace activation,
monitor routing, container edits, header selection, and committed pointer edits.
It snapshots logical layout, window intent, display intent, and readable native frames.
Failure reverses every attempted placement, including the failed write, before restoring logical intent.
A failed rollback retains recovery ownership and a per-window placement error.
`windows.group_hidden` distinguishes inactive group children from other unavailable windows.

```zig
const source = try layouts.selected(state, focused);
const target = try layouts.directionalTarget(state, source, .right);
const preview = try layouts.previewDrop(state, source, target, .right, preview_scratch);
try layouts.commitDrop(state, preview);
layouts.arrange(state, usable_frame, gap);
switch (layouts.visibility(identity)) {
	.visible => |frame| enqueuePlacement(identity, frame),
	.hidden_by_group => enqueueVerifiedParking(identity),
	.unavailable => {},
}
```

The example stops at the native boundary.
It does not demonstrate verified geometry, header rendering, pointer input, or restart behavior.
