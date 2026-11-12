const std = @import("std");
const native = @import("native.zig");
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = enum { dwindle, master };
const Direction = enum { left, right, up, down };
const Command = union(enum) {
    status,
    windows,
    monitors,
    workspaces,
    reload,
    quit,
    restore,
    focus: Direction,
    swap: Direction,
    move: Direction,
    resize: f64,
    toggle_floating,
    layout: Layout,
    workspace: usize,
    send_to_workspace: usize,
};
const Window = struct { identity: u64, observation: native.WMWindow, workspace: usize, display: u32, floating: bool = false, parked: bool = false, parking_frame: Rect, floating_frame: Rect, goal: Rect, placement_error: ?[]const u8 = null };
const Display = struct { identity: u32, frame: Rect, name: [128]u8, workspace: usize = 0 };
const Workspace = struct { name: [64:0]u8 = @splat(0), layout: Layout = .dwindle, ratio: f64 = 0.55 };
const Rule = struct { bundle: [256:0]u8 = @splat(0), floating: bool = false, workspace: ?usize = null };
const Config = struct {
    gap: f64 = 12,
    border_width: f64 = 2,
    border_color: u32 = 0x9bafff,
    duration: f64 = 0.12,
    workspaces: [10]Workspace = @splat(.{}),
    workspace_count: usize = 5,
    bindings: [128]native.WMBinding = undefined,
    binding_count: usize = 0,
    rules: [64]Rule = @splat(.{}),
    rule_count: usize = 0,
};
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

pub fn main(initial: std.process.Init.Minimal) u8 {
    const arguments = initial.args.vector;
    return @intCast(native.platform_main(@intCast(arguments.len), @ptrCast(arguments.ptr)));
}

