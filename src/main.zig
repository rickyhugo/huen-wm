const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const commands = @import("command.zig");
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
const Window = struct { identity: u64, observation: native.WMWindow, workspace: usize, display: u32, floating: bool = false, parked: bool = false, parking_frame: Rect, floating_frame: Rect, goal: Rect, placement_error: ?[]const u8 = null };
const Display = struct { identity: u32, frame: Rect, full_bounds: Rect, name: [128]u8, workspace: usize = 0 };
const Config = configuration.ConfigCandidate;
var config: Config = .{};
var windows: std.ArrayList(Window) = .empty;
var displays: std.ArrayList(Display) = .empty;
var focused: ?u64 = null;
var reply_buffer: ?[:0]u8 = null;
var initialized = false;
var suspended = false;
const Transition = struct { display: u32, workspace: usize, generation: u64 };
var transition: ?Transition = null;
var generation: u64 = 0;
var transition_error: ?[]const u8 = null;
var config_request: configuration.Request = .{};
var config_generation: u64 = 0;
var config_state: enum { idle, pending, ready, failed } = .idle;
var config_error: ?[]const u8 = null;

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
    config = candidate;
    config_state = .ready;
    initialized = true;
    return true;
}

export fn wm_activate_config() bool {
    return native.platform_bindings(&config.bindings, config.binding_count);
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
    if (!native.platform_bindings(&candidate.bindings, candidate.binding_count)) {
        rejectConfig("HotkeyCollision");
        return;
    }
    config = candidate;
    config_state = .ready;
    config_error = null;
    for (displays.items) |*display| display.workspace = @min(display.workspace, config.workspace_count - 1);
    for (windows.items) |*window| window.workspace = @min(window.workspace, config.workspace_count - 1);
    native.platform_config_changed();
    reconcile();
}

