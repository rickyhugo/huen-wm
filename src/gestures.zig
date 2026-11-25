const native = @import("native.zig");
const tiling = @import("layout.zig");
const size_bounds = @import("bounds.zig");
const pointer = @import("pointer.zig");
const interaction = @import("interaction.zig");
const swiping = @import("swipe.zig");
const desktop = @import("desktop.zig");
const placer = @import("placer.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const focus = @import("focus.zig");
const discovery = @import("discovery.zig");
const text = native.text;
const Rect = desktop.Rect;

var swipe_recognizer: swiping.Recognizer = .{};
var gestures_enabled = false;
var pointer_controls: pointer.Controls = .{};

// A modified drag that moves or resizes a floating window. A resize moves the edges nearest the press, as in Hyprland.
const FloatingDrag = struct { gesture_id: u64, identity: u64, origin: interaction.Point, frame: Rect, from_left: bool, from_top: bool };
var floating_drag: ?FloatingDrag = null;

fn pointerWindows(output: []pointer.Window) []pointer.Window {
    for (desktop.windows(), 0..) |window, index| {
        const hit = window.visible() and !window.parked and !window.managedFullscreen() and !desktop.displayBlocked(window.display) and window.observation.hit_eligible and window.observation.motion == .idle;
        output[index] = .{
            .identity = window.identity,
            .public_id = window.observation.public_window_id,
            .goal = window.goal,
            .eligible = hit and !window.floating and desktop.framesNear(window.observation.frame, window.targetFrame(), 2),
            .title = text(&desktop.windows()[index].observation.title),
            .floating = if (hit and window.floating) window.observation.frame else null,
            .focused = focus.current() == window.identity,
        };
    }
    return output[0..desktop.windows().len];
}

pub fn publish() void {
    // A new publication cancels the active gesture, and the dragged window's hit changes with every update.
    if (!desktop.isInitialized() or pointer_controls.stop_deadline != null or floating_drag != null) return;
    var observed: [1024]pointer.Window = undefined;
    var active: [32]*tiling.WorkspaceLayout = undefined;
    for (desktop.displays(), 0..) |display, index| active[index] = desktop.workspaceLayout(display.identity, display.workspace);
    pointer_controls.publish(desktop.layouts(), pointerWindows(&observed), active[0..desktop.displays().len], !desktop.isSuspended() and !scene.pending() and !routing.blocked(), desktop.config().border_color, desktop.config().border_width) catch |err| {
        pointer_controls.error_message = @errorName(err);
        interaction.huen_groups_clear();
    };
}

pub fn poll() void {
    if (!desktop.isInitialized()) return;
    if (desktop.isSuspended() or pointer_controls.stop_deadline != null) {
        // The end of an active drag is discarded below, and an active drag pauses scans.
        floating_drag = null;
        native.platform_drag_active(false);
        var discarded: interaction.Event = undefined;
        for (0..64) |_| if (!interaction.huen_input_poll(&discarded)) break;
        return;
    }
    var sample: interaction.Event = undefined;
    var count: usize = 0;
    poll: while (count < 64 and interaction.huen_input_poll(&sample)) : (count += 1) {
        if (sample.gesture == .move_floating or sample.gesture == .resize_floating) {
            switch (sample.kind) {
                .start => {
                    if (sample.generation != pointer_controls.generation) continue;
                    const window = desktop.windows()[desktop.windowIndex(sample.target.window_identity) orelse continue];
                    if (!window.floating or window.parked or !window.visible() or window.managedFullscreen()) continue;
                    const frame = window.observation.frame;
                    floating_drag = .{
                        .gesture_id = sample.gesture_id,
                        .identity = window.identity,
                        .origin = sample.origin,
                        .frame = frame,
                        .from_left = sample.origin.left < frame.left + frame.width / 2,
                        .from_top = sample.origin.top < frame.top + frame.height / 2,
                    };
                    _ = focus.verify(window.identity);
                    // The border stays hidden from the press to the release, so it never trails the window.
                    native.platform_drag_active(true);
                },
                .update, .end, .cancel => {
                    const drag = floating_drag orelse continue;
                    if (drag.gesture_id != sample.gesture_id) continue;
                    if (sample.kind != .update) floating_drag = null;
                    defer if (floating_drag == null) {
                        native.platform_config_changed();
                        native.platform_drag_active(false);
                        publish();
                    };
                    const window = &desktop.windows()[desktop.windowIndex(drag.identity) orelse continue];
                    if (!window.floating) continue;
                    if (sample.kind != .cancel and !sample.crossed_threshold) continue;
                    const frame = if (sample.kind == .cancel) drag.frame else dragged: {
                        const horizontal = sample.point.left - drag.origin.left;
                        const vertical = sample.point.top - drag.origin.top;
                        var dragged = drag.frame;
                        if (sample.gesture == .move_floating) {
                            dragged.left += horizontal;
                            dragged.top += vertical;
                            break :dragged dragged;
                        }
                        dragged.width = @max(tiling.minimum_tile_extent, drag.frame.width + if (drag.from_left) -horizontal else horizontal);
                        dragged.height = @max(tiling.minimum_tile_extent, drag.frame.height + if (drag.from_top) -vertical else vertical);
                        if (drag.from_left) dragged.left = drag.frame.left + drag.frame.width - dragged.width;
                        if (drag.from_top) dragged.top = drag.frame.top + drag.frame.height - dragged.height;
                        break :dragged dragged;
                    };
                    window.floating_frame = frame;
                    window.floating_restore = false;
                    _ = native.platform_frame(window.identity, frame, 0, .visible_goal);
                },
                .group_select => {},
            }
            continue;
        }
        if (sample.kind == .start or sample.kind == .end or sample.kind == .group_select) {
            discovery.refresh();
            if (!placer.deriveGoals()) continue;
        }
        var observed: [1024]pointer.Window = undefined;
        const edit = pointer_controls.event(desktop.layouts(), pointerWindows(&observed), sample, desktop.config().gap, desktop.config().border_color, desktop.config().border_width) catch |err| {
            pointer_controls.error_message = @errorName(err);
            interaction.huen_groups_preview(null);
            continue;
        } orelse continue;
        var handle = desktop.layouts().resolve(switch (edit) {
            .group => |selection| selection.group,
            .drop => |preview| preview.source,
            .resize => |preview| preview.boundary.node,
        }) catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        while (desktop.layouts().nodes[handle].parent) |parent| handle = parent;
        const state = for (&desktop.layouts().roots) |*slot| {
            if (slot.*) |*layout| if (layout.root == handle) break layout;
        } else {
            pointer_controls.error_message = "StaleNode";
            continue :poll;
        };
        const transaction = placer.Transaction.begin(.{ .display = state.display }) catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        defer transaction.deinit();
        const result: anyerror!?u64 = switch (edit) {
            .group => |selection| desktop.layouts().selectGroupChild(state, selection.group, selection.child),
            .drop => |preview| drop: {
                const representative = desktop.layouts().representative(preview.source) catch |err| break :drop err;
                desktop.layouts().commitDrop(state, preview) catch |err| break :drop err;
                break :drop representative;
            },
            // Clearing bounds during the drag would move the published boundaries and cancel the gesture, so the release retries the rest.
            .resize => |preview| resize: {
                const requested = if (preview.boundary.axis == .width) sample.point.left - sample.origin.left else sample.point.top - sample.origin.top;
                desktop.layouts().commitResize(preview, desktop.config().gap) catch |err| break :resize err;
                if (@abs(requested - preview.applied_delta) <= size_bounds.tolerance or !placer.forgetWorkspaceBounds(state.display, state.workspace)) break :resize null;
                if (!placer.deriveGoals()) break :resize error.LayoutProjectionFailed;
                var boundary = preview.boundary;
                boundary.revision = desktop.layouts().revision;
                const retry = desktop.layouts().previewResize(boundary, requested - preview.applied_delta, desktop.config().gap) catch |err| break :resize err;
                desktop.layouts().commitResize(retry, desktop.config().gap) catch |err| break :resize err;
                break :resize null;
            },
        };
        const target = result catch |err| {
            pointer_controls.error_message = transaction.abort(err);
            continue;
        };
        if (!transaction.commit()) continue;
        if (target) |identity| if (!focus.verify(identity)) {
            pointer_controls.error_message = "HeaderFocusRejected";
        };
        native.platform_config_changed();
    }
    if (pointer_controls.revision != desktop.layouts().revision) publish();
}

pub fn configure() void {
    pointer_controls.configure(desktop.config().mouse.enabled, desktop.config().mouse.modifiers);
    if (gestures_enabled == desktop.config().swipe.enabled) return;
    gestures_enabled = desktop.config().swipe.enabled;
    native.huen_observe_gestures(gestures_enabled);
}

// Returns the workspace command a completed swipe runs, after selecting the display under the pointer.
pub fn swipe(fingers: u32, horizontal: f64, vertical: f64) ?[*:0]const u8 {
    if (!desktop.isInitialized() or !desktop.config().swipe.enabled) return null;
    swipe_recognizer.fingers = desktop.config().swipe.fingers;
    const step = swipe_recognizer.sample(fingers, horizontal, vertical, native.platform_monotonic()) orelse return null;
    if (desktop.isSuspended() or scene.pending() or native.platform_pointer_buttons()) return null;
    var point: native.WMPoint = undefined;
    if (native.platform_pointer(&point)) for (desktop.displays()) |display| {
        const bounds = display.full_bounds;
        if (point.left < bounds.left or point.left >= bounds.left + bounds.width or point.top < bounds.top or point.top >= bounds.top + bounds.height) continue;
        focus.select(display.identity);
        break;
    };
    return if (step == .next) "workspace occupied+1" else "workspace occupied-1";
}

// Stops the input tap. False while it still drains events, which shutdown retries.
pub fn release() bool {
    if (!pointer_controls.stop(native.platform_monotonic())) return false;
    if (pointer_controls.forced_stop) native.platform_error("Input release drain exceeded 250 ms; tap teardown forced");
    return true;
}

pub fn status() struct { availability: interaction.Availability, generation: u64, err_message: ?[]const u8, forced_stop: bool } {
    return .{ .availability = interaction.huen_input_status(), .generation = pointer_controls.generation, .err_message = pointer_controls.error_message, .forced_stop = pointer_controls.forced_stop };
}
