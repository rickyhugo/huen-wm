const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const rules = @import("rules.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const pointer = @import("pointer.zig");
const interaction = @import("interaction.zig");
const session = @import("session.zig");
const continuity = @import("continuity.zig");
const selector = @import("selector.zig");
const history = @import("history.zig");
const monitor = @import("monitor.zig");
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
const Window = struct { identity: u64, observation: native.WMWindow, workspace: usize, display: u32, discovered: f64 = 0, floating: bool = false, floating_restore: bool = false, parked: bool = false, parking_frame: Rect, floating_frame: Rect, last_floating_frame: ?Rect = null, goal: Rect, placement_error: ?[]const u8 = null };
const Display = struct { identity: u32, frame: Rect, full_bounds: Rect, name: [128]u8, built_in: bool, workspace: usize = 0, previous_workspace: ?usize = null };
const Config = configuration.ConfigCandidate;
var config: Config = .{};
var layouts: tiling.Store = .{};
var windows: std.ArrayList(Window) = .empty;
var displays: std.ArrayList(Display) = .empty;
var focused: ?u64 = null;
var focus_history: history.Ring = .{};
var active_mode: usize = 0;
const PendingClose = struct { identity: u64, pid: c_int, process_token: f64, deadline: f64 };
var pending_close: ?PendingClose = null;
var close_state: enum { idle, pending, closed, termination_requested, termination_rejected, expired, cancelled } = .idle;
var selected_display: ?u32 = null;
var last_observed_focus: ?u64 = null;
// `shown` caches whether the workspace was active on its display at the start of the tick, so a
// workspace on a display that just vanished keeps that fact until routing moves it. `shown_when_lost`
// keeps it while the workspace waits on a fallback display, so a reconnect shows it again.
const Placement = struct { display: ?u32 = null, home: [128]u8 = @splat(0), shown: bool = false, shown_when_lost: bool = false };
var placements: [10]Placement = @splat(.{});
var global_previous: ?usize = null;
// The most recently selected display that had a placed workspace. With global routing, an empty
// selected display resolves "current workspace" from this display.
var current_display: ?u32 = null;
var routing_blocked = false;
var reply_buffer: ?[:0]u8 = null;
var initialized = false;
var suspended = false;
const Transition = struct { display: u32, workspace: usize, from: usize, generation: u64, focus_target: ?u64 };
const SnapshotPresentation = enum { idle, pending, instant, captured, fallback };
var transition: ?Transition = null;
var generation: u64 = 0;
var snapshot_presentation: SnapshotPresentation = .idle;
var transition_error: ?[]const u8 = null;
var config_request: configuration.Request = .{};
var config_generation: u64 = 0;
var config_state: enum { idle, pending, ready, failed } = .idle;
var config_error: ?[]const u8 = null;
const StatusPresentation = union(enum) {
    disabled,
    visible: struct { display_identity: ?u32, content: native.WMStatusPresentation },
};
var published_status: StatusPresentation = .disabled;
var status_active = false;
var pointer_controls: pointer.Controls = .{};
var session_config_hash: [64]u8 = @splat(0);
var session_boot: [128]u8 = @splat(0);
var session_loaded = false;
var session_focus_pending = false;
var session_frozen: ?continuity.Frozen = null;
var session_freeze_attempted = false;
var session_save_attempted = false;
var session_status: struct {
    load: enum { disabled, pending, none, restored, rejected, failed } = .disabled,
    save: enum { idle, frozen, saved, skipped, failed } = .idle,
    matched: usize = 0,
    unmatched: usize = 0,
    ambiguous: usize = 0,
    unavailable: usize = 0,
    errors: usize = 0,
    err_message: ?[]const u8 = null,
} = .{};

fn sessionError(message: []const u8) void {
    session_status.err_message = message;
    session_status.errors += 1;
}
fn configureSession() void {
    if (!config.session.enabled) return;
    const encoded = std.json.Stringify.valueAlloc(allocator, config, .{}) catch |err| {
        sessionError(@errorName(err));
        return;
    };
    defer allocator.free(encoded);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    session_config_hash = std.fmt.bytesToHex(digest, .lower);
    if (!session.huen_session_boot_identity(&session_boot, session_boot.len)) sessionError("BootIdentityUnavailable");
    if (!session_loaded) session_status.load = .pending;
}
fn sessionScope() session.Scope {
    return .{ .config = &session_config_hash, .filter = std.mem.span(native.platform_filter()), .boot = text(&session_boot) };
}
fn sessionWindows() ![]continuity.LiveWindow {
    var result: std.ArrayList(continuity.LiveWindow) = .empty;
    errdefer result.deinit(allocator);
    session_status.unavailable = 0;
    for (windows.items) |window| {
        var attributes: session.NativeAttributes = undefined;
        if (externallyEligible(window) and native.platform_session_attributes(window.identity, &attributes)) if (attributes.key()) |_| {
            try result.append(allocator, .{ .identity = window.identity, .display = window.display, .workspace = window.workspace, .floating = window.floating, .frame = window.floating_frame, .attributes = attributes });
            continue;
        } else |_| {};
        session_status.unavailable += 1;
    }
    return result.toOwnedSlice(allocator);
}
fn sessionScreens(output: []continuity.Screen) []continuity.Screen {
    for (displays.items, 0..) |display, index| {
        output[index] = .{ .identity = display.identity, .workspace = display.workspace, .full_bounds = display.full_bounds, .hint = @splat(0) };
        _ = session.huen_session_display_uuid(display.identity, &output[index].hint, output[index].hint.len);
    }
    return output[0..displays.items.len];
}
fn freezeSession() void {
    if (session_freeze_attempted) return;
    session_freeze_attempted = true;
    if (!config.session.enabled) return;
    const current = sessionWindows() catch |err| {
        sessionError(@errorName(err));
        session_status.save = .failed;
        return;
    };
    defer allocator.free(current);
    var screens: [32]continuity.Screen = undefined;
    var homes: [10][128]u8 = undefined;
    for (&homes, placements) |*home, placement| home.* = placement.home;
    session_frozen = continuity.freeze(&layouts, current, sessionScreens(&screens), &config, homes[0..config.workspace_count], sessionScope()) catch |err| {
        sessionError(@errorName(err));
        session_status.save = .failed;
        return;
    };
    session_status.save = .frozen;
}
fn saveSession(clean: bool) void {
    if (session_save_attempted or !config.session.enabled) return;
    session_save_attempted = true;
    const checkpoint = if (session_frozen) |*frozen| frozen else return;
    defer {
        checkpoint.deinit();
        session_frozen = null;
    }
    if (!clean or checkpoint.snapshot.windows.len == 0) {
        session_status.save = .skipped;
        return;
    }
    session.save(allocator, checkpoint.snapshot, .clean) catch |err| {
        sessionError(@errorName(err));
        session_status.save = .failed;
        return;
    };
    session_status.save = .saved;
}
fn pointerWindows(output: []pointer.Window) []pointer.Window {
    for (windows.items, 0..) |window, index| output[index] = .{
        .identity = window.identity,
        .public_id = window.observation.public_window_id,
        .eligible = visible(window) and !window.floating and !window.parked and !managedFullscreen(window) and !displayBlocked(window.display) and window.observation.hit_eligible and window.observation.motion == .idle and framesNear(window.observation.frame, targetFrame(window), 2),
        .title = text(&windows.items[index].observation.title),
    };
    return output[0..windows.items.len];
}
fn publishPointer() void {
    if (!initialized or pointer_controls.stop_deadline != null) return;
    var observed: [1024]pointer.Window = undefined;
    var active: [32]*tiling.WorkspaceLayout = undefined;
    for (displays.items, 0..) |display, index| active[index] = workspaceLayout(display.identity, display.workspace);
    pointer_controls.publish(&layouts, pointerWindows(&observed), active[0..displays.items.len], !suspended and transition == null and !routing_blocked, config.border_color, config.border_width) catch |err| {
        pointer_controls.error_message = @errorName(err);
        interaction.huen_groups_clear();
    };
}
export fn wm_input_poll() void {
    if (!initialized) return;
    if (suspended or pointer_controls.stop_deadline != null) {
        var discarded: interaction.Event = undefined;
        var count: usize = 0;
        while (count < 64 and interaction.huen_input_poll(&discarded)) : (count += 1) {}
        return;
    }
    var sample: interaction.Event = undefined;
    var count: usize = 0;
    poll: while (count < 64 and interaction.huen_input_poll(&sample)) : (count += 1) {
        if (sample.kind == .start or sample.kind == .end or sample.kind == .group_select) {
            refreshObservations();
            if (!deriveGoals()) continue;
        }
        var observed: [1024]pointer.Window = undefined;
        const edit = pointer_controls.event(&layouts, pointerWindows(&observed), sample, config.gap, config.border_color, config.border_width) catch |err| {
            pointer_controls.error_message = @errorName(err);
            interaction.huen_groups_preview(null);
            continue;
        } orelse continue;
        const reference_value = switch (edit) {
            .group => |selection| selection.group,
            .drop => |preview| preview.source,
            .resize => |preview| preview.boundary.node,
        };
        var handle = layouts.resolve(reference_value) catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        while (layouts.nodes[handle].parent) |parent| handle = parent;
        const state = for (&layouts.roots) |*slot| {
            if (slot.*) |*layout| if (layout.root == handle) break layout;
        } else {
            pointer_controls.error_message = "StaleNode";
            continue :poll;
        };
        const transaction = PlacementTransaction.begin(.{ .display = state.display }) catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        defer transaction.deinit();
        const result: anyerror!?u64 = switch (edit) {
            .group => |selection| layouts.selectGroupChild(state, selection.group, selection.child),
            .drop => |preview| drop: {
                const representative = layouts.representative(preview.source) catch |err| break :drop err;
                layouts.commitDrop(state, preview) catch |err| break :drop err;
                break :drop representative;
            },
            .resize => |preview| if (layouts.commitResize(preview, config.gap)) null else |err| err,
        };
        const target = result catch |err| {
            transaction.rollback(0);
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        if (!transaction.commit()) continue;
        if (target) |identity| if (!focusVerified(identity)) {
            pointer_controls.error_message = "HeaderFocusRejected";
        };
        native.platform_config_changed();
    }
    if (pointer_controls.revision != layouts.revision) publishPointer();
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
fn publishStatus() void {
    if (!status_active) return;
    const next: StatusPresentation = if (!config.status_bar.enabled) .disabled else status: {
        var presentation = std.mem.zeroes(native.WMStatusPresentation);
        const display: ?Display = if (displays.items.len > 0) displays.items[activeDisplay()] else null;
        // With global routing, a display that has no workspace placed on it shows a dash.
        const placed: ?usize = if (display) |current| placedWorkspace(current) else null;
        const workspace_index = placed orelse 0;
        const name = if (placed != null) text(&config.workspaces[workspace_index].name) else "No workspace";
        var index_buffer: [8]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buffer, "{d}", .{workspace_index + 1}) catch unreachable;
        var label_buffer: [80]u8 = undefined;
        const label = if (suspended) "Paused" else if (display == null) "Huen WM" else if (placed == null) "—" else switch (config.status_bar.label) {
            .name => name,
            .index => index_text,
            .index_and_name => if (std.mem.eql(u8, name, index_text)) name else std.fmt.bufPrint(&label_buffer, "{s}  {s}", .{ index_text, name }) catch unreachable,
        };
        statusText(&presentation.title, if (active_mode != 0 and !suspended) text(&config.modes[active_mode].name) else label, 24);
        var tooltip_buffer: [512]u8 = undefined;
        const tooltip = std.fmt.bufPrint(&tooltip_buffer, "Huen WM · {s} · {s} · Mode {s}{s}", .{
            if (display) |current| text(&current.name) else "No display",
            name,
            text(&config.modes[active_mode].name),
            if (transition_error != null) " · Workspace switch failed" else "",
        }) catch unreachable;
        statusText(&presentation.tooltip, tooltip, 255);
        for (config.workspaces[0..config.workspace_count], 0..) |*workspace, index| {
            const row = &presentation.rows[index];
            var row_buffer: [80]u8 = undefined;
            var number_buffer: [8]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buffer, "{d}", .{index + 1}) catch unreachable;
            const workspace_name = text(&workspace.name);
            const title = if (std.mem.eql(u8, number, workspace_name)) workspace_name else std.fmt.bufPrint(&row_buffer, "{s}  {s}", .{ number, workspace_name }) catch unreachable;
            statusText(&row.title, title, 79);
            const command = std.fmt.bufPrint(&row.command, "workspace {d}", .{index + 1}) catch unreachable;
            row.command[command.len] = 0;
            row.checked = placed == index;
            row.enabled = display != null and !suspended and transition == null;
        }
        const reload = &presentation.rows[config.workspace_count];
        statusText(&reload.title, "Reload configuration", 79);
        statusText(&reload.command, "reload", 127);
        reload.enabled = !suspended and transition == null and !config_request.inFlight();
        const quit = &presentation.rows[config.workspace_count + 1];
        statusText(&quit.title, "Quit", 79);
        statusText(&quit.command, "quit", 127);
        quit.enabled = true;
        presentation.row_count = config.workspace_count + 2;
        break :status .{ .visible = .{ .display_identity = if (display) |current| current.identity else null, .content = presentation } };
    };
    const unchanged = switch (next) {
        .disabled => published_status == .disabled,
        .visible => |visible_status| switch (published_status) {
            .disabled => false,
            .visible => |previous| std.meta.eql(visible_status, previous),
        },
    };
    if (unchanged) return;
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
fn text(buffer: anytype) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}
fn json(value: anytype) [*:0]const u8 {
    if (reply_buffer) |previous| allocator.free(previous);
    reply_buffer = null;
    const encoded = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return "{\"error\":\"out of memory\"}\n";
    defer allocator.free(encoded);
    reply_buffer = std.fmt.allocPrintSentinel(allocator, "{s}\n", .{encoded}, 0) catch return "{\"error\":\"out of memory\"}\n";
    return reply_buffer.?.ptr;
}
fn failure(message: []const u8) [*:0]const u8 {
    return json(.{ .err_message = message, .@"error" = true });
}
export fn wm_initialize(path: [*:0]const u8) bool {
    const candidate = configuration.load(path) catch |err| {
        native.platform_error(@errorName(err));
        return false;
    };
    applyLayoutDefaults(&candidate);
    config = candidate;
    config_state = .ready;
    initialized = true;
    configureSession();
    return true;
}
export fn wm_activate_config() bool {
    if (!native.platform_bindings(&config.modes[0].bindings, config.modes[0].binding_count)) return false;
    active_mode = 0;
    status_active = true;
    pointer_controls.configure(config.mouse.enabled, config.mouse.modifiers);
    publishStatus();
    return true;
}
fn rejectConfig(message: [:0]const u8) void {
    config_state = .failed;
    config_error = message;
    native.platform_error(message.ptr);
}
export fn wm_config_poll() void {
    // Cancelled requests must still drain while shutdown waits for the worker.
    if (transition != null and config_state == .pending) return;
    const completion = config_request.take() orelse return;
    if (completion.generation != config_generation or config_state != .pending) return;
    const candidate = switch (completion.result) {
        .ready => |candidate| candidate,
        .failed => |err| return rejectConfig(@errorName(err)),
    };
    if (suspended) return rejectConfig("RuntimeSuspendedRestartToResume");
    if (!native.platform_bindings(&candidate.modes[0].bindings, candidate.modes[0].binding_count)) return rejectConfig("HotkeyCollision");
    applyLayoutDefaults(&candidate);
    config = candidate;
    pointer_controls.configure(config.mouse.enabled, config.mouse.modifiers);
    configureSession();
    active_mode = 0;
    config_state = .ready;
    config_error = null;
    if (displays.items.len > 0) routing_blocked = !routeMembership();
    native.platform_config_changed();
    reconcile();
    publishStatus();
}
fn cancelConfig() void {
    if (config_state != .pending) return;
    config_request.cancel();
    config_state = .failed;
    config_error = "ConfigLoadCancelled";
}
fn applyLayoutDefaults(candidate: *const Config) void {
    var remap: [10]?usize = @splat(null);
    var claimed: [10]bool = @splat(false);
    for (config.workspaces[0..config.workspace_count], 0..) |*previous, old_index| for (candidate.workspaces[0..candidate.workspace_count], 0..) |*next, new_index| {
        if (!claimed[new_index] and std.mem.eql(u8, text(&previous.name), text(&next.name))) {
            remap[old_index] = new_index;
            claimed[new_index] = true;
            break;
        }
    };
    for (&layouts.roots) |*slot| if (slot.*) |*state| {
        const index = state.workspace;
        const next_index = remap[index] orelse {
            layouts.discard(state);
            slot.* = null;
            continue;
        };
        const previous = config.workspaces[index];
        const next = candidate.workspaces[next_index];
        state.workspace = next_index;
        if (previous.layout != next.layout or previous.ratio != next.ratio) {
            layouts.discard(state);
            state.layout = next.layout;
            state.ratio = next.ratio;
        }
    };
    for (windows.items) |*window| window.workspace = remap[window.workspace] orelse @min(window.workspace, candidate.workspace_count - 1);
    for (displays.items) |*display| {
        display.workspace = remap[display.workspace] orelse @min(display.workspace, candidate.workspace_count - 1);
        display.previous_workspace = remapPrevious(display.previous_workspace, display.workspace, &remap);
    }
    var remapped: [10]Placement = @splat(.{});
    for (remapped[0..candidate.workspace_count]) |*placement| placement.display = workspaceOwner();
    for (placements[0..config.workspace_count], remap[0..config.workspace_count]) |placement, next_index| if (next_index) |index| {
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
    return if (config.workspace_monitors != null) &global_previous else &displays.items[display_slot].previous_workspace;
}
fn recordPrevious(display_slot: usize, from: usize, workspace: usize) void {
    if (from != workspace) previousWorkspace(display_slot).* = from;
}
// With global routing, an empty display uses the active workspace of the most recently selected
// display that had one, else the lowest shown workspace.
fn currentWorkspace(display_slot: usize) usize {
    const display = displays.items[display_slot];
    if (placedWorkspace(display)) |workspace| return workspace;
    if (current_display) |identity| if (displayIndex(identity)) |index| if (placedWorkspace(displays.items[index])) |workspace| return workspace;
    for (0..config.workspace_count) |workspace| if (shownWorkspace(workspace)) return workspace;
    return @min(display.workspace, config.workspace_count - 1);
}
fn trackCurrentDisplay() void {
    const identity = selected_display orelse return;
    const index = displayIndex(identity) orelse return;
    if (placedWorkspace(displays.items[index]) != null) current_display = identity;
}
fn resolveWorkspace(selection: commands.WorkspaceSelector, display_slot: usize) !usize {
    var occupied: selector.Occupancy = .empty;
    const display = displays.items[display_slot];
    for (windows.items) |window| if (externallyEligible(window) and (config.workspace_monitors != null or window.display == display.identity)) occupied.set(window.workspace);
    // `workspace N` from an empty display does not flip to the previous workspace, except in owner
    // mode, where the owner's workspace is the current one for every display.
    const back_and_forth = config.workspace_back_and_forth and (placedWorkspace(display) != null or workspaceOwner() != null);
    return selector.resolve(selection, .{ .config = &config, .current = currentWorkspace(display_slot), .previous = previousWorkspace(display_slot).*, .occupied = occupied, .back_and_forth = back_and_forth });
}
fn selectionSlot(window_index: usize, display_slot: usize) usize {
    if (config.workspace_monitors != null) return display_slot;
    return displayIndex(windows.items[window_index].display).?;
}
fn workspaceLayout(display: u32, workspace: usize) *tiling.WorkspaceLayout {
    const defaults = config.workspaces[workspace];
    return layouts.workspace(display, workspace, defaults.layout, defaults.ratio);
}
fn managedFullscreen(window: Window) bool {
    const state = layouts.lookup(window.display, window.workspace) orelse return false;
    return state.fullscreen == window.identity;
}
fn targetFrame(window: Window) Rect {
    if (managedFullscreen(window)) {
        if (displayIndex(window.display)) |index| return displays.items[index].frame;
    }
    return if (window.floating) window.floating_frame else window.goal;
}
fn resizeTiled(source_index: usize, axis: commands.Axis, delta: f64) !f64 {
    const source = windows.items[source_index];
    const state = workspaceLayout(source.display, source.workspace);
    if (state.layout == .dwindle) return layouts.resizePoints(source.identity, axis, delta, config.gap);
    if (axis != .width) return error.MasterHeightResizeUnsupported;
    var master: ?u64 = null;
    var count: usize = 0;
    for (windows.items) |window| {
        if (window.display != source.display or window.workspace != source.workspace or !visible(window) or window.floating) continue;
        if (master == null) master = window.identity;
        count += 1;
    }
    if (count < 2) return 0;
    const area = inset(displays.items[displayIndex(source.display).?].frame, config.gap);
    const available = area.width - @min(config.gap, @max(0, area.width - 2));
    if (available < 160) return 0;
    const sign: f64 = if (master == source.identity) 1 else -1;
    const previous = available * state.ratio;
    const next = std.math.clamp(previous + sign * delta, 80, available - 80);
    state.ratio = next / available;
    return (next - previous) * sign;
}
fn displayIndex(identity: u32) ?usize {
    for (displays.items, 0..) |display, index| if (display.identity == identity) return index;
    return null;
}
fn windowIndex(identity: u64) ?usize {
    for (windows.items, 0..) |window, index| if (window.identity == identity) return index;
    return null;
}
fn activeDisplay() usize {
    if (selected_display) |identity| if (displayIndex(identity)) |index| return index;
    return 0;
}
fn selectDisplay(identity: u32) void {
    if (selected_display == identity) return;
    selected_display = identity;
    trackCurrentDisplay();
    if (!config.mouse_follows_monitor) return;
    const index = displayIndex(identity) orelse return;
    const bounds = displays.items[index].full_bounds;
    var point: native.WMPoint = undefined;
    if (!native.platform_pointer(&point)) return;
    if (point.left >= bounds.left and point.left < bounds.left + bounds.width and point.top >= bounds.top and point.top < bounds.top + bounds.height) return;
    if (!native.platform_warp_pointer(.{ .left = bounds.left + bounds.width / 2, .top = bounds.top + bounds.height / 2 })) native.platform_error("Mouse warp failed");
}
fn monitorScreens(output: []monitor.Screen) []monitor.Screen {
    const count = @min(output.len, displays.items.len);
    for (displays.items[0..count], output[0..count]) |*display, *screen| screen.* = .{ .identity = display.identity, .full_bounds = display.full_bounds, .built_in = display.built_in, .name = text(&display.name) };
    return output[0..count];
}
fn workspaceOwner() ?u32 {
    const first = placements[0].display orelse return null;
    for (placements[1..config.workspace_count]) |placement| if (placement.display != first) return null;
    return first;
}
// The display's active workspace, or null when global routing places no workspace on it.
fn placedWorkspace(display: Display) ?usize {
    if (config.workspace_monitors == null or placements[display.workspace].display == display.identity) return display.workspace;
    return null;
}
fn shownWorkspace(workspace: usize) bool {
    const identity = placements[workspace].display orelse return false;
    if (displayIndex(identity)) |index| return displays.items[index].workspace == workspace;
    return placements[workspace].shown;
}
fn resolvePlacements() [10]?u32 {
    var resolved: [10]?u32 = @splat(null);
    const preferences = config.workspace_monitors orelse return resolved;
    var fallback: [2]commands.MonitorSelector = undefined;
    for (preferences.order[0..preferences.count], fallback[0..preferences.count]) |preference, *selection| selection.* = .{ .class = switch (preference) {
        .external => .external,
        .@"built-in" => .@"built-in",
    } };
    var screens: [monitor.capacity]monitor.Screen = undefined;
    const available = monitorScreens(&screens);
    for (config.workspaces[0..config.workspace_count], placements[0..config.workspace_count], resolved[0..config.workspace_count]) |*workspace, *placement, *destination| {
        const home = text(&placement.home);
        const home_display: ?u32 = if (home.len == 0) null else for (displays.items) |display| {
            var uuid: [64]u8 = @splat(0);
            if (session.huen_session_display_uuid(display.identity, &uuid, uuid.len) and std.mem.eql(u8, text(&uuid), home)) break display.identity;
        } else null;
        destination.* = monitor.place(available, .{ .home = home_display, .monitors = workspace.monitor.slice(), .fallback = fallback[0..preferences.count], .current = placement.display });
    }
    return resolved;
}
fn commitPlacements(resolved: [10]?u32) void {
    for (&placements, resolved) |*placement, destination| {
        if (destination != placement.display) {
            const lost = if (placement.display) |identity| displayIndex(identity) == null else false;
            placement.shown_when_lost = lost and (placement.shown or placement.shown_when_lost);
        }
        placement.display = destination;
    }
}
const Routing = struct {
    const Activation = struct { display: u32, workspace: usize };
    destinations: [10]?u32 = @splat(null),
    activate: []const Activation = &.{},
    send: ?struct { index: usize, display: u32, workspace: usize } = null,
};
fn placementActivations(resolved: [10]?u32, forced: []const Routing.Activation, output: *[11]Routing.Activation) []Routing.Activation {
    const workspace_count = config.workspace_count;
    @memcpy(output[0..forced.len], forced);
    var count = forced.len;
    scan: for (displays.items) |display| {
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
        output[count] = .{ .display = identity, .workspace = choice };
        count += 1;
    }
    return output[0..count];
}
const PlacementTransaction = struct {
    const Scope = union(enum) {
        all,
        display: u32,
        pair: [2]u32,

        fn contains(self: Scope, display: u32) bool {
            return switch (self) {
                .all => true,
                .display => |identity| identity == display,
                .pair => |identities| identities[0] == display or identities[1] == display,
            };
        }
    };

    store: *tiling.Store,
    intent: []Window,
    screens: []Display,
    originals: []?Rect,
    selected: ?u32,

    fn begin(scope: Scope) !PlacementTransaction {
        const store = try allocator.create(tiling.Store);
        errdefer allocator.destroy(store);
        store.* = layouts;
        const intent = try allocator.dupe(Window, windows.items);
        errdefer allocator.free(intent);
        const screens = try allocator.dupe(Display, displays.items);
        errdefer allocator.free(screens);
        const originals = try allocator.alloc(?Rect, windows.items.len);
        errdefer allocator.free(originals);
        for (windows.items, 0..) |window, index| {
            originals[index] = null;
            if (!scope.contains(window.display)) continue;
            if (displayBlocked(window.display)) return error.NativeFullscreenBlocksPlacement;
            if (window.observation.stale and (window.observation.onscreen or window.parked)) return error.StaleWindowBlocksPlacement;
            if (!externallyEligible(window)) continue;
            var frame: Rect = undefined;
            if (!native.platform_read_frame(window.identity, &frame)) return error.PlacementSnapshotUnreadable;
            originals[index] = frame;
        }
        return .{ .store = store, .intent = intent, .screens = screens, .originals = originals, .selected = selected_display };
    }

    fn deinit(self: PlacementTransaction) void {
        allocator.destroy(self.store);
        allocator.free(self.intent);
        allocator.free(self.screens);
        allocator.free(self.originals);
    }

    fn rollback(self: PlacementTransaction, attempted: usize) void {
        var remaining = attempted;
        while (remaining > 0) {
            remaining -= 1;
            const identity = windows.items[remaining].identity;
            const original_index = self.identityIndex(identity);
            const original = self.originals[original_index] orelse continue;
            if (verifiedFrame(identity, original, null)) continue;
            const intent = &self.intent[original_index];
            if (!intent.parked) intent.parking_frame = original;
            intent.parked = true;
            intent.placement_error = "Placement rollback rejected; recovery ownership retained";
        }
        layouts = self.store.*;
        @memcpy(windows.items, self.intent);
        @memcpy(displays.items, self.screens);
        selected_display = self.selected;
    }

    fn identityIndex(self: PlacementTransaction, identity: u64) usize {
        for (self.intent, 0..) |window, index| if (window.identity == identity) return index;
        unreachable;
    }

    fn commit(self: PlacementTransaction) bool {
        if (!deriveGoals()) {
            self.rollback(0);
            return false;
        }
        for (windows.items, 0..) |*window, index| {
            if (self.originals[self.identityIndex(window.identity)] == null) continue;
            const outcome = if (visible(window.*)) placeVisibility(window, targetFrame(window.*), false) else parkWindow(window);
            if (outcome == .applied) continue;
            // An application that rejects its tile size must not block every other window. Float it, as reconcile does,
            // and derive goals again so later windows do not receive tiles sized around the rejected one.
            if (outcome == .rolled_back and visible(window.*) and !window.floating) {
                floatRejectedTile(window);
                if (window.floating and deriveGoals() and placeVisibility(window, targetFrame(window.*), false) == .applied) continue;
            }
            self.rollback(index + 1);
            transition_error = "Placement rejected; reverse rollback attempted; inspect window recovery errors";
            return false;
        }
        transition_error = null;
        return true;
    }
};
fn commitRouting(request: Routing) bool {
    const transaction = PlacementTransaction.begin(.all) catch |err| {
        transition_error = @errorName(err);
        return false;
    };
    defer transaction.deinit();
    const staged = allocator.alloc(u32, windows.items.len) catch return false;
    defer allocator.free(staged);
    for (request.activate) |activation| if (displayBlocked(activation.display)) {
        transition_error = "Native fullscreen window blocks routing destination";
        return false;
    };
    for (windows.items, 0..) |window, index| {
        const destination = if (request.send != null and request.send.?.index == index) request.send.?.display else request.destinations[window.workspace] orelse if (displayIndex(window.display) == null) displays.items[0].identity else window.display;
        staged[index] = destination;
        if (window.observation.minimized or window.observation.fullscreen or (!window.observation.onscreen and !window.parked)) {
            if (destination != window.display or (window.observation.fullscreen and request.send != null and request.send.?.index == index)) {
                transition_error = "Routing deferred for unavailable or native fullscreen window";
                return false;
            }
            continue;
        }
        if (window.observation.stale or displayBlocked(destination) or displayBlocked(window.display)) {
            transition_error = "Routing blocked by stale or native fullscreen window";
            return false;
        }
        var original: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &original)) {
            transition_error = "Routing geometry could not be read";
            return false;
        }
    }
    for (&layouts.roots) |*slot| if (slot.*) |*state| {
        const destination = request.destinations[state.workspace] orelse if (displayIndex(state.display) == null) displays.items[0].identity else state.display;
        if (destination == state.display) continue;
        if (layouts.lookup(destination, state.workspace)) |existing| {
            const defaults = config.workspaces[state.workspace];
            const empty_default = existing.root == null and existing.fullscreen == null and existing.layout == defaults.layout and existing.ratio == defaults.ratio;
            if (empty_default) {
                existing.* = state.*;
                existing.display = destination;
            } else layouts.discard(state);
            slot.* = null;
        } else state.display = destination;
    };
    for (request.activate) |activation| displays.items[displayIndex(activation.display).?].workspace = activation.workspace;
    for (windows.items, 0..) |*window, index| {
        const destination = staged[index];
        if (request.send) |send| if (send.index == index) {
            window.workspace = send.workspace;
        };
        if (destination != window.display) {
            const area = inset(displays.items[displayIndex(destination).?].frame, config.gap);
            // Keeps a floating window's center at the same proportional position in the destination area.
            var relocated = window.floating_frame;
            if (displayIndex(window.display)) |slot| {
                const previous = inset(displays.items[slot].frame, config.gap);
                relocated.left = area.left + (relocated.left + relocated.width / 2 - previous.left) / previous.width * area.width - relocated.width / 2;
                relocated.top = area.top + (relocated.top + relocated.height / 2 - previous.top) / previous.height * area.height - relocated.height / 2;
            }
            window.floating_frame = boundedFloating(relocated, area);
            window.parking_frame = boundedFloating(window.parking_frame, area);
            window.display = destination;
        }
    }
    if (request.send) |send| layouts.forgetIdentity(windows.items[send.index].identity);
    return transaction.commit();
}
fn routeMembership() bool {
    const resolved = resolvePlacements();
    var needed = false;
    for (resolved[0..config.workspace_count], placements[0..config.workspace_count]) |destination, placement| if (destination != placement.display) {
        needed = true;
    };
    for (windows.items) |window| {
        const destination = resolved[window.workspace];
        if (displayIndex(window.display) == null or (destination != null and window.display != destination.?)) needed = true;
    }
    for (layouts.roots) |slot| if (slot) |state| {
        const defaults = config.workspaces[state.workspace];
        const has_state = state.root != null or state.fullscreen != null or state.layout != defaults.layout or state.ratio != defaults.ratio;
        const destination = resolved[state.workspace];
        if (has_state and (displayIndex(state.display) == null or (destination != null and state.display != destination.?))) needed = true;
    };
    if (!needed) return true;
    var activations: [11]Routing.Activation = undefined;
    if (!commitRouting(.{ .destinations = resolved, .activate = placementActivations(resolved, &.{}, &activations) })) return false;
    commitPlacements(resolved);
    return true;
}
fn visible(window: Window) bool {
    if (!externallyEligible(window)) return false;
    if (!window.floating and layouts.visibility(window.identity) == .hidden_by_group) return false;
    const index = displayIndex(window.display) orelse return false;
    return window.workspace == displays.items[index].workspace;
}
fn externallyEligible(window: Window) bool {
    return !window.observation.minimized and !window.observation.fullscreen and !window.observation.stale and (window.observation.onscreen or window.parked);
}
fn layoutMembers(output: []tiling.Member) []tiling.Member {
    var count: usize = 0;
    for (windows.items) |window| {
        const display = displays.items[displayIndex(window.display) orelse continue];
        output[count] = .{ .identity = window.identity, .display = window.display, .workspace = window.workspace, .tiled = !window.floating, .active = externallyEligible(window), .area = inset(display.frame, config.gap) };
        count += 1;
    }
    return output[0..count];
}
fn rememberFocus(identity: u64) void {
    const index = windowIndex(identity) orelse return;
    const window = windows.items[index];
    focus_history.push(identity);
    var members: [1024]tiling.Member = undefined;
    layouts.rememberFocus(workspaceLayout(window.display, window.workspace), identity, layoutMembers(&members)) catch |err| {
        transition_error = @errorName(err);
    };
}
fn focusVerified(identity: u64) bool {
    if (!native.platform_focus(identity) or native.platform_focused_window() != identity) return false;
    focused = identity;
    last_observed_focus = identity;
    rememberFocus(identity);
    if (windowIndex(identity)) |index| selectDisplay(windows.items[index].display);
    return true;
}
fn displayBlocked(identity: u32) bool {
    for (windows.items) |window| if (window.display == identity and window.observation.fullscreen) return true;
    return false;
}
fn inset(frame: Rect, gap: f64) Rect {
    const padding = @min(gap, @max(0, (@min(frame.width, frame.height) - 1) / 2));
    return .{ .left = frame.left + padding, .top = frame.top + padding, .width = frame.width - 2 * padding, .height = frame.height - 2 * padding };
}
fn boundedFloating(frame: Rect, area: Rect) Rect {
    var bounded = frame;
    bounded.width = @min(frame.width, area.width);
    bounded.height = @min(frame.height, area.height);
    bounded.left = std.math.clamp(frame.left, area.left, area.left + area.width - bounded.width);
    bounded.top = std.math.clamp(frame.top, area.top, area.top + area.height - bounded.height);
    return bounded;
}
fn floatRejectedTile(window: *Window) void {
    if (managedFullscreen(window.*)) {
        workspaceLayout(window.display, window.workspace).fullscreen = null;
        placementFailure(window, "Application rejected managed fullscreen; underlying layout retained");
        return;
    }
    if (window.floating) return;
    window.floating = true;
    window.floating_frame = boundedFloating(window.parking_frame, inset(displays.items[displayIndex(window.display).?].frame, config.gap));
    placementFailure(window, "Application rejected tile; retrying with floating recovery geometry");
}
fn deriveGoals() bool {
    for (&layouts.roots) |*slot| if (slot.*) |*state| {
        if (displayIndex(state.display) == null) {
            layouts.discard(state);
            slot.* = null;
        }
    };
    for (displays.items) |display| for (0..config.workspace_count) |workspace| {
        _ = workspaceLayout(display.identity, workspace);
    };
    var members: [1024]tiling.Member = undefined;
    layouts.sync(layoutMembers(&members), focused, config.gap) catch |err| {
        transition_error = @errorName(err);
        return false;
    };
    for (&layouts.roots) |*slot| if (slot.*) |*state| {
        const display = displays.items[displayIndex(state.display) orelse continue];
        layouts.arrange(state, inset(display.frame, config.gap), config.gap);
    };
    for (displays.items) |display| {
        if (displayBlocked(display.identity)) continue;
        var indices: [1024]usize = undefined;
        var count: usize = 0;
        for (windows.items, 0..) |window, index| if (window.display == display.identity and visible(window) and !window.floating) {
            indices[count] = index;
            count += 1;
        };
        if (count == 0) continue;
        const workspace = workspaceLayout(display.identity, display.workspace);
        const area = inset(display.frame, config.gap);
        if (count == 1) {
            windows.items[indices[0]].goal = area;
            continue;
        }
        if (workspace.layout == .master) {
            const columns = tiling.split(area, .width, workspace.ratio, config.gap);
            windows.items[indices[0]].goal = columns[0];
            const rows: f64 = @floatFromInt(count - 1);
            const spacing = @min(config.gap, columns[1].height / (2 * rows));
            const height = (columns[1].height - spacing * (rows - 1)) / rows;
            for (indices[1..count], 0..) |index, row| {
                var frame = columns[1];
                frame.top += @as(f64, @floatFromInt(row)) * (height + spacing);
                frame.height = height;
                windows.items[index].goal = frame;
            }
        } else for (indices[0..count]) |index| {
            if (layouts.goal(windows.items[index].identity)) |frame| windows.items[index].goal = frame;
        }
    }
    return true;
}
fn framesNear(first: Rect, second: Rect, tolerance: f64) bool {
    return @abs(first.left - second.left) <= tolerance and @abs(first.top - second.top) <= tolerance and @abs(first.width - second.width) <= tolerance and @abs(first.height - second.height) <= tolerance;
}
fn placementFailure(window: *Window, message: []const u8) void {
    const repeated = if (window.placement_error) |previous| std.mem.eql(u8, previous, message) else false;
    window.placement_error = message;
    transition_error = message;
    if (repeated) return;
    var buffer: [256:0]u8 = @splat(0);
    const formatted = std.fmt.bufPrint(&buffer, "Window {d}: {s}", .{ window.identity, message }) catch return;
    buffer[formatted.len] = 0;
    native.platform_error(&buffer);
}
fn overlapsOtherDisplays(frame: Rect, displayIdentity: u32) bool {
    for (displays.items) |display| {
        if (display.identity == displayIdentity) continue;
        const area = display.full_bounds;
        if (@min(frame.left + frame.width, area.left + area.width) > @max(frame.left, area.left) and
            @min(frame.top + frame.height, area.top + area.height) > @max(frame.top, area.top)) return true;
    }
    return false;
}
fn parkedFrameAccepted(actual: Rect, target: Rect, displayIdentity: u32) bool {
    const area = displays.items[displayIndex(displayIdentity).?].frame;
    const bottom = area.top + area.height;
    const horizontalContact = @min(actual.left + actual.width, area.left + area.width) - @max(actual.left, area.left);
    return @abs(actual.width - target.width) <= 2 and @abs(actual.height - target.height) <= 2 and
        @abs(actual.left - target.left) <= 2 and @abs(actual.left + actual.width - target.left - target.width) <= 2 and
        horizontalContact > 0 and horizontalContact <= 3 and
        actual.top >= area.top and actual.top <= bottom and actual.top + actual.height >= bottom and
        !overlapsOtherDisplays(actual, displayIdentity);
}
fn verifiedFrame(identity: u64, target: Rect, parkedDisplay: ?u32) bool {
    _ = native.platform_frame(identity, target, 0, .verified_placement);
    var actual: Rect = undefined;
    if (!native.platform_read_frame(identity, &actual)) return false;
    return if (parkedDisplay) |displayIdentity| parkedFrameAccepted(actual, target, displayIdentity) else framesNear(actual, target, 2);
}
const PlacementOutcome = enum { applied, rolled_back, recovery_required, unreadable, no_corner };