fn cancelConfig() void {
    if (config_state != .pending) return;
    config_request.cancel();
    config_state = .failed;
    config_error = "ConfigLoadCancelled";
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
fn split(frame: Rect, horizontal: bool, ratio: f64, gap: f64) [2]Rect {
    var first = frame;
    var second = frame;
    const spacing = @min(gap, @max(0, (if (horizontal) frame.width else frame.height) - 2));
    if (horizontal) {
        first.width = (frame.width - spacing) * ratio;
        second.left += first.width + spacing;
        second.width = frame.width - first.width - spacing;
    } else {
        first.height = (frame.height - spacing) * ratio;
        second.top += first.height + spacing;
        second.height = frame.height - first.height - spacing;
    }
    return .{ first, second };
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
    if (window.floating) return;
    const slot = displayIndex(window.display) orelse return;
    window.floating = true;
    window.floating_frame = boundedFloating(window.parking_frame, inset(displays.items[slot].frame, config.gap));
    placementFailure(window, "Application rejected tile; retrying with floating recovery geometry");
}

fn deriveGoals() void {
    for (displays.items) |display| {
        if (displayBlocked(display.identity)) continue;
        var indices: [1024]usize = undefined;
        var count: usize = 0;
        for (windows.items, 0..) |window, index| if (window.display == display.identity and visible(window) and !window.floating and count < indices.len) {
            indices[count] = index;
            count += 1;
        };
        if (count == 0) continue;
        const workspace = config.workspaces[display.workspace];
        const area = inset(display.frame, config.gap);
        if (count == 1) {
            windows.items[indices[0]].goal = area;
            continue;
        }
        if (workspace.layout == .master) {
            const columns = split(area, true, workspace.ratio, config.gap);
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
            var remaining = area;
            for (indices[0..count], 0..) |index, position| {
                if (position == count - 1) {
                    windows.items[index].goal = remaining;
                    break;
                }
                const halves = split(remaining, remaining.width >= remaining.height, if (position == 0) workspace.ratio else 0.5, config.gap);
                windows.items[index].goal = halves[0];
                remaining = halves[1];
            }
        }
    }
    for (windows.items) |*window| {
        if (visible(window.*) and !window.floating and (window.goal.width < 80 or window.goal.height < 80)) {
            window.floating = true;
            window.floating_frame = if (window.parked) window.parking_frame else window.observation.frame;
            window.goal = window.floating_frame;
            placementFailure(window, "Tile too crowded; window left floating");
        }
    }
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

var debug_verification_failures: u32 = 0;

fn overlapsOtherDisplays(frame: Rect, displayIdentity: u32) bool {
    for (displays.items) |display| {
        if (display.identity == displayIdentity) continue;
        const area = display.full_bounds;
        if (@min(frame.left + frame.width, area.left + area.width) > @max(frame.left, area.left) and
            @min(frame.top + frame.height, area.top + area.height) > @max(frame.top, area.top)) return true;
    }
    return false;
}

fn parkingFrame(displayIdentity: u32, original: Rect) ?Rect {
    const slot = displayIndex(displayIdentity) orelse return null;
    const area = displays.items[slot].frame;
    var candidate = original;
    candidate.top = area.top + area.height - 1;
    candidate.left = area.left + area.width - 1;
    if (!overlapsOtherDisplays(candidate, displayIdentity)) return candidate;
    candidate.left = area.left + 1 - original.width;
    if (!overlapsOtherDisplays(candidate, displayIdentity)) return candidate;
    return null;
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
    const write_result = native.platform_frame(identity, target, 0);
    var actual: Rect = std.mem.zeroes(Rect);
    const readable = native.platform_read_frame(identity, &actual);
    const verified = readable and
        (if (parkedDisplay) |displayIdentity|
            parkedFrameAccepted(actual, target, displayIdentity)
        else
            framesNear(actual, target, 2));
    if (!verified and debug_verification_failures < 32) {
        debug_verification_failures += 1;
        std.debug.print("[DEBUG-parking] verified-frame identity={d} write_result={} desired=[{d:.3},{d:.3},{d:.3},{d:.3}] actual_readable={} actual=[{d:.3},{d:.3},{d:.3},{d:.3}] failure={d}/32\n", .{
            identity, write_result, target.left, target.top,   target.width,  target.height,
            readable, actual.left,  actual.top,  actual.width, actual.height, debug_verification_failures,
        });
    }
    return verified;
}

const PlacementOutcome = enum { applied, rolled_back, recovery_required, unreadable };

fn placeVisibility(window: *Window, target: Rect, parked: bool) PlacementOutcome {
    var original: Rect = undefined;
    if (!native.platform_read_frame(window.identity, &original)) {
        placementFailure(window, "Placement geometry unreadable");
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
        placementFailure(window, "Placement rejected; prior geometry verified");
        return .rolled_back;
    }
    placementFailure(window, "Placement and rollback rejected; recovery ownership retained");
    return .recovery_required;
}
fn reconcile() void {
    if (suspended or transition != null or displays.items.len == 0) return;
    deriveGoals();
    for (windows.items) |*window| {
        if (window.observation.minimized or window.observation.fullscreen or window.observation.stale or displayBlocked(window.display) or (!window.observation.onscreen and !window.parked)) continue;
        if (!visible(window.*)) {
            const original = if (window.parked) window.parking_frame else window.observation.frame;
            const parked = parkingFrame(window.display, original) orelse {
                placementFailure(window, "No parking corner avoids other displays");
                continue;
            };
            if (!window.parked or !parkedFrameAccepted(window.observation.frame, parked, window.display)) _ = placeVisibility(window, parked, true);
        } else {
            const target = if (window.floating) window.floating_frame else window.goal;
            const actual = window.observation.frame;
            if (window.parked) {
                const outcome = placeVisibility(window, target, false);
                if (outcome == .rolled_back or outcome == .recovery_required) floatRejectedTile(window);
            } else if (!framesNear(actual, target, 2)) {
                const applied = native.platform_frame(window.identity, target, config.duration);
                var accepted: Rect = actual;
                const rejected = !applied or (config.duration == 0 and (!native.platform_read_frame(window.identity, &accepted) or !framesNear(accepted, target, 2)));
                if (rejected) {
                    window.floating = true;
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
export fn wm_tick() void {
    if (!initialized) return;
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
            } else if (transition == null and window.floating and !window.parked and !observation.stale) window.floating_frame = observation.frame;
        } else {
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
fn announce(displayIndexValue: usize) void {
    const display = displays.items[displayIndexValue];
    var buffer: [256:0]u8 = @splat(0);
    const name = text(&config.workspaces[display.workspace].name);
    const message = std.fmt.bufPrint(&buffer, "{d}  {s}  ·  {s}", .{ display.workspace + 1, name, text(&display.name) }) catch return;
    buffer[message.len] = 0;
    native.platform_hud(&buffer);
}

fn cancelTransition() void {
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
    deriveGoals();
    for (windows.items, 0..) |window, index| {
        if (window.display != displayIdentity or window.observation.minimized or window.observation.fullscreen) continue;
        if (!window.observation.onscreen and !window.parked) continue;
        if (window.observation.stale or count == placements.len) {
            displays.items[displaySlot].workspace = previousWorkspace;
            deriveGoals();
            placementFailure(&windows.items[index], "Workspace snapshot contains a stale or excess window");
            return false;
        }
        var original: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &original)) {
            displays.items[displaySlot].workspace = previousWorkspace;
            deriveGoals();
            placementFailure(&windows.items[index], "Workspace geometry could not be read");
            return false;
        }
        const parked = window.workspace != workspace;
        var target = if (window.floating) window.floating_frame else window.goal;
        if (parked) {
            target = parkingFrame(window.display, if (window.parked) window.parking_frame else original) orelse {
                displays.items[displaySlot].workspace = previousWorkspace;
                deriveGoals();
                placementFailure(&windows.items[index], "No parking corner avoids other displays");
                return false;
            };
        }
        placements[count] = .{ .index = index, .original = original, .target = target, .parked = parked, .previously_parked = window.parked, .parking_frame = window.parking_frame };
        count += 1;
    }
    for (placements[0..count], 0..) |placement, position| {
        const outcome = placeVisibility(&windows.items[placement.index], placement.target, placement.parked);
        if (outcome != .applied) {
            for (placements[0 .. position + 1]) |rollback| {
                var window = &windows.items[rollback.index];
                _ = placeVisibility(window, rollback.original, rollback.previously_parked);
                if (rollback.previously_parked) window.parking_frame = rollback.parking_frame;
            }
            if (!placement.parked and outcome != .unreadable) floatRejectedTile(&windows.items[placement.index]);
            displays.items[displaySlot].workspace = previousWorkspace;
            deriveGoals();
            transition_error = "Workspace placement rejected. Rollback attempted; inspect per-window errors and retry restore if needed.";
            return false;
        }
    }
    for (windows.items) |window| if (window.display == displayIdentity and visible(window)) {
        native.platform_focus(window.identity);
        break;
    };
    transition_error = null;
    announce(displaySlot);
    native.platform_config_changed();
    return true;
}

fn sceneReady(context: ?*anyopaque, covered: bool) callconv(.c) void {
    _ = context;
    const pending = transition orelse return;
    const slot = displayIndex(pending.display);
    if (slot) |displaySlot| {
        _ = commitWorkspace(displaySlot, pending.workspace);
    } else transition_error = "Display disconnected during workspace capture";
    transition = null;
    if (covered) native.huen_scene_finish(pending.generation);
}
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    const command = parseCommand(std.mem.span(commandText), config.workspace_count) catch |err| return failure(@errorName(err));
    switch (command) {
        .status => return json(.{ .running = true, .suspended = suspended, .window_count = windows.items.len, .display_count = displays.items.len, .workspace_backend = "offscreen-parking", .filter = std.mem.span(native.platform_filter()), .scene_capture_allowed = native.huen_scene_capture_allowed(), .transition_pending = transition != null, .transition_error = transition_error, .config_reload = .{ .request_id = config_generation, .state = config_state, .err_message = config_error } }),
        .windows => {
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8 };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (windows.items) |*window| items.append(allocator, .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focused == window.identity, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error }) catch return failure("OutOfMemory");
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
                items.append(allocator, .{ .display = display.identity, .index = index + 1, .name = text(&workspace.name), .active = display.workspace == index, .layout = workspace.layout }) catch return failure("OutOfMemory");
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
            cancelConfig();
            cancelTransition();
            native.platform_quit();
            return json(.{ .ok = true });
        },
        .restore => {
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
    const displaySlot = activeDisplay();
    const display = &displays.items[displaySlot];
    switch (command) {
        .workspace => |workspace| {
            if (workspace == display.workspace) return json(.{ .ok = true });
            if (config.duration == 0 or !native.huen_scene_capture_allowed()) {
                if (!commitWorkspace(displaySlot, workspace)) return failure(transition_error orelse "WorkspacePlacementFailed");
                return json(.{ .ok = true });
            }
            generation += 1;
            transition = .{ .display = display.identity, .workspace = workspace, .generation = generation };
            native.huen_scene_begin(display.identity, generation, config.duration, sceneReady, null);
            return json(.{ .ok = true, .accepted = true, .generation = generation });
        },
        .layout => |layout| config.workspaces[display.workspace].layout = layout,
        .resize => |delta| config.workspaces[display.workspace].ratio = std.math.clamp(config.workspaces[display.workspace].ratio + delta, 0.1, 0.9),
        else => {
            const sourceIndex = windowIndex(focused orelse return failure("NoFocusedWindow")) orelse return failure("NoFocusedWindow");
            switch (command) {
                .toggle_floating => {
                    var window = &windows.items[sourceIndex];
                    window.floating = !window.floating;
                    window.floating_frame = window.observation.frame;
                },
                .send_to_workspace => |workspace| {
                    const previous = windows.items[sourceIndex].workspace;
                    windows.items[sourceIndex].workspace = workspace;
                    if (!commitWorkspace(displaySlot, display.workspace)) {
                        windows.items[sourceIndex].workspace = previous;
                        return failure(transition_error orelse "WorkspacePlacementFailed");
                    }
                },
                .focus => |direction| {
                    const target = neighbor(sourceIndex, direction) orelse return failure("NoWindowInDirection");
                    native.platform_focus(windows.items[target].identity);
                },
                .swap => |direction| {
                    const target = neighbor(sourceIndex, direction) orelse return failure("NoWindowInDirection");
                    const sourceDisplay = windows.items[sourceIndex].display;
                    const sourceWorkspace = windows.items[sourceIndex].workspace;
                    windows.items[sourceIndex].display = windows.items[target].display;
                    windows.items[sourceIndex].workspace = windows.items[target].workspace;
                    windows.items[target].display = sourceDisplay;
                    windows.items[target].workspace = sourceWorkspace;
                    std.mem.swap(Window, &windows.items[sourceIndex], &windows.items[target]);
                },
                .move => |direction| {
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
    cancelConfig();
    if (config_request.inFlight()) return false;
    cancelTransition();
    const outstanding = native.platform_restore();
    if (outstanding != 0) native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
    native.platform_border(0, 0, 0);
    return true;
}
