const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const rules = @import("rules.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const pointer = @import("pointer.zig");
const interaction = @import("interaction.zig");
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
const Window = struct { identity: u64, observation: native.WMWindow, workspace: usize, display: u32, floating: bool = false, floating_restore: bool = false, parked: bool = false, parking_frame: Rect, floating_frame: Rect, goal: Rect, placement_error: ?[]const u8 = null };
const Display = struct { identity: u32, frame: Rect, full_bounds: Rect, name: [128]u8, built_in: bool, workspace: usize = 0 };
const Config = configuration.ConfigCandidate;
var config: Config = .{};
var layouts: tiling.Store = .{};
var windows: std.ArrayList(Window) = .empty;
var displays: std.ArrayList(Display) = .empty;
var focused: ?u64 = null;
var active_mode: usize = 0;
const PendingClose = struct { identity: u64, pid: c_int, process_token: f64, deadline: f64 };
var pending_close: ?PendingClose = null;
var close_state: enum { idle, pending, closed, termination_requested, termination_rejected, expired, cancelled } = .idle;
var selected_display: ?u32 = null;
var last_observed_focus: ?u64 = null;
var workspace_owner: ?u32 = null;
var owner_workspace: usize = 0;
var routing_blocked = false;
var reply_buffer: ?[:0]u8 = null;
var initialized = false;
var suspended = false;
const Transition = struct { display: u32, workspace: usize, generation: u64 };
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

fn stateForNode(reference_value: tiling.NodeRef) !*tiling.WorkspaceLayout {
    var handle = try layouts.resolve(reference_value);
    while (layouts.nodes[handle].parent) |parent| handle = parent;
    for (&layouts.roots) |*slot| if (slot.*) |*state| {
        if (state.root == handle) return state;
    };
    return error.StaleNode;
}

fn pollPointer() void {
    var sample: interaction.Event = undefined;
    var count: usize = 0;
    while (count < 64 and interaction.huen_input_poll(&sample)) : (count += 1) {
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
        const transaction = PlacementTransaction.begin() catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        defer transaction.deinit();
        var target: ?u64 = null;
        const result: anyerror!void = switch (edit) {
            .group => |selection| selection: {
                const state = stateForNode(selection.group) catch |err| break :selection err;
                target = layouts.selectGroupChild(state, selection.group, selection.child) catch |err| break :selection err;
                break :selection {};
            },
            .drop => |preview| drop: {
                const state = stateForNode(preview.source) catch |err| break :drop err;
                target = layouts.representative(preview.source) catch |err| break :drop err;
                break :drop layouts.commitDrop(state, preview);
            },
            .resize => |preview| layouts.commitResize(preview, config.gap),
        };
        result catch |err| {
            transaction.rollback(0);
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        if (!transaction.commit()) continue;
        if (target) |identity| {
            if (!focusVerified(identity)) pointer_controls.error_message = "HeaderFocusRejected";
        }
        native.platform_config_changed();
    }
}

export fn wm_input_poll() void {
    if (!initialized or suspended or pointer_controls.stop_deadline != null) return;
    pollPointer();
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

fn deriveStatus() StatusPresentation {
    if (!config.status_bar.enabled) return .disabled;
    var presentation = std.mem.zeroes(native.WMStatusPresentation);
    const display: ?Display = if (displays.items.len > 0) displays.items[activeDisplay()] else null;
    const workspace_index = if (display) |current| current.workspace else 0;
    const name = text(&config.workspaces[workspace_index].name);
    var index_buffer: [8]u8 = undefined;
    const index_text = std.fmt.bufPrint(&index_buffer, "{d}", .{workspace_index + 1}) catch unreachable;
    var label_buffer: [80]u8 = undefined;
    const label = if (suspended) "Paused" else if (display == null) "Huen WM" else switch (config.status_bar.label) {
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
        row.checked = display != null and workspace_index == index;
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
    return .{ .visible = .{ .display_identity = if (display) |current| current.identity else null, .content = presentation } };
}

fn publishStatus() void {
    if (!status_active) return;
    const next = deriveStatus();
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
        .failed => |err| {
            rejectConfig(@errorName(err));
            return;
        },
    };
    if (suspended) {
        rejectConfig("RuntimeSuspendedRestartToResume");
        return;
    }
    if (!native.platform_bindings(&candidate.modes[0].bindings, candidate.modes[0].binding_count)) {
        rejectConfig("HotkeyCollision");
        return;
    }
    applyLayoutDefaults(&candidate);
    config = candidate;
    pointer_controls.configure(config.mouse.enabled, config.mouse.modifiers);
    active_mode = 0;
    config_state = .ready;
    config_error = null;
    for (displays.items) |*display| display.workspace = @min(display.workspace, config.workspace_count - 1);
    for (windows.items) |*window| window.workspace = @min(window.workspace, config.workspace_count - 1);
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
    for (config.workspaces[0..config.workspace_count], 0..) |*previous, old_index| {
        for (candidate.workspaces[0..candidate.workspace_count], 0..) |*next, new_index| {
            if (!claimed[new_index] and std.mem.eql(u8, text(&previous.name), text(&next.name))) {
                remap[old_index] = new_index;
                claimed[new_index] = true;
                break;
            }
        }
    }
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
    for (displays.items) |*display| display.workspace = remap[display.workspace] orelse @min(display.workspace, candidate.workspace_count - 1);
    owner_workspace = remap[owner_workspace] orelse @min(owner_workspace, candidate.workspace_count - 1);
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
fn resizeMaster(source_index: usize, axis: commands.Axis, delta: f64) !f64 {
    if (axis != .width) return error.MasterHeightResizeUnsupported;
    const source = windows.items[source_index];
    var master: ?u64 = null;
    var count: usize = 0;
    for (windows.items) |window| {
        if (window.display != source.display or window.workspace != source.workspace or !visible(window) or window.floating) continue;
        if (master == null) master = window.identity;
        count += 1;
    }
    if (count < 2) return 0;
    const state = workspaceLayout(source.display, source.workspace);
    const display = displays.items[displayIndex(source.display) orelse return error.NoDisplays];
    const area = inset(display.frame, config.gap);
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
    if (!config.mouse_follows_monitor) return;
    const index = displayIndex(identity) orelse return;
    const bounds = displays.items[index].full_bounds;
    var point: native.WMPoint = undefined;
    if (!native.platform_pointer(&point)) return;
    if (point.left >= bounds.left and point.left < bounds.left + bounds.width and point.top >= bounds.top and point.top < bounds.top + bounds.height) return;
    if (!native.platform_warp_pointer(.{ .left = bounds.left + bounds.width / 2, .top = bounds.top + bounds.height / 2 })) native.platform_error("Mouse warp failed");
}

fn preferredOwner() ?u32 {
    const preferences = config.workspace_monitors orelse return null;
    for (preferences.order[0..preferences.count]) |preference| {
        var best: ?u32 = null;
        for (displays.items) |display| {
            if (display.built_in != (preference == .@"built-in")) continue;
            if (workspace_owner == display.identity) return display.identity;
            if (best == null or display.identity < best.?) best = display.identity;
        }
        if (best != null) return best;
    }
    if (workspace_owner) |identity| if (displayIndex(identity) != null) return identity;
    var fallback: ?u32 = null;
    for (displays.items) |display| if (fallback == null or display.identity < fallback.?) {
        fallback = display.identity;
    };
    return fallback;
}

const Routing = struct {
    const Activation = struct { display: u32, workspace: usize };
    owner: ?u32 = null,
    activate: ?Activation = null,
    send: ?struct { index: usize, display: u32, workspace: usize } = null,
};

fn ownerActivation(owner: ?u32) ?Routing.Activation {
    const destination = owner orelse return null;
    if (owner == workspace_owner) return null;
    const workspace = if (workspace_owner) |previous|
        if (displayIndex(previous)) |index| displays.items[index].workspace else @min(owner_workspace, config.workspace_count - 1)
    else
        displays.items[displayIndex(destination).?].workspace;
    return .{ .display = destination, .workspace = workspace };
}

const PlacementTransaction = struct {
    store: *tiling.Store,
    intent: []Window,
    screens: []Display,
    originals: []?Rect,
    selected: ?u32,

    fn begin() !PlacementTransaction {
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
            if (!externallyEligible(window)) continue;
            if (displayBlocked(window.display)) return error.NativeFullscreenBlocksPlacement;
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
            const restored = verifiedFrame(identity, original, null);
            if (!restored) {
                if (!self.intent[original_index].parked) self.intent[original_index].parking_frame = original;
                self.intent[original_index].parked = true;
                self.intent[original_index].placement_error = "Placement rollback rejected; recovery ownership retained";
            }
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
            self.rollback(index + 1);
            transition_error = "Placement rejected; reverse rollback attempted; inspect window recovery errors";
            return false;
        }
        transition_error = null;
        return true;
    }
};

fn commitRouting(request: Routing) bool {
    const transaction = PlacementTransaction.begin() catch |err| {
        transition_error = @errorName(err);
        return false;
    };
    defer transaction.deinit();
    const Placement = struct { original: ?Rect = null, destination: u32 };
    const placements = allocator.alloc(Placement, windows.items.len) catch return false;
    defer allocator.free(placements);
    if (request.activate) |activation| if (displayBlocked(activation.display)) {
        transition_error = "Native fullscreen window blocks routing destination";
        return false;
    };
    for (windows.items, 0..) |window, index| {
        const destination = if (request.send != null and request.send.?.index == index) request.send.?.display else request.owner orelse if (displayIndex(window.display) == null) displays.items[0].identity else window.display;
        placements[index] = .{ .destination = destination };
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
        placements[index].original = original;
    }
    for (&layouts.roots) |*slot| if (slot.*) |*state| {
        const destination = request.owner orelse if (displayIndex(state.display) == null) displays.items[0].identity else state.display;
        if (destination == state.display) continue;
        if (layouts.lookup(destination, state.workspace)) |existing| {
            const defaults = config.workspaces[state.workspace];
            const empty_default = existing.root == null and existing.fullscreen == null and existing.layout == defaults.layout and existing.ratio == defaults.ratio;
            if (empty_default) {
                existing.* = state.*;
                existing.display = destination;
                slot.* = null;
            } else {
                layouts.discard(state);
                slot.* = null;
            }
        } else state.display = destination;
    };
    if (request.activate) |activation| displays.items[displayIndex(activation.display).?].workspace = activation.workspace;
    for (windows.items, 0..) |*window, index| {
        const destination = placements[index].destination;
        if (request.send) |send| if (send.index == index) {
            window.workspace = send.workspace;
        };
        if (destination != window.display) {
            window.display = destination;
            const area = inset(displays.items[displayIndex(destination).?].frame, config.gap);
            window.floating_frame = boundedFloating(window.floating_frame, area);
            window.parking_frame = boundedFloating(window.parking_frame, area);
        }
    }
    if (request.send) |send| layouts.forgetIdentity(windows.items[send.index].identity);
    return transaction.commit();
}

fn routeMembership() bool {
    const owner = preferredOwner();
    var needed = owner != workspace_owner;
    for (windows.items) |window| {
        if (displayIndex(window.display) == null or (owner != null and window.display != owner.?)) needed = true;
    }
    for (layouts.roots) |slot| if (slot) |state| {
        const defaults = config.workspaces[state.workspace];
        const has_state = state.root != null or state.fullscreen != null or state.layout != defaults.layout or state.ratio != defaults.ratio;
        if (has_state and (displayIndex(state.display) == null or (owner != null and state.display != owner.?))) needed = true;
    };
    if (!needed) return true;
    const activation = ownerActivation(owner);
    if (!commitRouting(.{ .owner = owner, .activate = activation })) return false;
    workspace_owner = owner;
    if (activation) |active| owner_workspace = active.workspace;
    return true;
}
fn nearestDisplay(frame: Rect) u32 {
    var best: f64 = std.math.inf(f64);
    var identity = displays.items[0].identity;
    for (displays.items) |display| {
        const horizontal = frame.left + frame.width / 2 - display.frame.left - display.frame.width / 2;
        const vertical = frame.top + frame.height / 2 - display.frame.top - display.frame.height / 2;
        const distance = horizontal * horizontal + vertical * vertical;
        if (distance < best) {
            best = distance;
            identity = display.identity;
        }
    }
    return identity;
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
    const slot = displayIndex(window.display) orelse return;
    window.floating = true;
    window.floating_frame = boundedFloating(window.parking_frame, inset(displays.items[slot].frame, config.gap));
    placementFailure(window, "Application rejected tile; retrying with floating recovery geometry");
}

fn deriveGoals() bool {
    for (&layouts.roots) |*slot| if (slot.*) |*state| {
        if (displayIndex(state.display) == null) {
            layouts.discard(state);
            slot.* = null;
        }
    };
    for (displays.items) |display| {
        for (0..config.workspace_count) |workspace| _ = workspaceLayout(display.identity, workspace);
    }
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
        for (windows.items, 0..) |window, index| if (window.display == display.identity and visible(window) and !window.floating and count < indices.len) {
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
        } else {
            for (indices[0..count]) |index| {
                if (layouts.goal(windows.items[index].identity)) |frame| windows.items[index].goal = frame;
            }
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

fn parkingFrames(displayIdentity: u32, original: Rect) ?[2]Rect {
    const slot = displayIndex(displayIdentity) orelse return null;
    const area = displays.items[slot].frame;
    var candidate = original;
    candidate.top = area.top + area.height - 1;
    candidate.left = area.left + area.width - 1;
    const right = candidate;
    candidate.left = area.left + 1 - original.width;
    return .{ right, candidate };
}

fn parkedFrameAccepted(actual: Rect, target: Rect, displayIdentity: u32) bool {
    const slot = displayIndex(displayIdentity) orelse return false;
    const area = displays.items[slot].frame;
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
    var actual: Rect = std.mem.zeroes(Rect);
    const readable = native.platform_read_frame(identity, &actual);
    const verified = readable and
        (if (parkedDisplay) |displayIdentity|
            parkedFrameAccepted(actual, target, displayIdentity)
        else
            framesNear(actual, target, 2));
    return verified;
}

const PlacementOutcome = enum { applied, rolled_back, recovery_required, unreadable, no_corner };

fn attemptVisibility(window: *Window, target: Rect, parked: bool) PlacementOutcome {
    var original: Rect = undefined;
    if (!native.platform_read_frame(window.identity, &original)) {
        return .unreadable;
    }
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
    const candidates = parkingFrames(window.display, if (window.parked) window.parking_frame else actual) orelse {
        reportPlacementOutcome(window, .no_corner);
        return .no_corner;
    };
    if (window.parked) {
        for (candidates) |candidate| {
            if (parkedFrameAccepted(actual, candidate, window.display)) {
                window.placement_error = null;
                return .applied;
            }
        }
    }
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
        if (visible(window.*) and !window.floating and !managedFullscreen(window.*) and (window.goal.width < 80 or window.goal.height < 80)) {
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
        } else {
            const target = targetFrame(window.*);
            const actual = window.observation.frame;
            if (window.parked) {
                const outcome = placeVisibility(window, target, false);
                if (outcome == .rolled_back or outcome == .recovery_required) floatRejectedTile(window);
            } else {
                const duration = if (window.floating_restore and !managedFullscreen(window.*)) 0 else config.duration;
                const applied = native.platform_frame(window.identity, target, duration, .visible_goal);
                var accepted: Rect = actual;
                const rejected = !applied or (duration == 0 and (!native.platform_read_frame(window.identity, &accepted) or !framesNear(accepted, target, 2)));
                if (rejected) {
                    if (managedFullscreen(window.*)) {
                        floatRejectedTile(window);
                        continue;
                    }
                    window.floating = true;
                    window.floating_restore = false;
                    if (!native.platform_read_frame(window.identity, &accepted)) accepted = actual;
                    window.floating_frame = accepted;
                    placementFailure(window, "Application rejected layout geometry; window left floating");
                }
            }
        }
    }
    var borderIdentity: u64 = 0;
    if (focused) |identity| if (windowIndex(identity)) |index| {
        const window = windows.items[index];
        if (visible(window) and !window.parked) borderIdentity = identity;
    };
    native.platform_border(borderIdentity, config.border_width, config.border_color);
}
fn pollClose() void {
    const pending = pending_close orelse return;
    const observed = if (native.platform_monotonic() < pending.deadline) native.platform_close_state(pending.identity, pending.pid, pending.process_token) else -1;
    if (native.platform_monotonic() >= pending.deadline) {
        close_state = .expired;
    } else if (observed == 2) {
        close_state = if (native.platform_terminate_if_empty(pending.identity, pending.pid, pending.process_token)) .termination_requested else .termination_rejected;
    } else if (observed == 1) {
        close_state = .closed;
    } else return;
    pending_close = null;
    native.platform_close_cancel();
}

export fn wm_tick() void {
    pollClose();
    if (!initialized) return;
    defer publishStatus();
    defer publishPointer();
    var observedDisplays: [32]native.WMDisplay = undefined;
    const displayCount = native.platform_displays(&observedDisplays, observedDisplays.len);
    var updated: std.ArrayList(Display) = .empty;
    var topology_changed = displayCount != displays.items.len;
    if (workspace_owner) |identity| if (displayIndex(identity)) |index| {
        owner_workspace = displays.items[index].workspace;
    };
    for (observedDisplays[0..displayCount]) |observation| {
        const previous = displayIndex(observation.identity);
        if (previous) |index| {
            if (!std.meta.eql(displays.items[index].full_bounds, observation.full_bounds) or !std.meta.eql(displays.items[index].frame, observation.frame) or displays.items[index].built_in != observation.built_in) topology_changed = true;
        } else topology_changed = true;
        updated.append(allocator, .{ .identity = observation.identity, .frame = observation.frame, .full_bounds = observation.full_bounds, .name = observation.name, .built_in = observation.built_in, .workspace = if (previous) |index| displays.items[index].workspace else 0 }) catch {
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
            const display = nearestDisplay(observation.frame);
            const displaySlot = displayIndex(display).?;
            var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = displays.items[displaySlot].workspace, .parking_frame = observation.frame, .floating_frame = observation.frame, .goal = observation.frame };
            const decision = rules.resolve(config.rules[0..config.rule_count], .{ .bundle = text(&observation.bundle), .title = text(&observation.title), .title_complete = observation.title_complete });
            window.floating = decision.floating orelse false;
            if (decision.workspace) |workspace| window.workspace = workspace;
            if (window.floating) {
                if (decision.geometry) |geometry| {
                    const destination = preferredOwner() orelse display;
                    const area = inset(displays.items[displayIndex(destination).?].frame, config.gap);
                    window.floating_frame = boundedFloating(.{ .left = area.left + geometry.left, .top = area.top + geometry.top, .width = geometry.width, .height = geometry.height }, area);
                    window.floating_restore = true;
                }
            }
            windows.append(allocator, window) catch return;
        }
    }
    var index: usize = 0;
    while (index < windows.items.len) {
        var found = false;
        for (observed[0..count]) |observation| if (observation.identity == windows.items[index].identity) {
            found = true;
            break;
        };
        if (!found) {
            layouts.forgetIdentity(windows.items[index].identity);
            _ = windows.orderedRemove(index);
        } else index += 1;
    }
    routing_blocked = if (!suspended and transition == null) !routeMembership() else routing_blocked;
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
    reconcile();
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

fn wrappedNeighbor(source_index: usize, direction: Direction) usize {
    const source = windows.items[source_index];
    const source_frame = if (source.floating) source.floating_frame else source.goal;
    var forward_target: ?usize = null;
    var forward_score = std.math.inf(f64);
    var wrap_target = source_index;
    var wrap_distance: f64 = 0;
    var wrap_cross = std.math.inf(f64);
    for (windows.items, 0..) |candidate, index| {
        if (index == source_index or !visible(candidate) or candidate.parked or candidate.display != source.display or candidate.workspace != source.workspace) continue;
        const frame = if (candidate.floating) candidate.floating_frame else candidate.goal;
        const horizontal = frame.left + frame.width / 2 - source_frame.left - source_frame.width / 2;
        const vertical = frame.top + frame.height / 2 - source_frame.top - source_frame.height / 2;
        const forward = switch (direction) {
            .left => -horizontal,
            .right => horizontal,
            .up => -vertical,
            .down => vertical,
        };
        const cross = switch (direction) {
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
    return forward_target orelse wrap_target;
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

fn focusWorkspace(displayIdentity: u32) void {
    refreshObservations();
    if (!deriveGoals()) return;
    const index = displayIndex(displayIdentity) orelse return;
    const state = workspaceLayout(displayIdentity, displays.items[index].workspace);
    var members: [1024]tiling.Member = undefined;
    const target = layouts.focusCandidate(state, layoutMembers(&members));
    if (target) |identity| {
        const window = windows.items[windowIndex(identity) orelse return];
        if (!visible(window) or window.parked) {
            const transaction = PlacementTransaction.begin() catch |err| {
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

fn commitWorkspace(displaySlot: usize, workspace: usize) bool {
    const displayIdentity = displays.items[displaySlot].identity;
    if (displayBlocked(displayIdentity)) {
        transition_error = "Native fullscreen window blocks this display";
        return false;
    }
    const transaction = PlacementTransaction.begin() catch |err| {
        transition_error = @errorName(err);
        return false;
    };
    defer transaction.deinit();
    displays.items[displaySlot].workspace = workspace;
    var members: [1024]tiling.Member = undefined;
    const state = workspaceLayout(displayIdentity, workspace);
    if (layouts.focusCandidate(state, layoutMembers(&members))) |identity| {
        if (layouts.nodeForIdentity(identity) != null) layouts.reveal(state, identity) catch |err| {
            transaction.rollback(0);
            transition_error = @errorName(err);
            return false;
        };
    }
    if (!transaction.commit()) return false;
    if (workspace_owner == displayIdentity) owner_workspace = workspace;
    focusWorkspace(displayIdentity);
    transition_error = null;
    native.platform_config_changed();
    return true;
}

fn sceneReady(context: ?*anyopaque, covered: bool) callconv(.c) void {
    const callbackGeneration = @intFromPtr(context orelse return);
    const pending = transition orelse return;
    if (callbackGeneration != pending.generation) return;
    defer publishStatus();
    snapshot_presentation = if (covered) .captured else .fallback;
    const slot = displayIndex(pending.display);
    if (slot) |displaySlot| {
        _ = commitWorkspace(displaySlot, pending.workspace);
    } else transition_error = "Display disconnected during workspace capture";
    transition = null;
    if (covered) native.huen_scene_finish(pending.generation);
}
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    defer publishStatus();
    defer publishPointer();
    const command = parseCommand(std.mem.span(commandText), config.workspace_count) catch |err| return failure(@errorName(err));
    switch (command) {
        .status => {
            const launch = native.platform_launch_status();
            return json(.{
                .running = true,
                .suspended = suspended,
                .active_mode = text(&config.modes[active_mode].name),
                .close_state = close_state,
                .launch = .{ .request_id = launch.request_id, .state = launch.state, .message = text(&launch.message) },
                .window_count = windows.items.len,
                .display_count = displays.items.len,
                .selected_monitor = selected_display,
                .workspace_owner = workspace_owner,
                .routing_blocked = routing_blocked,
                .workspace_backend = "corner-parking",
                .filter = std.mem.span(native.platform_filter()),
                .scene_capture_allowed = native.huen_scene_capture_allowed(),
                .snapshot_presentation = snapshot_presentation,
                .snapshot_generation = generation,
                .transition_pending = transition != null,
                .transition_error = transition_error,
                .mouse = .{ .availability = interaction.huen_input_status(), .generation = pointer_controls.generation, .err_message = pointer_controls.error_message, .forced_stop = pointer_controls.forced_stop },
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
            const request_id = native.platform_launch(request.bundle.text(), request.new_instance);
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
            const Item = struct { id: u32, name: []const u8, frame: Rect, full_bounds: Rect, built_in: bool, workspace: usize, blocked_by_fullscreen: bool };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (displays.items) |*display| items.append(allocator, .{ .id = display.identity, .name = text(&display.name), .frame = display.frame, .full_bounds = display.full_bounds, .built_in = display.built_in, .workspace = display.workspace + 1, .blocked_by_fullscreen = displayBlocked(display.identity) }) catch return failure("OutOfMemory");
            return json(items.items);
        },
        .workspaces => {
            const Item = struct { display: u32, index: usize, name: []const u8, active: bool, layout: Layout };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (displays.items) |display| {
                if (config.workspace_monitors != null and workspace_owner != display.identity) continue;
                for (config.workspaces[0..config.workspace_count], 0..) |*workspace, index| {
                    const layout = if (layouts.lookup(display.identity, index)) |state| state.layout else workspace.layout;
                    items.append(allocator, .{ .display = display.identity, .index = index + 1, .name = text(&workspace.name), .active = display.workspace == index, .layout = layout }) catch return failure("OutOfMemory");
                }
            }
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
            suspended = true;
            const outstanding = native.platform_restore();
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
    const displaySlot = activeDisplay();
    const display = &displays.items[displaySlot];
    switch (command) {
        .workspace => |workspace| {
            var destination_slot = displaySlot;
            if (config.workspace_monitors != null) {
                const owner = preferredOwner() orelse return failure("NoWorkspaceOwner");
                var migration = workspace_owner != owner;
                for (windows.items) |window| if (window.display != owner) {
                    migration = true;
                };
                if (migration) {
                    generation += 1;
                    snapshot_presentation = .instant;
                    if (!commitRouting(.{ .owner = owner, .activate = .{ .display = owner, .workspace = workspace } })) return failure(transition_error orelse "MonitorRoutingFailed");
                    workspace_owner = owner;
                    owner_workspace = workspace;
                    routing_blocked = false;
                    focusWorkspace(owner);
                    native.platform_config_changed();
                    return json(.{ .ok = true });
                }
                if (!routeMembership()) {
                    routing_blocked = true;
                    return failure(transition_error orelse "MonitorRoutingFailed");
                }
                routing_blocked = false;
                destination_slot = displayIndex(owner).?;
            }
            const destination = displays.items[destination_slot];
            if (workspace == destination.workspace) {
                focusWorkspace(destination.identity);
                return json(.{ .ok = true });
            }
            generation += 1;
            if (config.duration == 0 or !native.huen_scene_capture_allowed()) {
                snapshot_presentation = .instant;
                if (!commitWorkspace(destination_slot, workspace)) return failure(transition_error orelse "WorkspacePlacementFailed");
                return json(.{ .ok = true });
            }
            snapshot_presentation = .pending;
            transition = .{ .display = destination.identity, .workspace = workspace, .generation = generation };
            native.huen_scene_begin(destination.identity, generation, config.duration, sceneReady, @ptrFromInt(generation));
            return json(.{ .ok = true, .accepted = true, .generation = generation });
        },
        .layout => |layout| {
            const transaction = PlacementTransaction.begin() catch |err| return failure(@errorName(err));
            defer transaction.deinit();
            workspaceLayout(display.identity, display.workspace).layout = layout;
            if (!transaction.commit()) return failure(transition_error orelse "LayoutPlacementFailed");
            native.platform_config_changed();
            return json(.{ .ok = true });
        },
        .resize => |delta| layouts.adjustRatio(workspaceLayout(display.identity, display.workspace), delta),
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
                    const transaction = PlacementTransaction.begin() catch |err| return failure(@errorName(err));
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
                    const state = workspaceLayout(source.display, source.workspace);
                    const applied = if (state.layout == .dwindle)
                        layouts.resizePoints(source.identity, resize.axis, resize.delta, config.gap) catch |err| return failure(@errorName(err))
                    else
                        resizeMaster(sourceIndex, resize.axis, resize.delta) catch |err| return failure(@errorName(err));
                    reconcile();
                    native.platform_config_changed();
                    return json(.{ .ok = true, .applied_delta = applied });
                },
                .fullscreen => {
                    const transaction = PlacementTransaction.begin() catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    const state = workspaceLayout(source.display, source.workspace);
                    if (!source.floating) layouts.reveal(state, source.identity) catch |err| return failure(@errorName(err));
                    if (source.floating) source.floating_restore = true;
                    state.fullscreen = if (state.fullscreen == source.identity) null else source.identity;
                    if (!transaction.commit()) return failure(transition_error orelse "FullscreenPlacementFailed");
                    const verified = focusVerified(source.identity);
                    return json(.{ .ok = true, .verified = verified });
                },
                .close => |quit_if_last| {
                    if (pending_close != null) return failure("ClosePending");
                    const window = windows.items[sourceIndex];
                    var process_token: f64 = 0;
                    if (!native.platform_close(window.identity, quit_if_last, &process_token)) return failure("CloseRejected");
                    if (quit_if_last) {
                        pending_close = .{ .identity = window.identity, .pid = window.observation.pid, .process_token = process_token, .deadline = native.platform_monotonic() + 5 };
                        close_state = .pending;
                    }
                    return json(.{ .ok = true, .accepted = true });
                },
                .toggle_floating => {
                    if (managedFullscreen(source.*)) return failure("ManagedFullscreenActive");
                    var window = &windows.items[sourceIndex];
                    window.floating = !window.floating;
                    window.floating_frame = window.observation.frame;
                },
                .send_to_workspace => |workspace| {
                    const owner = preferredOwner();
                    const destination = owner orelse windows.items[sourceIndex].display;
                    const activation = ownerActivation(owner);
                    if (!commitRouting(.{ .owner = owner, .activate = activation, .send = .{ .index = sourceIndex, .display = destination, .workspace = workspace } })) return failure(transition_error orelse "MonitorRoutingFailed");
                    workspace_owner = owner;
                    if (activation) |active| owner_workspace = active.workspace;
                    routing_blocked = false;
                    if (!visible(windows.items[sourceIndex])) focused = null;
                    native.platform_config_changed();
                    return json(.{ .ok = true });
                },
                .focus => |request| {
                    const target = if (request.wrap) wrappedNeighbor(sourceIndex, request.direction) else neighbor(sourceIndex, request.direction) orelse return failure("NoWindowInDirection");
                    const identity = windows.items[target].identity;
                    const verified = focusVerified(identity);
                    return json(.{ .ok = true, .accepted = true, .verified = verified, .target = identity });
                },
                .swap => |direction| {
                    const target = neighbor(sourceIndex, direction) orelse return failure("NoWindowInDirection");
                    const identity = source.identity;
                    const transaction = PlacementTransaction.begin() catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    layouts.swap(windows.items[sourceIndex].identity, windows.items[target].identity);
                    if (managedFullscreen(windows.items[sourceIndex])) workspaceLayout(windows.items[sourceIndex].display, windows.items[sourceIndex].workspace).fullscreen = null;
                    if (managedFullscreen(windows.items[target])) workspaceLayout(windows.items[target].display, windows.items[target].workspace).fullscreen = null;
                    const sourceDisplay = windows.items[sourceIndex].display;
                    const sourceWorkspace = windows.items[sourceIndex].workspace;
                    windows.items[sourceIndex].display = windows.items[target].display;
                    windows.items[sourceIndex].workspace = windows.items[target].workspace;
                    windows.items[target].display = sourceDisplay;
                    windows.items[target].workspace = sourceWorkspace;
                    std.mem.swap(Window, &windows.items[sourceIndex], &windows.items[target]);
                    if (!transaction.commit()) return failure(transition_error orelse "SwapPlacementFailed");
                    const verified = focusVerified(identity);
                    return json(.{ .ok = true, .verified = verified });
                },
                .move => |direction| {
                    if (managedFullscreen(source.*)) return failure("ManagedFullscreenActive");
                    var window = &windows.items[sourceIndex];
                    if (!window.floating) {
                        if (!native.platform_read_frame(window.identity, &window.floating_frame)) return failure("WindowGeometryUnavailable");
                    }
                    window.floating = true;
                    var frame = window.floating_frame;
                    switch (direction) {
                        .left => frame.left -= 40,
                        .right => frame.left += 40,
                        .up => frame.top -= 40,
                        .down => frame.top += 40,
                    }
                    window.floating_frame = frame;
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
    suspended = true;
    pending_close = null;
    native.platform_close_cancel();
    status_active = false;
    native.platform_status_present(null);
    cancelConfig();
    if (config_request.inFlight()) return false;
    if (!pointer_controls.stop(native.platform_monotonic())) return false;
    cancelTransition();
    const outstanding = native.platform_restore();
    if (outstanding != 0) native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
    native.platform_border(0, 0, 0);
    return true;
}
