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
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
// Whether an application moves its window back on screen after it is parked. `escaped` holds when it last did.
const Escape = union(enum) { settled, escaped: f64, exempt };
const PendingTileWrite = struct { frame: Rect, at: f64, snap_candidate: ?Rect = null };
const snap_back_window: f64 = 1.0;
const launch_grace: f64 = 1.0;
const Window = struct { identity: u64, observation: native.WMWindow, workspace: usize, display: u32, discovered: f64 = 0, floating: bool = false, floating_restore: bool = false, parked: bool = false, urgent: bool = false, parking_frame: Rect, floating_frame: Rect, last_floating_frame: ?Rect = null, goal: Rect, placement_error: ?[]const u8 = null, escape: Escape = .settled, parked_at: ?f64 = null, bounds: tiling.Bounds = .{}, placed: ?PendingTileWrite = null, discovered_frame: Rect, vanished: ?f64 = null, vanished_parked: bool = false, established: bool = false };
const Display = struct { identity: u32, frame: Rect, full_bounds: Rect, name: [128]u8, built_in: bool, workspace: usize = 0, previous_workspace: ?usize = null };
const Config = configuration.ConfigCandidate;
var config: Config = .{};
var layouts: tiling.Store = .{};
var window_buffer: [1024]Window = undefined;
var windows: std.ArrayList(Window) = .initBuffer(&window_buffer);
var display_buffer: [monitor.capacity]Display = undefined;
var displays: std.ArrayList(Display) = .initBuffer(&display_buffer);
var focused: ?u64 = null;
var focus_history: history.Ring = .{};
var active_mode: usize = 0;
const PendingClose = struct { identity: u64, pid: c_int, process_token: f64, deadline: f64 };
var pending_close: ?PendingClose = null;
var close_state: enum { idle, pending, closed, termination_requested, termination_rejected, expired, cancelled } = .idle;
var selected_display: ?u32 = null;
var last_observed_focus: ?u64 = null;
// When the window that had focus last went away, so focus that macOS then hands to another window is not taken for a request.
var focus_lost: f64 = -std.math.inf(f64);
// macOS moves windows when a display goes away, which must not count as an application moving its own window.
var topology_changed_at: f64 = -std.math.inf(f64);
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
var shortcut_buffer: [64]commands.WorkspaceSelector = undefined;
var workspace_shortcuts: std.ArrayList(commands.WorkspaceSelector) = .initBuffer(&shortcut_buffer);
// A workspace switch within about 250 ms of an activation makes the applications involved wait on WindowServer for 300
// to 500 ms. Every AX call to them times out meanwhile, so their windows go stale and block placement.
const activation_settle = 0.3;
var activated: f64 = -std.math.inf(f64);
var hotkey_watch: delivery.Watch = .{};
var hotkey_recovery: struct { missed: usize = 0, rebinds: usize = 0, rebound: f64 = -std.math.inf(f64) } = .{};
var swipe_recognizer: swipe.Recognizer = .{};
var journal_failed = false;
var journaled_transition: ?[]const u8 = null;
var gestures_enabled = false;
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
// A modified drag that moves or resizes a floating window. A resize moves the edges nearest the press, as in Hyprland.
const FloatingDrag = struct { gesture_id: u64, identity: u64, origin: interaction.Point, frame: Rect, from_left: bool, from_top: bool };
var floating_drag: ?FloatingDrag = null;
var session_config_hash: [64]u8 = @splat(0);
var session_boot: [128]u8 = @splat(0);
var session_loaded = false;
var session_focus_pending = false;
var session_frozen: ?continuity.Frozen = null;
var session_freeze_attempted = false;
var session_save_attempted = false;
var parking_journal: parking.Writer = .{};
var parking_journal_failed = false;
// A parked window the manager lost track of while its application still runs. Its record stays in the journal and is
// matched against new windows for up to a minute, because most orphans are windows their application closed while parked.
const orphan_lifetime = 60.0;
const Orphan = struct { bundle: [256]u8, pid: c_int, token: f64, original: Rect, corners: [2]Rect, since: f64 };
var orphan_buffer: [256]Orphan = undefined;
var orphans: std.ArrayList(Orphan) = .initBuffer(&orphan_buffer);
const ParkingRecovery = struct { records: usize = 0, recovered: usize = 0, failed: usize = 0 };
// Null until the first tick that has displays has matched the journal of the previous process.
var parking_recovery: ?ParkingRecovery = null;
var placement_memory: memory.Memory = .{};
var placement_memory_loaded = false;
var placement_claims: usize = 0;
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
        if (externallyEligible(window) and displayIndex(window.display) != null and native.platform_session_attributes(window.identity, &attributes)) if (attributes.key()) |_| {
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
    const current = sessionWindows() catch |err| return saveFailed(err);
    defer allocator.free(current);
    var screens: [32]continuity.Screen = undefined;
    var homes: [10][128]u8 = undefined;
    for (&homes, placements) |*home, placement| home.* = placement.home;
    session_frozen = continuity.freeze(&layouts, current, sessionScreens(&screens), &config, homes[0..config.workspace_count], sessionScope()) catch |err| return saveFailed(err);
    session_status.save = .frozen;
}
fn saveFailed(err: anyerror) void {
    sessionError(@errorName(err));
    session_status.save = .failed;
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
    session.save(allocator, checkpoint.snapshot) catch |err| return saveFailed(err);
    session_status.save = .saved;
}
fn pointerWindows(output: []pointer.Window) []pointer.Window {
    for (windows.items, 0..) |window, index| {
        const hit = visible(window) and !window.parked and !managedFullscreen(window) and !displayBlocked(window.display) and window.observation.hit_eligible and window.observation.motion == .idle;
        output[index] = .{
            .identity = window.identity,
            .public_id = window.observation.public_window_id,
            .goal = window.goal,
            .eligible = hit and !window.floating and framesNear(window.observation.frame, targetFrame(window), 2),
            .title = text(&windows.items[index].observation.title),
            .floating = if (hit and window.floating) window.observation.frame else null,
            .focused = focused == window.identity,
        };
    }
    return output[0..windows.items.len];
}
fn publishPointer() void {
    // A new publication cancels the active gesture, and the dragged window's hit changes with every update.
    if (!initialized or pointer_controls.stop_deadline != null or floating_drag != null) return;
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
        // The end of an active drag is discarded below, and an active drag pauses scans.
        floating_drag = null;
        native.platform_drag_active(false);
        var discarded: interaction.Event = undefined;
        var count: usize = 0;
        while (count < 64 and interaction.huen_input_poll(&discarded)) : (count += 1) {}
        return;
    }
    var sample: interaction.Event = undefined;
    var count: usize = 0;
    poll: while (count < 64 and interaction.huen_input_poll(&sample)) : (count += 1) {
        if (sample.gesture == .move_floating or sample.gesture == .resize_floating) {
            switch (sample.kind) {
                .start => {
                    if (sample.generation != pointer_controls.generation) continue;
                    const window = windows.items[windowIndex(sample.target.window_identity) orelse continue];
                    if (!window.floating or window.parked or !visible(window) or managedFullscreen(window)) continue;
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
                    const window = &windows.items[windowIndex(drag.identity) orelse continue];
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
            // Clearing bounds during the drag would move the published boundaries and cancel the gesture, so the release retries the rest.
            .resize => |preview| resize: {
                const requested = if (preview.boundary.axis == .width) sample.point.left - sample.origin.left else sample.point.top - sample.origin.top;
                layouts.commitResize(preview, config.gap) catch |err| break :resize err;
                if (@abs(requested - preview.applied_delta) <= size_bounds.tolerance or !forgetWorkspaceBounds(state.display, state.workspace)) break :resize null;
                if (!deriveGoals()) break :resize error.LayoutProjectionFailed;
                var boundary = preview.boundary;
                boundary.revision = layouts.revision;
                const retry = layouts.previewResize(boundary, requested - preview.applied_delta, config.gap) catch |err| break :resize err;
                layouts.commitResize(retry, config.gap) catch |err| break :resize err;
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
        // A dot marks a workspace that holds an urgent window, and the title while any workspace does.
        var urgent: [10]bool = @splat(false);
        var alert = false;
        for (windows.items) |window| if (window.urgent) {
            urgent[window.workspace] = true;
            alert = true;
        };
        const shown = if (active_mode != 0 and !suspended) text(&config.modes[active_mode].name) else label;
        switch (config.status_bar.style) {
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
            text(&config.modes[active_mode].name),
            if (transition_error != null) " · Workspace switch failed" else "",
        }) catch unreachable;
        statusText(&presentation.tooltip, tooltip, 255);
        for (config.workspaces[0..config.workspace_count], 0..) |*workspace, index| {
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
    const candidate = configuration.evaluate(path, null, null) catch |err| {
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
    configureInput();
    publishStatus();
    return true;
}
fn configureInput() void {
    pointer_controls.configure(config.mouse.enabled, config.mouse.modifiers);
    if (gestures_enabled == config.swipe.enabled) return;
    gestures_enabled = config.swipe.enabled;
    native.huen_observe_gestures(gestures_enabled);
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
    hotkey_watch.forgetPresses();
    applyLayoutDefaults(&candidate);
    config = candidate;
    configureInput();
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
fn workspaceView(display_slot: usize) selector.View {
    var occupied: selector.Occupancy = .empty;
    const display = displays.items[display_slot];
    for (windows.items) |window| if (externallyEligible(window) and (config.workspace_monitors != null or window.display == display.identity)) occupied.set(window.workspace);
    // `workspace N` from an empty display does not flip to the previous workspace, except in owner
    // mode, where the owner's workspace is the current one for every display.
    const back_and_forth = config.workspace_back_and_forth and (placedWorkspace(display) != null or workspaceOwner() != null);
    return .{ .config = &config, .current = currentWorkspace(display_slot), .previous = previousWorkspace(display_slot).*, .occupied = occupied, .back_and_forth = back_and_forth };
}
fn resolveWorkspace(selection: commands.WorkspaceSelector, display_slot: usize) !usize {
    return selector.resolve(selection, workspaceView(display_slot));
}
fn workspaceLayout(display: u32, workspace: usize) *tiling.WorkspaceLayout {
    const defaults = config.workspaces[workspace];
    return layouts.ensureWorkspace(display, workspace, defaults.layout, defaults.ratio);
}
fn managedFullscreen(window: Window) bool {
    const state = layouts.lookup(window.display, window.workspace) orelse return false;
    return state.fullscreen == window.identity;
}
fn targetFrame(window: Window) Rect {
    if (managedFullscreen(window)) if (displayIndex(window.display)) |index| return displays.items[index].frame;
    return if (window.floating) window.floating_frame else window.bounds.fit(window.goal);
}
fn resizeTiled(source_index: usize, axis: commands.Axis, delta: f64) !f64 {
    const source = windows.items[source_index];
    const state = workspaceLayout(source.display, source.workspace);
    if (state.layout == .dwindle) return layouts.resizePoints(source.identity, axis, delta, config.gap);
    if (axis != .width) return error.MasterHeightResizeUnsupported;
    var indices: [1024]usize = undefined;
    var count: usize = 0;
    for (windows.items, 0..) |window, index| {
        if (window.display != source.display or window.workspace != source.workspace or !visible(window) or window.floating) continue;
        indices[count] = index;
        count += 1;
    }
    if (count < 2) return 0;
    const area = displayArea(source.display);
    const available = area.width - @min(config.gap, @max(0, area.width - 2));
    const limits = switch (tiling.leadingRange(available, available * state.ratio, masterSides(indices[0..count]))) {
        .fits => |span| span,
        .overlaps => return 0,
    };
    const sign: f64 = if (indices[0] == source_index) 1 else -1;
    const previous = std.math.clamp(available * state.ratio, limits.lower, limits.upper);
    const next = std.math.clamp(previous + sign * delta, limits.lower, limits.upper);
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
    for (displays.items, output[0..displays.items.len]) |*display, *screen| screen.* = .{ .identity = display.identity, .full_bounds = display.full_bounds, .built_in = display.built_in, .name = text(&display.name) };
    return output[0..displays.items.len];
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
const Activation = struct { display: u32, workspace: usize };
fn route(resolved: [10]?u32, forced: []const Activation, send: ?struct { index: usize, display: u32, workspace: usize }) bool {
    const workspace_count = config.workspace_count;
    var activations: [11]Activation = undefined;
    @memcpy(activations[0..forced.len], forced);
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
        activations[count] = .{ .display = identity, .workspace = choice };
        count += 1;
    }
    const transaction = PlacementTransaction.begin(.all) catch |err| {
        transition_error = @errorName(err);
        return false;
    };
    defer transaction.deinit();
    var staged: [1024]u32 = undefined;
    for (activations[0..count]) |activation| if (displayBlocked(activation.display)) {
        transition_error = "Native fullscreen window blocks routing destination";
        return false;
    };
    for (windows.items, 0..) |window, index| {
        const sent = send != null and send.?.index == index;
        const destination = if (sent) send.?.display else resolved[window.workspace] orelse if (displayIndex(window.display) == null) displays.items[0].identity else window.display;
        staged[index] = destination;
        if (window.vanished != null) continue;
        if (window.observation.minimized or window.observation.fullscreen or (!window.observation.onscreen and !window.parked)) {
            if (destination != window.display or (window.observation.fullscreen and sent)) {
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
        const destination = resolved[state.workspace] orelse if (displayIndex(state.display) == null) displays.items[0].identity else state.display;
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
    for (activations[0..count]) |activation| displays.items[displayIndex(activation.display).?].workspace = activation.workspace;
    for (windows.items, staged[0..windows.items.len], 0..) |*window, destination, index| {
        if (send) |request| if (request.index == index) {
            window.workspace = request.workspace;
        };
        if (destination == window.display) continue;
        const area = displayArea(destination);
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
    if (send) |request| layouts.forgetIdentity(windows.items[request.index].identity);
    if (!transaction.commit()) return false;
    for (&placements, resolved) |*placement, destination| {
        if (destination != placement.display) {
            const lost = if (placement.display) |identity| displayIndex(identity) == null else false;
            placement.shown_when_lost = lost and (placement.shown or placement.shown_when_lost);
        }
        placement.display = destination;
    }
    routing_blocked = false;
    return true;
}
const PlacementTransaction = struct {
    const Scope = union(enum) { all, display: u32, pair: [2]u32 };
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
            const included = switch (scope) {
                .all => true,
                .display => |identity| identity == window.display,
                .pair => |identities| identities[0] == window.display or identities[1] == window.display,
            };
            if (!included) continue;
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
    // `attempted` holds indices into `windows.items` in the order their placement was attempted.
    fn rollback(self: PlacementTransaction, attempted: []const usize) void {
        saveParkingJournal(self.intent);
        var remaining = attempted.len;
        while (remaining > 0) {
            remaining -= 1;
            const identity = windows.items[attempted[remaining]].identity;
            const original_index = self.identityIndex(identity);
            const original = self.originals[original_index] orelse continue;
            var restored = original;
            if (verifiedFrame(identity, original, null, &restored)) continue;
            const intent = &self.intent[original_index];
            if (!intent.parked) intent.parking_frame = original;
            intent.parked = true;
            intent.parked_at = null;
            intent.placement_error = "Placement rollback rejected; recovery ownership retained";
        }
        layouts = self.store.*;
        @memcpy(windows.items, self.intent);
        @memcpy(displays.items, self.screens);
        selected_display = self.selected;
    }
    fn abort(self: PlacementTransaction, err: anyerror) []const u8 {
        self.rollback(&.{});
        return @errorName(err);
    }
    fn identityIndex(self: PlacementTransaction, identity: u64) usize {
        for (self.intent, 0..) |window, index| if (window.identity == identity) return index;
        unreachable;
    }
    // Shows the incoming windows before parking the outgoing ones, back to front, so the desktop never shows through.
    fn commit(self: PlacementTransaction) bool {
        if (!deriveGoals()) {
            self.rollback(&.{});
            return false;
        }
        var order: [1024]usize = undefined;
        var count: usize = 0;
        for (windows.items, 0..) |window, index| if (self.originals[self.identityIndex(window.identity)] != null and visible(window)) {
            order[count] = index;
            count += 1;
        };
        const shown = count;
        for (windows.items, 0..) |window, index| if (self.originals[self.identityIndex(window.identity)] != null and !visible(window)) {
            order[count] = index;
            count += 1;
        };
        std.mem.sort(usize, order[shown..count], {}, backToFront);
        for (order[0..count], 0..) |index, position| {
            const window = &windows.items[index];
            const outcome = if (visible(window.*)) placeVisible(window) else parkWindow(window);
            if (outcome == .applied) continue;
            // An application that rejects its tile size must not block every other window. Float it, as reconcile does,
            // and derive goals again so later windows do not receive tiles sized around the rejected one.
            if (outcome == .rolled_back and visible(window.*) and !window.floating) {
                floatRejectedTile(window);
                if (window.floating and deriveGoals() and placeVisible(window) == .applied) continue;
            }
            self.rollback(order[0 .. position + 1]);
            transition_error = "Placement rejected; reverse rollback attempted; inspect window recovery errors";
            return false;
        }
        transition_error = null;
        return true;
    }
    // Unknown stack positions are `maxInt(u32)`, so they come first.
    fn backToFront(_: void, first: usize, second: usize) bool {
        return windows.items[first].observation.stack_order > windows.items[second].observation.stack_order;
    }
};
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
    return !needed or route(resolved, &.{}, null);
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
        output[count] = .{ .identity = window.identity, .display = window.display, .workspace = window.workspace, .tiled = !window.floating, .active = externallyEligible(window), .area = inset(display.frame, config.gap), .bounds = window.bounds, .vanished = window.vanished != null };
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
    activated = native.platform_monotonic();
    if (!native.platform_focus(identity) or native.platform_focused_window() != identity) return false;
    focused = identity;
    last_observed_focus = identity;
    rememberFocus(identity);
    if (windowIndex(identity)) |index| {
        windows.items[index].urgent = false;
        selectDisplay(windows.items[index].display);
    }
    return true;
}
// Records a native focus change. A command leaves an activation request to the next tick, and so does a tick during a
// workspace transition. A tick reads focus from the last scan, and a scan of one application leaves the focus of the
// others as it was, so a tick confirms a request against live focus.
fn observeFocus(observed: ?u64, settle: bool) void {
    focused = observed;
    if (observed) |identity| if (windowIndex(identity)) |slot| if (visible(windows.items[slot])) {
        windows.items[slot].urgent = false;
    };
    if (observed == last_observed_focus) return;
    const previous = last_observed_focus;
    // A request is focus that an application took for a window on a hidden workspace, as when a link opens in a browser there.
    // A new window that a rule placed there is not a request. Neither is focus that macOS moves there because the focused
    // window went away, nor focus that comes back to the window that had it last, such as one that a command sent there.
    const requested = if (observed) |identity| requested: {
        if (suspended or (focus_history.count > 0 and focus_history.entries[0] == identity)) break :requested false;
        const window = windows.items[windowIndex(identity) orelse break :requested false];
        const slot = displayIndex(window.display) orelse break :requested false;
        if (!externallyEligible(window) or window.workspace == displays.items[slot].workspace) break :requested false;
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
        const taker = &windows.items[windowIndex(identity).?];
        taker.urgent = true;
        const decision = ruleDecision(&taker.observation);
        if (decision.focus_on_activate orelse config.focus_on_activate) {
            _ = jumpToWindow(identity, activeDisplay());
        } else if (previous) |holder_identity| if (windowIndex(holder_identity)) |holder_index| {
            const holder = windows.items[holder_index];
            if (visible(holder) and !holder.parked and native.platform_focus(holder.identity)) {
                focused = previous;
                return;
            }
        };
    }
    const window = windows.items[windowIndex(identity) orelse return];
    rememberFocus(identity);
    if (displayIndex(window.display) != null) selectDisplay(window.display);
}
fn ruleDecision(observation: *const native.WMWindow) rules.Decision {
    return rules.resolve(config.rules[0..config.rule_count], .{ .bundle = text(&observation.bundle), .title = text(&observation.title), .title_complete = observation.title_complete });
}
fn displayBlocked(identity: u32) bool {
    for (windows.items) |window| if (window.display == identity and window.observation.fullscreen) return true;
    return false;
}
fn displayArea(identity: u32) Rect {
    return inset(displays.items[displayIndex(identity).?].frame, config.gap);
}
fn inset(frame: Rect, gap: f64) Rect {
    const padding = @min(gap, @max(0, (@min(frame.width, frame.height) - 1) / 2));
    return .{ .left = frame.left + padding, .top = frame.top + padding, .width = frame.width - 2 * padding, .height = frame.height - 2 * padding };
}
fn boundedFloating(frame: Rect, area: Rect) Rect {
    var bounded = frame;
    bounded.width = @min(frame.width, area.width);
    bounded.height = @min(frame.height, area.height);
    // The sum is taken last, so rounding cannot put the upper bound below the lower one.
    bounded.left = std.math.clamp(frame.left, area.left, area.left + (area.width - bounded.width));
    bounded.top = std.math.clamp(frame.top, area.top, area.top + (area.height - bounded.height));
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
    window.placed = null;
    window.floating_frame = boundedFloating(window.parking_frame, displayArea(window.display));
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
            const lone = &windows.items[indices[0]];
            lone.goal = area;
            if (config.single_window_max_width > 0) {
                lone.goal.width = @min(area.width, @max(config.single_window_max_width, lone.bounds.minimumAt(.width)));
                lone.goal.left += (area.width - lone.goal.width) / 2;
            }
            continue;
        }
        if (workspace.layout == .master) {
            const columns = tiling.split(area, .width, workspace.ratio, config.gap, masterSides(indices[0..count]));
            windows.items[indices[0]].goal = columns[0];
            const rows: f64 = @floatFromInt(count - 1);
            const spacing = @min(config.gap, columns[1].height / (2 * rows));
            const height = (columns[1].height - spacing * (rows - 1)) / rows;
            var bound_height: [1024]?f64 = @splat(null);
            var share = height;
            var required = spacing * (rows - 1);
            for (indices[1..count]) |index| required += rowMinimum(windows.items[index]);
            var extra: f64 = 0;
            if (required <= columns[1].height) {
                var remaining = columns[1].height - spacing * (rows - 1);
                var unbound = count - 1;
                var settled = false;
                while (!settled) {
                    settled = true;
                    for (indices[1..count], bound_height[1..count]) |index, *fixed| if (fixed.* == null) {
                        const minimum = rowMinimum(windows.items[index]);
                        const ceiling_height: ?f64 = if (windows.items[index].bounds.ceilingAt(.height)) |ceiling| if (ceiling.binds(share)) @max(minimum, ceiling.accepted) else null else null;
                        if (minimum > share) {
                            fixed.* = minimum;
                        } else if (ceiling_height) |capped| {
                            fixed.* = capped;
                        } else continue;
                        remaining -= fixed.*.?;
                        unbound -= 1;
                        settled = false;
                    };
                    if (!settled and unbound > 0) share = remaining / @as(f64, @floatFromInt(unbound));
                }
                if (unbound == 0 and remaining > 0) extra = remaining / rows;
            }
            var shift: f64 = 0;
            for (indices[1..count], bound_height[1..count], 0..) |index, fixed, row| {
                var frame = columns[1];
                frame.top += @as(f64, @floatFromInt(row)) * (share + spacing) + shift;
                frame.height = if (fixed) |resolved| resolved + extra else share;
                shift += frame.height - share;
                windows.items[index].goal = frame;
            }
        } else for (indices[0..count]) |index| {
            if (layouts.goal(windows.items[index].identity)) |frame| windows.items[index].goal = frame;
        }
    }
    return true;
}
fn rowMinimum(window: Window) f64 {
    return @max(tiling.minimum_tile_extent, window.bounds.minimumAt(.height));
}
fn masterSides(indices: []const usize) [2]tiling.Side {
    var minimums: [2]f64 = @splat(tiling.minimum_tile_extent);
    for (indices, 0..) |index, ordinal| {
        const slot: usize = if (ordinal == 0) 0 else 1;
        minimums[slot] = @max(minimums[slot], windows.items[index].bounds.minimumAt(.width));
    }
    var stack_ceiling = windows.items[indices[1]].bounds.ceilingAt(.width);
    for (indices[2..]) |index| stack_ceiling = tiling.combineAcross(stack_ceiling, windows.items[index].bounds.ceilingAt(.width));
    return .{
        .{ .minimum = minimums[0], .compact = minimums[0], .ceiling = windows.items[indices[0]].bounds.ceilingAt(.width) },
        .{ .minimum = minimums[1], .compact = minimums[1], .ceiling = stack_ceiling },
    };
}
fn framesNear(first: Rect, second: Rect, tolerance: f64) bool {
    return @abs(first.left - second.left) <= tolerance and @abs(first.top - second.top) <= tolerance and @abs(first.width - second.width) <= tolerance and @abs(first.height - second.height) <= tolerance;
}
fn placementFailure(window: *Window, message: []const u8) void {
    const repeated = if (window.placement_error) |previous| std.mem.eql(u8, previous, message) else false;
    window.placement_error = message;
    transition_error = message;
    journaled_transition = message;
    if (repeated) return;
    if (journaling()) {
        var actual: Rect = undefined;
        const readable = native.platform_read_frame(window.identity, &actual);
        _ = journal("placement", .{ .window = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .message = message, .workspace = window.workspace + 1, .display = window.display, .goal = window.goal, .target = targetFrame(window.*), .actual = if (readable) actual else null });
    }
    var buffer: [256:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(&buffer, "Window {d}: {s}", .{ window.identity, message }) catch return;
    native.platform_error(&buffer);
}
fn journaling() bool {
    return native.platform_filter()[0] == 0;
}
fn journal(event: []const u8, fields: anytype) bool {
    if (!journaling()) return false;
    var buffer: [4096]u8 = undefined;
    const line = journalLine(&buffer, event, fields) catch return false;
    if (session.huen_journal_append(line.ptr, line.len)) return true;
    if (!journal_failed) native.platform_error("Journal append failed; later failures are not reported");
    journal_failed = true;
    return false;
}
fn journalLine(buffer: []u8, event: []const u8, fields: anytype) ![]const u8 {
    var clock: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &clock);
    var writer: std.Io.Writer = .fixed(buffer);
    var stream: std.json.Stringify = .{ .writer = &writer };
    try stream.beginObject();
    try stream.objectField("at");
    try stream.write(clock.sec);
    try stream.objectField("event");
    try stream.write(event);
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
        try stream.objectField(name);
        try stream.write(@field(fields, name));
    }
    try stream.endObject();
    try writer.writeByte('\n');
    return writer.buffered();
}
fn journalTransition() void {
    const message = transition_error orelse return;
    if (journaled_transition) |previous| if (std.mem.eql(u8, previous, message)) return;
    journaled_transition = message;
    _ = journal("transition", .{ .message = message });
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
fn verifiedFrame(identity: u64, target: Rect, parkedDisplay: ?u32, actual: *Rect) bool {
    _ = native.platform_frame(identity, target, 0, .verified_placement);
    if (!native.platform_read_frame(identity, actual)) return false;
    return if (parkedDisplay) |displayIdentity| parkedFrameAccepted(actual.*, target, displayIdentity) else framesNear(actual.*, target, 2);
}
// A refusal carries the frame the application accepted instead.
const PlacementOutcome = union(enum) { applied, rolled_back: Rect, recovery_required: Rect, unreadable, no_corner };
fn attemptVisibility(window: *Window, target: Rect, parked: bool) PlacementOutcome {
    var original: Rect = undefined;
    if (!native.platform_read_frame(window.identity, &original)) return .unreadable;
    const previouslyParked = window.parked;
    if (!previouslyParked) window.parking_frame = original;
    // A failed AX write can still move the window. Own it before the first write.
    window.parked = true;
    if (parked and !previouslyParked) saveParkingJournal(&.{});
    var accepted = target;
    if (verifiedFrame(window.identity, target, if (parked) window.display else null, &accepted)) {
        window.parked = parked;
        window.parked_at = if (parked) native.platform_monotonic() else null;
        if (parked) window.placed = null;
        window.placement_error = null;
        return .applied;
    }
    var restored = original;
    if (verifiedFrame(window.identity, original, null, &restored)) {
        window.parked = previouslyParked;
        return .{ .rolled_back = accepted };
    }
    window.parked_at = null;
    return .{ .recovery_required = accepted };
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
fn placeVisible(window: *Window) PlacementOutcome {
    const target = targetFrame(window.*);
    var outcome = attemptVisibility(window, target, false);
    const refusal: ?Rect = switch (outcome) {
        .rolled_back, .recovery_required => |accepted| accepted,
        else => null,
    };
    if (refusal) |accepted| if (!managedFullscreen(window.*)) {
        if (!window.floating) {
            if (outcome == .rolled_back and learnBounds(window, target, accepted)) outcome = attemptVisibility(window, targetFrame(window.*), false);
        } else if (@abs(accepted.width - target.width) > 2 or @abs(accepted.height - target.height) > 2) {
            // A floating window takes the size its application answered with, or the same refusal would repeat on every attempt.
            // An application that raised its minimum also refuses the rollback to the old size, so both refusals are retried.
            window.floating_frame.width = accepted.width;
            window.floating_frame.height = accepted.height;
            outcome = attemptVisibility(window, targetFrame(window.*), false);
        }
    };
    if (outcome == .applied and !window.floating and !managedFullscreen(window.*)) window.placed = .{ .frame = targetFrame(window.*), .at = native.platform_monotonic() };
    reportPlacementOutcome(window, outcome);
    return outcome;
}
// A learned bound can come from a size someone else set during placement, such as a native edge drag, and a minimum never
// lowers itself. A resize it blocks clears it, and placement learns it again if the application still refuses.
fn forgetWorkspaceBounds(display: u32, workspace: usize) bool {
    var forgot = false;
    for (windows.items) |*window| {
        if (window.display != display or window.workspace != workspace or window.floating) continue;
        if (std.meta.eql(window.bounds, size_bounds.Bounds{})) continue;
        window.bounds = .{};
        window.placed = null;
        forgot = true;
    }
    return forgot;
}
fn learnBounds(window: *Window, requested: Rect, accepted: Rect) bool {
    if (!window.established and native.platform_monotonic() - window.discovered < launch_grace) return false;
    const area = inset(displays.items[displayIndex(window.display) orelse return false].frame, config.gap);
    const previous = window.bounds;
    const next = previous.learn(.{ requested.width, requested.height }, .{ accepted.width, accepted.height }, .{ area.width, area.height });
    if (std.meta.eql(next, previous)) return false;
    window.bounds = next;
    if (deriveGoals() and for (windows.items) |other| {
        if (other.display != window.display or !visible(other) or other.floating or managedFullscreen(other)) continue;
        if (other.goal.width < other.bounds.minimumAt(.width) - 2 or other.goal.height < other.bounds.minimumAt(.height) - 2) break false;
    } else true) return true;
    window.bounds = previous;
    _ = deriveGoals();
    return false;
}
fn parkWindow(window: *Window) PlacementOutcome {
    if (window.escape == .exempt) return .applied;
    const outcome: PlacementOutcome = outcome: {
        var actual: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &actual)) break :outcome .unreadable;
        const area = displays.items[displayIndex(window.display) orelse break :outcome .no_corner].frame;
        // A parked window keeps the size its application gave it, so a corner is never written with a size the application refuses.
        if (window.parked) {
            window.parking_frame.width = actual.width;
            window.parking_frame.height = actual.height;
        }
        const candidates = parking.corners(actual, area);
        if (window.parked) for (candidates) |candidate| if (parkedFrameAccepted(actual, candidate, window.display)) {
            window.placement_error = null;
            return .applied;
        };
        // A frame that only touches the display is a parked strip that a Dock resize exposed.
        const horizontal = @min(actual.left + actual.width, area.left + area.width) - @max(actual.left, area.left);
        const vertical = @min(actual.top + actual.height, area.top + area.height) - @max(actual.top, area.top);
        if (window.parked and window.parked_at != null and horizontal > 3 and vertical > 3) {
            const now = native.platform_monotonic();
            if (now - topology_changed_at > 2) {
                window.escape = switch (window.escape) {
                    .escaped => |at| if (now - at <= 300) .exempt else .{ .escaped = now },
                    else => .{ .escaped = now },
                };
                // Only a park verified after this one can escape again, so one refusal is not counted twice.
                window.parked_at = null;
                if (window.escape == .exempt) {
                    window.parked = false;
                    placementFailure(window, "Application keeps moving its window back on screen; window is no longer parked");
                    return .applied;
                }
            }
        }
        var attempted: PlacementOutcome = .no_corner;
        for (candidates) |candidate| {
            if (overlapsOtherDisplays(candidate, window.display)) continue;
            attempted = attemptVisibility(window, candidate, true);
            if (attempted != .rolled_back) break;
        }
        break :outcome attempted;
    };
    reportPlacementOutcome(window, outcome);
    return outcome;
}
fn reconcile() void {
    if (suspended or transition != null or displays.items.len == 0 or routing_blocked) return;
    if (!deriveGoals()) return;
    var passes: usize = 0;
    while (true) : (passes += 1) {
        const relayout = place: {
            for (windows.items) |*window| {
                if (visible(window.*) and !window.floating and !managedFullscreen(window.*) and (window.goal.width < tiling.minimum_tile_extent or window.goal.height < tiling.minimum_tile_extent)) {
                    window.floating = true;
                    window.placed = null;
                    window.floating_frame = if (window.parked) window.parking_frame else window.observation.frame;
                    window.goal = window.floating_frame;
                    placementFailure(window, "Tile too crowded; window left floating");
                }
            }
            const now = native.platform_monotonic();
            for (windows.items) |*window| {
                if (!externallyEligible(window.*) or displayBlocked(window.display)) continue;
                if (!visible(window.*)) {
                    _ = parkWindow(window);
                    continue;
                }
                const target = targetFrame(window.*);
                if (window.parked) {
                    const outcome = placeVisible(window);
                    if (outcome == .rolled_back or outcome == .recovery_required) floatRejectedTile(window);
                    continue;
                }
                settle: {
                    if (window.floating or managedFullscreen(window.*)) break :settle;
                    const placed = if (window.placed) |*active| active else break :settle;
                    if (!framesNear(target, placed.frame, size_bounds.tolerance) or now - placed.at > snap_back_window) {
                        window.placed = null;
                        break :settle;
                    }
                    if (now < placed.at or window.observation.motion != .idle) break :settle;
                    const observed = window.observation.frame;
                    if (@abs(observed.width - placed.frame.width) <= size_bounds.tolerance and @abs(observed.height - placed.frame.height) <= size_bounds.tolerance) {
                        placed.snap_candidate = null;
                        break :settle;
                    }
                    if (placed.snap_candidate) |previous| if (@abs(observed.width - previous.width) <= size_bounds.tolerance and @abs(observed.height - previous.height) <= size_bounds.tolerance) {
                        const requested = placed.frame;
                        window.placed = null;
                        if (learnBounds(window, requested, observed)) break :place true;
                        break :settle;
                    };
                    placed.snap_candidate = observed;
                    native.platform_config_changed();
                    continue;
                }
                const duration = if (window.floating_restore and !managedFullscreen(window.*)) 0 else config.duration;
                const needs_write = !framesNear(window.observation.frame, target, size_bounds.tolerance);
                var accepted: Rect = window.observation.frame;
                if (native.platform_frame(window.identity, target, duration, .visible_goal) and (duration != 0 or (native.platform_read_frame(window.identity, &accepted) and framesNear(accepted, target, 2)))) {
                    if (!window.floating and !managedFullscreen(window.*) and needs_write) window.placed = .{ .frame = target, .at = now + duration };
                    continue;
                }
                if (managedFullscreen(window.*)) {
                    floatRejectedTile(window);
                    continue;
                }
                if (!native.platform_read_frame(window.identity, &accepted)) accepted = window.observation.frame;
                if (!window.floating and learnBounds(window, target, accepted)) break :place true;
                if (now - window.discovered < launch_grace) continue;
                const tiled = !window.floating;
                window.floating = true;
                window.placed = null;
                window.floating_restore = false;
                window.floating_frame = accepted;
                placementFailure(window, "Application rejected layout geometry; window left floating");
                if (tiled) break :place true;
            }
            break :place false;
        };
        if (!relayout or passes == windows.items.len) break;
        if (!deriveGoals()) return;
    }
    var borderIdentity: u64 = 0;
    var borderWidth = config.border_width;
    var borderColor = config.border_color;
    if (focused) |identity| if (windowIndex(identity)) |index| {
        const window = windows.items[index];
        // Border actions resolve against the current title, so a reload or a title change applies without rediscovery.
        const decision = ruleDecision(&window.observation);
        borderWidth = decision.border_width orelse borderWidth;
        borderColor = decision.border_color orelse borderColor;
        if (visible(window) and !window.parked and (decision.border orelse (config.border_single_window or for (windows.items) |other| {
            if (other.identity != window.identity and other.display == window.display and other.workspace == window.workspace and visible(other)) break true;
        } else false))) borderIdentity = identity;
    };
    native.platform_border(borderIdentity, borderWidth, borderColor);
    saveParkingJournal(&.{});
}
fn reportParkingJournal(message: []const u8, err: anyerror) void {
    var buffer: [256:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ message, @errorName(err) }) catch return;
    native.platform_error(&buffer);
}
fn writeParkingJournal(records: []const parking.Record) void {
    parking_journal.save(allocator, std.mem.span(native.platform_filter()), records) catch |err| {
        if (!parking_journal_failed) reportParkingJournal("Parking journal save failed", err);
        parking_journal_failed = true;
        return;
    };
    parking_journal_failed = false;
}
// A corner that touches another display is never used, so a window there is not a parked one.
fn parkingRecord(window: *const Window) ?parking.Record {
    const display = displays.items[displayIndex(window.display) orelse return null];
    var corners = parking.corners(window.parking_frame, display.frame);
    const blocked = [2]bool{ overlapsOtherDisplays(corners[0], window.display), overlapsOtherDisplays(corners[1], window.display) };
    if (blocked[0] and blocked[1]) return null;
    if (blocked[0]) corners[0] = corners[1];
    if (blocked[1]) corners[1] = corners[0];
    const record: parking.Record = .{ .bundle = text(&window.observation.bundle), .pid = window.observation.pid, .token = window.observation.process_token, .original = window.parking_frame, .corners = corners };
    return if (parking.valid(record)) record else null;
}
fn orphanRecord(lost: *const Orphan) parking.Record {
    return .{ .bundle = text(&lost.bundle), .pid = lost.pid, .token = lost.token, .original = lost.original, .corners = lost.corners };
}
fn orphanOf(record: parking.Record, since: f64) Orphan {
    var result: Orphan = .{ .bundle = @splat(0), .pid = record.pid, .token = record.token, .original = record.original, .corners = record.corners, .since = since };
    @memcpy(result.bundle[0..record.bundle.len], record.bundle);
    return result;
}
// `prior` is the window state a rollback is about to return to. A window that the transaction showed goes back to its corner.
fn saveParkingJournal(prior: []const Window) void {
    var records: [parking.max_records]parking.Record = undefined;
    var count: usize = 0;
    for (windows.items) |*window| if ((window.parked or window.vanished_parked) and count < records.len) if (parkingRecord(window)) |record| {
        records[count] = record;
        count += 1;
    };
    for (prior) |*window| {
        if (!window.parked or count == records.len) continue;
        if (windowIndex(window.identity)) |index| if (windows.items[index].parked) continue;
        records[count] = parkingRecord(window) orelse continue;
        count += 1;
    }
    for (orphans.items) |*lost| if (count < records.len) {
        records[count] = orphanRecord(lost);
        count += 1;
    };
    writeParkingJournal(records[0..count]);
}
// After a verified restore only the orphans can still sit at a corner.
fn settleParkingJournal() void {
    var records: [256]parking.Record = undefined;
    for (orphans.items, records[0..orphans.items.len]) |*lost, *record| record.* = orphanRecord(lost);
    writeParkingJournal(records[0..orphans.items.len]);
}
// The display layout may have changed since the crash, so the frame is bounded to the display it overlaps most.
fn recoveryFrame(frame: Rect) Rect {
    var largest: f64 = 0;
    var area = displays.items[0].frame;
    for (displays.items) |display| {
        const bounds = display.full_bounds;
        const width = @min(frame.left + frame.width, bounds.left + bounds.width) - @max(frame.left, bounds.left);
        const height = @min(frame.top + frame.height, bounds.top + bounds.height) - @max(frame.top, bounds.top);
        if (width > 0 and height > 0 and width * height > largest) {
            largest = width * height;
            area = display.frame;
        }
    }
    return boundedFloating(frame, area);
}
const replacement_grace = 0.5;
fn replaces(ghost: Window, successor: Window) bool {
    const vanished = ghost.vanished orelse return false;
    return successor.vanished == null and successor.observation.pid == ghost.observation.pid and @abs(successor.discovered - vanished) <= replacement_grace and framesNear(successor.discovered_frame, ghost.observation.frame, 4);
}
fn placementEntry(window: Window, frame: Rect, expires: f64) ?memory.Entry {
    if (window.observation.bundle[0] == 0) return null;
    var entry: memory.Entry = .{ .bundle = window.observation.bundle, .floating = window.floating, .floating_frame = window.floating_frame, .frame = frame, .expires = expires };
    const name = text(&config.workspaces[window.workspace].name);
    @memcpy(entry.workspace[0..name.len], name);
    return entry;
}
fn processExited(process: memory.Process) bool {
    return native.platform_process_token(process.pid) != process.token;
}
fn writePlacements(entries: []const memory.Entry) void {
    const hash = memory.scopeHash(std.mem.span(native.platform_filter()));
    const encoded = memory.encode(allocator, entries) catch return native.platform_error("Placement memory: out of memory");
    defer allocator.free(encoded);
    if (!session.huen_session_write("placements", &hash, encoded.ptr, encoded.len, true)) native.platform_error("Placement memory: file write failed");
}
// After restoration each window is where a restarted manager will discover it.
fn persistPlacements() void {
    if (!config.placement_memory) return;
    const now = native.platform_monotonic();
    var persisted = placement_memory;
    persisted.prune(now);
    // An entry whose application still runs is for a closed window, so the next manager must not hand it out.
    persisted.settle(now, processExited);
    persisted.dropPending();
    for (windows.items) |window| {
        var frame: Rect = undefined;
        if (window.vanished == null and native.platform_read_frame(window.identity, &frame)) persisted.remember(placementEntry(window, frame, now) orelse continue);
    }
    writePlacements(persisted.entries[0..persisted.count]);
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
    defer journalTransition();
    var observedDisplays: [32]native.WMDisplay = undefined;
    const displayCount = native.platform_displays(&observedDisplays, observedDisplays.len);
    var updated: [monitor.capacity]Display = undefined;
    var topology_changed = displayCount != displays.items.len;
    for (&placements, 0..) |*placement, workspace| if (placement.display) |identity| if (displayIndex(identity)) |index| {
        placement.shown = displays.items[index].workspace == workspace;
    };
    for (observedDisplays[0..displayCount], updated[0..displayCount]) |observation, *display| {
        const previous: ?Display = if (displayIndex(observation.identity)) |index| displays.items[index] else null;
        if (previous == null or !std.meta.eql(previous.?.full_bounds, observation.full_bounds) or !std.meta.eql(previous.?.frame, observation.frame) or previous.?.built_in != observation.built_in) topology_changed = true;
        display.* = .{ .identity = observation.identity, .frame = observation.frame, .full_bounds = observation.full_bounds, .name = observation.name, .built_in = observation.built_in, .workspace = if (previous) |known| known.workspace else 0, .previous_workspace = if (previous) |known| known.previous_workspace else null };
    }
    if (topology_changed) {
        if (displays.items.len != 0) topology_changed_at = native.platform_monotonic();
        generation += 1;
        cancelTransition();
        workspace_shortcuts.clearRetainingCapacity();
    }
    displays.clearRetainingCapacity();
    displays.appendSliceAssumeCapacity(updated[0..displayCount]);
    if (displays.items.len == 0) return;
    if (!placement_memory_loaded and config.placement_memory) load: {
        const hash = memory.scopeHash(std.mem.span(native.platform_filter()));
        const bytes = allocator.alloc(u8, memory.max_bytes) catch {
            native.platform_error("Placement memory: out of memory");
            break :load;
        };
        defer allocator.free(bytes);
        var used: usize = 0;
        switch (session.huen_session_read("placements", &hash, bytes.ptr, bytes.len, &used)) {
            0 => memory.decode(allocator, bytes[0..used], native.platform_monotonic() + 60, &placement_memory) catch native.platform_error("Placement memory: file rejected"),
            1 => break :load,
            else => {
                native.platform_error("Placement memory: file unreadable");
                break :load;
            },
        }
        writePlacements(&.{});
    }
    placement_memory_loaded = true;
    if (placement_memory.count > 0) placement_memory.settle(native.platform_monotonic(), processExited);
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_windows(&observed, observed.len);
    var recovered: [1024]parking.Recovery = undefined;
    const first_scan = parking_recovery == null;
    // Patches the observations with the readback so discovery assigns each window to the display it is on now.
    // The first scan matches the journal of the previous process. Later scans match the orphans against windows not seen before.
    const recoveries = if (!first_scan and orphans.items.len == 0) recovered[0..0] else recover: {
        var outcome: ParkingRecovery = parking_recovery orelse .{};
        defer parking_recovery = outcome;
        var records: [parking.max_records]parking.Record = undefined;
        var since: [parking.max_records]f64 = undefined;
        const now = native.platform_monotonic();
        var record_count: usize = 0;
        var loaded: ?std.json.Parsed(parking.Journal) = null;
        defer if (loaded) |*parsed| parsed.deinit();
        if (first_scan) {
            loaded = parking.load(allocator, std.mem.span(native.platform_filter())) catch |err| {
                reportParkingJournal("Parking journal rejected", err);
                break :recover recovered[0..0];
            };
            if (loaded) |parsed| {
                record_count = parsed.value.records.len;
                @memcpy(records[0..record_count], parsed.value.records);
                @memset(since[0..record_count], now);
                outcome.records = record_count;
            }
        } else for (orphans.items) |*lost| {
            records[record_count] = orphanRecord(lost);
            since[record_count] = lost.since;
            record_count += 1;
        }
        if (record_count == 0) break :recover recovered[0..0];
        var eligible: [1024]bool = undefined;
        for (observed[0..count], eligible[0..count]) |observation, *open| open.* = windowIndex(observation.identity) == null;
        var claimed: [parking.max_records]bool = @splat(false);
        const matches = parking.match(records[0..record_count], observed[0..count], eligible[0..count], claimed[0..record_count], &recovered);
        // An unmatched record stays for up to a minute while its application runs, because a scan can miss an application that does not answer.
        var kept: [256]Orphan = undefined;
        var kept_count: usize = 0;
        for (records[0..record_count], claimed[0..record_count], since[0..record_count]) |record, used, lost_at| {
            if (used or kept_count == kept.len or now - lost_at > orphan_lifetime or processExited(.{ .pid = record.pid, .token = record.token })) continue;
            kept[kept_count] = orphanOf(record, lost_at);
            kept_count += 1;
        }
        orphans.clearRetainingCapacity();
        orphans.appendSliceAssumeCapacity(kept[0..kept_count]);
        for (matches) |*recovery| {
            const window = &observed[recovery.index];
            recovery.original = recoveryFrame(recovery.original);
            var actual = window.frame;
            if (native.platform_adopt_original(window.identity, recovery.original, &actual)) outcome.recovered += 1 else outcome.failed += 1;
            window.frame = actual;
        }
        if (matches.len > 0) native.platform_config_changed();
        break :recover matches;
    };
    var observed_focus: ?u64 = null;
    for (observed[0..count]) |observation| {
        if (observation.focused) observed_focus = observation.identity;
        if (windowIndex(observation.identity)) |index| {
            var window = &windows.items[index];
            window.observation = observation;
            if (window.vanished != null) {
                window.vanished = null;
                window.parked = window.vanished_parked;
                window.vanished_parked = false;
            }
            if (displayIndex(window.display) != null and transition == null and window.floating and !managedFullscreen(window.*) and !window.parked and !observation.stale and observation.motion == .idle) {
                if (window.floating_restore) {
                    if (framesNear(observation.frame, window.floating_frame, 2)) window.floating_restore = false;
                } else window.floating_frame = observation.frame;
            }
            continue;
        }
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
        var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = joined, .parking_frame = observation.frame, .floating_frame = observation.frame, .goal = observation.frame, .discovered_frame = observation.frame };
        const decision = ruleDecision(&observation);
        window.floating = decision.floating orelse false;
        if (decision.workspace) |workspace| window.workspace = workspace;
        if (window.floating and (decision.geometry != null or decision.centered)) {
            const destination = resolvePlacements()[window.workspace] orelse display;
            const area = displayArea(destination);
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
        // A recovered window stays owned even when it did not reach its frame or shares it with another window of its application.
        for (recoveries) |recovery| if (observed[recovery.index].identity == observation.identity) {
            window.parked = true;
            window.parking_frame = recovery.original;
        };
        window.discovered = native.platform_monotonic();
        // A window the first scan finds predates the manager, but its application may have launched only moments before.
        window.established = first_scan and age: {
            if (observation.process_token == 0) break :age false;
            // The token is a launch date in seconds since 2001.
            var clock: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &clock);
            break :age @as(f64, @floatFromInt(clock.sec)) - 978307200 - observation.process_token > 5;
        };
        if (config.placement_memory and decision.workspace == null) claim: {
            const entry = placement_memory.claim(text(&window.observation.bundle), window.observation.frame, window.discovered) orelse break :claim;
            const workspace = config.workspaceIndex(text(&entry.workspace)) orelse break :claim;
            placement_claims += 1;
            window.workspace = workspace;
            if (decision.floating == null) window.floating = entry.floating;
            if (!window.floating or decision.geometry != null or decision.centered) break :claim;
            const destination = resolvePlacements()[workspace] orelse display;
            window.floating_frame = boundedFloating(entry.floating_frame, displayArea(destination));
            window.floating_restore = true;
        }
        windows.appendAssumeCapacity(window);
    }
    var now: ?f64 = null;
    for (windows.items) |*window| {
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
    while (index < windows.items.len) {
        const vanished = windows.items[index].vanished orelse {
            index += 1;
            continue;
        };
        const successor_index = search: {
            var found: ?usize = null;
            for (windows.items, 0..) |candidate, candidate_index| if (replaces(windows.items[index], candidate)) {
                if (found != null) break :search null;
                found = candidate_index;
            };
            const successor = windows.items[found orelse break :search null];
            for (windows.items, 0..) |other, other_index| if (other_index != index and replaces(other, successor)) break :search null;
            break :search found;
        };
        // The successor takes the ghost's slot because the master layout orders its stack by slot.
        if (successor_index) |successor_slot| {
            const ghost = windows.items[index];
            var successor = windows.items[successor_slot];
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
                successor.parking_frame = recoveryFrame(ghost.parking_frame);
                successor.parked = true;
                var actual = successor.observation.frame;
                _ = native.platform_adopt_original(successor.identity, successor.parking_frame, &actual);
                successor.observation.frame = actual;
            }
            layouts.replaceIdentity(ghost.identity, successor.identity);
            focus_history.rename(ghost.identity, successor.identity);
            if (last_observed_focus == ghost.identity) last_observed_focus = successor.identity;
            windows.items[index] = successor;
            _ = windows.orderedRemove(successor_slot);
            continue;
        }
        if (now == null) now = native.platform_monotonic();
        if (now.? - vanished > replacement_grace) {
            // The window can still sit at its corner, as when its application stops being a regular application.
            if (windows.items[index].vanished_parked) if (parkingRecord(&windows.items[index])) |record| {
                if (orphans.items.len == orphans.capacity) _ = orphans.orderedRemove(0);
                orphans.appendAssumeCapacity(orphanOf(record, now.?));
            };
            // An application can take seconds to exit after its windows close, so the entry waits for `settle` to see the exit.
            const gone = windows.items[index];
            if (config.placement_memory and gone.observation.process_token != 0) if (placementEntry(gone, gone.observation.frame, now.? + 30)) |entry| {
                var owned = entry;
                owned.owner = .{ .process = .{ .pid = gone.observation.pid, .token = gone.observation.process_token }, .since = now.? };
                placement_memory.remember(owned);
            };
            layouts.forgetIdentity(windows.items[index].identity);
            focus_history.forget(windows.items[index].identity);
            _ = windows.orderedRemove(index);
        } else index += 1;
    }
    if (!session_loaded) load: {
        session_loaded = true;
        if (!config.session.enabled) break :load;
        var loaded = session.load(allocator, sessionScope());
        defer if (loaded.parsed) |*parsed| parsed.deinit();
        session_status.load = switch (loaded.diagnostic) {
            .none => .none,
            .ready => .pending,
            .rejected => .rejected,
        };
        if (loaded.rejection) |rejection| sessionError(@tagName(rejection));
        const checkpoint = if (loaded.parsed) |*parsed| &parsed.value else break :load;
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
    observeFocus(observed_focus, true);
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
    for (windows.items, 0..) |candidate, index| {
        if (index == sourceIndex or !visible(candidate) or candidate.parked) continue;
        const forward, const cross = offsets(&windows.items[sourceIndex], &candidate, direction);
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
            layouts.reveal(state, identity) catch |err| {
                transition_error = transaction.abort(err);
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
    if (focus_target orelse layouts.focusCandidate(state, layoutMembers(&members))) |identity| layouts.reveal(state, identity) catch |err| {
        transition_error = transaction.abort(err);
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
    defer journalTransition();
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
        if (!route(resolved, &.{.{ .display = owner, .workspace = workspace }}, null)) return failure(transition_error orelse "MonitorRoutingFailed");
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
fn jumpToWindow(identity: u64, display_slot: usize) [*:0]const u8 {
    const window = windows.items[windowIndex(identity).?];
    if (config.workspace_monitors != null) return showWorkspace(window.workspace, currentWorkspace(display_slot), identity);
    const slot = displayIndex(window.display).?;
    if (window.workspace != displays.items[slot].workspace) return switchWorkspace(slot, window.workspace, displays.items[slot].workspace, identity);
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
        _ = journal("error", .{ .message = "Hotkey not delivered; ran it from the key press" });
        if (now - hotkey_recovery.rebound >= 5) {
            hotkey_recovery.rebound = now;
            hotkey_recovery.rebinds += 1;
            if (!native.platform_rebind()) {
                native.platform_error("Hotkey re-registration failed");
                _ = journal("error", .{ .message = "Hotkey re-registration failed" });
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
    if (!initialized or !config.swipe.enabled) return;
    swipe_recognizer.fingers = config.swipe.fingers;
    const step = swipe_recognizer.sample(fingers, horizontal, vertical, native.platform_monotonic()) orelse return;
    if (suspended or transition != null or native.platform_pointer_buttons()) return;
    var point: native.WMPoint = undefined;
    if (native.platform_pointer(&point)) for (displays.items) |display| {
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
    if (suspended or displays.items.len == 0 or transition != null) return;
    defer publishStatus();
    defer publishPointer();
    defer journalTransition();
    var remaining = workspace_shortcuts.items;
    while (remaining.len != 0) {
        observeCommandState();
        const slot = activeDisplay();
        var view = workspaceView(slot);
        const from = view.current;
        const owners = resolvePlacements();
        var destination: ?u32 = null;
        while (remaining.len != 0) {
            const target = selector.resolve(remaining[0], view) catch {
                remaining = remaining[1..];
                continue;
            };
            const owner = owners[target] orelse displays.items[slot].identity;
            if (destination != null and destination != owner) break;
            destination = owner;
            if (target != view.current) view.previous = view.current;
            view.current = target;
            view.back_and_forth = config.workspace_back_and_forth;
            remaining = remaining[1..];
        }
        if (destination != null) _ = if (config.workspace_monitors != null) showWorkspace(view.current, from, null) else switchWorkspace(slot, view.current, from, null);
    }
}
export fn wm_hotkey(commandText: [*:0]const u8) void {
    const command = parseCommand(std.mem.span(commandText), config.workspace_count) catch return;
    if (command != .workspace or suspended or transition != null or displays.items.len == 0 or (config.duration != 0 and native.huen_scene_capture_allowed())) {
        _ = wm_command(commandText);
        return;
    }
    if (workspace_shortcuts.items.len == workspace_shortcuts.capacity) placeShortcuts();
    workspace_shortcuts.appendAssumeCapacity(command.workspace);
}
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    defer publishStatus();
    defer publishPointer();
    defer journalTransition();
    const command = parseCommand(std.mem.span(commandText), config.workspace_count) catch |err| return failure(@errorName(err));
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
                .hotkeys = .{ .watchdog = if (native.huen_observe_active()) "active" else "unavailable", .missed = hotkey_recovery.missed, .rebinds = hotkey_recovery.rebinds },
                .mouse = .{ .availability = interaction.huen_input_status(), .generation = pointer_controls.generation, .err_message = pointer_controls.error_message, .forced_stop = pointer_controls.forced_stop },
                .session = session_status,
                .parking_recovery = parking_recovery,
                .placement_memory = .{ .entries = if (placement_memory.count == 0) 0 else unexpired: {
                    placement_memory.prune(native.platform_monotonic());
                    break :unexpired placement_memory.count;
                }, .claimed = placement_claims },
                .config_reload = .{ .request_id = config_generation, .state = config_state, .err_message = config_error },
            });
        },
        .mode => |name| {
            const index = config.modeIndex(name.text()) orelse return failure("UnknownMode");
            const mode = &config.modes[index];
            if (!native.platform_bindings(&mode.bindings, mode.binding_count)) return failure("HotkeyCollision");
            hotkey_watch.forgetPresses();
            active_mode = index;
            return json(.{ .ok = true, .active_mode = text(&mode.name) });
        },
        .launch => |request| {
            if (suspended) return failure("RuntimeSuspendedRestartToResume");
            const request_id = native.platform_launch(request.bundle.text(), request.new_instance, request.hidden);
            if (request_id == 0) return failure("ApplicationNotFound");
            return json(.{ .ok = true, .accepted = true, .request_id = request_id });
        },
        .wrong => |note| {
            if (!journaling()) return failure("JournalDisabledByFilter");
            var length = @min(note.len, 200);
            while (length < note.len and note[length] & 0xc0 == 0x80) length -= 1;
            const Shown = struct { display: u32, workspace: ?usize };
            var shown: [monitor.capacity]Shown = undefined;
            for (displays.items, shown[0..displays.items.len]) |display, *item| item.* = .{ .display = display.identity, .workspace = if (placedWorkspace(display)) |workspace| workspace + 1 else null };
            var parked: usize = 0;
            for (windows.items) |window| parked += @intFromBool(window.parked);
            if (!journal("mark", .{ .note = note[0..length], .window_count = windows.items.len, .parked_count = parked, .workspaces = shown[0..displays.items.len], .transition_error = transition_error })) return failure("JournalAppendFailed");
            return json(.{ .ok = true });
        },
        .exec_and_forget => |shell| {
            if (suspended) return failure("RuntimeSuspendedRestartToResume");
            var terminated: [512:0]u8 = @splat(0);
            @memcpy(terminated[0..shell.len], shell);
            if (!native.platform_exec(&terminated)) return failure("ProcessLaunchFailed");
            return json(.{ .ok = true, .accepted = true });
        },
        .windows => {
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, urgent: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, managed_fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8, group_hidden: bool, parking_exempt: bool, minimum: struct { width: f64, height: f64 }, maximum: struct { width: ?f64, height: ?f64 } };
            var items: [1024]Item = undefined;
            for (windows.items, items[0..windows.items.len]) |*window, *item| item.* = .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focused == window.identity, .urgent = window.urgent, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .managed_fullscreen = managedFullscreen(window.*), .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error, .group_hidden = !window.floating and layouts.visibility(window.identity) == .hidden_by_group, .parking_exempt = window.escape == .exempt, .minimum = .{ .width = window.bounds.minimumAt(.width), .height = window.bounds.minimumAt(.height) }, .maximum = .{ .width = if (window.bounds.ceilingAt(.width)) |ceiling| ceiling.accepted else null, .height = if (window.bounds.ceilingAt(.height)) |ceiling| ceiling.accepted else null } };
            return json(items[0..windows.items.len]);
        },
        .monitors => {
            const Item = struct { id: u32, uuid: ?[]const u8, name: []const u8, frame: Rect, full_bounds: Rect, built_in: bool, workspace: ?usize, selected: bool, blocked_by_fullscreen: bool };
            var items: [monitor.capacity]Item = undefined;
            var uuids: [monitor.capacity][64]u8 = undefined;
            const count = displays.items.len;
            for (displays.items, uuids[0..count], items[0..count]) |*display, *uuid, *item| {
                uuid.* = @splat(0);
                const known = session.huen_session_display_uuid(display.identity, uuid, uuid.len);
                const placed = placedWorkspace(display.*);
                item.* = .{ .id = display.identity, .uuid = if (known) text(uuid) else null, .name = text(&display.name), .frame = display.frame, .full_bounds = display.full_bounds, .built_in = display.built_in, .workspace = if (placed) |workspace| workspace + 1 else null, .selected = selected_display == display.identity, .blocked_by_fullscreen = displayBlocked(display.identity) };
            }
            return json(items[0..count]);
        },
        .workspaces => {
            const Item = struct { display: u32, index: usize, name: []const u8, active: bool, urgent: bool, layout: Layout };
            var items: [monitor.capacity * 10]Item = undefined;
            var count: usize = 0;
            for (displays.items) |display| for (config.workspaces[0..config.workspace_count], 0..) |*workspace, index| {
                if (config.workspace_monitors != null and placements[index].display != display.identity) continue;
                const layout = if (layouts.lookup(display.identity, index)) |state| state.layout else workspace.layout;
                const urgent = for (windows.items) |window| {
                    if (window.urgent and window.display == display.identity and window.workspace == index) break true;
                } else false;
                items[count] = .{ .display = display.identity, .index = index + 1, .name = text(&workspace.name), .active = display.workspace == index, .urgent = urgent, .layout = layout };
                count += 1;
            };
            return json(items[0..count]);
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
        .quit, .restore => {
            if (command == .restore and pending_close != null) close_state = .cancelled;
            pending_close = null;
            native.platform_close_cancel();
            cancelConfig();
            cancelTransition();
            if (command == .quit) {
                native.platform_quit();
                return json(.{ .ok = true });
            }
            freezeSession();
            suspended = true;
            const outstanding = native.platform_restore();
            persistPlacements();
            if (outstanding == 0) {
                saveSession(true);
                settleParkingJournal();
            }
            native.platform_border(0, 0, 0);
            if (outstanding != 0) return json(.{ .@"error" = true, .err_message = "Geometry restoration incomplete. Retry restore after unminimizing or leaving fullscreen.", .outstanding = outstanding, .suspended = true });
            return json(.{ .ok = true, .suspended = true, .note = "Restored live-session geometry. Restart to resume tiling." });
        },
        else => {},
    }
    if (suspended) return failure("RuntimeSuspendedRestartToResume");
    if (transition != null) return failure("WorkspaceTransitionPending");
    if (displays.items.len == 0) return failure("NoDisplays");
    observeCommandState();
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
            // Each moved workspace's runtime home becomes its destination display, which shows it.
            var forced: [2]Activation = .{ .{ .display = target, .workspace = workspace }, undefined };
            var count: usize = 1;
            if (command == .swap_monitor_workspaces) {
                const target_workspace = displays.items[displayIndex(target).?].workspace;
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
                const fallback: ?usize = if (global_previous != null and resolved[global_previous.?] == vacated) global_previous else for (0..config.workspace_count) |candidate| {
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
                return failure(transition_error orelse "MonitorRoutingFailed");
            }
            focusWorkspace(target, null);
            native.platform_config_changed();
            return json(.{ .ok = true, .monitor = target, .verified = selected_display == target, .focused = focused });
        },
        .cycle => |request| {
            var identities: [1024]u64 = undefined;
            const target = selector.cycleTarget(readingOrder(display.identity, request.kind, &identities), focused, request.step) orelse return failure("NoWindowToCycle");
            return json(.{ .ok = true, .accepted = true, .verified = focusVerified(target), .target = target });
        },
        .focus_last, .focus_urgent => {
            const urgent: ?u64 = if (command == .focus_urgent) for (windows.items) |window| {
                if (window.urgent and focusable(window.identity)) break window.identity;
            } else null else null;
            return jumpToWindow(urgent orelse focus_history.pick(focused, focusable) orelse return failure("NoPreviousWindow"), displaySlot);
        },
        .move_app => |request| {
            const resolved = resolvePlacements();
            const workspace = resolveWorkspace(request.workspace, displaySlot) catch |err| return failure(@errorName(err));
            var identities: [1024]u64 = undefined;
            var count: usize = 0;
            for (windows.items) |window| if (window.vanished == null and std.mem.eql(u8, text(&window.observation.bundle), request.bundle.text())) {
                identities[count] = window.identity;
                count += 1;
            };
            var moved: usize = 0;
            var first_error: ?[]const u8 = null;
            for (identities[0..count]) |identity| {
                const index = windowIndex(identity) orelse continue;
                const window = windows.items[index];
                const destination = resolved[workspace] orelse window.display;
                if (workspace == window.workspace and destination == window.display) continue;
                if (route(resolved, &.{}, .{ .index = index, .display = destination, .workspace = workspace })) moved += 1 else if (first_error == null) {
                    first_error = transition_error orelse "MonitorRoutingFailed";
                }
            }
            if (focused) |identity| if (windowIndex(identity)) |index| if (!visible(windows.items[index])) {
                focused = null;
            };
            if (moved > 0) native.platform_config_changed();
            if (first_error) |message| return json(.{ .@"error" = true, .err_message = message, .moved = moved });
            return json(.{ .ok = true, .moved = moved });
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
                    const edited: anyerror!?u64 = switch (command) {
                        .tilemove => |direction| if (layouts.tilemove(state, source.identity, direction)) null else |err| err,
                        .group => |action| layouts.editGroup(state, source.identity, action),
                        else => unreachable,
                    };
                    const target = edited catch |err| return failure(transaction.abort(err));
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
                    const identity = source.identity;
                    const before = source.goal;
                    var applied = resizeTiled(sourceIndex, resize.axis, resize.delta) catch |err| return failure(@errorName(err));
                    const retried = @abs(resize.delta - applied) > size_bounds.tolerance and forgetWorkspaceBounds(source.display, source.workspace);
                    if (retried) {
                        if (!deriveGoals()) return failure(transition_error orelse "LayoutProjectionFailed");
                        _ = resizeTiled(sourceIndex, resize.axis, resize.delta - applied) catch |err| return failure(@errorName(err));
                    }
                    reconcile();
                    // Placement learns a bound again when the application still refuses, so only the placed goal shows the change.
                    if (retried) if (windowIndex(identity)) |index| {
                        const after = windows.items[index].goal;
                        applied = if (resize.axis == .width) after.width - before.width else after.height - before.height;
                    };
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
                    const area = displayArea(source.display);
                    var frame = source.floating_frame;
                    frame.width = std.math.clamp(frame.width + offset.horizontal, 80, @max(80, area.left + area.width - frame.left));
                    frame.height = std.math.clamp(frame.height + offset.vertical, 80, @max(80, area.top + area.height - frame.top));
                    source.floating_frame = frame;
                },
                .center, .move_by => {
                    if (managedFullscreen(source.*)) return failure("ManagedFullscreenActive");
                    if (!source.floating) return failure("WindowNotFloating");
                    const area = displayArea(source.display);
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
                    if (source.floating) source.floating_restore = true else layouts.reveal(state, source.identity) catch |err| return failure(transaction.abort(err));
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
                        source.bounds = .{};
                        source.placed = null;
                    } else {
                        // Like Hyprland: return to the last floating frame, or float at `floating_size`, centered.
                        const area = displayArea(source.display);
                        const width = area.width * config.floating_size.width;
                        const height = area.height * config.floating_size.height;
                        var frame = boundedFloating(source.last_floating_frame orelse .{
                            .left = area.left + (area.width - width) / 2,
                            .top = area.top + (area.height - height) / 2,
                            .width = width,
                            .height = height,
                        }, area);
                        // Shifts the frame down and right by the same distance until its top-left corner is clear of every other floating window
                        // on the workspace, so windows floated at the same frame all stay visible. At the area's edge the cascade restarts from the top left.
                        const step = 32;
                        var attempts: usize = 0;
                        while (attempts < windows.items.len) : (attempts += 1) {
                            const taken = for (windows.items) |other| {
                                if (other.identity != source.identity and other.floating and !other.parked and other.display == source.display and other.workspace == source.workspace and visible(other) and @abs(other.floating_frame.left - frame.left) < step / 2 and @abs(other.floating_frame.top - frame.top) < step / 2) break true;
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
                    const workspace = resolveWorkspace(selection, if (config.workspace_monitors != null) displaySlot else displayIndex(source.display).?) catch |err| return failure(@errorName(err));
                    const destination = resolved[workspace] orelse source.display;
                    if (workspace == source.workspace and destination == source.display) return json(.{ .ok = true, .changed = false });
                    if (command == .send_to_workspace) {
                        if (!route(resolved, &.{}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return failure(transition_error orelse "MonitorRoutingFailed");
                        if (!visible(source.*)) focused = null;
                        native.platform_config_changed();
                        return json(.{ .ok = true });
                    }
                    const destination_slot = displayIndex(destination).?;
                    const from = currentWorkspace(if (config.workspace_monitors != null) displaySlot else destination_slot);
                    const identity = source.identity;
                    generation += 1;
                    snapshot_presentation = .instant;
                    if (!route(resolved, &.{.{ .display = destination, .workspace = workspace }}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return failure(transition_error orelse "MonitorRoutingFailed");
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
                    if (!route(resolved, &.{.{ .display = target, .workspace = workspace }}, .{ .index = sourceIndex, .display = target, .workspace = workspace })) return failure(transition_error orelse "MonitorRoutingFailed");
                    native.platform_config_changed();
                    if (command == .move_to_monitor) return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = focusVerified(source.identity), .target = source.identity });
                    // The selection stays, so keyboard focus returns to the selected display's candidate.
                    const selected = selected_display orelse origin;
                    focusWorkspace(selected, null);
                    return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = selected_display == selected, .focused = focused });
                },
                .focus => |request| {
                    const target = if (request.wrap) wrapped: {
                        var forward_target: ?usize = null;
                        var forward_score = std.math.inf(f64);
                        var wrap_target = sourceIndex;
                        var wrap_distance: f64 = 0;
                        var wrap_cross = std.math.inf(f64);
                        for (windows.items, 0..) |candidate, index| {
                            if (index == sourceIndex or !visible(candidate) or candidate.parked or candidate.display != source.display or candidate.workspace != source.workspace) continue;
                            const forward, const cross = offsets(source, &candidate, request.direction);
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
                    const target = selector.cycleTarget(readingOrder(source.display, .tiled, &identities), source.identity, step) orelse return failure("NoWindowToCycle");
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
    persistPlacements();
    saveSession(outstanding == 0);
    if (outstanding == 0) settleParkingJournal() else {
        native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
        _ = journal("error", .{ .message = "Shutdown left unrestored windows", .outstanding = outstanding });
    }
    native.platform_border(0, 0, 0);
    return true;
}
