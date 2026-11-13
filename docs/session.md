# Session checkpoint API

## Scope

`src/session.zig` stores logical intent for a normal manager restart while applications remain open.
The module does not restore windows itself.
It does not persist native recovery authority, AX objects, native window IDs, or original frames.
Session enablement, engine conversion, native record lookup, and lifecycle wiring belong to the caller.
There is no background or dirty checkpoint writer.

`Scope.config` is the caller's active configuration identity or hash.
`Scope.filter` is the exact active application filter, including an empty filter.
`Scope.boot` is the current boot identity.
`huen_session_boot_identity` supplies a public `kern.boottime` token.
All three values must match at load.
Configuration identities must encode relevant configuration content, not only a path.
Changing the configuration identity rejects the whole checkpoint.
The module never changes live intent on rejection.

The file is `~/Library/Application Support/HuenWM/session-<hash>.json`.
`scopeHash` computes SHA-256 over a versioned prefix, configuration identity, and filter with unambiguous separators.
Boot identity remains in the file, not the filename.
Fixture-filter state therefore cannot replace normal unfiltered state.

## Logical shapes

`Snapshot` contains version 1, a clean marker, scope, windows, nodes, and roots.
All indices are zero-based logical array indices, never layout-pool handles.
`Window.root` is a root index.
Each window contains a `StableKey`, display hint, floating flag, and optional display-local floating frame.
Floating frames describe intent, not native original-frame recovery.

`NodeShape` is a tagged union.
Its `leaf` value is a window index.
`Split` has an axis, finite ratio strictly between zero and one, two node indices, and a selected child ordinal.
`Group` has a tabbed or stacked mode, ordered node indices, and a selected child ordinal.
Group selection is not a node index.
Containers require at least two children.

`Root` contains a workspace name and duplicate-name occurrence, display UUID hint, and active marker.
It also contains default layout, default ratio, defaults fingerprint, runtime layout, and runtime ratio.
`node` and `selection` are optional node indices.
`focused` and `fullscreen` are optional window indices in the same root.
The defaults fingerprint is supplied by the caller.
The caller compares it with current defaults before importing topology.
An absent display hint is an empty string, not permission to guess from geometry.
At most one root per display hint is active.

`validate` rejects unknown versions, invalid UTF-8, embedded NUL bytes, out-of-range references, and nonfinite numbers.
It rejects cycles, duplicate parents, shared roots, unreachable nodes, duplicate leaves, and floating leaves.
It also rejects cross-root window references and selections.
Windows without leaves are allowed for unavailable or newly observed members.
Duplicate stable keys remain valid records so matching can skip every ambiguous candidate.
Ratios are rejected, never clamped.
Default ratios have the configuration range 0.1 through 0.9.
Runtime and split ratios are strictly between zero and one because minimum-size resizing can produce narrower fractions.
Floating coordinates have absolute values at most 1,000,000 points.
Floating dimensions are positive and at most 1,000,000 points.
The caller applies display-size policy before placement.

The bounds are 4 MiB of JSON, 1024 windows, 2047 nodes, 320 roots, and 2046 total child references.
The graph validator uses a fixed iterative stack.
There is no artificial 64-level tree limit.
A valid binary tree can have 1023 container levels with 1024 leaves.
Workspace names occupy fewer than 64 UTF-8 bytes.
Display hints and defaults fingerprints occupy fewer than 128 bytes.
Configuration identity and filter each occupy fewer than 4096 bytes.

## Identity and matching

`native/session.h` defines `HuenSessionAttributes`.
`NativeAttributes` is its Zig `extern struct` mirror.
The platform adapter passes its retained `AXUIElementRef` and PID to `huen_session_identify`.
The helper does not inspect the platform adapter's private records.
Calls belong on the native adapter's normal AX thread.
There are no AX calls during JSON parsing.

A key requires the exact bundle ID, PID, and `NSRunningApplication.launchDate`.
It also requires a nonempty AX role.
An unavailable subrole is represented by an empty string.
The discriminator is a nonempty `AXIdentifier`, or an `AXDocument` URL when the identifier is unavailable.
Role and subrole participate in both forms.
Invalid types, truncated UTF-8, embedded NUL bytes, and malformed required attributes return false.
An invalid identifier does not fall back to a document.
The helper never uses a title, frame, private CG ID, or heuristic fingerprint.

The native capacities, including termination, are 256 bytes for bundle, 2048 for identifier or document, and 128 each for role and subrole.
`NativeAttributes.key()` borrows strings from the attributes object.
The caller retains that object until encoding or copies the strings into checkpoint-owned memory.
`huen_session_display_uuid` optionally supplies a public display UUID hint.

`match(saved_keys, current_keys)` returns logical `Pair` indices and counts.
Both key arrays must contain valid keys and at most 1024 entries.
The caller omits windows whose native metadata is unavailable and retains a separate index map for that compact array.
Each complete key must occur exactly once on both sides.
Every duplicate saved candidate is skipped, not only later duplicates.
Counts describe saved records.
`ambiguous_saved` takes precedence over `ambiguous_current`, followed by `missing`.
`count` is the number of unique pairs.
Current-only keys are unmatched discovery candidates.
Process replacement and reboot do not match.
A closed and recreated window that reuses the same complete identifier within one process remains a residual risk.
Public AX attributes cannot eliminate that risk.

