# Native mouse and group interaction reference

`native/interaction.h` defines the C ABI. `src/interaction.zig` mirrors it.
`native/input.m` owns the singleton event queue, snapshots, and event tap.
`native/groups.m` owns nonactivating header buttons and previews.
Both native files must link into the same executable.

All calls require the main thread. The tap runs on the main run loop in common modes.
There are no worker threads, runtime JSON messages, AX window scans, CLI calls, or layout mutations in this module.
The main caller owns policy, eligibility, layout, foreign-window placement, and focus.

## Coordinates and identities

All rectangles and pointer samples use global top-left coordinates in points.
They use full display bounds, not the usable frame below the menu bar.
AppKit conversion uses the primary display's full height minus the rectangle's top and height.
Negative coordinates on secondary displays remain negative.

`HuenNodeRef` contains a pool slot and a nonzero slot generation.
The snapshot generation identifies the whole immutable projection.
`window_identity` is the caller's live native identity.
`window_id` is the public CG window ID, not an AX object or a persisted identity.
Boundary hits carry the exact split reference in `boundary`.
Header hits carry the child reference in `node` and the parent reference in `group`.
Tile hits require nonzero native identity, CG window ID, and node generation.
Boundary and header hits require their relevant reference generations.
Unused references can be zero.

The native bridge copies all hit regions and header items.
It retains no caller buffers or title pointers.
Header titles contain at most 255 UTF-8 bytes plus a null terminator.
Invalid UTF-8 displays as `Untitled`.

## Publication

`huen_input_publish` accepts at most 4096 hit regions.
It rejects null buffers with nonzero counts, zero or decreasing generations, invalid rectangles, and invalid hit kinds or references.
Allocation or validation failure returns false and preserves the previous publication.
An equal generation can repeat the same ordered hit map.
A changed hit map with the same generation returns false.
Comparison ignores structure padding.

The caller increments the generation after every change to geometry, topology, eligibility, header targets, or transition state.
Generations must not wrap or be reused during a lifecycle.
An accepted new generation cancels the active gesture and hides old headers and previews.
An unready or transitioning publication also cancels and hides them.
The cancelled button remains owned until its matching release.
Queued events retain their original generation.
The caller rejects events whose generation, node references, native identities, or eligibility are no longer current.

Only supplied hits are eligible. Native input does not independently inspect foreign windows or stacking.
The caller excludes obscured, minimized, fullscreen, floating, inactive, stale, and otherwise ineligible windows.
For overlapping hits of the same kind, the last supplied hit wins.
Header rectangles block modified left-down from reaching tile hits underneath.
The caller includes visible header rectangles in the hit map even though their clicks use AppKit buttons.
Empty projections remove all hit targets and headers.

## Availability and gestures

`huen_input_configure` takes an enable flag and the existing Carbon modifier encoding.
Command is 256, Shift is 512, Option is 2048, and Control is 4096.
Only those bits are valid. A zero mask or unknown bit disables input.
Matching requires exactly those four modifier classes. Caps Lock and Fn do not affect the match.
Input starts disabled and does not request permissions.

`huen_input_status` checks `CGPreflightListenEventAccess` and `AXIsProcessTrusted` without prompts.
It returns disabled, available, permission denied, tap unavailable, or stopping.
Available means that the public session tap exists and is enabled. It does not certify a snapshot or a desktop outcome.
`huen_input_poll` refreshes status before it reads the queue.
Polling is necessary to observe permission loss even when no pointer event arrives.
The main caller polls on its normal bounded main-loop tick.

Modified left-down on a tile starts reorder.
Modified right-down on a boundary starts resize.
Down is claimed only with enabled input, an available tap, a ready projection, no transition, and queue capacity.
Unclaimed events pass through unchanged.
The native bridge never injects replacement clicks.

The start event arms a gesture immediately.
Its origin and target remain fixed throughout that gesture.
Updates and the end event carry the current point and a monotonic timestamp in nanoseconds.
Timestamps come from `CLOCK_MONOTONIC_RAW`, not wall time or foreign-window motion timestamps.
The `crossed_threshold` flag latches after a displacement of at least four points.
The main caller can show a preview immediately but commits no edit on an end event with a false threshold flag.
A modified click therefore consumes its paired down and up without a reorder.
The bridge does not move foreign windows during a gesture.

Modifier loss, Escape, tap disable, permission loss, reconfiguration, publication invalidation, and shutdown cancel an active gesture.
Cancellation emits one cancel event and enters release draining.
The owned drag stream and matching up remain consumed after cancellation.
Other buttons and unrelated events pass through.
Escape is consumed only when it cancels an active gesture.
Timeout and user-disabled tap notifications cancel, then reenable the tap if permission still allows it and input or a release drain needs it.
The callback performs permission preflight only, not AX window queries.

The queue has 64 entries.
New gestures and header selections enter only when at most 60 entries are occupied.
Consecutive updates for one gesture overwrite the last update.
Motion cannot use the last reserved terminal slot.
Only one gesture can own a button, and header commands cannot enter during ownership.
Every accepted start therefore has capacity for its end or cancel event.
A cancelled gesture ends with cancel, not another end event when up arrives.
Queue pressure rejects new ownership rather than dropping an owned release.

## Headers and previews

`huen_groups_publish` requires a ready matching input generation.
Header selection does not require enabled mouse gestures or event-tap permission.
The caller supplies already projected horizontal tab rows or vertical stacked rows.
The native bridge does not compute group layout.

The presentation bounds copied storage and button count to 2046 items.
That limit covers the direct child headers of a 1024-leaf tree with nested containers.
One nonactivating panel contains each group's buttons, with at most 1024 panels.
Each group's rectangles must not overlap and must cover their bounding rectangle within floating-point tolerance.
The bridge rejects gaps that could intercept clicks intended for a foreign window.
Reducing the group count closes excess panels. `huen_groups_clear` closes the whole pool and preview.
The bridge copies each item into its button.
Validation happens before presentation changes. Invalid input preserves the previous presentation.

