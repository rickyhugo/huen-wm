const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const rules = @import("rules.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const size_bounds = @import("bounds.zig");
const pointer = @import("pointer.zig");
const interaction = @import("interaction.zig");
const session = @import("session.zig");
const continuity = @import("continuity.zig");
const selector = @import("selector.zig");
const history = @import("history.zig");
const monitor = @import("monitor.zig");
const parking = @import("parking.zig");
const delivery = @import("delivery.zig");
const swipe = @import("swipe.zig");
const memory = @import("memory.zig");
const reply = @import("reply.zig");
const journal = @import("journal.zig");
const world = @import("world.zig");
const Window = world.Window;
const Display = world.Display;
const Config = world.Config;
const reload = @import("reload.zig");
const edits = @import("edits.zig");
const recovery = @import("recovery.zig");
const recall = @import("recall.zig");
const checkpoint = @import("checkpoint.zig");
const placer = @import("placer.zig");
const json = reply.json;
const failure = reply.failure;
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
pub var focused: ?u64 = null;
var focus_history: history.Ring = .{};
var active_mode: usize = 0;
var last_observed_focus: ?u64 = null;
// When the window that had focus last went away, so focus that macOS then hands to another window is not taken for a request.
var focus_lost: f64 = -std.math.inf(f64);
// `shown` caches whether the workspace was active on its display at the start of the tick, so a
// workspace on a display that just vanished keeps that fact until routing moves it. `shown_when_lost`
// keeps it while the workspace waits on a fallback display, so a reconnect shows it again.
const Placement = struct { display: ?u32 = null, home: [128]u8 = @splat(0), shown: bool = false, shown_when_lost: bool = false };
pub var placements: [10]Placement = @splat(.{});
var global_previous: ?usize = null;
// The most recently selected display that had a placed workspace. With global routing, an empty
// selected display resolves "current workspace" from this display.
var current_display: ?u32 = null;
pub var routing_blocked = false;
const Transition = struct { display: u32, workspace: usize, from: usize, generation: u64, focus_target: ?u64 };
const SnapshotPresentation = enum { idle, pending, instant, captured, fallback };
pub var transition: ?Transition = null;
var generation: u64 = 0;
var snapshot_presentation: SnapshotPresentation = .idle;
var shortcut_buffer: [64]commands.WorkspaceSelector = undefined;
var workspace_shortcuts: std.ArrayList(commands.WorkspaceSelector) = .initBuffer(&shortcut_buffer);
// A workspace switch within about 250 ms of an activation makes the applications involved wait on WindowServer for 300
// to 500 ms. Every AX call to them times out meanwhile, so their windows go stale and block placement.
const activation_settle = 0.3;
var activated: f64 = -std.math.inf(f64);
var hotkey_watch: delivery.Watch = .{};
var hotkey_recovery: struct { missed: usize = 0, rebinds: usize = 0, rebound: f64 = -std.math.inf(f64) } = .{};
var swipe_recognizer: swipe.Recognizer = .{};
var gestures_enabled = false;
const StatusPresentation = union(enum) {
    disabled,
    visible: struct { display_identity: ?u32, content: native.WMStatusPresentation },
};
var published_status: StatusPresentation = .disabled;
var status_active = false;
var pointer_controls: pointer.Controls = .{};
// A modified drag that moves or resizes a floating window. A resize moves the edges nearest the press, as in Hyprland.
const FloatingDrag = struct { gesture_id: u64, identity: u64, origin: interaction.Point, frame: Rect, from_left: bool, from_top: bool };
var floating_drag: ?FloatingDrag = null;
fn pointerWindows(output: []pointer.Window) []pointer.Window {
    for (world.windows(), 0..) |window, index| {
        const hit = window.visible() and !window.parked and !window.managedFullscreen() and !world.displayBlocked(window.display) and window.observation.hit_eligible and window.observation.motion == .idle;
        output[index] = .{
            .identity = window.identity,
            .public_id = window.observation.public_window_id,
            .goal = window.goal,
            .eligible = hit and !window.floating and world.framesNear(window.observation.frame, window.targetFrame(), 2),
            .title = text(&world.windows()[index].observation.title),
            .floating = if (hit and window.floating) window.observation.frame else null,
            .focused = focused == window.identity,
        };
    }
    return output[0..world.windows().len];
}
fn publishPointer() void {
    // A new publication cancels the active gesture, and the dragged window's hit changes with every update.
    if (!world.isInitialized() or pointer_controls.stop_deadline != null or floating_drag != null) return;
    var observed: [1024]pointer.Window = undefined;
    var active: [32]*tiling.WorkspaceLayout = undefined;
    for (world.displays(), 0..) |display, index| active[index] = world.workspaceLayout(display.identity, display.workspace);
    pointer_controls.publish(world.layouts(), pointerWindows(&observed), active[0..world.displays().len], !world.isSuspended() and transition == null and !routing_blocked, world.config().border_color, world.config().border_width) catch |err| {
        pointer_controls.error_message = @errorName(err);
        interaction.huen_groups_clear();
    };
}
export fn wm_input_poll() void {
    if (!world.isInitialized()) return;
    if (world.isSuspended() or pointer_controls.stop_deadline != null) {
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
                    const window = world.windows()[world.windowIndex(sample.target.window_identity) orelse continue];
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
                    _ = focusVerified(window.identity);
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
                        publishPointer();
                    };
                    const window = &world.windows()[world.windowIndex(drag.identity) orelse continue];
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
            refreshObservations();
            if (!placer.deriveGoals()) continue;
        }
        var observed: [1024]pointer.Window = undefined;
        const edit = pointer_controls.event(world.layouts(), pointerWindows(&observed), sample, world.config().gap, world.config().border_color, world.config().border_width) catch |err| {
            pointer_controls.error_message = @errorName(err);
            interaction.huen_groups_preview(null);
            continue;
        } orelse continue;
        var handle = world.layouts().resolve(switch (edit) {
            .group => |selection| selection.group,
            .drop => |preview| preview.source,
            .resize => |preview| preview.boundary.node,
        }) catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        while (world.layouts().nodes[handle].parent) |parent| handle = parent;
        const state = for (&world.layouts().roots) |*slot| {
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
            .group => |selection| world.layouts().selectGroupChild(state, selection.group, selection.child),
            .drop => |preview| drop: {
                const representative = world.layouts().representative(preview.source) catch |err| break :drop err;
                world.layouts().commitDrop(state, preview) catch |err| break :drop err;
                break :drop representative;
            },
            // Clearing bounds during the drag would move the published boundaries and cancel the gesture, so the release retries the rest.
            .resize => |preview| resize: {
                const requested = if (preview.boundary.axis == .width) sample.point.left - sample.origin.left else sample.point.top - sample.origin.top;
                world.layouts().commitResize(preview, world.config().gap) catch |err| break :resize err;
                if (@abs(requested - preview.applied_delta) <= size_bounds.tolerance or !placer.forgetWorkspaceBounds(state.display, state.workspace)) break :resize null;
                if (!placer.deriveGoals()) break :resize error.LayoutProjectionFailed;
                var boundary = preview.boundary;
                boundary.revision = world.layouts().revision;
                const retry = world.layouts().previewResize(boundary, requested - preview.applied_delta, world.config().gap) catch |err| break :resize err;
                world.layouts().commitResize(retry, world.config().gap) catch |err| break :resize err;
                break :resize null;
            },
        };
        const target = result catch |err| {
            pointer_controls.error_message = transaction.abort(err);
            continue;
        };
        if (!transaction.commit()) continue;
        if (target) |identity| if (!focusVerified(identity)) {
            pointer_controls.error_message = "HeaderFocusRejected";
        };
        native.platform_config_changed();
    }
    if (pointer_controls.revision != world.layouts().revision) publishPointer();
}
fn statusText(destination: []u8, source: []const u8, scalar_limit: usize) void {
    @memset(destination, 0);
    var length: usize = 0;
    var scalars: usize = 0;
    while (length < source.len and scalars < scalar_limit) : (scalars += 1) {
        const width = std.unicode.utf8ByteSequenceLength(source[length]) catch break;
        if (length + width > source.len or length + width >= destination.len) break;
        length += width;
    }
    @memcpy(destination[0..length], source[0..length]);
}
fn publishState() void {
    journal.flushTransition();
    publishPointer();
    publishStatus();
}
fn publishStatus() void {
    if (!status_active) return;
    const next: StatusPresentation = if (!world.config().status_bar.enabled) .disabled else status: {
        var presentation = std.mem.zeroes(native.WMStatusPresentation);
        const display: ?Display = if (world.displays().len > 0) world.displays()[world.activeDisplay()] else null;
        // With global routing, a display that has no workspace placed on it shows a dash.
        const placed: ?usize = if (display) |current| placedWorkspace(current) else null;
        const workspace_index = placed orelse 0;
        const name = if (placed != null) text(&world.config().workspaces[workspace_index].name) else "No workspace";
        var index_buffer: [8]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buffer, "{d}", .{workspace_index + 1}) catch unreachable;
        var label_buffer: [80]u8 = undefined;
        const label = if (world.isSuspended()) "Paused" else if (display == null) "Huen WM" else if (placed == null) "—" else switch (world.config().status_bar.label) {
            .name => name,
            .index => index_text,
            .index_and_name => if (std.mem.eql(u8, name, index_text)) name else std.fmt.bufPrint(&label_buffer, "{s}  {s}", .{ index_text, name }) catch unreachable,
        };
        // A dot marks a workspace that holds an urgent window, and the title while any workspace does.
        var urgent: [10]bool = @splat(false);
        var alert = false;
        for (world.windows()) |window| if (window.urgent) {
            urgent[window.workspace] = true;
            alert = true;
        };
        const shown = if (active_mode != 0 and !world.isSuspended()) text(&world.config().modes[active_mode].name) else label;
        switch (world.config().status_bar.style) {
            .text => statusText(&presentation.title, shown, 24),
            .badge => statusText(&presentation.badge, shown, 24),
        }
        if (alert) {
            const mark = " •";
            @memcpy(presentation.title[text(&presentation.title).len..][0..mark.len], mark);
        }
        var tooltip_buffer: [512]u8 = undefined;
        const tooltip = std.fmt.bufPrint(&tooltip_buffer, "Huen WM · {s} · {s} · Mode {s}{s}", .{
            if (display) |current| text(&current.name) else "No display",
            name,
            text(&world.config().modes[active_mode].name),
            if (journal.lastError() != null) " · Workspace switch failed" else "",
        }) catch unreachable;
        statusText(&presentation.tooltip, tooltip, 255);
        for (world.config().workspaces[0..world.config().workspace_count], 0..) |*workspace, index| {
            const row = &presentation.rows[index];
            var row_buffer: [96]u8 = undefined;
            var number_buffer: [8]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buffer, "{d}", .{index + 1}) catch unreachable;
            const workspace_name = text(&workspace.name);
            const mark = if (urgent[index]) " •" else "";
            const title = if (std.mem.eql(u8, number, workspace_name)) std.fmt.bufPrint(&row_buffer, "{s}{s}", .{ workspace_name, mark }) catch unreachable else std.fmt.bufPrint(&row_buffer, "{s}  {s}{s}", .{ number, workspace_name, mark }) catch unreachable;
            statusText(&row.title, title, 79);
            _ = std.fmt.bufPrint(&row.command, "workspace {d}", .{index + 1}) catch unreachable;
            row.checked = placed == index;
            row.enabled = display != null and !world.isSuspended() and transition == null;
        }
        const reload_row = &presentation.rows[world.config().workspace_count];
        statusText(&reload_row.title, "Reload configuration", 79);
        statusText(&reload_row.command, "reload", 127);
        reload_row.enabled = !world.isSuspended() and transition == null and !reload.inFlight();
        const quit_row = &presentation.rows[world.config().workspace_count + 1];
        statusText(&quit_row.title, "Quit", 79);
        statusText(&quit_row.command, "quit", 127);
        quit_row.enabled = true;
        presentation.row_count = world.config().workspace_count + 2;
        break :status .{ .visible = .{ .display_identity = if (display) |current| current.identity else null, .content = presentation } };
    };
    if (std.meta.eql(next, published_status)) return;
    published_status = next;
    switch (next) {
        .disabled => native.platform_status_present(null),
        .visible => |*presentation| native.platform_status_present(&presentation.content),
    }
}
pub fn main(initial: std.process.Init.Minimal) u8 {
    const arguments = initial.args.vector;
    if (arguments.len >= 2 and std.mem.eql(u8, std.mem.span(arguments[1]), "--config-worker")) {
        if (arguments.len != 3) return 1;
        return configuration.workerMain(arguments[2]);
    }
    return @intCast(native.platform_main(@intCast(arguments.len), @ptrCast(arguments.ptr)));
}
const text = native.text;
export fn wm_initialize(path: [*:0]const u8) bool {
    const candidate = reload.evaluate(path) orelse return false;
    applyLayoutDefaults(&candidate);
    world.setConfig(&candidate);
    reload.markReady();
    world.markInitialized();
    checkpoint.configure();
    return true;
}
export fn wm_activate_config() bool {
    if (!native.platform_bindings(&world.config().modes[0].bindings, world.config().modes[0].binding_count)) return false;
    active_mode = 0;
    status_active = true;
    configureInput();
    publishStatus();
    return true;
}
fn configureInput() void {
    pointer_controls.configure(world.config().mouse.enabled, world.config().mouse.modifiers);
    if (gestures_enabled == world.config().swipe.enabled) return;
    gestures_enabled = world.config().swipe.enabled;
    native.huen_observe_gestures(gestures_enabled);
}
export fn wm_config_poll() void {
    // Cancelled requests must still drain while shutdown waits for the worker.
    if (transition != null and reload.waiting()) return;
    const candidate = reload.take() orelse return;
    if (!native.platform_bindings(&candidate.modes[0].bindings, candidate.modes[0].binding_count)) return reload.reject("HotkeyCollision");
    hotkey_watch.forgetPresses();
    applyLayoutDefaults(&candidate);
    world.setConfig(&candidate);
    configureInput();
    checkpoint.configure();
    active_mode = 0;
    reload.settle();
    if (world.displays().len > 0) routing_blocked = !routeMembership();
    native.platform_config_changed();
    placer.reconcile();
    publishStatus();
}
fn applyLayoutDefaults(candidate: *const Config) void {
    var remap: [10]?usize = @splat(null);
    var claimed: [10]bool = @splat(false);
    for (world.config().workspaces[0..world.config().workspace_count], 0..) |*previous, old_index| for (candidate.workspaces[0..candidate.workspace_count], 0..) |*next, new_index| {
        if (!claimed[new_index] and std.mem.eql(u8, text(&previous.name), text(&next.name))) {
            remap[old_index] = new_index;
            claimed[new_index] = true;
            break;
        }
    };
    for (&world.layouts().roots) |*slot| if (slot.*) |*state| {
        const index = state.workspace;
        const next_index = remap[index] orelse {
            world.layouts().discard(state);
            slot.* = null;
            continue;
        };
        const previous = world.config().workspaces[index];
        const next = candidate.workspaces[next_index];
        state.workspace = next_index;
        if (previous.layout != next.layout or previous.ratio != next.ratio) {
            world.layouts().discard(state);
            state.layout = next.layout;
            state.ratio = next.ratio;
        }
    };
    for (world.windows()) |*window| window.workspace = remap[window.workspace] orelse @min(window.workspace, candidate.workspace_count - 1);
    for (world.displays()) |*display| {
        display.workspace = remap[display.workspace] orelse @min(display.workspace, candidate.workspace_count - 1);
        display.previous_workspace = remapPrevious(display.previous_workspace, display.workspace, &remap);
    }
    var remapped: [10]Placement = @splat(.{});
    for (remapped[0..candidate.workspace_count]) |*placement| placement.display = workspaceOwner();
    for (placements[0..world.config().workspace_count], remap[0..world.config().workspace_count]) |placement, next_index| if (next_index) |index| {
        remapped[index] = placement;
    };
    // A reload returns workspaces with a monitor field to configuration placement. Leaving global
    // routing clears every runtime home.
    for (remapped[0..candidate.workspace_count], candidate.workspaces[0..candidate.workspace_count]) |*placement, *workspace| {
        if (candidate.workspace_monitors == null or workspace.monitor.count > 0) placement.home = @splat(0);
    }
    placements = remapped;
    const current = for (0..candidate.workspace_count) |workspace| {
        if (shownWorkspace(workspace)) break workspace;
    } else 0;
    global_previous = remapPrevious(global_previous, current, &remap);
}
fn remapPrevious(previous: ?usize, current: usize, remap: []const ?usize) ?usize {
    const next = remap[previous orelse return null] orelse return null;
    return if (next == current) null else next;
}
fn previousWorkspace(display_slot: usize) *?usize {
    return if (world.config().workspace_monitors != null) &global_previous else &world.displays()[display_slot].previous_workspace;
}
fn recordPrevious(display_slot: usize, from: usize, workspace: usize) void {
    if (from != workspace) previousWorkspace(display_slot).* = from;
}
// With global routing, an empty display uses the active workspace of the most recently selected
// display that had one, else the lowest shown workspace.
fn currentWorkspace(display_slot: usize) usize {
    const display = world.displays()[display_slot];
    if (placedWorkspace(display)) |workspace| return workspace;
    if (current_display) |identity| if (world.displayIndex(identity)) |index| if (placedWorkspace(world.displays()[index])) |workspace| return workspace;
    for (0..world.config().workspace_count) |workspace| if (shownWorkspace(workspace)) return workspace;
    return @min(display.workspace, world.config().workspace_count - 1);
}
fn trackCurrentDisplay() void {
    const identity = world.selected() orelse return;
    const index = world.displayIndex(identity) orelse return;
    if (placedWorkspace(world.displays()[index]) != null) current_display = identity;
}
fn workspaceView(display_slot: usize) selector.View {
    var occupied: selector.Occupancy = .empty;
    const display = world.displays()[display_slot];
    for (world.windows()) |window| if (window.eligible() and (world.config().workspace_monitors != null or window.display == display.identity)) occupied.set(window.workspace);
    // `workspace N` from an empty display does not flip to the previous workspace, except in owner
    // mode, where the owner's workspace is the current one for every display.
    const back_and_forth = world.config().workspace_back_and_forth and (placedWorkspace(display) != null or workspaceOwner() != null);
    return .{ .config = world.config(), .current = currentWorkspace(display_slot), .previous = previousWorkspace(display_slot).*, .occupied = occupied, .back_and_forth = back_and_forth };
}
fn resolveWorkspace(selection: commands.WorkspaceSelector, display_slot: usize) !usize {
    return selector.resolve(selection, workspaceView(display_slot));
}
fn selectDisplay(identity: u32) void {
    if (world.selected() == identity) return;
    world.setSelected(identity);
    trackCurrentDisplay();
    if (!world.config().mouse_follows_monitor) return;
    const index = world.displayIndex(identity) orelse return;
    const bounds = world.displays()[index].full_bounds;
    var point: native.WMPoint = undefined;
    if (!native.platform_pointer(&point)) return;
    if (point.left >= bounds.left and point.left < bounds.left + bounds.width and point.top >= bounds.top and point.top < bounds.top + bounds.height) return;
    if (!native.platform_warp_pointer(.{ .left = bounds.left + bounds.width / 2, .top = bounds.top + bounds.height / 2 })) native.platform_error("Mouse warp failed");
}
fn workspaceOwner() ?u32 {
    const first = placements[0].display orelse return null;
    for (placements[1..world.config().workspace_count]) |placement| if (placement.display != first) return null;
    return first;
}
// The display's active workspace, or null when global routing places no workspace on it.
fn placedWorkspace(display: Display) ?usize {
    if (world.config().workspace_monitors == null or placements[display.workspace].display == display.identity) return display.workspace;
    return null;
}
fn shownWorkspace(workspace: usize) bool {
    const identity = placements[workspace].display orelse return false;
    if (world.displayIndex(identity)) |index| return world.displays()[index].workspace == workspace;
    return placements[workspace].shown;
}
pub fn resolvePlacements() [10]?u32 {
    var resolved: [10]?u32 = @splat(null);
    const preferences = world.config().workspace_monitors orelse return resolved;
    var fallback: [2]commands.MonitorSelector = undefined;
    for (preferences.order[0..preferences.count], fallback[0..preferences.count]) |preference, *selection| selection.* = .{ .class = switch (preference) {
        .external => .external,
        .@"built-in" => .@"built-in",
    } };
    var screens: [monitor.capacity]monitor.Screen = undefined;
    const available = world.monitorScreens(&screens);
    for (world.config().workspaces[0..world.config().workspace_count], placements[0..world.config().workspace_count], resolved[0..world.config().workspace_count]) |*workspace, *placement, *destination| {
        const home = text(&placement.home);
        const home_display: ?u32 = if (home.len == 0) null else for (world.displays()) |display| {
            var uuid: [64]u8 = @splat(0);
            if (session.huen_session_display_uuid(display.identity, &uuid, uuid.len) and std.mem.eql(u8, text(&uuid), home)) break display.identity;
        } else null;
        destination.* = monitor.place(available, .{ .home = home_display, .monitors = workspace.monitor.slice(), .fallback = fallback[0..preferences.count], .current = placement.display });
    }
    return resolved;
}
const Activation = struct { display: u32, workspace: usize };
fn route(resolved: [10]?u32, forced: []const Activation, send: ?struct { index: usize, display: u32, workspace: usize }) bool {
    const workspace_count = world.config().workspace_count;
    var activations: [11]Activation = undefined;
    @memcpy(activations[0..forced.len], forced);
    var count = forced.len;
    scan: for (world.displays()) |display| {
        const identity = display.identity;
        for (forced) |activation| if (activation.display == identity) continue :scan;
        const current = display.workspace;
        var gained = false;
        var hosts = false;
        for (resolved[0..workspace_count], placements[0..workspace_count]) |destination, placement| if (destination == identity) {
            hosts = true;
            if (placement.display != identity) gained = true;
        };
        const lost = placements[current].display == identity and resolved[current] != identity;
        if (!hosts or !(gained or lost)) continue;
        const choice = if (placements[current].display == identity and resolved[current] == identity) current else for (0..workspace_count) |workspace| {
            if (resolved[workspace] == identity and placements[workspace].display != identity and shownWorkspace(workspace)) break workspace;
        } else for (0..workspace_count) |workspace| {
            // A reconnected display shows the workspace it showed when it disconnected.
            if (resolved[workspace] == identity and placements[workspace].display != identity and placements[workspace].shown_when_lost) break workspace;
        } else if (resolved[current] == identity) current else for (0..workspace_count) |workspace| {
            if (resolved[workspace] == identity) break workspace;
        } else unreachable;
        activations[count] = .{ .display = identity, .workspace = choice };
        count += 1;
    }
    const transaction = placer.Transaction.begin(.all) catch |err| {
        journal.setError(@errorName(err));
        return false;
    };
    defer transaction.deinit();
    var staged: [1024]u32 = undefined;
    for (activations[0..count]) |activation| if (world.displayBlocked(activation.display)) {
        journal.setError("Native fullscreen window blocks routing destination");
        return false;
    };
    for (world.windows(), 0..) |window, index| {
        const sent = send != null and send.?.index == index;
        const destination = if (sent) send.?.display else resolved[window.workspace] orelse if (world.displayIndex(window.display) == null) world.displays()[0].identity else window.display;
        staged[index] = destination;
        if (window.vanished != null) continue;
        if (window.observation.minimized or window.observation.fullscreen or (!window.observation.onscreen and !window.parked)) {
            if (destination != window.display or (window.observation.fullscreen and sent)) {
                journal.setError("Routing deferred for unavailable or native fullscreen window");
                return false;
            }
            continue;
        }
        if (window.observation.stale or world.displayBlocked(destination) or world.displayBlocked(window.display)) {
            journal.setError("Routing blocked by stale or native fullscreen window");
            return false;
        }
        var original: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &original)) {
            journal.setError("Routing geometry could not be read");
            return false;
        }
    }
    for (&world.layouts().roots) |*slot| if (slot.*) |*state| {
        const destination = resolved[state.workspace] orelse if (world.displayIndex(state.display) == null) world.displays()[0].identity else state.display;
        if (destination == state.display) continue;
        if (world.layouts().lookup(destination, state.workspace)) |existing| {
            const defaults = world.config().workspaces[state.workspace];
            const empty_default = existing.root == null and existing.fullscreen == null and existing.layout == defaults.layout and existing.ratio == defaults.ratio;
            if (empty_default) {
                existing.* = state.*;
                existing.display = destination;
            } else world.layouts().discard(state);
            slot.* = null;
        } else state.display = destination;
    };
    for (activations[0..count]) |activation| world.displays()[world.displayIndex(activation.display).?].workspace = activation.workspace;
    for (world.windows(), staged[0..world.windows().len], 0..) |*window, destination, index| {
        if (send) |request| if (request.index == index) {
            window.workspace = request.workspace;
        };
        if (destination == window.display) continue;
        const area = world.displayArea(destination);
        // Keeps a floating window's center at the same proportional position in the destination area.
        var relocated = window.floating_frame;
        if (world.displayIndex(window.display)) |slot| {
            const previous = world.displays()[slot].area();
            relocated.left = area.left + (relocated.left + relocated.width / 2 - previous.left) / previous.width * area.width - relocated.width / 2;
            relocated.top = area.top + (relocated.top + relocated.height / 2 - previous.top) / previous.height * area.height - relocated.height / 2;
        }
        window.floating_frame = world.boundedFloating(relocated, area);
        window.parking_frame = world.boundedFloating(window.parking_frame, area);
        window.display = destination;
    }
    if (send) |request| world.layouts().forgetIdentity(world.windows()[request.index].identity);
    if (!transaction.commit()) return false;
    for (&placements, resolved) |*placement, destination| {
        if (destination != placement.display) {
            const lost = if (placement.display) |identity| world.displayIndex(identity) == null else false;
            placement.shown_when_lost = lost and (placement.shown or placement.shown_when_lost);
        }
        placement.display = destination;
    }
    routing_blocked = false;
    return true;
}
fn routeMembership() bool {
    const resolved = resolvePlacements();
    var needed = false;
    for (resolved[0..world.config().workspace_count], placements[0..world.config().workspace_count]) |destination, placement| if (destination != placement.display) {
        needed = true;
    };
    for (world.windows()) |window| {
        const destination = resolved[window.workspace];
        if (world.displayIndex(window.display) == null or (destination != null and window.display != destination.?)) needed = true;
    }
    for (world.layouts().roots) |slot| if (slot) |state| {
        const defaults = world.config().workspaces[state.workspace];
        const has_state = state.root != null or state.fullscreen != null or state.layout != defaults.layout or state.ratio != defaults.ratio;
        const destination = resolved[state.workspace];
        if (has_state and (world.displayIndex(state.display) == null or (destination != null and state.display != destination.?))) needed = true;
    };
    return !needed or route(resolved, &.{}, null);
}
fn rememberFocus(identity: u64) void {
    const index = world.windowIndex(identity) orelse return;
    const window = world.windows()[index];
    focus_history.push(identity);
    var members: [1024]tiling.Member = undefined;
    world.layouts().rememberFocus(world.workspaceLayout(window.display, window.workspace), identity, world.layoutMembers(&members)) catch |err| {
        journal.setError(@errorName(err));
    };
}
fn focusVerified(identity: u64) bool {
    activated = native.platform_monotonic();
    if (!native.platform_focus(identity) or native.platform_focused_window() != identity) return false;
    focused = identity;
    last_observed_focus = identity;
    rememberFocus(identity);
    if (world.windowIndex(identity)) |index| {
        world.windows()[index].urgent = false;
        selectDisplay(world.windows()[index].display);
    }
    return true;
}
// Records a native focus change. A command leaves an activation request to the next tick, and so does a tick during a
// workspace transition. A tick reads focus from the last scan, and a scan of one application leaves the focus of the
// others as it was, so a tick confirms a request against live focus.
fn observeFocus(observed: ?u64, settle: bool) void {
    focused = observed;
    if (observed) |identity| if (world.windowIndex(identity)) |slot| if (world.windows()[slot].visible()) {
        world.windows()[slot].urgent = false;
    };
    if (observed == last_observed_focus) return;
    const previous = last_observed_focus;
    // A request is focus that an application took for a window on a hidden workspace, as when a link opens in a browser there.
    // A new window that a rule placed there is not a request. Neither is focus that macOS moves there because the focused
    // window went away, nor focus that comes back to the window that had it last, such as one that a command sent there.
    const requested = if (observed) |identity| requested: {
        if (world.isSuspended() or (focus_history.count > 0 and focus_history.entries[0] == identity)) break :requested false;
        const window = world.windows()[world.windowIndex(identity) orelse break :requested false];
        const slot = world.displayIndex(window.display) orelse break :requested false;
        if (!window.eligible() or window.workspace == world.displays()[slot].workspace) break :requested false;
        const now = native.platform_monotonic();
        if (now - window.discovered < 1.0) break :requested false;
        const asked = if (previous) |holder| focusable(holder) else now - focus_lost > 1.0;
        break :requested asked and (!settle or native.platform_focused_window() == identity);
    } else false;
    if (requested and (!settle or transition != null)) return;
    if (previous) |holder| if (!focusable(holder)) {
        focus_lost = native.platform_monotonic();
    };
    last_observed_focus = observed;
    const identity = observed orelse return;
    // Like Hyprland's `focus_on_activate`: follows the request to the window's workspace, or marks the window urgent and
    // asks for focus to return to the window that had it. Activation of another application completes later, so the
    // next observation records the returned focus.
    if (requested) {
        const taker = &world.windows()[world.windowIndex(identity).?];
        taker.urgent = true;
        const decision = world.ruleDecision(&taker.observation);
        if (decision.focus_on_activate orelse world.config().focus_on_activate) {
            _ = jumpToWindow(identity, world.activeDisplay());
        } else if (previous) |holder_identity| if (world.windowIndex(holder_identity)) |holder_index| {
            const holder = world.windows()[holder_index];
            if (holder.visible() and !holder.parked and native.platform_focus(holder.identity)) {
                focused = previous;
                return;
            }
        };
    }
    const window = world.windows()[world.windowIndex(identity) orelse return];
    rememberFocus(identity);
    if (world.displayIndex(window.display) != null) selectDisplay(window.display);
}
const replacement_grace = 0.5;
fn replaces(ghost: Window, successor: Window) bool {
    const vanished = ghost.vanished orelse return false;
    return successor.vanished == null and successor.observation.pid == ghost.observation.pid and @abs(successor.discovered - vanished) <= replacement_grace and world.framesNear(successor.discovered_frame, ghost.observation.frame, 4);
}
export fn wm_tick() void {
    edits.pollClose();
    if (!world.isInitialized()) return;
    defer publishState();
    var observedDisplays: [32]native.WMDisplay = undefined;
    const displayCount = native.platform_displays(&observedDisplays, observedDisplays.len);
    var updated: [monitor.capacity]Display = undefined;
    var topology_changed = displayCount != world.displays().len;
    for (&placements, 0..) |*placement, workspace| if (placement.display) |identity| if (world.displayIndex(identity)) |index| {
        placement.shown = world.displays()[index].workspace == workspace;
    };
    for (observedDisplays[0..displayCount], updated[0..displayCount]) |observation, *display| {
        const previous: ?Display = if (world.displayIndex(observation.identity)) |index| world.displays()[index] else null;
        if (previous == null or !std.meta.eql(previous.?.full_bounds, observation.full_bounds) or !std.meta.eql(previous.?.frame, observation.frame) or previous.?.built_in != observation.built_in) topology_changed = true;
        display.* = .{ .identity = observation.identity, .frame = observation.frame, .full_bounds = observation.full_bounds, .name = observation.name, .built_in = observation.built_in, .workspace = if (previous) |known| known.workspace else 0, .previous_workspace = if (previous) |known| known.previous_workspace else null };
    }
    if (topology_changed) {
        if (world.displays().len != 0) placer.noteTopologyChange();
        generation += 1;
        cancelTransition();
        workspace_shortcuts.clearRetainingCapacity();
    }
    world.replaceDisplays(updated[0..displayCount]);
    if (world.displays().len == 0) return;
    recall.load();
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_windows(&observed, observed.len);
    var recovered: [1024]parking.Recovery = undefined;
    const recoveries = recovery.recover(observed[0..count], &recovered);
    var observed_focus: ?u64 = null;
    for (observed[0..count]) |observation| {
        if (observation.focused) observed_focus = observation.identity;
        if (world.windowIndex(observation.identity)) |index| {
            var window = &world.windows()[index];
            window.observation = observation;
            if (window.vanished != null) {
                window.vanished = null;
                window.parked = window.vanished_parked;
                window.vanished_parked = false;
            }
            if (world.displayIndex(window.display) != null and transition == null and window.floating and !window.managedFullscreen() and !window.parked and !observation.stale and observation.motion == .idle) {
                if (window.floating_restore) {
                    if (world.framesNear(observation.frame, window.floating_frame, 2)) window.floating_restore = false;
                } else window.floating_frame = observation.frame;
            }
            continue;
        }
        if (world.windows().len == 1024) continue;
        var best: f64 = std.math.inf(f64);
        var displaySlot: usize = 0;
        for (world.displays(), 0..) |candidate, slot| {
            const horizontal = observation.frame.left + observation.frame.width / 2 - candidate.frame.left - candidate.frame.width / 2;
            const vertical = observation.frame.top + observation.frame.height / 2 - candidate.frame.top - candidate.frame.height / 2;
            const distance = horizontal * horizontal + vertical * vertical;
            if (distance < best) {
                best = distance;
                displaySlot = slot;
            }
        }
        const display = world.displays()[displaySlot].identity;
        // With global routing, a window on an empty display joins the current workspace.
        const joined = placedWorkspace(world.displays()[displaySlot]) orelse currentWorkspace(displaySlot);
        var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = joined, .parking_frame = observation.frame, .floating_frame = observation.frame, .goal = observation.frame, .discovered_frame = observation.frame };
        const decision = world.ruleDecision(&observation);
        window.floating = decision.floating orelse false;
        if (decision.workspace) |workspace| window.workspace = workspace;
        if (window.floating and (decision.geometry != null or decision.centered)) {
            const destination = resolvePlacements()[window.workspace] orelse display;
            const area = world.displayArea(destination);
            var frame = observation.frame;
            if (decision.geometry) |geometry| frame = .{ .left = area.left + geometry.left, .top = area.top + geometry.top, .width = geometry.width, .height = geometry.height };
            // A centered window keeps its size, so an application with a fixed window size still accepts the placement.
            if (decision.centered) {
                frame.left = area.left + (area.width - frame.width) / 2;
                frame.top = area.top + (area.height - frame.height) / 2;
            }
            window.floating_frame = world.boundedFloating(frame, area);
            window.floating_restore = true;
        }
        // A recovered window stays owned even when it did not reach its frame or shares it with another window of its application.
        for (recoveries.matches) |match| if (observed[match.index].identity == observation.identity) {
            window.parked = true;
            window.parking_frame = match.original;
        };
        window.discovered = native.platform_monotonic();
        // A window the first scan finds predates the manager, but its application may have launched only moments before.
        window.established = recoveries.first_scan and age: {
            if (observation.process_token == 0) break :age false;
            // The token is a launch date in seconds since 2001.
            break :age @as(f64, @floatFromInt(journal.wallSeconds())) - 978307200 - observation.process_token > 5;
        };
        recall.claim(&window, decision, display);
        world.addWindow(window);
    }
    var now: ?f64 = null;
    for (world.windows()) |*window| {
        if (window.vanished != null) continue;
        for (observed[0..count]) |observation| {
            if (observation.identity == window.identity) break;
        } else {
            window.vanished = now orelse native.platform_monotonic();
            now = window.vanished;
            window.observation.stale = true;
            window.observation.onscreen = false;
            window.observation.focused = false;
            window.observation.fullscreen = false;
            window.vanished_parked = window.parked;
            window.parked = false;
            window.urgent = false;
        }
    }
    var index: usize = 0;
    while (index < world.windows().len) {
        const vanished = world.windows()[index].vanished orelse {
            index += 1;
            continue;
        };
        const successor_index = search: {
            var found: ?usize = null;
            for (world.windows(), 0..) |candidate, candidate_index| if (replaces(world.windows()[index], candidate)) {
                if (found != null) break :search null;
                found = candidate_index;
            };
            const successor = world.windows()[found orelse break :search null];
            for (world.windows(), 0..) |other, other_index| if (other_index != index and replaces(other, successor)) break :search null;
            break :search found;
        };
        // The successor takes the ghost's slot because the master layout orders its stack by slot.
        if (successor_index) |successor_slot| {
            const ghost = world.windows()[index];
            var successor = world.windows()[successor_slot];
            successor.workspace = ghost.workspace;
            successor.display = ghost.display;
            successor.floating = ghost.floating;
            successor.floating_frame = ghost.floating_frame;
            successor.floating_restore = ghost.floating;
            successor.last_floating_frame = ghost.last_floating_frame;
            successor.bounds = ghost.bounds;
            successor.placed = null;
            // The successor appeared at the corner, so that frame must not become the geometry that restore writes back.
            if (ghost.vanished_parked) {
                successor.parking_frame = recovery.restingFrame(ghost.parking_frame);
                successor.parked = true;
                var actual = successor.observation.frame;
                _ = native.platform_adopt_original(successor.identity, successor.parking_frame, &actual);
                successor.observation.frame = actual;
            }
            world.layouts().replaceIdentity(ghost.identity, successor.identity);
            focus_history.rename(ghost.identity, successor.identity);
            if (last_observed_focus == ghost.identity) last_observed_focus = successor.identity;
            world.replaceWithSuccessor(index, successor_slot, successor);
            continue;
        }
        if (now == null) now = native.platform_monotonic();
        if (now.? - vanished > replacement_grace) {
            // The window can still sit at its corner, as when its application stops being a regular application.
            if (world.windows()[index].vanished_parked) recovery.orphan(&world.windows()[index], now.?);
            // An application can take seconds to exit after its windows close, so the entry waits for `settle` to see the exit.
            const gone = world.windows()[index];
            recall.rememberClosed(gone, now.?);
            world.layouts().forgetIdentity(world.windows()[index].identity);
            focus_history.forget(world.windows()[index].identity);
            world.removeWindow(index);
        } else index += 1;
    }
    checkpoint.restore();
    if (!world.isSuspended() and transition == null) routing_blocked = !routeMembership();
    observeFocus(observed_focus, true);
    if (focused) |identity| if (world.windowIndex(identity) == null) {
        focused = null;
    };
    world.ensureSelection();
    trackCurrentDisplay();
    placer.reconcile();
    if (checkpoint.takeFocusPending()) {
        focusWorkspace(world.displays()[world.activeDisplay()].identity, null);
    }
}
fn readingOrder(display: u32, kind: ?commands.WindowKind, output: []u64) []u64 {
    const Entry = struct {
        floating: bool,
        frame: Rect,
        identity: u64,
        fn lessThan(_: void, first: @This(), second: @This()) bool {
            if (first.floating != second.floating) return !first.floating;
            if (first.frame.top != second.frame.top) return first.frame.top < second.frame.top;
            if (first.frame.left != second.frame.left) return first.frame.left < second.frame.left;
            return first.identity < second.identity;
        }
    };
    var entries: [1024]Entry = undefined;
    var count: usize = 0;
    for (world.windows()) |window| {
        if (window.display != display or !window.visible() or window.parked) continue;
        if (kind) |wanted| if ((wanted == .floating) != window.floating) continue;
        entries[count] = .{ .floating = window.floating, .frame = window.targetFrame(), .identity = window.identity };
        count += 1;
    }
    std.mem.sort(Entry, entries[0..count], {}, Entry.lessThan);
    for (entries[0..count], 0..) |entry, index| output[index] = entry.identity;
    return output[0..count];
}
fn swapWindows(source_index: usize, target_index: usize) [*:0]const u8 {
    const source = &world.windows()[source_index];
    const target = &world.windows()[target_index];
    const identity = source.identity;
    const transaction = placer.Transaction.begin(.{ .pair = .{ source.display, target.display } }) catch |err| return failure(@errorName(err));
    defer transaction.deinit();
    world.layouts().swap(source.identity, target.identity);
    if (source.managedFullscreen()) world.workspaceLayout(source.display, source.workspace).fullscreen = null;
    if (target.managedFullscreen()) world.workspaceLayout(target.display, target.workspace).fullscreen = null;
    std.mem.swap(u32, &source.display, &target.display);
    std.mem.swap(usize, &source.workspace, &target.workspace);
    std.mem.swap(Window, source, target);
    if (!transaction.commit()) return failure(journal.lastError() orelse "SwapPlacementFailed");
    return json(.{ .ok = true, .verified = focusVerified(identity) });
}
// How far the candidate's center lies ahead of the source's in `direction`, and how far it lies off that line.
fn offsets(source: *const Window, candidate: *const Window, direction: Direction) [2]f64 {
    const from = if (source.floating) source.floating_frame else source.goal;
    const to = if (candidate.floating) candidate.floating_frame else candidate.goal;
    const horizontal = to.left + to.width / 2 - from.left - from.width / 2;
    const vertical = to.top + to.height / 2 - from.top - from.height / 2;
    return switch (direction) {
        .left => .{ -horizontal, @abs(vertical) },
        .right => .{ horizontal, @abs(vertical) },
        .up => .{ -vertical, @abs(horizontal) },
        .down => .{ vertical, @abs(horizontal) },
    };
}
fn neighbor(sourceIndex: usize, direction: Direction) ?usize {
    var best: f64 = std.math.inf(f64);
    var result: ?usize = null;
    for (world.windows(), 0..) |candidate, index| {
        if (index == sourceIndex or !candidate.visible() or candidate.parked) continue;
        const forward, const cross = offsets(&world.windows()[sourceIndex], &candidate, direction);
        if (forward <= 1) continue;
        const score = forward + cross * 2;
        if (score < best) {
            best = score;
            result = index;
        }
    }
    return result;
}
fn cancelTransition() void {
    if (transition != null) snapshot_presentation = .idle;
    transition = null;
    native.huen_scene_cancel();
}
fn refreshObservations() void {
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_refresh_windows(&observed, observed.len);
    for (world.windows()) |*window| {
        window.observation.stale = true;
        for (observed[0..count]) |observation| if (observation.identity == window.identity) {
            window.observation = observation;
            break;
        };
    }
}
fn focusable(identity: u64) bool {
    const window = world.windows()[world.windowIndex(identity) orelse return false];
    return window.eligible() and world.displayIndex(window.display) != null;
}
fn focusWorkspace(displayIdentity: u32, focus_target: ?u64) void {
    refreshObservations();
    if (!placer.deriveGoals()) return;
    const index = world.displayIndex(displayIdentity) orelse return;
    const state = world.workspaceLayout(displayIdentity, world.displays()[index].workspace);
    var members: [1024]tiling.Member = undefined;
    if (focus_target orelse world.layouts().focusCandidate(state, world.layoutMembers(&members))) |identity| {
        const window = world.windows()[world.windowIndex(identity) orelse return];
        if (!window.visible() or window.parked) {
            const transaction = placer.Transaction.begin(.{ .display = displayIdentity }) catch |err| {
                journal.setError(@errorName(err));
                return;
            };
            defer transaction.deinit();
            world.layouts().reveal(state, identity) catch |err| {
                journal.setError(transaction.abort(err));
                return;
            };
            if (!transaction.commit()) return;
        }
        if (!focusVerified(identity)) return;
    }
    selectDisplay(displayIdentity);
}
fn commitWorkspace(displaySlot: usize, workspace: usize, from: usize, focus_target: ?u64) bool {
    const displayIdentity = world.displays()[displaySlot].identity;
    if (world.displayBlocked(displayIdentity)) {
        journal.setError("Native fullscreen window blocks this display");
        return false;
    }
    const transaction = placer.Transaction.begin(.{ .display = displayIdentity }) catch |err| {
        journal.setError(@errorName(err));
        return false;
    };
    defer transaction.deinit();
    world.displays()[displaySlot].workspace = workspace;
    var members: [1024]tiling.Member = undefined;
    const state = world.workspaceLayout(displayIdentity, workspace);
    if (focus_target orelse world.layouts().focusCandidate(state, world.layoutMembers(&members))) |identity| world.layouts().reveal(state, identity) catch |err| {
        journal.setError(transaction.abort(err));
        return false;
    };
    if (!transaction.commit()) return false;
    recordPrevious(displaySlot, from, workspace);
    focusWorkspace(displayIdentity, focus_target);
    journal.setError(null);
    native.platform_config_changed();
    return true;
}
fn sceneReady(context: ?*anyopaque, covered: bool) callconv(.c) void {
    const callbackGeneration = @intFromPtr(context orelse return);
    const pending = transition orelse return;
    if (callbackGeneration != pending.generation) return;
    defer publishStatus();
    defer journal.flushTransition();
    native.platform_settle_budget_begin();
    snapshot_presentation = if (covered) .captured else .fallback;
    if (world.displayIndex(pending.display)) |displaySlot| {
        _ = commitWorkspace(displaySlot, pending.workspace, pending.from, pending.focus_target);
    } else journal.setError("Display disconnected during workspace capture");
    transition = null;
    if (covered) native.huen_scene_finish(pending.generation);
}
fn switchWorkspace(display_slot: usize, workspace: usize, from: usize, focus_target: ?u64) [*:0]const u8 {
    const destination = world.displays()[display_slot];
    if (workspace == destination.workspace) {
        focusWorkspace(destination.identity, focus_target);
        return json(.{ .ok = true, .changed = false });
    }
    generation += 1;
    if (world.config().duration == 0 or !native.huen_scene_capture_allowed()) {
        snapshot_presentation = .instant;
        if (!commitWorkspace(display_slot, workspace, from, focus_target)) return failure(journal.lastError() orelse "WorkspacePlacementFailed");
        return json(.{ .ok = true });
    }
    snapshot_presentation = .pending;
    transition = .{ .display = destination.identity, .workspace = workspace, .from = from, .generation = generation, .focus_target = focus_target };
    native.huen_scene_begin(destination.identity, generation, world.config().duration, sceneReady, @ptrFromInt(generation));
    return json(.{ .ok = true, .accepted = true, .generation = generation });
}
// Global mode: show `workspace` on its display and select that display. `from` is the
// selected display's workspace and becomes the global previous workspace.
fn showWorkspace(workspace: usize, from: usize, focus_target: ?u64) [*:0]const u8 {
    const resolved = resolvePlacements();
    const owner = resolved[workspace] orelse return failure("NoWorkspaceOwner");
    const destination_slot = world.displayIndex(owner).?;
    var migration = false;
    for (resolved[0..world.config().workspace_count], placements[0..world.config().workspace_count]) |destination, placement| if (destination != placement.display) {
        migration = true;
    };
    for (world.windows()) |window| if (window.display != resolved[window.workspace].?) {
        migration = true;
    };
    if (migration) {
        generation += 1;
        snapshot_presentation = .instant;
        if (!route(resolved, &.{.{ .display = owner, .workspace = workspace }}, null)) return failure(journal.lastError() orelse "MonitorRoutingFailed");
        recordPrevious(destination_slot, from, workspace);
        focusWorkspace(owner, focus_target);
        native.platform_config_changed();
        return json(.{ .ok = true, .monitor = owner, .verified = world.selected() == owner, .target = focus_target });
    }
    routing_blocked = !routeMembership();
    if (routing_blocked) return failure(journal.lastError() orelse "MonitorRoutingFailed");
    if (world.displays()[destination_slot].workspace != workspace) return switchWorkspace(destination_slot, workspace, from, focus_target);
    focusWorkspace(owner, focus_target);
    const verified = world.selected() == owner and (focus_target == null or focused == focus_target);
    if (verified) recordPrevious(destination_slot, from, workspace);
    return json(.{ .ok = true, .changed = false, .monitor = owner, .verified = verified, .target = focus_target });
}
fn jumpToWindow(identity: u64, display_slot: usize) [*:0]const u8 {
    const window = world.windows()[world.windowIndex(identity).?];
    if (world.config().workspace_monitors != null) return showWorkspace(window.workspace, currentWorkspace(display_slot), identity);
    const slot = world.displayIndex(window.display).?;
    if (window.workspace != world.displays()[slot].workspace) return switchWorkspace(slot, window.workspace, world.displays()[slot].workspace, identity);
    focusWorkspace(window.display, identity);
    return json(.{ .ok = true, .verified = focused == identity, .target = identity });
}
fn observeCommandState() void {
    refreshObservations();
    const observed_focus = native.platform_focused_window();
    observeFocus(if (observed_focus != 0) observed_focus else null, false);
    trackCurrentDisplay();
}
export fn wm_hotkey_poll() void {
    const now = native.platform_monotonic();
    // macOS can stop delivering registered hotkeys without an error.
    if (hotkey_watch.overdue(now)) |command| {
        hotkey_recovery.missed += 1;
        var buffer: [256:0]u8 = @splat(0);
        _ = std.fmt.bufPrint(&buffer, "macOS did not deliver hotkey \"{s}\"; ran it from the key press", .{text(&command)}) catch {};
        native.platform_error(&buffer);
        _ = journal.append("error", .{ .message = "Hotkey not delivered; ran it from the key press" });
        if (now - hotkey_recovery.rebound >= 5) {
            hotkey_recovery.rebound = now;
            hotkey_recovery.rebinds += 1;
            if (!native.platform_rebind()) {
                native.platform_error("Hotkey re-registration failed");
                _ = journal.append("error", .{ .message = "Hotkey re-registration failed" });
            }
        }
        wm_hotkey(&command);
    }
    if (now - activated >= activation_settle) placeShortcuts();
}
export fn wm_hotkey_pressed(slot: u32, command: [*:0]const u8) void {
    hotkey_watch.pressed(slot, std.mem.span(command), native.platform_monotonic());
}
export fn wm_hotkey_delivered(slot: u32, command: [*:0]const u8) void {
    if (hotkey_watch.delivered(slot, native.platform_monotonic())) wm_hotkey(command);
}
export fn wm_swipe(fingers: u32, horizontal: f64, vertical: f64) void {
    if (!world.isInitialized() or !world.config().swipe.enabled) return;
    swipe_recognizer.fingers = world.config().swipe.fingers;
    const step = swipe_recognizer.sample(fingers, horizontal, vertical, native.platform_monotonic()) orelse return;
    if (world.isSuspended() or transition != null or native.platform_pointer_buttons()) return;
    var point: native.WMPoint = undefined;
    if (native.platform_pointer(&point)) for (world.displays()) |display| {
        const bounds = display.full_bounds;
        if (point.left < bounds.left or point.left >= bounds.left + bounds.width or point.top < bounds.top or point.top >= bounds.top + bounds.height) continue;
        selectDisplay(display.identity);
        break;
    };
    wm_hotkey(if (step == .next) "workspace occupied+1" else "workspace occupied-1");
}
fn placeShortcuts() void {
    if (workspace_shortcuts.items.len == 0) return;
    defer workspace_shortcuts.clearRetainingCapacity();
    if (world.isSuspended() or world.displays().len == 0 or transition != null) return;
    defer publishState();
    var remaining = workspace_shortcuts.items;
    while (remaining.len != 0) {
        observeCommandState();
        const slot = world.activeDisplay();
        var view = workspaceView(slot);
        const from = view.current;
        const owners = resolvePlacements();
        var destination: ?u32 = null;
        while (remaining.len != 0) {
            const target = selector.resolve(remaining[0], view) catch {
                remaining = remaining[1..];
                continue;
            };
            const owner = owners[target] orelse world.displays()[slot].identity;
            if (destination != null and destination != owner) break;
            destination = owner;
            if (target != view.current) view.previous = view.current;
            view.current = target;
            view.back_and_forth = world.config().workspace_back_and_forth;
            remaining = remaining[1..];
        }
        if (destination != null) _ = if (world.config().workspace_monitors != null) showWorkspace(view.current, from, null) else switchWorkspace(slot, view.current, from, null);
    }
}
export fn wm_hotkey(commandText: [*:0]const u8) void {
    const command = parseCommand(std.mem.span(commandText), world.config().workspace_count) catch return;
    if (command != .workspace or world.isSuspended() or transition != null or world.displays().len == 0 or (world.config().duration != 0 and native.huen_scene_capture_allowed())) {
        _ = wm_command(commandText);
        return;
    }
    if (workspace_shortcuts.items.len == workspace_shortcuts.capacity) placeShortcuts();
    workspace_shortcuts.appendAssumeCapacity(command.workspace);
}
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    defer publishState();
    const command = parseCommand(std.mem.span(commandText), world.config().workspace_count) catch |err| return failure(@errorName(err));
    switch (command) {
        .status, .windows, .monitors, .workspaces, .wrong => {},
        .quit, .restore => workspace_shortcuts.clearRetainingCapacity(),
        else => placeShortcuts(),
    }
    switch (command) {
        .status => {
            const launch = native.platform_launch_status();
            const Placed = struct { index: usize, name: []const u8, display: ?u32, home: []const u8 };
            var placed: [10]Placed = undefined;
            for (world.config().workspaces[0..world.config().workspace_count], placements[0..world.config().workspace_count], placed[0..world.config().workspace_count], 0..) |*workspace, *placement, *item, index| {
                item.* = .{ .index = index + 1, .name = text(&workspace.name), .display = placement.display, .home = text(&placement.home) };
            }
            return json(.{
                .running = true,
                .suspended = world.isSuspended(),
                .active_mode = text(&world.config().modes[active_mode].name),
                .close_state = edits.closeState(),
                .launch = .{ .request_id = launch.request_id, .state = launch.state, .message = text(&launch.message) },
                .window_count = world.windows().len,
                .display_count = world.displays().len,
                .selected_monitor = world.selected(),
                .workspace_owner = workspaceOwner(),
                .placements = placed[0..world.config().workspace_count],
                .routing_blocked = routing_blocked,
                .workspace_backend = "corner-parking",
                .filter = std.mem.span(native.platform_filter()),
                .scene_capture_allowed = native.huen_scene_capture_allowed(),
                .snapshot_presentation = snapshot_presentation,
                .snapshot_generation = generation,
                .transition_pending = transition != null,
                .transition_error = journal.lastError(),
                .hotkeys = .{ .watchdog = if (native.huen_observe_active()) "active" else "unavailable", .missed = hotkey_recovery.missed, .rebinds = hotkey_recovery.rebinds },
                .mouse = .{ .availability = interaction.huen_input_status(), .generation = pointer_controls.generation, .err_message = pointer_controls.error_message, .forced_stop = pointer_controls.forced_stop },
                .session = checkpoint.status(),
                .parking_recovery = recovery.status(),
                .placement_memory = recall.status(),
                .config_reload = reload.status(),
            });
        },
        .mode => |name| {
            const index = world.config().modeIndex(name.text()) orelse return failure("UnknownMode");
            const mode = &world.config().modes[index];
            if (!native.platform_bindings(&mode.bindings, mode.binding_count)) return failure("HotkeyCollision");
            hotkey_watch.forgetPresses();
            active_mode = index;
            return json(.{ .ok = true, .active_mode = text(&mode.name) });
        },
        .launch => |request| return edits.launch(request),
        .wrong => |note| {
            if (!journal.enabled()) return failure("JournalDisabledByFilter");
            var length = @min(note.len, 200);
            while (length < note.len and note[length] & 0xc0 == 0x80) length -= 1;
            const Shown = struct { display: u32, workspace: ?usize };
            var shown: [monitor.capacity]Shown = undefined;
            for (world.displays(), shown[0..world.displays().len]) |display, *item| item.* = .{ .display = display.identity, .workspace = if (placedWorkspace(display)) |workspace| workspace + 1 else null };
            var parked: usize = 0;
            for (world.windows()) |window| parked += @intFromBool(window.parked);
            if (!journal.append("mark", .{ .note = note[0..length], .window_count = world.windows().len, .parked_count = parked, .workspaces = shown[0..world.displays().len], .transition_error = journal.lastError() })) return failure("JournalAppendFailed");
            return json(.{ .ok = true });
        },
        .exec_and_forget => |shell| return edits.exec(shell),
        .windows => {
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, urgent: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, managed_fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8, group_hidden: bool, parking_exempt: bool, minimum: struct { width: f64, height: f64 }, maximum: struct { width: ?f64, height: ?f64 } };
            var items: [1024]Item = undefined;
            for (world.windows(), items[0..world.windows().len]) |*window, *item| item.* = .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focused == window.identity, .urgent = window.urgent, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .managed_fullscreen = window.managedFullscreen(), .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error, .group_hidden = !window.floating and world.layouts().visibility(window.identity) == .hidden_by_group, .parking_exempt = window.escape == .exempt, .minimum = .{ .width = window.bounds.minimumAt(.width), .height = window.bounds.minimumAt(.height) }, .maximum = .{ .width = if (window.bounds.ceilingAt(.width)) |ceiling| ceiling.accepted else null, .height = if (window.bounds.ceilingAt(.height)) |ceiling| ceiling.accepted else null } };
            return json(items[0..world.windows().len]);
        },
        .monitors => {
            const Item = struct { id: u32, uuid: ?[]const u8, name: []const u8, frame: Rect, full_bounds: Rect, built_in: bool, workspace: ?usize, selected: bool, blocked_by_fullscreen: bool };
            var items: [monitor.capacity]Item = undefined;
            var uuids: [monitor.capacity][64]u8 = undefined;
            const count = world.displays().len;
            for (world.displays(), uuids[0..count], items[0..count]) |*display, *uuid, *item| {
                uuid.* = @splat(0);
                const known = session.huen_session_display_uuid(display.identity, uuid, uuid.len);
                const placed = placedWorkspace(display.*);
                item.* = .{ .id = display.identity, .uuid = if (known) text(uuid) else null, .name = text(&display.name), .frame = display.frame, .full_bounds = display.full_bounds, .built_in = display.built_in, .workspace = if (placed) |workspace| workspace + 1 else null, .selected = world.selected() == display.identity, .blocked_by_fullscreen = world.displayBlocked(display.identity) };
            }
            return json(items[0..count]);
        },
        .workspaces => {
            const Item = struct { display: u32, index: usize, name: []const u8, active: bool, urgent: bool, layout: Layout };
            var items: [monitor.capacity * 10]Item = undefined;
            var count: usize = 0;
            for (world.displays()) |display| for (world.config().workspaces[0..world.config().workspace_count], 0..) |*workspace, index| {
                if (world.config().workspace_monitors != null and placements[index].display != display.identity) continue;
                const layout = if (world.layouts().lookup(display.identity, index)) |state| state.layout else workspace.layout;
                const urgent = for (world.windows()) |window| {
                    if (window.urgent and window.display == display.identity and window.workspace == index) break true;
                } else false;
                items[count] = .{ .display = display.identity, .index = index + 1, .name = text(&workspace.name), .active = display.workspace == index, .urgent = urgent, .layout = layout };
                count += 1;
            };
            return json(items[0..count]);
        },
        .reload => {
            if (transition != null) return failure("WorkspaceTransitionPending");
            return reload.start();
        },
        .quit, .restore => {
            edits.cancelClose(command == .restore);
            reload.cancel();
            cancelTransition();
            if (command == .quit) {
                native.platform_quit();
                return json(.{ .ok = true });
            }
            checkpoint.freeze();
            world.markSuspended();
            const outstanding = native.platform_restore();
            recall.persist();
            if (outstanding == 0) {
                checkpoint.save(true);
                recovery.settle();
            }
            native.platform_border(0, 0, 0);
            if (outstanding != 0) return json(.{ .@"error" = true, .err_message = "Geometry restoration incomplete. Retry restore after unminimizing or leaving fullscreen.", .outstanding = outstanding, .suspended = true });
            return json(.{ .ok = true, .suspended = true, .note = "Restored live-session geometry. Restart to resume tiling." });
        },
        else => {},
    }
    if (world.isSuspended()) return failure("RuntimeSuspendedRestartToResume");
    if (transition != null) return failure("WorkspaceTransitionPending");
    if (world.displays().len == 0) return failure("NoDisplays");
    observeCommandState();
    const displaySlot = world.activeDisplay();
    const display = &world.displays()[displaySlot];
    switch (command) {
        .workspace => |selection| {
            const workspace = resolveWorkspace(selection, displaySlot) catch |err| return failure(@errorName(err));
            if (world.config().workspace_monitors == null) return switchWorkspace(displaySlot, workspace, display.workspace, null);
            return showWorkspace(workspace, currentWorkspace(displaySlot), null);
        },
        .focus_monitor => |selection| {
            var screens: [monitor.capacity]monitor.Screen = undefined;
            const target = monitor.resolve(selection, world.monitorScreens(&screens), display.identity) catch |err| return failure(@errorName(err));
            const changed = world.selected() != target;
            focusWorkspace(target, null);
            return json(.{ .ok = true, .accepted = true, .changed = changed, .monitor = target, .verified = world.selected() == target, .focused = focused });
        },
        .move_workspace_to_monitor, .swap_monitor_workspaces => |selection| {
            if (world.config().workspace_monitors == null) return failure("RequiresGlobalWorkspaces");
            var screens: [monitor.capacity]monitor.Screen = undefined;
            const target = monitor.resolve(selection, world.monitorScreens(&screens), display.identity) catch |err| return failure(@errorName(err));
            const workspace = display.workspace;
            if (placements[workspace].display != display.identity) return failure("NoWorkspaceOnMonitor");
            if (target == display.identity) return json(.{ .ok = true, .changed = false, .monitor = target });
            // Each moved workspace's runtime home becomes its destination display, which shows it.
            var forced: [2]Activation = .{ .{ .display = target, .workspace = workspace }, undefined };
            var count: usize = 1;
            if (command == .swap_monitor_workspaces) {
                const target_workspace = world.displays()[world.displayIndex(target).?].workspace;
                if (placements[target_workspace].display != target) return failure("NoWorkspaceOnMonitor");
                forced[1] = .{ .display = display.identity, .workspace = target_workspace };
                count = 2;
            }
            var homes: [10][128]u8 = undefined;
            for (&homes, placements) |*home, placement| home.* = placement.home;
            for (forced[0..count]) |move| {
                const moved = &placements[move.workspace].home;
                moved.* = @splat(0);
                if (session.huen_session_display_uuid(move.display, moved, moved.len)) continue;
                for (&placements, homes) |*placement, home| placement.home = home;
                return failure("MonitorUuidUnavailable");
            }
            const resolved = resolvePlacements();
            // The vacated display shows the global previous workspace if it is placed there, else its lowest placed one, else nothing.
            if (command == .move_workspace_to_monitor) {
                const vacated = display.identity;
                const fallback: ?usize = if (global_previous != null and resolved[global_previous.?] == vacated) global_previous else for (0..world.config().workspace_count) |candidate| {
                    if (resolved[candidate] == vacated) break candidate;
                } else null;
                if (fallback) |shown| {
                    forced[1] = .{ .display = vacated, .workspace = shown };
                    count = 2;
                }
            }
            generation += 1;
            snapshot_presentation = .instant;
            if (!route(resolved, forced[0..count], null)) {
                for (&placements, homes) |*placement, home| placement.home = home;
                return failure(journal.lastError() orelse "MonitorRoutingFailed");
            }
            focusWorkspace(target, null);
            native.platform_config_changed();
            return json(.{ .ok = true, .monitor = target, .verified = world.selected() == target, .focused = focused });
        },
        .cycle => |request| {
            var identities: [1024]u64 = undefined;
            const target = selector.cycleTarget(readingOrder(display.identity, request.kind, &identities), focused, request.step) orelse return failure("NoWindowToCycle");
            return json(.{ .ok = true, .accepted = true, .verified = focusVerified(target), .target = target });
        },
        .focus_last, .focus_urgent => {
            const urgent: ?u64 = if (command == .focus_urgent) for (world.windows()) |window| {
                if (window.urgent and focusable(window.identity)) break window.identity;
            } else null else null;
            return jumpToWindow(urgent orelse focus_history.pick(focused, focusable) orelse return failure("NoPreviousWindow"), displaySlot);
        },
        .move_app => |request| {
            const resolved = resolvePlacements();
            const workspace = resolveWorkspace(request.workspace, displaySlot) catch |err| return failure(@errorName(err));
            var identities: [1024]u64 = undefined;
            var count: usize = 0;
            for (world.windows()) |window| if (window.vanished == null and std.mem.eql(u8, text(&window.observation.bundle), request.bundle.text())) {
                identities[count] = window.identity;
                count += 1;
            };
            var moved: usize = 0;
            var first_error: ?[]const u8 = null;
            for (identities[0..count]) |identity| {
                const index = world.windowIndex(identity) orelse continue;
                const window = world.windows()[index];
                const destination = resolved[workspace] orelse window.display;
                if (workspace == window.workspace and destination == window.display) continue;
                if (route(resolved, &.{}, .{ .index = index, .display = destination, .workspace = workspace })) moved += 1 else if (first_error == null) {
                    first_error = journal.lastError() orelse "MonitorRoutingFailed";
                }
            }
            if (focused) |identity| if (world.windowIndex(identity)) |index| if (!world.windows()[index].visible()) {
                focused = null;
            };
            if (moved > 0) native.platform_config_changed();
            if (first_error) |message| return json(.{ .@"error" = true, .err_message = message, .moved = moved });
            return json(.{ .ok = true, .moved = moved });
        },
        .layout => |layout| {
            if (placedWorkspace(display.*) == null) return failure("NoWorkspaceOnMonitor");
            const transaction = placer.Transaction.begin(.{ .display = display.identity }) catch |err| return failure(@errorName(err));
            defer transaction.deinit();
            world.workspaceLayout(display.identity, display.workspace).layout = layout;
            if (!transaction.commit()) return failure(journal.lastError() orelse "LayoutPlacementFailed");
            native.platform_config_changed();
            return json(.{ .ok = true });
        },
        .resize => |delta| {
            if (placedWorkspace(display.*) == null) return failure("NoWorkspaceOnMonitor");
            world.layouts().adjustRatio(world.workspaceLayout(display.identity, display.workspace), delta);
        },
        else => {
            const sourceIndex = world.windowIndex(focused orelse return failure("NoFocusedWindow")) orelse return failure("NoFocusedWindow");
            const source = &world.windows()[sourceIndex];
            if (!source.visible()) return failure("FocusedWindowNotManaged");
            switch (command) {
                .select => |direction| {
                    const state = world.workspaceLayout(source.display, source.workspace);
                    const selection = world.layouts().select(state, source.identity, direction) catch |err| return failure(@errorName(err));
                    const representative = world.layouts().representative(selection) catch |err| return failure(@errorName(err));
                    return json(.{ .ok = true, .selection = selection, .representative = representative });
                },
                .tilemove, .group => {
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    const transaction = placer.Transaction.begin(.{ .display = source.display }) catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    const state = world.workspaceLayout(source.display, source.workspace);
                    const edited: anyerror!?u64 = switch (command) {
                        .tilemove => |direction| if (world.layouts().tilemove(state, source.identity, direction)) null else |err| err,
                        .group => |action| world.layouts().editGroup(state, source.identity, action),
                        else => unreachable,
                    };
                    const target = edited catch |err| return failure(transaction.abort(err));
                    if (!transaction.commit()) return failure(journal.lastError() orelse "GroupPlacementFailed");
                    const verified = if (target) |identity| focusVerified(identity) else true;
                    native.platform_config_changed();
                    return json(.{ .ok = true, .target = target, .verified = verified });
                },
                .split => |orientation| {
                    const state = world.workspaceLayout(source.display, source.workspace);
                    if (state.layout != .dwindle) return failure("SplitRequiresDwindle");
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    world.layouts().orient(source.identity, orientation) catch |err| return failure(@errorName(err));
                },
                .resize_points => |resize| {
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    if (!placer.deriveGoals()) return failure(journal.lastError() orelse "LayoutProjectionFailed");
                    const identity = source.identity;
                    const before = source.goal;
                    var applied = placer.resizeTiled(sourceIndex, resize.axis, resize.delta) catch |err| return failure(@errorName(err));
                    const retried = @abs(resize.delta - applied) > size_bounds.tolerance and placer.forgetWorkspaceBounds(source.display, source.workspace);
                    if (retried) {
                        if (!placer.deriveGoals()) return failure(journal.lastError() orelse "LayoutProjectionFailed");
                        _ = placer.resizeTiled(sourceIndex, resize.axis, resize.delta - applied) catch |err| return failure(@errorName(err));
                    }
                    placer.reconcile();
                    // Placement learns a bound again when the application still refuses, so only the placed goal shows the change.
                    if (retried) if (world.windowIndex(identity)) |index| {
                        const after = world.windows()[index].goal;
                        applied = if (resize.axis == .width) after.width - before.width else after.height - before.height;
                    };
                    native.platform_config_changed();
                    return json(.{ .ok = true, .applied_delta = applied });
                },
                .resize_by => |offset| {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (!source.floating) {
                        if (offset.vertical != 0 and world.workspaceLayout(source.display, source.workspace).layout == .master) return failure("MasterHeightResizeUnsupported");
                        if (!placer.deriveGoals()) return failure(journal.lastError() orelse "LayoutProjectionFailed");
                        const width = if (offset.horizontal != 0) placer.resizeTiled(sourceIndex, .width, offset.horizontal) catch |err| return failure(@errorName(err)) else 0;
                        const height = if (offset.vertical != 0) placer.resizeTiled(sourceIndex, .height, offset.vertical) catch |err| return failure(@errorName(err)) else 0;
                        placer.reconcile();
                        native.platform_config_changed();
                        return json(.{ .ok = true, .applied = .{ .width = width, .height = height } });
                    }
                    const area = world.displayArea(source.display);
                    var frame = source.floating_frame;
                    frame.width = std.math.clamp(frame.width + offset.horizontal, 80, @max(80, area.left + area.width - frame.left));
                    frame.height = std.math.clamp(frame.height + offset.vertical, 80, @max(80, area.top + area.height - frame.top));
                    source.floating_frame = frame;
                },
                .center, .move_by => {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (!source.floating) return failure("WindowNotFloating");
                    const area = world.displayArea(source.display);
                    var frame = source.floating_frame;
                    switch (command) {
                        .center => {
                            frame.left = area.left + (area.width - frame.width) / 2;
                            frame.top = area.top + (area.height - frame.height) / 2;
                        },
                        .move_by => |offset| {
                            frame.left += offset.horizontal;
                            frame.top += offset.vertical;
                        },
                        else => unreachable,
                    }
                    source.floating_frame = world.boundedFloating(frame, area);
                },
                .fullscreen => {
                    const transaction = placer.Transaction.begin(.{ .display = source.display }) catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    const state = world.workspaceLayout(source.display, source.workspace);
                    if (source.floating) source.floating_restore = true else world.layouts().reveal(state, source.identity) catch |err| return failure(transaction.abort(err));
                    state.fullscreen = if (state.fullscreen == source.identity) null else source.identity;
                    if (!transaction.commit()) return failure(journal.lastError() orelse "FullscreenPlacementFailed");
                    return json(.{ .ok = true, .verified = focusVerified(source.identity) });
                },
                .close => |quit_if_last| return edits.close(source, quit_if_last),
                .toggle_floating => {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (source.floating) {
                        source.last_floating_frame = source.floating_frame;
                        source.floating = false;
                        source.bounds = .{};
                        source.placed = null;
                    } else {
                        // Like Hyprland: return to the last floating frame, or float at `floating_size`, centered.
                        const area = world.displayArea(source.display);
                        const width = area.width * world.config().floating_size.width;
                        const height = area.height * world.config().floating_size.height;
                        var frame = world.boundedFloating(source.last_floating_frame orelse .{
                            .left = area.left + (area.width - width) / 2,
                            .top = area.top + (area.height - height) / 2,
                            .width = width,
                            .height = height,
                        }, area);
                        // Shifts the frame down and right by the same distance until its top-left corner is clear of every other floating window
                        // on the workspace, so windows floated at the same frame all stay visible. At the area's edge the cascade restarts from the top left.
                        const step = 32;
                        var attempts: usize = 0;
                        while (attempts < world.windows().len) : (attempts += 1) {
                            const taken = for (world.windows()) |other| {
                                if (other.identity != source.identity and other.floating and !other.parked and other.display == source.display and other.workspace == source.workspace and other.visible() and @abs(other.floating_frame.left - frame.left) < step / 2 and @abs(other.floating_frame.top - frame.top) < step / 2) break true;
                            } else false;
                            if (!taken) break;
                            frame.left += step;
                            frame.top += step;
                            if (frame.left + frame.width > area.left + area.width or frame.top + frame.height > area.top + area.height) {
                                frame.left = area.left;
                                frame.top = area.top;
                            }
                        }
                        source.floating = true;
                        source.placed = null;
                        source.floating_frame = frame;
                    }
                },
                .send_to_workspace, .move_to_workspace => |selection| {
                    const resolved = resolvePlacements();
                    const workspace = resolveWorkspace(selection, if (world.config().workspace_monitors != null) displaySlot else world.displayIndex(source.display).?) catch |err| return failure(@errorName(err));
                    const destination = resolved[workspace] orelse source.display;
                    if (workspace == source.workspace and destination == source.display) return json(.{ .ok = true, .changed = false });
                    if (command == .send_to_workspace) {
                        if (!route(resolved, &.{}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return failure(journal.lastError() orelse "MonitorRoutingFailed");
                        if (!source.visible()) focused = null;
                        native.platform_config_changed();
                        return json(.{ .ok = true });
                    }
                    const destination_slot = world.displayIndex(destination).?;
                    const from = currentWorkspace(if (world.config().workspace_monitors != null) displaySlot else destination_slot);
                    const identity = source.identity;
                    generation += 1;
                    snapshot_presentation = .instant;
                    if (!route(resolved, &.{.{ .display = destination, .workspace = workspace }}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return failure(journal.lastError() orelse "MonitorRoutingFailed");
                    recordPrevious(destination_slot, from, workspace);
                    const verified = focusVerified(identity);
                    native.platform_config_changed();
                    return json(.{ .ok = true, .verified = verified, .target = identity });
                },
                .send_to_monitor, .move_to_monitor => |selection| {
                    // Sends a window to the target display's active workspace. Directions are relative to the window's
                    // display. With global routing, a display that has no workspace placed on it rejects the send
                    // instead of placing a workspace there.
                    const origin = source.display;
                    var screens: [monitor.capacity]monitor.Screen = undefined;
                    const target = monitor.resolve(selection, world.monitorScreens(&screens), origin) catch |err| return failure(@errorName(err));
                    const workspace = world.displays()[world.displayIndex(target).?].workspace;
                    if (target == origin) return json(.{ .ok = true, .changed = false, .monitor = target, .workspace = source.workspace + 1 });
                    const resolved = resolvePlacements();
                    if (world.config().workspace_monitors != null and resolved[workspace] != target) return failure("NoWorkspaceOnMonitor");
                    if (!route(resolved, &.{.{ .display = target, .workspace = workspace }}, .{ .index = sourceIndex, .display = target, .workspace = workspace })) return failure(journal.lastError() orelse "MonitorRoutingFailed");
                    native.platform_config_changed();
                    if (command == .move_to_monitor) return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = focusVerified(source.identity), .target = source.identity });
                    // The selection stays, so keyboard focus returns to the selected display's candidate.
                    const selected = world.selected() orelse origin;
                    focusWorkspace(selected, null);
                    return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = world.selected() == selected, .focused = focused });
                },
                .focus => |request| {
                    const target = if (request.wrap) wrapped: {
                        var forward_target: ?usize = null;
                        var forward_score = std.math.inf(f64);
                        var wrap_target = sourceIndex;
                        var wrap_distance: f64 = 0;
                        var wrap_cross = std.math.inf(f64);
                        for (world.windows(), 0..) |candidate, index| {
                            if (index == sourceIndex or !candidate.visible() or candidate.parked or candidate.display != source.display or candidate.workspace != source.workspace) continue;
                            const forward, const cross = offsets(source, &candidate, request.direction);
                            const score = forward + cross * 2;
                            if (forward > 1 and (score < forward_score or (score == forward_score and (forward_target == null or candidate.identity < world.windows()[forward_target.?].identity)))) {
                                forward_target = index;
                                forward_score = score;
                            }
                            if (forward < wrap_distance or (forward == wrap_distance and (cross < wrap_cross or (cross == wrap_cross and candidate.identity < world.windows()[wrap_target].identity)))) {
                                wrap_target = index;
                                wrap_distance = forward;
                                wrap_cross = cross;
                            }
                        }
                        break :wrapped forward_target orelse wrap_target;
                    } else neighbor(sourceIndex, request.direction) orelse return failure("NoWindowInDirection");
                    const identity = world.windows()[target].identity;
                    return json(.{ .ok = true, .accepted = true, .verified = focusVerified(identity), .target = identity });
                },
                .swap => |direction| return swapWindows(sourceIndex, neighbor(sourceIndex, direction) orelse return failure("NoWindowInDirection")),
                .swap_cycle => |step| {
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    var identities: [1024]u64 = undefined;
                    const target = selector.cycleTarget(readingOrder(source.display, .tiled, &identities), source.identity, step) orelse return failure("NoWindowToCycle");
                    if (target == source.identity) return json(.{ .ok = true, .changed = false });
                    return swapWindows(sourceIndex, world.windowIndex(target).?);
                },
                .move => |direction| {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (!source.floating and !native.platform_read_frame(source.identity, &source.floating_frame)) return failure("WindowGeometryUnavailable");
                    source.floating = true;
                    switch (direction) {
                        .left => source.floating_frame.left -= 40,
                        .right => source.floating_frame.left += 40,
                        .up => source.floating_frame.top -= 40,
                        .down => source.floating_frame.top += 40,
                    }
                },
                else => unreachable,
            }
        },
    }
    placer.reconcile();
    native.platform_config_changed();
    return json(.{ .ok = true });
}
export fn wm_shutdown() bool {
    checkpoint.freeze();
    world.markSuspended();
    edits.cancelClose(false);
    status_active = false;
    native.platform_status_present(null);
    reload.cancel();
    if (reload.inFlight()) return false;
    if (!pointer_controls.stop(native.platform_monotonic())) return false;
    if (pointer_controls.forced_stop) native.platform_error("Input release drain exceeded 250 ms; tap teardown forced");
    cancelTransition();
    const outstanding = native.platform_restore();
    recall.persist();
    checkpoint.save(outstanding == 0);
    if (outstanding == 0) recovery.settle() else {
        native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
        _ = journal.append("error", .{ .message = "Shutdown left unrestored windows", .outstanding = outstanding });
    }
    native.platform_border(0, 0, 0);
    return true;
}
