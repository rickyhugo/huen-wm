const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
const Window = struct { identity: u64, observation: native.WMWindow, workspace: usize, display: u32, floating: bool = false, floating_restore: bool = false, parked: bool = false, parking_frame: Rect, floating_frame: Rect, goal: Rect, placement_error: ?[]const u8 = null };
const Display = struct { identity: u32, frame: Rect, full_bounds: Rect, name: [128]u8, workspace: usize = 0 };
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
    active_mode = 0;
    config_state = .ready;
    config_error = null;
    for (displays.items) |*display| display.workspace = @min(display.workspace, config.workspace_count - 1);
    for (windows.items) |*window| window.workspace = @min(window.workspace, config.workspace_count - 1);
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
    if (focused) |identity| if (windowIndex(identity)) |index| if (displayIndex(windows.items[index].display)) |display| return display;
    return 0;
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
    const index = displayIndex(window.display) orelse return false;
    return window.workspace == displays.items[index].workspace and !window.observation.minimized and !window.observation.fullscreen and !window.observation.stale and (window.observation.onscreen or window.parked);
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
    var member_count: usize = 0;
    for (windows.items) |window| {
        const display = displays.items[displayIndex(window.display) orelse continue];
        members[member_count] = .{
            .identity = window.identity,
            .display = window.display,
            .workspace = window.workspace,
            .tiled = !window.floating,
            .active = !window.observation.minimized and !window.observation.fullscreen and !window.observation.stale and (window.observation.onscreen or window.parked),
            .area = inset(display.frame, config.gap),
        };
        member_count += 1;
    }
    layouts.sync(members[0..member_count], focused, config.gap) catch |err| {
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
    if (suspended or transition != null or displays.items.len == 0) return;
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
    var observedDisplays: [32]native.WMDisplay = undefined;
    const displayCount = native.platform_displays(&observedDisplays, observedDisplays.len);
    var updated: std.ArrayList(Display) = .empty;
    for (observedDisplays[0..displayCount]) |observation| {
        const previous = displayIndex(observation.identity);
        updated.append(allocator, .{ .identity = observation.identity, .frame = observation.frame, .full_bounds = observation.full_bounds, .name = observation.name, .workspace = if (previous) |index| displays.items[index].workspace else 0 }) catch return;
    }
    displays.deinit(allocator);
    displays = updated;
    if (displays.items.len == 0) return;
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_windows(&observed, observed.len);
    focused = null;
    for (observed[0..count]) |observation| {
        if (observation.focused) focused = observation.identity;
        if (windowIndex(observation.identity)) |index| {
            var window = &windows.items[index];
            window.observation = observation;
            if (displayIndex(window.display) == null) {
                window.display = displays.items[0].identity;
                window.workspace = displays.items[0].workspace;
                const area = inset(displays.items[0].frame, config.gap);
                window.floating_frame = boundedFloating(window.floating_frame, area);
                window.parking_frame = boundedFloating(window.parking_frame, area);
                if (!suspended and transition == null and window.floating and !window.parked and observation.onscreen) _ = placeVisibility(window, window.floating_frame, false);
            } else if (transition == null and window.floating and !managedFullscreen(window.*) and !window.parked and !observation.stale) {
                if (window.floating_restore) {
                    if (framesNear(observation.frame, window.floating_frame, 2)) window.floating_restore = false;
                } else window.floating_frame = observation.frame;
            }
        } else {
            if (windows.items.len == 1024) continue;
            const display = nearestDisplay(observation.frame);
            const displaySlot = displayIndex(display).?;
            var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = displays.items[displaySlot].workspace, .parking_frame = observation.frame, .floating_frame = observation.frame, .goal = observation.frame };
            for (config.rules[0..config.rule_count]) |rule| if (std.mem.eql(u8, text(&rule.bundle), text(&observation.bundle))) {
                window.floating = rule.floating;
                if (rule.workspace) |workspace| window.workspace = workspace;
            };
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
        if (!found) _ = windows.orderedRemove(index) else index += 1;
    }
    reconcile();
}
fn neighbor(sourceIndex: usize, direction: Direction) ?usize {
    const source = windows.items[sourceIndex];
    const sourceFrame = if (source.floating) source.floating_frame else source.goal;
    var best: f64 = std.math.inf(f64);
    var result: ?usize = null;
    for (windows.items, 0..) |candidate, index| {
        if (index == sourceIndex or !visible(candidate)) continue;
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
        if (index == source_index or !visible(candidate) or candidate.display != source.display or candidate.workspace != source.workspace) continue;
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

fn commitWorkspace(displaySlot: usize, workspace: usize) bool {
    const previousWorkspace = displays.items[displaySlot].workspace;
    const displayIdentity = displays.items[displaySlot].identity;
    if (displayBlocked(displayIdentity)) {
        transition_error = "Native fullscreen window blocks this display";
        return false;
    }
    const Placement = struct { index: usize, original: Rect, target: Rect, parked: bool, previously_parked: bool, parking_frame: Rect };
    var placements: [1024]Placement = undefined;
    var count: usize = 0;
    displays.items[displaySlot].workspace = workspace;
    if (!deriveGoals()) {
        displays.items[displaySlot].workspace = previousWorkspace;
        _ = deriveGoals();
        return false;
    }
    for (windows.items, 0..) |window, index| {
        if (window.display != displayIdentity or window.observation.minimized or window.observation.fullscreen) continue;
        if (!window.observation.onscreen and !window.parked) continue;
        if (window.observation.stale or count == placements.len) {
            displays.items[displaySlot].workspace = previousWorkspace;
            _ = deriveGoals();
            placementFailure(&windows.items[index], "Workspace snapshot contains a stale or excess window");
            return false;
        }
        var original: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &original)) {
            displays.items[displaySlot].workspace = previousWorkspace;
            _ = deriveGoals();
            placementFailure(&windows.items[index], "Workspace geometry could not be read");
            return false;
        }
        const parked = window.workspace != workspace;
        const target = targetFrame(window);
        placements[count] = .{ .index = index, .original = original, .target = target, .parked = parked, .previously_parked = window.parked, .parking_frame = window.parking_frame };
        count += 1;
    }
    for (placements[0..count], 0..) |placement, position| {
        const outcome = if (placement.parked)
            parkWindow(&windows.items[placement.index])
        else
            placeVisibility(&windows.items[placement.index], placement.target, false);
        if (outcome != .applied) {
            for (placements[0..position]) |rollback| {
                var window = &windows.items[rollback.index];
                _ = placeVisibility(window, rollback.original, rollback.previously_parked);
                if (rollback.previously_parked) window.parking_frame = rollback.parking_frame;
            }
            if (!placement.parked and outcome != .unreadable) floatRejectedTile(&windows.items[placement.index]);
            displays.items[displaySlot].workspace = previousWorkspace;
            _ = deriveGoals();
            transition_error = "Workspace placement rejected. Rollback attempted; inspect per-window errors and retry restore if needed.";
            return false;
        }
    }
    const winner = workspaceLayout(displayIdentity, workspace).fullscreen;
    var focus_target: ?u64 = null;
    for (windows.items) |window| if (window.display == displayIdentity and visible(window)) {
        if (focus_target == null or winner == window.identity) focus_target = window.identity;
    };
    if (focus_target) |identity| _ = native.platform_focus(identity);
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
    const command = parseCommand(std.mem.span(commandText), config.workspace_count) catch |err| return failure(@errorName(err));
    switch (command) {
        .status => {
            const launch = native.platform_launch_status();
            return json(.{ .running = true, .suspended = suspended, .active_mode = text(&config.modes[active_mode].name), .close_state = close_state, .launch = .{ .request_id = launch.request_id, .state = launch.state, .message = text(&launch.message) }, .window_count = windows.items.len, .display_count = displays.items.len, .workspace_backend = "corner-parking", .filter = std.mem.span(native.platform_filter()), .scene_capture_allowed = native.huen_scene_capture_allowed(), .snapshot_presentation = snapshot_presentation, .snapshot_generation = generation, .transition_pending = transition != null, .transition_error = transition_error, .config_reload = .{ .request_id = config_generation, .state = config_state, .err_message = config_error } });
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
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, managed_fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8 };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (windows.items) |*window| items.append(allocator, .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focused == window.identity, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .managed_fullscreen = managedFullscreen(window.*), .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error }) catch return failure("OutOfMemory");
            return json(items.items);
        },
        .monitors => {
            const Item = struct { id: u32, name: []const u8, frame: Rect, full_bounds: Rect, workspace: usize, blocked_by_fullscreen: bool };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (displays.items) |*display| items.append(allocator, .{ .id = display.identity, .name = text(&display.name), .frame = display.frame, .full_bounds = display.full_bounds, .workspace = display.workspace + 1, .blocked_by_fullscreen = displayBlocked(display.identity) }) catch return failure("OutOfMemory");
            return json(items.items);
        },
        .workspaces => {
            const Item = struct { display: u32, index: usize, name: []const u8, active: bool, layout: Layout };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (displays.items) |display| for (config.workspaces[0..config.workspace_count], 0..) |*workspace, index| {
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
    const observed_focus = native.platform_focused_window();
    focused = if (observed_focus != 0) observed_focus else null;
    const displaySlot = activeDisplay();
    const display = &displays.items[displaySlot];
    switch (command) {
        .workspace => |workspace| {
            if (workspace == display.workspace) return json(.{ .ok = true });
            generation += 1;
            if (config.duration == 0 or !native.huen_scene_capture_allowed()) {
                snapshot_presentation = .instant;
                if (!commitWorkspace(displaySlot, workspace)) return failure(transition_error orelse "WorkspacePlacementFailed");
                return json(.{ .ok = true });
            }
            snapshot_presentation = .pending;
            transition = .{ .display = display.identity, .workspace = workspace, .generation = generation };
            native.huen_scene_begin(display.identity, generation, config.duration, sceneReady, @ptrFromInt(generation));
            return json(.{ .ok = true, .accepted = true, .generation = generation });
        },
        .layout => |layout| workspaceLayout(display.identity, display.workspace).layout = layout,
        .resize => |delta| layouts.adjustRatio(workspaceLayout(display.identity, display.workspace), delta),
        else => {
            const sourceIndex = windowIndex(focused orelse return failure("NoFocusedWindow")) orelse return failure("NoFocusedWindow");
            const source = &windows.items[sourceIndex];
            if (!visible(source.*)) return failure("FocusedWindowNotManaged");
            switch (command) {
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
                    const state = workspaceLayout(source.display, source.workspace);
                    if (source.floating) source.floating_restore = true;
                    state.fullscreen = if (state.fullscreen == source.identity) null else source.identity;
                    _ = native.platform_focus(source.identity);
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
                    const previous_layouts = layouts;
                    const previous = windows.items[sourceIndex].workspace;
                    if (workspace == previous) return json(.{ .ok = true });
                    windows.items[sourceIndex].workspace = workspace;
                    if (!commitWorkspace(displaySlot, display.workspace)) {
                        windows.items[sourceIndex].workspace = previous;
                        layouts = previous_layouts;
                        _ = deriveGoals();
                        return failure(transition_error orelse "WorkspacePlacementFailed");
                    }
                },
                .focus => |request| {
                    const target = if (request.wrap) wrappedNeighbor(sourceIndex, request.direction) else neighbor(sourceIndex, request.direction) orelse return failure("NoWindowInDirection");
                    const identity = windows.items[target].identity;
                    if (!native.platform_focus(identity)) return failure("FocusRejected");
                    const verified = native.platform_focused_window() == identity;
                    if (verified) focused = identity;
                    return json(.{ .ok = true, .accepted = true, .verified = verified, .target = identity });
                },
                .swap => |direction| {
                    const target = neighbor(sourceIndex, direction) orelse return failure("NoWindowInDirection");
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
    pending_close = null;
    native.platform_close_cancel();
    status_active = false;
    native.platform_status_present(null);
    cancelConfig();
    if (config_request.inFlight()) return false;
    cancelTransition();
    const outstanding = native.platform_restore();
    if (outstanding != 0) native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
    native.platform_border(0, 0, 0);
    return true;
}