## Lifecycle API

`load(allocator, scope)` returns `Loaded` with `none`, `ready`, or `rejected`.
A rejected result includes `storage`, `schema`, `scope`, or `unclean`.
`Loaded.snapshot()` borrows the bounded, validated snapshot.
`Loaded.deinit()` releases its allocation.
`decode` provides the same validation for caller-supplied bytes without filesystem or native access.

`save(allocator, checkpoint, outcome)` returns an error on failure.
It requires both `checkpoint.clean == true` and `outcome == .clean`.
It rejects zero-window snapshots, so an empty bootstrap cannot replace the last good checkpoint.
The clean marker is not proof of a native recovery outcome.
Only the caller can supply that outcome.
The caller freezes logical intent, captures the checkpoint, restores physical original frames, and then publishes the frozen checkpoint only after clean recovery.
A failed physical restore uses `.failed` or omits the save.
A storage error never blocks or replaces native geometry recovery.
An interruption before successful save retains the previous checkpoint.
There is no guaranteed crash recovery.

The following skeleton shows the ownership order.
`freezeCheckpoint`, `restoreOriginalFrames`, and `importPrunedCheckpoint` are caller operations, not session APIs.

```zig
const frozen = try engine.freezeCheckpoint(scope);
const recovery = native_adapter.restoreOriginalFrames();
session.save(allocator, frozen, if (recovery.clean) .clean else .failed) catch |failure| {
    reportSessionSave(failure);
};

var loaded = session.load(allocator, scope);
defer loaded.deinit();
if (loaded.snapshot()) |snapshot| {
    const mapping = try session.match(saved_keys, current_keys);
    try engine.importPrunedCheckpoint(snapshot, mapping.pairs[0..mapping.count]);
}
```

Engine export assigns contiguous logical node and window indices.
It translates private handles to `NodeShape`, `Root`, and `Window` values.
Engine import maps names by occurrence and display hints using current routing policy.
It drops unmatched leaves, collapses containers with one remaining child, and repairs selected child ordinals.
An empty container disappears.
Removed workspaces and changed default fingerprints discard affected topology and focus.
Import never creates parking or original-frame recovery authority.
Fresh rules apply to unmatched live windows after the restore decision.
Geometry and focus still require the existing verified native transaction.
Focus memory changes only after observed focus success.

## File safety

The native file adapter opens each application-support path component relative to an open directory.
It rejects symlinks, foreign ownership, and group-writable or world-writable ancestors.
`HuenWM` must be mode 0700.
The session file must be a mode-0600 regular file owned by the current user.
Existing unsafe files are rejected rather than repaired.
The load path also creates the private `HuenWM` directory if absent.
The existing `Library` and `Application Support` directories are required.

Writes create a random same-directory sibling with exclusive creation, no-follow, and mode 0600.
They write all bytes, fsync the file, close it, rename it, and fsync the directory.
A failed write removes the temporary file where possible.
An interruption can leave an unused temporary file.
A directory-fsync failure is reported even if rename already replaced the checkpoint.

## Integration and verification status

The runtime links `native/session.m` and owns retained AX record lookup through `platform_session_attributes`.
`src/continuity.zig` converts between bounded session records and the layout store.
Its conversion storage and temporary stores are heap allocated.

Startup matching runs after the first window snapshot, before discovery placement.
Unavailable metadata is omitted on both sides of matching.
Matched records remap workspace names by occurrence and displays by current monitor policy.
Unmatched leaves disappear and singleton containers collapse.
Unmatched current windows keep current rules and join through normal discovery.
No imported record grants parking or original-frame recovery ownership.

The configuration scope is SHA-256 over the complete decoded configuration.
Any effective configuration change rejects the previous checkpoint.
The application filter and boot identity are checked separately.
Default-disabled sessions perform no checkpoint storage I/O or native identity collection.
Enabling sessions through reload starts clean-save support but defers loading until a new process.

`restore`, `quit`, and signal shutdown share one frozen logical snapshot.
The frozen snapshot is saved once, only after native original-frame restoration is clean.
A suspended runtime never exports its later reconciled state over that snapshot.
`status.session` exposes load and save outcomes, matched and unmatched saved records,
ambiguous matches, unavailable live metadata, error count, and the last error.
`restored` describes imported logical intent. Native placement and focus still require desktop acceptance.

The native unit uses public AppKit, Foundation, and ApplicationServices APIs.
Strict Objective-C compilation and a linked Zig 0.17 module probe compile the public paths.
The headless probe exercises bounded JSON conversion and strict duplicate matching without AX calls or session-file access.
Actual application identity reads, file durability, manager restart restoration, display routing, native geometry, and native focus remain pending integration verification.