fn text(buffer: anytype) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}
fn copyText(destination: []u8, source: []const u8) !void {
    if (source.len >= destination.len) return error.TextTooLong;
    if (!std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidText;
    @memset(destination, 0);
    @memcpy(destination[0..source.len], source);
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
fn parseCommand(input: []const u8, workspace_count: usize) !Command {
    var tokens = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const verb = tokens.next() orelse return error.MissingCommand;
    const argument = tokens.next();
    if (tokens.next() != null) return error.ExtraArgument;
    const plain = .{ "status", "windows", "monitors", "workspaces", "reload", "quit", "restore" };
    inline for (plain) |name| if (std.mem.eql(u8, verb, name)) {
        if (argument != null) return error.ExtraArgument;
        return @unionInit(Command, name, {});
    };
    if (std.mem.eql(u8, verb, "stop")) {
        if (argument != null) return error.ExtraArgument;
        return .quit;
    }
    if (std.mem.eql(u8, verb, "recover")) {
        if (argument != null) return error.ExtraArgument;
        return .restore;
    }
    if (std.mem.eql(u8, verb, "toggle-floating")) {
        if (argument != null) return error.ExtraArgument;
        return .toggle_floating;
    }
    const value = argument orelse return error.MissingArgument;
    inline for (.{ "focus", "swap", "move" }) |name| if (std.mem.eql(u8, verb, name)) return @unionInit(Command, name, std.meta.stringToEnum(Direction, value) orelse return error.InvalidDirection);
    if (std.mem.eql(u8, verb, "layout")) return .{ .layout = std.meta.stringToEnum(Layout, value) orelse return error.InvalidLayout };
    if (std.mem.eql(u8, verb, "resize")) {
        const delta = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(delta) or @abs(delta) > 0.5) return error.InvalidRatioDelta;
        return .{ .resize = delta };
    }
    const index = std.fmt.parseInt(usize, value, 10) catch return error.UnknownCommand;
    if (index == 0 or index > workspace_count) return error.InvalidWorkspace;
    if (std.mem.eql(u8, verb, "workspace")) return .{ .workspace = index - 1 };
    if (std.mem.eql(u8, verb, "send-to-workspace")) return .{ .send_to_workspace = index - 1 };
    return error.UnknownCommand;
}

fn pop(state: *native.lua_State) void {
    native.lua_settop(state, -2);
}
fn checkKeys(state: *native.lua_State, allowed: []const []const u8) !void {
    native.lua_pushnil(state);
    while (native.lua_next(state, -2) != 0) {
        if (native.lua_type(state, -2) != native.LUA_TSTRING) return error.ExpectedNamedField;
        const key = std.mem.span(native.lua_tolstring(state, -2, null));
        var found = false;
        for (allowed) |name| if (std.mem.eql(u8, name, key)) {
            found = true;
            break;
        };
        if (!found) return error.UnknownConfigurationField;
        pop(state);
    }
}
fn fieldNumber(state: *native.lua_State, key: [*:0]const u8, default: f64, minimum: f64, maximum: f64) !f64 {
    const kind = native.lua_getfield(state, -1, key);
    defer pop(state);
    if (kind == native.LUA_TNIL) return default;
    if (kind != native.LUA_TNUMBER) return error.ExpectedNumber;
    const number = native.lua_tonumberx(state, -1, null);
    if (!std.math.isFinite(number) or number < minimum or number > maximum) return error.NumberOutOfRange;
    return number;
}
fn fieldString(state: *native.lua_State, key: [*:0]const u8) !?[]const u8 {
    const kind = native.lua_getfield(state, -1, key);
    defer pop(state);
    if (kind == native.LUA_TNIL) return null;
    if (kind != native.LUA_TSTRING) return error.ExpectedString;
    var length: usize = 0;
    const pointer = native.lua_tolstring(state, -1, &length);
    return pointer[0..length];
}
fn fieldBool(state: *native.lua_State, key: [*:0]const u8, default: bool) !bool {
    const kind = native.lua_getfield(state, -1, key);
    defer pop(state);
    if (kind == native.LUA_TNIL) return default;
    if (kind != native.LUA_TBOOLEAN) return error.ExpectedBoolean;
    return native.lua_toboolean(state, -1) != 0;
}
fn keyCode(name: []const u8) !u32 {
    const Key = struct { name: []const u8, code: u32 };
    const keys = [_]Key{
        .{ .name = "a", .code = 0x00 },      .{ .name = "s", .code = 0x01 },     .{ .name = "d", .code = 0x02 },       .{ .name = "f", .code = 0x03 },
        .{ .name = "h", .code = 0x04 },      .{ .name = "g", .code = 0x05 },     .{ .name = "z", .code = 0x06 },       .{ .name = "x", .code = 0x07 },
        .{ .name = "c", .code = 0x08 },      .{ .name = "v", .code = 0x09 },     .{ .name = "section", .code = 0x0a }, .{ .name = "b", .code = 0x0b },
        .{ .name = "q", .code = 0x0c },      .{ .name = "w", .code = 0x0d },     .{ .name = "e", .code = 0x0e },       .{ .name = "r", .code = 0x0f },
        .{ .name = "y", .code = 0x10 },      .{ .name = "t", .code = 0x11 },     .{ .name = "1", .code = 0x12 },       .{ .name = "2", .code = 0x13 },
        .{ .name = "3", .code = 0x14 },      .{ .name = "4", .code = 0x15 },     .{ .name = "6", .code = 0x16 },       .{ .name = "5", .code = 0x17 },
        .{ .name = "=", .code = 0x18 },      .{ .name = "9", .code = 0x19 },     .{ .name = "7", .code = 0x1a },       .{ .name = "-", .code = 0x1b },
        .{ .name = "8", .code = 0x1c },      .{ .name = "0", .code = 0x1d },     .{ .name = "]", .code = 0x1e },       .{ .name = "o", .code = 0x1f },
        .{ .name = "u", .code = 0x20 },      .{ .name = "[", .code = 0x21 },     .{ .name = "i", .code = 0x22 },       .{ .name = "p", .code = 0x23 },
        .{ .name = "return", .code = 0x24 }, .{ .name = "l", .code = 0x25 },     .{ .name = "j", .code = 0x26 },       .{ .name = "'", .code = 0x27 },
        .{ .name = "k", .code = 0x28 },      .{ .name = ";", .code = 0x29 },     .{ .name = "\\", .code = 0x2a },      .{ .name = ",", .code = 0x2b },
        .{ .name = "/", .code = 0x2c },      .{ .name = "n", .code = 0x2d },     .{ .name = "m", .code = 0x2e },       .{ .name = ".", .code = 0x2f },
        .{ .name = "tab", .code = 0x30 },    .{ .name = "space", .code = 0x31 }, .{ .name = "`", .code = 0x32 },       .{ .name = "backspace", .code = 0x33 },
        .{ .name = "escape", .code = 0x35 }, .{ .name = "left", .code = 0x7b },  .{ .name = "right", .code = 0x7c },   .{ .name = "down", .code = 0x7d },
        .{ .name = "up", .code = 0x7e },
    };
    for (keys) |key| if (std.mem.eql(u8, key.name, name)) return key.code;
    return error.UnknownKey;
}
fn modifiers(value: []const u8) !u32 {
    var parts = std.mem.tokenizeScalar(u8, value, '+');
    var flags: u32 = 0;
    while (parts.next()) |part| {
        const flag: u32 = if (std.mem.eql(u8, part, "cmd")) 256 else if (std.mem.eql(u8, part, "shift")) 512 else if (std.mem.eql(u8, part, "alt")) 2048 else if (std.mem.eql(u8, part, "ctrl")) 4096 else return error.UnknownModifier;
        if (flags & flag != 0) return error.DuplicateModifier;
        flags |= flag;
    }
    if (flags == 0) return error.ModifierRequired;
    return flags;
}
fn loadConfig(path: [*:0]const u8) !Config {
    var result: Config = .{};
    for (&result.workspaces, 0..) |*workspace, index| {
        const name = try std.fmt.bufPrint(&workspace.name, "{d}", .{index + 1});
        workspace.name[name.len] = 0;
    }
    const state = native.platform_lua_open() orelse return error.LuaAllocationFailed;
    defer native.lua_close(state);
    if (native.luaL_loadfilex(state, path, "t") != native.LUA_OK or native.lua_pcallk(state, 0, 1, 0, 0, null) != native.LUA_OK) {
        native.platform_error(native.lua_tolstring(state, -1, null));
        return error.LuaConfigurationFailed;
    }
    if (native.lua_type(state, -1) != native.LUA_TTABLE) return error.ExpectedReturnedTable;
    try checkKeys(state, &.{ "gap", "layout", "master_ratio", "border_width", "border_color", "motion_duration", "workspaces", "bindings", "rules" });
    result.gap = try fieldNumber(state, "gap", 12, 0, 100);
    result.border_width = try fieldNumber(state, "border_width", 2, 0, 12);
    result.duration = try fieldNumber(state, "motion_duration", 0.12, 0, 0.5);
    if (try fieldString(state, "border_color")) |color| {
        if (color.len != 7 or color[0] != '#') return error.InvalidColor;
        result.border_color = try std.fmt.parseInt(u32, color[1..], 16);
    }
    const layout = if (try fieldString(state, "layout")) |name| std.meta.stringToEnum(Layout, name) orelse return error.InvalidLayout else .dwindle;
    const ratio = try fieldNumber(state, "master_ratio", 0.55, 0.1, 0.9);
    for (&result.workspaces) |*workspace| {
        workspace.layout = layout;
        workspace.ratio = ratio;
    }
    const workspaceKind = native.lua_getfield(state, -1, "workspaces");
    if (workspaceKind != native.LUA_TNIL) {
        if (workspaceKind != native.LUA_TTABLE) return error.ExpectedWorkspaces;
        result.workspace_count = native.lua_rawlen(state, -1);
        if (result.workspace_count == 0 or result.workspace_count > 10) return error.InvalidWorkspaceCount;
        for (0..result.workspace_count) |index| {
            if (native.lua_rawgeti(state, -1, @intCast(index + 1)) != native.LUA_TSTRING) return error.ExpectedWorkspaceName;
            var length: usize = 0;
            const name = native.lua_tolstring(state, -1, &length);
            if (length == 0) return error.EmptyWorkspaceName;
            try copyText(&result.workspaces[index].name, name[0..length]);
            pop(state);
        }
    }
    pop(state);
    const bindingsKind = native.lua_getfield(state, -1, "bindings");
    if (bindingsKind != native.LUA_TNIL) {
        if (bindingsKind != native.LUA_TTABLE) return error.ExpectedBindings;
        result.binding_count = native.lua_rawlen(state, -1);
        if (result.binding_count > 128) return error.TooManyBindings;
        for (0..result.binding_count) |index| {
            if (native.lua_rawgeti(state, -1, @intCast(index + 1)) != native.LUA_TTABLE) return error.ExpectedBinding;
            try checkKeys(state, &.{ "key", "mods", "command" });
            var binding: native.WMBinding = std.mem.zeroes(native.WMBinding);
            binding.key = try keyCode((try fieldString(state, "key")) orelse return error.MissingKey);
            binding.modifiers = try modifiers((try fieldString(state, "mods")) orelse return error.MissingModifiers);
            const command = (try fieldString(state, "command")) orelse return error.MissingCommand;
            _ = try parseCommand(command, result.workspace_count);
            try copyText(&binding.command, command);
            for (result.bindings[0..index]) |previous| if (previous.key == binding.key and previous.modifiers == binding.modifiers) return error.DuplicateBinding;
            result.bindings[index] = binding;
            pop(state);
        }
    }
    pop(state);
    const rulesKind = native.lua_getfield(state, -1, "rules");
    if (rulesKind != native.LUA_TNIL) {
        if (rulesKind != native.LUA_TTABLE) return error.ExpectedRules;
        result.rule_count = native.lua_rawlen(state, -1);
        if (result.rule_count > 64) return error.TooManyRules;
        for (0..result.rule_count) |index| {
            if (native.lua_rawgeti(state, -1, @intCast(index + 1)) != native.LUA_TTABLE) return error.ExpectedRule;
            try checkKeys(state, &.{ "bundle", "floating", "workspace" });
            var rule: Rule = .{};
            try copyText(&rule.bundle, (try fieldString(state, "bundle")) orelse return error.MissingBundle);
            rule.floating = try fieldBool(state, "floating", false);
            const workspace = try fieldNumber(state, "workspace", 0, 0, @floatFromInt(result.workspace_count));
            if (@floor(workspace) != workspace) return error.InvalidWorkspace;
            if (workspace > 0) rule.workspace = @as(usize, @intFromFloat(workspace)) - 1;
            result.rules[index] = rule;
            pop(state);
        }
    }
    return result;
}

export fn wm_initialize(path: [*:0]const u8) bool {
    const candidate = loadConfig(path) catch |err| {
        native.platform_error(@errorName(err));
        return false;
    };
    config = candidate;
    initialized = true;
    return true;
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

fn verifiedFrame(identity: u64, target: Rect) bool {
    _ = native.platform_frame(identity, target, 0);
    var actual: Rect = undefined;
    return native.platform_read_frame(identity, &actual) and framesNear(actual, target, 2);
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
    if (verifiedFrame(window.identity, target)) {
        window.parked = parked;
        window.placement_error = null;
        return .applied;
    }
    if (verifiedFrame(window.identity, original)) {
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
    var farRight: f64 = 0;
    for (displays.items) |display| farRight = @max(farRight, display.frame.left + display.frame.width);
    for (windows.items) |*window| {
        if (window.observation.minimized or window.observation.fullscreen or window.observation.stale or displayBlocked(window.display) or (!window.observation.onscreen and !window.parked)) continue;
        if (!visible(window.*)) {
            if (!window.parked) window.parking_frame = window.observation.frame;
            var parked = window.parking_frame;
            parked.left = farRight + 4096;
            parked.top = 64;
            if (!window.parked or !framesNear(window.observation.frame, parked, 2)) _ = placeVisibility(window, parked, true);
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
    native.platform_border(focused orelse 0, config.border_width, config.border_color);
}
export fn wm_tick() void {
    if (!initialized) return;
    var observedDisplays: [32]native.WMDisplay = undefined;
    const displayCount = native.platform_displays(&observedDisplays, observedDisplays.len);
    var updated: std.ArrayList(Display) = .empty;
    for (observedDisplays[0..displayCount]) |observation| {
        const previous = displayIndex(observation.identity);
        updated.append(allocator, .{ .identity = observation.identity, .frame = observation.frame, .name = observation.name, .workspace = if (previous) |index| displays.items[index].workspace else 0 }) catch return;
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
    var farRight: f64 = 0;
    for (displays.items) |display| farRight = @max(farRight, display.frame.left + display.frame.width);
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
            target = if (window.parked) window.parking_frame else original;
            target.left = farRight + 4096;
            target.top = 64;
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
        .status => return json(.{ .running = true, .suspended = suspended, .window_count = windows.items.len, .display_count = displays.items.len, .workspace_backend = "offscreen-parking", .filter = std.mem.span(native.platform_filter()), .scene_capture_allowed = native.huen_scene_capture_allowed(), .transition_pending = transition != null, .transition_error = transition_error }),
        .windows => {
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8 };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (windows.items) |*window| items.append(allocator, .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focused == window.identity, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error }) catch return failure("OutOfMemory");
            return json(items.items);
        },
        .monitors => {
            const Item = struct { id: u32, name: []const u8, frame: Rect, workspace: usize, blocked_by_fullscreen: bool };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (displays.items) |*display| items.append(allocator, .{ .id = display.identity, .name = text(&display.name), .frame = display.frame, .workspace = display.workspace + 1, .blocked_by_fullscreen = displayBlocked(display.identity) }) catch return failure("OutOfMemory");
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
            const candidate = loadConfig(native.platform_config_path()) catch |err| return failure(@errorName(err));
            if (!native.platform_bindings(&candidate.bindings, candidate.binding_count)) return failure("HotkeyCollision");
            config = candidate;
            for (displays.items) |*display| display.workspace = @min(display.workspace, config.workspace_count - 1);
            for (windows.items) |*window| window.workspace = @min(window.workspace, config.workspace_count - 1);
            native.platform_config_changed();
            reconcile();
            return json(.{ .ok = true });
        },
        .quit => {
            cancelTransition();
            native.platform_quit();
            return json(.{ .ok = true });
        },
        .restore => {
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
export fn wm_shutdown() void {
    cancelTransition();
    const outstanding = native.platform_restore();
    if (outstanding != 0) native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
    native.platform_border(0, 0, 0);
}