fn attemptVisibility(window: *Window, target: Rect, parked: bool) PlacementOutcome {
    var original: Rect = undefined;
    if (!native.platform_read_frame(window.identity, &original)) return .unreadable;
    const previouslyParked = window.parked;
    if (!previouslyParked) window.parking_frame = original;
    // A failed AX write can still move the window. Own it before the first write.
    window.parked = true;
    if (verifiedFrame(window.identity, target, if (parked) window.display else null)) {
        window.parked = parked;
        window.placement_error = null;
        return .applied;
    }
    if (verifiedFrame(window.identity, original, null)) {
        window.parked = previouslyParked;
        return .rolled_back;
    }
    return .recovery_required;
}
fn reportPlacementOutcome(window: *Window, outcome: PlacementOutcome) void {
    switch (outcome) {
        .applied => {},
        .rolled_back => placementFailure(window, "Placement rejected; prior geometry verified"),
        .recovery_required => placementFailure(window, "Placement and rollback rejected; recovery ownership retained"),
        .unreadable => placementFailure(window, "Placement geometry unreadable"),
        .no_corner => placementFailure(window, "No parking corner avoids other displays"),
    }
}
fn placeVisibility(window: *Window, target: Rect, parked: bool) PlacementOutcome {
    const outcome = attemptVisibility(window, target, parked);
    reportPlacementOutcome(window, outcome);
    return outcome;
}
fn parkWindow(window: *Window) PlacementOutcome {
    var actual: Rect = undefined;
    if (!native.platform_read_frame(window.identity, &actual)) {
        reportPlacementOutcome(window, .unreadable);
        return .unreadable;
    }
    const slot = displayIndex(window.display) orelse {
        reportPlacementOutcome(window, .no_corner);
        return .no_corner;
    };
    const area = displays.items[slot].frame;
    var right = if (window.parked) window.parking_frame else actual;
    right.top = area.top + area.height - 1;
    right.left = area.left + area.width - 1;
    var left = right;
    left.left = area.left + 1 - right.width;
    const candidates = [2]Rect{ right, left };
    if (window.parked) for (candidates) |candidate| if (parkedFrameAccepted(actual, candidate, window.display)) {
        window.placement_error = null;
        return .applied;
    };
    var outcome: PlacementOutcome = .no_corner;
    for (candidates) |candidate| {
        if (overlapsOtherDisplays(candidate, window.display)) continue;
        outcome = attemptVisibility(window, candidate, true);
        if (outcome != .rolled_back) break;
    }
    reportPlacementOutcome(window, outcome);
    return outcome;
}
fn reconcile() void {
    if (suspended or transition != null or displays.items.len == 0 or routing_blocked) return;
    if (!deriveGoals()) return;
    for (windows.items) |*window| {
        if (visible(window.*) and !window.floating and !managedFullscreen(window.*) and (window.goal.width < tiling.minimum_tile_extent or window.goal.height < tiling.minimum_tile_extent)) {
            window.floating = true;
            window.floating_frame = if (window.parked) window.parking_frame else window.observation.frame;
            window.goal = window.floating_frame;
            placementFailure(window, "Tile too crowded; window left floating");
        }
    }
    for (windows.items) |*window| {
        if (window.observation.minimized or window.observation.fullscreen or window.observation.stale or displayBlocked(window.display) or (!window.observation.onscreen and !window.parked)) continue;
        if (!visible(window.*)) {
            _ = parkWindow(window);
            continue;
        }
        const target = targetFrame(window.*);
        if (window.parked) {
            const outcome = placeVisibility(window, target, false);
            if (outcome == .rolled_back or outcome == .recovery_required) floatRejectedTile(window);
            continue;
        }
        const duration = if (window.floating_restore and !managedFullscreen(window.*)) 0 else config.duration;
        var accepted: Rect = window.observation.frame;
        if (native.platform_frame(window.identity, target, duration, .visible_goal) and (duration != 0 or (native.platform_read_frame(window.identity, &accepted) and framesNear(accepted, target, 2)))) continue;
        if (managedFullscreen(window.*)) {
            floatRejectedTile(window);
            continue;
        }
        // A launching application can refuse or override its first placements. Retry a new window before floating it.
        if (native.platform_monotonic() - window.discovered < 1.0) continue;
        window.floating = true;
        window.floating_restore = false;
        if (!native.platform_read_frame(window.identity, &accepted)) accepted = window.observation.frame;
        window.floating_frame = accepted;
        placementFailure(window, "Application rejected layout geometry; window left floating");
    }
    var borderIdentity: u64 = 0;
    if (focused) |identity| if (windowIndex(identity)) |index| {
        const window = windows.items[index];
        if (visible(window) and !window.parked and (config.border_single_window or for (windows.items) |other| {
            if (other.identity != window.identity and other.display == window.display and other.workspace == window.workspace and visible(other)) break true;
        } else false)) borderIdentity = identity;
    };
    native.platform_border(borderIdentity, config.border_width, config.border_color);
}
export fn wm_tick() void {
    if (pending_close) |pending| close: {
        const observed = if (native.platform_monotonic() < pending.deadline) native.platform_close_state(pending.identity, pending.pid, pending.process_token) else -1;
        close_state = if (native.platform_monotonic() >= pending.deadline) .expired else if (observed == 2) (if (native.platform_terminate_if_empty(pending.identity, pending.pid, pending.process_token)) .termination_requested else .termination_rejected) else if (observed == 1) .closed else break :close;
        pending_close = null;
        native.platform_close_cancel();
    }
    if (!initialized) return;
    defer publishStatus();
    defer publishPointer();
    var observedDisplays: [32]native.WMDisplay = undefined;
    const displayCount = native.platform_displays(&observedDisplays, observedDisplays.len);
    var updated: std.ArrayList(Display) = .empty;
    var topology_changed = displayCount != displays.items.len;
    for (&placements, 0..) |*placement, workspace| if (placement.display) |identity| if (displayIndex(identity)) |index| {
        placement.shown = displays.items[index].workspace == workspace;
    };
    for (observedDisplays[0..displayCount]) |observation| {
        const previous: ?Display = if (displayIndex(observation.identity)) |index| displays.items[index] else null;
        if (previous == null or !std.meta.eql(previous.?.full_bounds, observation.full_bounds) or !std.meta.eql(previous.?.frame, observation.frame) or previous.?.built_in != observation.built_in) topology_changed = true;
        updated.append(allocator, .{ .identity = observation.identity, .frame = observation.frame, .full_bounds = observation.full_bounds, .name = observation.name, .built_in = observation.built_in, .workspace = if (previous) |display| display.workspace else 0, .previous_workspace = if (previous) |display| display.previous_workspace else null }) catch {
            updated.deinit(allocator);
            return;
        };
    }
    if (topology_changed) {
        generation += 1;
        cancelTransition();
    }
    displays.deinit(allocator);
    displays = updated;
    if (displays.items.len == 0) return;
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_windows(&observed, observed.len);
    var observed_focus: ?u64 = null;
    for (observed[0..count]) |observation| {
        if (observation.focused) observed_focus = observation.identity;
        if (windowIndex(observation.identity)) |index| {
            var window = &windows.items[index];
            window.observation = observation;
            if (displayIndex(window.display) != null and transition == null and window.floating and !managedFullscreen(window.*) and !window.parked and !observation.stale and observation.motion == .idle) {
                if (window.floating_restore) {
                    if (framesNear(observation.frame, window.floating_frame, 2)) window.floating_restore = false;
                } else window.floating_frame = observation.frame;
            }
        } else {
            if (windows.items.len == 1024) continue;
            var best: f64 = std.math.inf(f64);
            var displaySlot: usize = 0;
            for (displays.items, 0..) |candidate, slot| {
                const horizontal = observation.frame.left + observation.frame.width / 2 - candidate.frame.left - candidate.frame.width / 2;
                const vertical = observation.frame.top + observation.frame.height / 2 - candidate.frame.top - candidate.frame.height / 2;
                const distance = horizontal * horizontal + vertical * vertical;
                if (distance < best) {
                    best = distance;
                    displaySlot = slot;
                }
            }
            const display = displays.items[displaySlot].identity;
            // With global routing, a window on an empty display joins the current workspace.
            const joined = placedWorkspace(displays.items[displaySlot]) orelse currentWorkspace(displaySlot);
            var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = joined, .parking_frame = observation.frame, .floating_frame = observation.frame, .goal = observation.frame };
            const decision = rules.resolve(config.rules[0..config.rule_count], .{ .bundle = text(&observation.bundle), .title = text(&observation.title), .title_complete = observation.title_complete });
            window.floating = decision.floating orelse false;
            if (decision.workspace) |workspace| window.workspace = workspace;
            if (window.floating and (decision.geometry != null or decision.centered)) {
                const destination = resolvePlacements()[window.workspace] orelse display;
                const area = inset(displays.items[displayIndex(destination).?].frame, config.gap);
                var frame = observation.frame;
                if (decision.geometry) |geometry| frame = .{ .left = area.left + geometry.left, .top = area.top + geometry.top, .width = geometry.width, .height = geometry.height };
                // A centered window keeps its size, so an application with a fixed window size still accepts the placement.
                if (decision.centered) {
                    frame.left = area.left + (area.width - frame.width) / 2;
                    frame.top = area.top + (area.height - frame.height) / 2;
                }
                window.floating_frame = boundedFloating(frame, area);
                window.floating_restore = true;
            }
            window.discovered = native.platform_monotonic();
            windows.append(allocator, window) catch return;
        }
    }
    var index: usize = 0;
    while (index < windows.items.len) {
        const found = for (observed[0..count]) |observation| {
            if (observation.identity == windows.items[index].identity) break true;
        } else false;
        if (!found) {
            layouts.forgetIdentity(windows.items[index].identity);
            focus_history.forget(windows.items[index].identity);
            _ = windows.orderedRemove(index);
        } else index += 1;
    }
    if (!session_loaded) load: {
        session_loaded = true;
        if (!config.session.enabled) break :load;
        var loaded = session.load(allocator, sessionScope());
        defer loaded.deinit();
        session_status.load = switch (loaded.diagnostic) {
            .none => .none,
            .ready => .pending,
            .rejected => .rejected,
        };
        if (loaded.rejection) |rejection| sessionError(@tagName(rejection));
        const checkpoint = loaded.snapshot() orelse break :load;
        const current = sessionWindows() catch |err| {
            sessionError(@errorName(err));
            session_status.load = .failed;
            break :load;
        };
        defer allocator.free(current);
        var screens: [32]continuity.Screen = undefined;
        // Saved runtime homes are seeded before placement so moved workspaces restore on their homes.
        if (config.workspace_monitors != null) for (continuity.savedHomes(checkpoint, &config), &placements) |saved, *placement| if (saved) |hint| {
            placement.home = @splat(0);
            @memcpy(placement.home[0..hint.len], hint);
        };
        const imported = continuity.restore(checkpoint, current, sessionScreens(&screens), &config, resolvePlacements()) catch |err| {
            sessionError(@errorName(err));
            session_status.load = .failed;
            break :load;
        };
        defer imported.deinit();
        layouts = imported.store.*;
        for (imported.assignments) |assignment| {
            const window = &windows.items[windowIndex(assignment.identity) orelse continue];
            window.display = assignment.display;
            window.workspace = assignment.workspace;
            window.floating = assignment.floating;
            if (assignment.frame) |frame| {
                const screen = displays.items[displayIndex(assignment.display).?];
                window.floating_frame = boundedFloating(frame, inset(screen.frame, config.gap));
                window.floating_restore = true;
            }
        }
        for (imported.active) |active| if (displayIndex(active.display)) |slot| {
            displays.items[slot].workspace = active.workspace;
        };
        session_status.matched = imported.matched;
        session_status.unmatched = checkpoint.windows.len - imported.matched;
        session_status.ambiguous = imported.ambiguous;
        session_status.load = if (imported.matched > 0) .restored else .none;
        session_focus_pending = imported.matched > 0;
    }
    if (!suspended and transition == null) routing_blocked = !routeMembership();
    focused = observed_focus;
    if (observed_focus != last_observed_focus) {
        if (observed_focus) |identity| if (windowIndex(identity)) |slot| {
            rememberFocus(identity);
            if (displayIndex(windows.items[slot].display) != null) selectDisplay(windows.items[slot].display);
        };
        last_observed_focus = observed_focus;
    }
    if (focused) |identity| if (windowIndex(identity) == null) {
        focused = null;
    };
    if (selected_display == null or displayIndex(selected_display.?) == null) selected_display = displays.items[0].identity;
    trackCurrentDisplay();
    reconcile();
    if (session_focus_pending) {
        session_focus_pending = false;
        focusWorkspace(displays.items[activeDisplay()].identity, null);
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
    for (windows.items) |window| {
        if (window.display != display or !visible(window) or window.parked) continue;
        if (kind) |wanted| if ((wanted == .floating) != window.floating) continue;
        entries[count] = .{ .floating = window.floating, .frame = targetFrame(window), .identity = window.identity };
        count += 1;
    }
    std.mem.sort(Entry, entries[0..count], {}, Entry.lessThan);
    for (entries[0..count], 0..) |entry, index| output[index] = entry.identity;
    return output[0..count];
}
fn swapWindows(source_index: usize, target_index: usize) [*:0]const u8 {
    const source = &windows.items[source_index];
    const target = &windows.items[target_index];
    const identity = source.identity;
    const transaction = PlacementTransaction.begin(.{ .pair = .{ source.display, target.display } }) catch |err| return failure(@errorName(err));
    defer transaction.deinit();
    layouts.swap(source.identity, target.identity);
    if (managedFullscreen(source.*)) workspaceLayout(source.display, source.workspace).fullscreen = null;
    if (managedFullscreen(target.*)) workspaceLayout(target.display, target.workspace).fullscreen = null;
    std.mem.swap(u32, &source.display, &target.display);
    std.mem.swap(usize, &source.workspace, &target.workspace);
    std.mem.swap(Window, source, target);
    if (!transaction.commit()) return failure(transition_error orelse "SwapPlacementFailed");
    return json(.{ .ok = true, .verified = focusVerified(identity) });
}
fn neighbor(sourceIndex: usize, direction: Direction) ?usize {
    const source = windows.items[sourceIndex];
    const sourceFrame = if (source.floating) source.floating_frame else source.goal;
    var best: f64 = std.math.inf(f64);
    var result: ?usize = null;
    for (windows.items, 0..) |candidate, index| {
        if (index == sourceIndex or !visible(candidate) or candidate.parked) continue;
        const candidateFrame = if (candidate.floating) candidate.floating_frame else candidate.goal;
        const horizontal = candidateFrame.left + candidateFrame.width / 2 - sourceFrame.left - sourceFrame.width / 2;
        const vertical = candidateFrame.top + candidateFrame.height / 2 - sourceFrame.top - sourceFrame.height / 2;
        const forward = switch (direction) {
            .left => -horizontal,
            .right => horizontal,
            .up => -vertical,
            .down => vertical,
        };
        if (forward <= 1) continue;
        const cross = switch (direction) {
            .left, .right => @abs(vertical),
            .up, .down => @abs(horizontal),
        };
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
    for (windows.items) |*window| {
        window.observation.stale = true;
        for (observed[0..count]) |observation| if (observation.identity == window.identity) {
            window.observation = observation;
            break;
        };
    }
}
fn focusable(identity: u64) bool {
    const window = windows.items[windowIndex(identity) orelse return false];
    return externallyEligible(window) and displayIndex(window.display) != null;
}
fn focusWorkspace(displayIdentity: u32, focus_target: ?u64) void {
    refreshObservations();
    if (!deriveGoals()) return;
    const index = displayIndex(displayIdentity) orelse return;
    const state = workspaceLayout(displayIdentity, displays.items[index].workspace);
    var members: [1024]tiling.Member = undefined;
    if (focus_target orelse layouts.focusCandidate(state, layoutMembers(&members))) |identity| {
        const window = windows.items[windowIndex(identity) orelse return];
        if (!visible(window) or window.parked) {
            const transaction = PlacementTransaction.begin(.{ .display = displayIdentity }) catch |err| {
                transition_error = @errorName(err);
                return;
            };
            defer transaction.deinit();
            if (layouts.nodeForIdentity(identity) != null) layouts.reveal(state, identity) catch |err| {
                transaction.rollback(0);
                transition_error = @errorName(err);
                return;
            };
            if (!transaction.commit()) return;
        }
        if (!focusVerified(identity)) return;
    }
    selectDisplay(displayIdentity);
}
fn commitWorkspace(displaySlot: usize, workspace: usize, from: usize, focus_target: ?u64) bool {
    const displayIdentity = displays.items[displaySlot].identity;
    if (displayBlocked(displayIdentity)) {
        transition_error = "Native fullscreen window blocks this display";
        return false;
    }
    const transaction = PlacementTransaction.begin(.{ .display = displayIdentity }) catch |err| {
        transition_error = @errorName(err);
        return false;
    };
    defer transaction.deinit();
    displays.items[displaySlot].workspace = workspace;
    var members: [1024]tiling.Member = undefined;
    const state = workspaceLayout(displayIdentity, workspace);
    if (focus_target orelse layouts.focusCandidate(state, layoutMembers(&members))) |identity| if (layouts.nodeForIdentity(identity) != null) layouts.reveal(state, identity) catch |err| {
        transaction.rollback(0);
        transition_error = @errorName(err);
        return false;
    };
    if (!transaction.commit()) return false;
    recordPrevious(displaySlot, from, workspace);
    focusWorkspace(displayIdentity, focus_target);
    transition_error = null;
    native.platform_config_changed();
    return true;
}
fn sceneReady(context: ?*anyopaque, covered: bool) callconv(.c) void {
    const callbackGeneration = @intFromPtr(context orelse return);
    const pending = transition orelse return;
    if (callbackGeneration != pending.generation) return;
    defer publishStatus();
    native.platform_settle_budget_begin();
    snapshot_presentation = if (covered) .captured else .fallback;
    if (displayIndex(pending.display)) |displaySlot| {
        _ = commitWorkspace(displaySlot, pending.workspace, pending.from, pending.focus_target);
    } else transition_error = "Display disconnected during workspace capture";
    transition = null;
    if (covered) native.huen_scene_finish(pending.generation);
}
fn switchWorkspace(display_slot: usize, workspace: usize, from: usize, focus_target: ?u64) [*:0]const u8 {
    const destination = displays.items[display_slot];
    if (workspace == destination.workspace) {
        focusWorkspace(destination.identity, focus_target);
        return json(.{ .ok = true, .changed = false });
    }
    generation += 1;
    if (config.duration == 0 or !native.huen_scene_capture_allowed()) {
        snapshot_presentation = .instant;
        if (!commitWorkspace(display_slot, workspace, from, focus_target)) return failure(transition_error orelse "WorkspacePlacementFailed");
        return json(.{ .ok = true });
    }
    snapshot_presentation = .pending;
    transition = .{ .display = destination.identity, .workspace = workspace, .from = from, .generation = generation, .focus_target = focus_target };
    native.huen_scene_begin(destination.identity, generation, config.duration, sceneReady, @ptrFromInt(generation));
    return json(.{ .ok = true, .accepted = true, .generation = generation });
}
// Global mode: show `workspace` on its display and select that display. `from` is the
// selected display's workspace and becomes the global previous workspace.
fn showWorkspace(workspace: usize, from: usize, focus_target: ?u64) [*:0]const u8 {
    const resolved = resolvePlacements();
    const owner = resolved[workspace] orelse return failure("NoWorkspaceOwner");
    const destination_slot = displayIndex(owner).?;
    var migration = false;
    for (resolved[0..config.workspace_count], placements[0..config.workspace_count]) |destination, placement| if (destination != placement.display) {
        migration = true;
    };
    for (windows.items) |window| if (window.display != resolved[window.workspace].?) {
        migration = true;
    };
    if (migration) {
        generation += 1;
        snapshot_presentation = .instant;
        var activations: [11]Routing.Activation = undefined;
        if (!commitRouting(.{ .destinations = resolved, .activate = placementActivations(resolved, &.{.{ .display = owner, .workspace = workspace }}, &activations) })) return failure(transition_error orelse "MonitorRoutingFailed");
        commitPlacements(resolved);
        routing_blocked = false;
        recordPrevious(destination_slot, from, workspace);
        focusWorkspace(owner, focus_target);
        native.platform_config_changed();
        return json(.{ .ok = true, .monitor = owner, .verified = selected_display == owner, .target = focus_target });
    }
    routing_blocked = !routeMembership();
    if (routing_blocked) return failure(transition_error orelse "MonitorRoutingFailed");
    if (displays.items[destination_slot].workspace != workspace) return switchWorkspace(destination_slot, workspace, from, focus_target);
    focusWorkspace(owner, focus_target);
    const verified = selected_display == owner and (focus_target == null or focused == focus_target);
    if (verified) recordPrevious(destination_slot, from, workspace);
    return json(.{ .ok = true, .changed = false, .monitor = owner, .verified = verified, .target = focus_target });
}
// Global mode: sets each moved workspace's runtime home to its destination display and shows it
// there. A display in `vacated` that loses its shown workspace shows the global previous workspace
// if it is placed there, else its lowest placed workspace, else nothing. Selects `follow`.
fn rehomeWorkspaces(moves: []const Routing.Activation, vacated: ?u32, follow: u32) [*:0]const u8 {
    var homes: [10][128]u8 = undefined;
    for (&homes, placements) |*home, placement| home.* = placement.home;
    for (moves) |move| {
        const moved = &placements[move.workspace].home;
        moved.* = @splat(0);
        if (session.huen_session_display_uuid(move.display, moved, moved.len)) continue;
        for (&placements, homes) |*placement, home| placement.home = home;
        return failure("MonitorUuidUnavailable");
    }
    const resolved = resolvePlacements();
    var forced: [3]Routing.Activation = undefined;
    @memcpy(forced[0..moves.len], moves);
    var count = moves.len;
    if (vacated) |identity| {
        const fallback: ?usize = if (global_previous != null and resolved[global_previous.?] == identity) global_previous else for (0..config.workspace_count) |workspace| {
            if (resolved[workspace] == identity) break workspace;
        } else null;
        if (fallback) |workspace| {
            forced[count] = .{ .display = identity, .workspace = workspace };
            count += 1;
        }
    }
    generation += 1;
    snapshot_presentation = .instant;
    var activations: [11]Routing.Activation = undefined;
    if (!commitRouting(.{ .destinations = resolved, .activate = placementActivations(resolved, forced[0..count], &activations) })) {
        for (&placements, homes) |*placement, home| placement.home = home;
        return failure(transition_error orelse "MonitorRoutingFailed");
    }
    commitPlacements(resolved);
    routing_blocked = false;
    focusWorkspace(follow, null);
    native.platform_config_changed();
    return json(.{ .ok = true, .monitor = follow, .verified = selected_display == follow, .focused = focused });
}
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    defer publishStatus();
    defer publishPointer();
    const command = parseCommand(std.mem.span(commandText), config.workspace_count) catch |err| return failure(@errorName(err));
    switch (command) {
        .status => {
            const launch = native.platform_launch_status();
            const Placed = struct { index: usize, name: []const u8, display: ?u32, home: []const u8 };
            var placed: [10]Placed = undefined;
            for (config.workspaces[0..config.workspace_count], placements[0..config.workspace_count], placed[0..config.workspace_count], 0..) |*workspace, *placement, *item, index| {
                item.* = .{ .index = index + 1, .name = text(&workspace.name), .display = placement.display, .home = text(&placement.home) };
            }
            return json(.{
                .running = true,
                .suspended = suspended,
                .active_mode = text(&config.modes[active_mode].name),
                .close_state = close_state,
                .launch = .{ .request_id = launch.request_id, .state = launch.state, .message = text(&launch.message) },
                .window_count = windows.items.len,
                .display_count = displays.items.len,
                .selected_monitor = selected_display,
                .workspace_owner = workspaceOwner(),
                .placements = placed[0..config.workspace_count],
                .routing_blocked = routing_blocked,
                .workspace_backend = "corner-parking",
                .filter = std.mem.span(native.platform_filter()),
                .scene_capture_allowed = native.huen_scene_capture_allowed(),
                .snapshot_presentation = snapshot_presentation,
                .snapshot_generation = generation,
                .transition_pending = transition != null,
                .transition_error = transition_error,
                .mouse = .{ .availability = interaction.huen_input_status(), .generation = pointer_controls.generation, .err_message = pointer_controls.error_message, .forced_stop = pointer_controls.forced_stop },
                .session = session_status,
                .config_reload = .{ .request_id = config_generation, .state = config_state, .err_message = config_error },
            });
        },
        .mode => |name| {
            const index = config.modeIndex(name.text()) orelse return failure("UnknownMode");
            const mode = &config.modes[index];
            if (!native.platform_bindings(&mode.bindings, mode.binding_count)) return failure("HotkeyCollision");
            active_mode = index;
            return json(.{ .ok = true, .active_mode = text(&mode.name) });
        },
        .launch => |request| {
            if (suspended) return failure("RuntimeSuspendedRestartToResume");
            const request_id = native.platform_launch(request.bundle.text(), request.new_instance, request.hidden);
            if (request_id == 0) return failure("ApplicationNotFound");
            return json(.{ .ok = true, .accepted = true, .request_id = request_id });
        },
        .exec_and_forget => |shell| {
            if (suspended) return failure("RuntimeSuspendedRestartToResume");
            const terminated = allocator.dupeSentinel(u8, shell, 0) catch return failure("OutOfMemory");
            defer allocator.free(terminated);
            if (!native.platform_exec(terminated)) return failure("ProcessLaunchFailed");
            return json(.{ .ok = true, .accepted = true });
        },
        .windows => {
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, managed_fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8, group_hidden: bool };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (windows.items) |*window| items.append(allocator, .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focused == window.identity, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .managed_fullscreen = managedFullscreen(window.*), .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error, .group_hidden = !window.floating and layouts.visibility(window.identity) == .hidden_by_group }) catch return failure("OutOfMemory");
            return json(items.items);
        },
        .monitors => {
            const Item = struct { id: u32, uuid: ?[]const u8, name: []const u8, frame: Rect, full_bounds: Rect, built_in: bool, workspace: ?usize, selected: bool, blocked_by_fullscreen: bool };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            var uuids: [monitor.capacity][64]u8 = undefined;
            const count = @min(displays.items.len, uuids.len);
            for (displays.items[0..count], uuids[0..count]) |*display, *uuid| {
                uuid.* = @splat(0);
                const known = session.huen_session_display_uuid(display.identity, uuid, uuid.len);
                const placed = placedWorkspace(display.*);
                items.append(allocator, .{ .id = display.identity, .uuid = if (known) text(uuid) else null, .name = text(&display.name), .frame = display.frame, .full_bounds = display.full_bounds, .built_in = display.built_in, .workspace = if (placed) |workspace| workspace + 1 else null, .selected = selected_display == display.identity, .blocked_by_fullscreen = displayBlocked(display.identity) }) catch return failure("OutOfMemory");
            }
            return json(items.items);
        },
        .workspaces => {
            const Item = struct { display: u32, index: usize, name: []const u8, active: bool, layout: Layout };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (displays.items) |display| for (config.workspaces[0..config.workspace_count], 0..) |*workspace, index| {
                if (config.workspace_monitors != null and placements[index].display != display.identity) continue;
                const layout = if (layouts.lookup(display.identity, index)) |state| state.layout else workspace.layout;
                items.append(allocator, .{ .display = display.identity, .index = index + 1, .name = text(&workspace.name), .active = display.workspace == index, .layout = layout }) catch return failure("OutOfMemory");
            };
            return json(items.items);
        },
        .reload => {
            if (transition != null) return failure("WorkspaceTransitionPending");
            if (suspended) return failure("RuntimeSuspendedRestartToResume");
            const request_id = config_generation + 1;
            config_request.start(native.platform_config_path(), request_id) catch |err| return failure(@errorName(err));
            config_generation = request_id;
            config_state = .pending;
            config_error = null;
            return json(.{ .ok = true, .accepted = true, .request_id = request_id });
        },
        .quit => {
            pending_close = null;
            native.platform_close_cancel();
            cancelConfig();
            cancelTransition();
            native.platform_quit();
            return json(.{ .ok = true });
        },
        .restore => {
            if (pending_close != null) close_state = .cancelled;
            pending_close = null;
            native.platform_close_cancel();
            cancelConfig();
            cancelTransition();
            freezeSession();
            suspended = true;
            const outstanding = native.platform_restore();
            if (outstanding == 0) saveSession(true);
            native.platform_border(0, 0, 0);
            if (outstanding != 0) return json(.{ .@"error" = true, .err_message = "Geometry restoration incomplete. Retry restore after unminimizing or leaving fullscreen.", .outstanding = outstanding, .suspended = true });
            return json(.{ .ok = true, .suspended = true, .note = "Restored live-session geometry. Restart to resume tiling." });
        },
        else => {},
    }
    if (suspended) return failure("RuntimeSuspendedRestartToResume");
    if (transition != null) return failure("WorkspaceTransitionPending");
    if (displays.items.len == 0) return failure("NoDisplays");
    refreshObservations();
    const observed_focus = native.platform_focused_window();
    focused = if (observed_focus != 0) observed_focus else null;
    if (focused != last_observed_focus) {
        last_observed_focus = focused;
        if (focused) |identity| if (windowIndex(identity)) |index| {
            rememberFocus(identity);
            if (displayIndex(windows.items[index].display) != null) selectDisplay(windows.items[index].display);
        };
    }
    trackCurrentDisplay();
    const displaySlot = activeDisplay();
    const display = &displays.items[displaySlot];
    switch (command) {
        .workspace => |selection| {
            const workspace = resolveWorkspace(selection, displaySlot) catch |err| return failure(@errorName(err));
            if (config.workspace_monitors == null) return switchWorkspace(displaySlot, workspace, display.workspace, null);
            return showWorkspace(workspace, currentWorkspace(displaySlot), null);
        },
        .focus_monitor => |selection| {
            var screens: [monitor.capacity]monitor.Screen = undefined;
            const target = monitor.resolve(selection, monitorScreens(&screens), display.identity) catch |err| return failure(@errorName(err));
            const changed = selected_display != target;
            focusWorkspace(target, null);
            return json(.{ .ok = true, .accepted = true, .changed = changed, .monitor = target, .verified = selected_display == target, .focused = focused });
        },
        .move_workspace_to_monitor, .swap_monitor_workspaces => |selection| {
            if (config.workspace_monitors == null) return failure("RequiresGlobalWorkspaces");
            var screens: [monitor.capacity]monitor.Screen = undefined;
            const target = monitor.resolve(selection, monitorScreens(&screens), display.identity) catch |err| return failure(@errorName(err));
            const workspace = display.workspace;
            if (placements[workspace].display != display.identity) return failure("NoWorkspaceOnMonitor");
            if (target == display.identity) return json(.{ .ok = true, .changed = false, .monitor = target });
            if (command == .move_workspace_to_monitor) return rehomeWorkspaces(&.{.{ .display = target, .workspace = workspace }}, display.identity, target);
            const target_workspace = displays.items[displayIndex(target).?].workspace;
            if (placements[target_workspace].display != target) return failure("NoWorkspaceOnMonitor");
            return rehomeWorkspaces(&.{ .{ .display = target, .workspace = workspace }, .{ .display = display.identity, .workspace = target_workspace } }, null, target);
        },
        .cycle => |request| {
            var identities: [1024]u64 = undefined;
            const target = selector.cycleTarget(readingOrder(display.identity, request.kind, &identities), focused, request.step) orelse return failure("NoWindowToCycle");
            return json(.{ .ok = true, .accepted = true, .verified = focusVerified(target), .target = target });
        },
        .focus_last => {
            const identity = focus_history.pick(focused, focusable) orelse return failure("NoPreviousWindow");
            const window = windows.items[windowIndex(identity).?];
            if (config.workspace_monitors != null) return showWorkspace(window.workspace, currentWorkspace(displaySlot), identity);
            const slot = displayIndex(window.display).?;
            if (window.workspace != displays.items[slot].workspace) return switchWorkspace(slot, window.workspace, displays.items[slot].workspace, identity);
            focusWorkspace(window.display, identity);
            return json(.{ .ok = true, .verified = focused == identity, .target = identity });
        },
        .layout => |layout| {
            if (placedWorkspace(display.*) == null) return failure("NoWorkspaceOnMonitor");
            const transaction = PlacementTransaction.begin(.{ .display = display.identity }) catch |err| return failure(@errorName(err));
            defer transaction.deinit();
            workspaceLayout(display.identity, display.workspace).layout = layout;
            if (!transaction.commit()) return failure(transition_error orelse "LayoutPlacementFailed");
            native.platform_config_changed();
            return json(.{ .ok = true });
        },
        .resize => |delta| {
            if (placedWorkspace(display.*) == null) return failure("NoWorkspaceOnMonitor");
            layouts.adjustRatio(workspaceLayout(display.identity, display.workspace), delta);
        },
        else => {
            const sourceIndex = windowIndex(focused orelse return failure("NoFocusedWindow")) orelse return failure("NoFocusedWindow");
            const source = &windows.items[sourceIndex];
            if (!visible(source.*)) return failure("FocusedWindowNotManaged");
            switch (command) {
                .select => |direction| {
                    const state = workspaceLayout(source.display, source.workspace);
                    const selection = layouts.select(state, source.identity, direction) catch |err| return failure(@errorName(err));
                    const representative = layouts.representative(selection) catch |err| return failure(@errorName(err));
                    return json(.{ .ok = true, .selection = selection, .representative = representative });
                },
                .tilemove, .group => {
                    if (source.floating or managedFullscreen(source.*)) return failure("WindowNotTiled");
                    const transaction = PlacementTransaction.begin(.{ .display = source.display }) catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    const state = workspaceLayout(source.display, source.workspace);
                    var target: ?u64 = null;
                    switch (command) {
                        .tilemove => |direction| layouts.tilemove(state, source.identity, direction) catch |err| {
                            transaction.rollback(0);
                            return failure(@errorName(err));
                        },
                        .group => |action| target = layouts.editGroup(state, source.identity, action) catch |err| {
                            transaction.rollback(0);
                            return failure(@errorName(err));
                        },
                        else => unreachable,
                    }
                    if (!transaction.commit()) return failure(transition_error orelse "GroupPlacementFailed");
                    const verified = if (target) |identity| focusVerified(identity) else true;
                    native.platform_config_changed();
                    return json(.{ .ok = true, .target = target, .verified = verified });
                },
                .split => |orientation| {
                    const state = workspaceLayout(source.display, source.workspace);
                    if (state.layout != .dwindle) return failure("SplitRequiresDwindle");
                    if (source.floating or managedFullscreen(source.*)) return failure("WindowNotTiled");
                    layouts.orient(source.identity, orientation) catch |err| return failure(@errorName(err));
                },
                .resize_points => |resize| {
                    if (source.floating or managedFullscreen(source.*)) return failure("WindowNotTiled");
                    if (!deriveGoals()) return failure(transition_error orelse "LayoutProjectionFailed");
                    const applied = resizeTiled(sourceIndex, resize.axis, resize.delta) catch |err| return failure(@errorName(err));
                    reconcile();
                    native.platform_config_changed();
                    return json(.{ .ok = true, .applied_delta = applied });
                },
                .resize_by => |offset| {
                    if (managedFullscreen(source.*)) return failure("ManagedFullscreenActive");
                    if (!source.floating) {
                        if (offset.vertical != 0 and workspaceLayout(source.display, source.workspace).layout == .master) return failure("MasterHeightResizeUnsupported");
                        if (!deriveGoals()) return failure(transition_error orelse "LayoutProjectionFailed");
                        const width = if (offset.horizontal != 0) resizeTiled(sourceIndex, .width, offset.horizontal) catch |err| return failure(@errorName(err)) else 0;
                        const height = if (offset.vertical != 0) resizeTiled(sourceIndex, .height, offset.vertical) catch |err| return failure(@errorName(err)) else 0;
                        reconcile();
                        native.platform_config_changed();
                        return json(.{ .ok = true, .applied = .{ .width = width, .height = height } });
                    }
                    const area = inset(displays.items[displayIndex(source.display).?].frame, config.gap);
                    var frame = source.floating_frame;
                    frame.width = std.math.clamp(frame.width + offset.horizontal, 80, @max(80, area.left + area.width - frame.left));
                    frame.height = std.math.clamp(frame.height + offset.vertical, 80, @max(80, area.top + area.height - frame.top));
                    source.floating_frame = frame;
                },
                .center, .move_by => {
                    if (managedFullscreen(source.*)) return failure("ManagedFullscreenActive");
                    if (!source.floating) return failure("WindowNotFloating");
                    const area = inset(displays.items[displayIndex(source.display).?].frame, config.gap);
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
                    source.floating_frame = boundedFloating(frame, area);
                },
                .fullscreen => {
                    const transaction = PlacementTransaction.begin(.{ .display = source.display }) catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    const state = workspaceLayout(source.display, source.workspace);
                    if (source.floating) source.floating_restore = true else layouts.reveal(state, source.identity) catch |err| {
                        transaction.rollback(0);
                        return failure(@errorName(err));
                    };
                    state.fullscreen = if (state.fullscreen == source.identity) null else source.identity;
                    if (!transaction.commit()) return failure(transition_error orelse "FullscreenPlacementFailed");
                    return json(.{ .ok = true, .verified = focusVerified(source.identity) });
                },
                .close => |quit_if_last| {
                    if (pending_close != null) return failure("ClosePending");
                    var process_token: f64 = 0;
                    if (!native.platform_close(source.identity, quit_if_last, &process_token)) return failure("CloseRejected");
                    if (quit_if_last) {
                        pending_close = .{ .identity = source.identity, .pid = source.observation.pid, .process_token = process_token, .deadline = native.platform_monotonic() + 5 };
                        close_state = .pending;
                    }
                    return json(.{ .ok = true, .accepted = true });
                },
                .toggle_floating => {
                    if (managedFullscreen(source.*)) return failure("ManagedFullscreenActive");
                    if (source.floating) {
                        source.last_floating_frame = source.floating_frame;
                        source.floating = false;
                    } else {
                        // Like Hyprland: return to the last floating frame, or float at half the usable area, centered.
                        const area = inset(displays.items[displayIndex(source.display).?].frame, config.gap);
                        source.floating = true;
                        source.floating_frame = boundedFloating(source.last_floating_frame orelse .{
                            .left = area.left + area.width / 4,
                            .top = area.top + area.height / 4,
                            .width = area.width / 2,
                            .height = area.height / 2,
                        }, area);
                    }
                },
                .send_to_workspace => |selection| {
                    const resolved = resolvePlacements();
                    const workspace = resolveWorkspace(selection, selectionSlot(sourceIndex, displaySlot)) catch |err| return failure(@errorName(err));
                    const destination = resolved[workspace] orelse source.display;
                    if (workspace == source.workspace and destination == source.display) return json(.{ .ok = true, .changed = false });
                    var activations: [11]Routing.Activation = undefined;
                    if (!commitRouting(.{ .destinations = resolved, .activate = placementActivations(resolved, &.{}, &activations), .send = .{ .index = sourceIndex, .display = destination, .workspace = workspace } })) return failure(transition_error orelse "MonitorRoutingFailed");
                    commitPlacements(resolved);
                    routing_blocked = false;
                    if (!visible(source.*)) focused = null;
                    native.platform_config_changed();
                    return json(.{ .ok = true });
                },
                .move_to_workspace => |selection| {
                    const resolved = resolvePlacements();
                    const workspace = resolveWorkspace(selection, selectionSlot(sourceIndex, displaySlot)) catch |err| return failure(@errorName(err));
                    const destination = resolved[workspace] orelse source.display;
                    const destination_slot = displayIndex(destination).?;
                    const from = currentWorkspace(if (config.workspace_monitors != null) displaySlot else destination_slot);
                    if (workspace == source.workspace and destination == source.display) return json(.{ .ok = true, .changed = false });
                    const identity = source.identity;
                    generation += 1;
                    snapshot_presentation = .instant;
                    var activations: [11]Routing.Activation = undefined;
                    if (!commitRouting(.{ .destinations = resolved, .activate = placementActivations(resolved, &.{.{ .display = destination, .workspace = workspace }}, &activations), .send = .{ .index = sourceIndex, .display = destination, .workspace = workspace } })) return failure(transition_error orelse "MonitorRoutingFailed");
                    commitPlacements(resolved);
                    routing_blocked = false;
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
                    const target = monitor.resolve(selection, monitorScreens(&screens), origin) catch |err| return failure(@errorName(err));
                    const workspace = displays.items[displayIndex(target).?].workspace;
                    if (target == origin) return json(.{ .ok = true, .changed = false, .monitor = target, .workspace = source.workspace + 1 });
                    const resolved = resolvePlacements();
                    if (config.workspace_monitors != null and resolved[workspace] != target) return failure("NoWorkspaceOnMonitor");
                    var activations: [11]Routing.Activation = undefined;
                    if (!commitRouting(.{ .destinations = resolved, .activate = placementActivations(resolved, &.{.{ .display = target, .workspace = workspace }}, &activations), .send = .{ .index = sourceIndex, .display = target, .workspace = workspace } })) return failure(transition_error orelse "MonitorRoutingFailed");
                    commitPlacements(resolved);
                    routing_blocked = false;
                    native.platform_config_changed();
                    if (command == .move_to_monitor) return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = focusVerified(source.identity), .target = source.identity });
                    // The selection stays, so keyboard focus returns to the selected display's candidate.
                    const selected = selected_display orelse origin;
                    focusWorkspace(selected, null);
                    return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = selected_display == selected, .focused = focused });
                },
                .focus => |request| {
                    const target = if (request.wrap) wrapped: {
                        const source_frame = if (source.floating) source.floating_frame else source.goal;
                        var forward_target: ?usize = null;
                        var forward_score = std.math.inf(f64);
                        var wrap_target = sourceIndex;
                        var wrap_distance: f64 = 0;
                        var wrap_cross = std.math.inf(f64);
                        for (windows.items, 0..) |candidate, index| {
                            if (index == sourceIndex or !visible(candidate) or candidate.parked or candidate.display != source.display or candidate.workspace != source.workspace) continue;
                            const frame = if (candidate.floating) candidate.floating_frame else candidate.goal;
                            const horizontal = frame.left + frame.width / 2 - source_frame.left - source_frame.width / 2;
                            const vertical = frame.top + frame.height / 2 - source_frame.top - source_frame.height / 2;
                            const forward = switch (request.direction) {
                                .left => -horizontal,
                                .right => horizontal,
                                .up => -vertical,
                                .down => vertical,
                            };
                            const cross = switch (request.direction) {
                                .left, .right => @abs(vertical),
                                .up, .down => @abs(horizontal),
                            };
                            const score = forward + cross * 2;
                            if (forward > 1 and (score < forward_score or (score == forward_score and (forward_target == null or candidate.identity < windows.items[forward_target.?].identity)))) {
                                forward_target = index;
                                forward_score = score;
                            }
                            if (forward < wrap_distance or (forward == wrap_distance and (cross < wrap_cross or (cross == wrap_cross and candidate.identity < windows.items[wrap_target].identity)))) {
                                wrap_target = index;
                                wrap_distance = forward;
                                wrap_cross = cross;
                            }
                        }
                        break :wrapped forward_target orelse wrap_target;
                    } else neighbor(sourceIndex, request.direction) orelse return failure("NoWindowInDirection");
                    const identity = windows.items[target].identity;
                    return json(.{ .ok = true, .accepted = true, .verified = focusVerified(identity), .target = identity });
                },
                .swap => |direction| return swapWindows(sourceIndex, neighbor(sourceIndex, direction) orelse return failure("NoWindowInDirection")),
                .swap_cycle => |step| {
                    if (source.floating or managedFullscreen(source.*)) return failure("WindowNotTiled");
                    var identities: [1024]u64 = undefined;
                    const target = selector.cycleTarget(readingOrder(source.display, .tiled, &identities), source.identity, step).?;
                    if (target == source.identity) return json(.{ .ok = true, .changed = false });
                    return swapWindows(sourceIndex, windowIndex(target).?);
                },
                .move => |direction| {
                    if (managedFullscreen(source.*)) return failure("ManagedFullscreenActive");
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
    reconcile();
    native.platform_config_changed();
    return json(.{ .ok = true });
}
export fn wm_shutdown() bool {
    freezeSession();
    suspended = true;
    pending_close = null;
    native.platform_close_cancel();
    status_active = false;
    native.platform_status_present(null);
    cancelConfig();
    if (config_request.inFlight()) return false;
    if (!pointer_controls.stop(native.platform_monotonic())) return false;
    if (pointer_controls.forced_stop) native.platform_error("Input release drain exceeded 250 ms; tap teardown forced");
    cancelTransition();
    const outstanding = native.platform_restore();
    saveSession(outstanding == 0);
    if (outstanding != 0) native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
    native.platform_border(0, 0, 0);
    return true;
}