The panels cannot become key or main windows and use nonactivating `orderFrontRegardless`.
They use the floating level, no shadow, no key focus ring, clipped titles, and the caller's border color.
The selected header uses the border color as its fill.
Each button exposes a button accessibility role, its title as the label, its selected Boolean value, and a press action.
A pointer press captures the item before AppKit's nested tracking loop.
A later publication cannot silently retarget that press.
Pointer and accessibility activation only enqueue `group_select`.
The main caller performs the actual group selection and verified focus after polling.
The bridge never activates Huen WM to handle a header click.

Panels do not opt into native fullscreen spaces.
The caller must publish an empty or filtered presentation for fullscreen and ineligible groups.
Public floating panels are not a guarantee of ordering against every other application's overlays.

`huen_groups_preview` shows an insertion frame or resize guide for a matching ready generation.
It uses the same border color and accepts widths greater than zero through 32 points.
It never receives mouse events or changes a foreign frame.
A null, stale, or invalid preview hides it.
Input end and cancel hide the preview when polled.
Publication invalidation and shutdown hide it immediately.

## Integration examples

The C caller publishes input first, then headers for the same generation.
All storage below belongs to the caller only for the duration of each call.

```c
#include <Carbon/Carbon.h>
#include "interaction.h"

HuenInputSnapshot snapshot = {
    .generation = revision,
    .hits = hits,
    .hit_count = hit_count,
    .ready = true,
};
bool published = huen_input_publish(&snapshot);
if (published) {
    HuenHeaderPresentation headers = {
        .generation = revision,
        .items = items,
        .item_count = item_count,
        .border_color = 0x88c0d0,
        .border_width = 2,
    };
    published = huen_groups_publish(&headers);
}
HuenInputAvailability availability = huen_input_configure(true, controlKey | optionKey);
```

The equivalent Zig declarations require no C import in production.

```zig
const interaction = @import("interaction.zig");
const availability = interaction.huen_input_configure(mouse.enabled, mouse.modifiers);
const published = interaction.huen_input_publish(&.{
    .generation = revision,
    .hits = hits.ptr,
    .hit_count = hits.len,
    .ready = ready,
    .transitioning = transitioning,
});
var event: interaction.Event = undefined;
while (interaction.huen_input_poll(&event)) {
    if (event.kind == .cancel) {
        discardPreview();
        continue;
    }
    if (event.generation != revision) continue;
    switch (event.kind) {
        .start, .update => updateCachedPreview(event),
        .end => if (event.crossed_threshold) commitVerifiedDrop(event),
        .cancel => unreachable,
        .group_select => selectGroupChildVerified(event.target.group, event.target.node),
    }
}
```

The example functions represent integration policy, not exports of this module.
The caller validates references and current eligibility before the switch.
Cancellation clears caller-owned preview state even when its generation is old.
A newer publication hides the native preview, but cannot clear caller-owned state.

## Shutdown

`huen_input_stop` freezes admission, cancels the gesture, and closes presentation panels.
It does not block or remove a tap that still owns a button.
`huen_input_stop_ready` reports whether the release has drained.
The caller continues servicing the main run loop and polling events while it waits.

The bounded shutdown policy is a 250 ms deadline measured by the caller's monotonic clock.
An idle drain uses `huen_input_finish_stop(false)`.
At the deadline, the caller uses `huen_input_finish_stop(true)` and records forced removal.
The final call removes the run-loop source, invalidates the tap, frees snapshots, clears queued events, and resets the module.
It returns false if shutdown has not started or if a non-forced call would abandon ownership.
The caller drains any events it needs before final teardown.
A new lifecycle can configure and publish after successful final teardown.

No public API can suppress a future up after the OS removes the event tap or after forced teardown.
Permission revocation, invalidation, process exit, and the shutdown deadline therefore leave an unavoidable release-suppression gap.
There is no synthetic click replay or indefinite shutdown wait.

## Verification limits

Native ARC compilation and isolated Zig ABI compilation do not verify physical input, panel appearance, accessibility behavior, focus preservation, multi-display coordinates, or OS permission transitions.
Those checks belong to the parent-owned native desktop acceptance.
This module does not install a manager, change permissions, or inject physical input.

The isolated compile checks for this change passed with these commands:

```sh
clang -mmacosx-version-min=14.0 -fobjc-arc -Wall -Wextra -Werror -c native/input.m -o ../huen-interaction-build/input.o
clang -mmacosx-version-min=14.0 -fobjc-arc -Wall -Wextra -Werror -c native/groups.m -o ../huen-interaction-build/groups.o
clang -dynamiclib ../huen-interaction-build/input.o ../huen-interaction-build/groups.o -framework Cocoa -framework Carbon -framework ApplicationServices -framework QuartzCore -o ../huen-interaction-build/libhuen-interaction.dylib
zig translate-c -lc native/interaction.h > ../huen-interaction-build/bridge.zig
zig build-obj -lc --dep interaction -Mroot=../huen-interaction-build/abi.zig -Minteraction=src/interaction.zig -femit-bin=../huen-interaction-build/abi.o
zig fmt --check src/interaction.zig
mise exec -- lua scripts/check-names.lua native/input.m native/groups.m native/interaction.h src/interaction.zig
```

The temporary ABI probe compares every mirrored structure's size, alignment, field offset, and field size against the translated C header.
It also checks enum values and references all public Zig declarations.
It is a compile-only artifact, not a new test suite.
Zig 0.17 requires `translate-c` for this check because it has removed `@cImport`.
