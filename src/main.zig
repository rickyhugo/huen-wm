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
const Window = struct { identity: u64, observation: native.WMWindow, workspace: usize, display: u32, floating: bool = false, parked: bool = false, floating_frame: Rect, goal: Rect };
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
const Transition = struct { display: u32, workspace: usize, generation: u64, cancelled: bool = false };
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
fn parseCommand(input: []const u8) !Command {
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
    if (index == 0 or index > config.workspace_count) return error.InvalidWorkspace;
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
    const names = [_][]const u8{ "a", "s", "d", "f", "h", "g", "z", "x", "c", "v", "b", "q", "w", "e", "r", "y", "t", "1", "2", "3", "4", "6", "5", "=", "9", "7", "-", "8", "0", "]", "o", "u", "[", "i", "p", "return", "l", "j", "'", "k", ";", "\\", ",", "/", "n", "m", ".", "tab", "space", "`", "backspace" };
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return @intCast(index);
    if (std.mem.eql(u8, name, "escape")) return 53;
    if (std.mem.eql(u8, name, "left")) return 123;
    if (std.mem.eql(u8, name, "right")) return 124;
    if (std.mem.eql(u8, name, "down")) return 125;
    if (std.mem.eql(u8, name, "up")) return 126;
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
        const previousConfig = config;
        config.workspace_count = result.workspace_count;
        defer config = previousConfig;
        for (0..result.binding_count) |index| {
            if (native.lua_rawgeti(state, -1, @intCast(index + 1)) != native.LUA_TTABLE) return error.ExpectedBinding;
            try checkKeys(state, &.{ "key", "mods", "command" });
            var binding: native.WMBinding = std.mem.zeroes(native.WMBinding);
            binding.key = try keyCode((try fieldString(state, "key")) orelse return error.MissingKey);
            binding.modifiers = try modifiers((try fieldString(state, "mods")) orelse return error.MissingModifiers);
            const command = (try fieldString(state, "command")) orelse return error.MissingCommand;
            _ = try parseCommand(command);
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
    return .{ .left = frame.left + gap, .top = frame.top + gap, .width = @max(80, frame.width - 2 * gap), .height = @max(80, frame.height - 2 * gap) };
}
fn split(frame: Rect, horizontal: bool, ratio: f64, gap: f64) [2]Rect {
    var first = frame;
    var second = frame;
    if (horizontal) {
        first.width = @max(80, (frame.width - gap) * ratio);
        second.left += first.width + gap;
        second.width = @max(80, frame.width - first.width - gap);
    } else {
        first.height = @max(80, (frame.height - gap) * ratio);
        second.top += first.height + gap;
        second.height = @max(80, frame.height - first.height - gap);
    }
    return .{ first, second };
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
            const height = @max(80, (columns[1].height - config.gap * @as(f64, @floatFromInt(count - 2))) / @as(f64, @floatFromInt(count - 1)));
            for (indices[1..count], 0..) |index, row| {
                var frame = columns[1];
                frame.top += @as(f64, @floatFromInt(row)) * (height + config.gap);
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
}
fn reconcile() void {
    if (suspended or transition != null or displays.items.len == 0) return;
    deriveGoals();
    var farRight: f64 = 0;
    for (displays.items) |display| farRight = @max(farRight, display.frame.left + display.frame.width);
    for (windows.items) |*window| {
        if (window.observation.minimized or window.observation.fullscreen or window.observation.stale or displayBlocked(window.display) or (!window.observation.onscreen and !window.parked)) continue;
        if (!visible(window.*)) {
            if (!window.parked) window.floating_frame = window.observation.frame;
            var parked = window.floating_frame;
            parked.left = farRight + 4096;
            parked.top = 64;
            var actual: Rect = undefined;
            if (native.platform_frame(window.identity, parked, 0) and native.platform_read_frame(window.identity, &actual) and @abs(actual.left - parked.left) <= 8 and @abs(actual.top - parked.top) <= 8) {
                window.parked = true;
            } else transition_error = "An application rejected offscreen parking";
        } else {
            const target = if (window.floating) window.floating_frame else window.goal;
            const actual = window.observation.frame;
            if (window.parked or @abs(actual.left - target.left) > 2 or @abs(actual.top - target.top) > 2 or @abs(actual.width - target.width) > 2 or @abs(actual.height - target.height) > 2) _ = native.platform_frame(window.identity, target, if (window.parked) 0 else config.duration);
            window.parked = false;
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
                window.floating_frame.width = @min(window.floating_frame.width, area.width);
                window.floating_frame.height = @min(window.floating_frame.height, area.height);
                window.floating_frame.left = std.math.clamp(window.floating_frame.left, area.left, area.left + area.width - window.floating_frame.width);
                window.floating_frame.top = std.math.clamp(window.floating_frame.top, area.top, area.top + area.height - window.floating_frame.height);
                if (window.floating and !window.parked) _ = native.platform_frame(window.identity, window.floating_frame, 0);
            } else if (window.floating and !window.parked and !observation.stale) window.floating_frame = observation.frame;
        } else {
            const display = nearestDisplay(observation.frame);
            const displaySlot = displayIndex(display).?;
            var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = displays.items[displaySlot].workspace, .floating_frame = observation.frame, .goal = observation.frame };
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
    if (transition) |*pending| pending.cancelled = true;
    native.huen_scene_cancel();
    transition = null;
}

fn commitWorkspace(displaySlot: usize, workspace: usize) bool {
    const previousWorkspace = displays.items[displaySlot].workspace;
    const displayIdentity = displays.items[displaySlot].identity;
    if (displayBlocked(displayIdentity)) {
        transition_error = "Native fullscreen window blocks this display";
        return false;
    }
    const Placement = struct { index: usize, original: Rect, target: Rect, parked: bool };
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
            return false;
        }
        var original: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &original)) {
            displays.items[displaySlot].workspace = previousWorkspace;
            return false;
        }
        const parked = window.workspace != workspace;
        var target = if (window.floating) window.floating_frame else window.goal;
        if (parked) {
            target = window.floating_frame;
            target.left = farRight + 4096;
            target.top = 64;
        }
        placements[count] = .{ .index = index, .original = original, .target = target, .parked = parked };
        count += 1;
    }
    for (placements[0..count], 0..) |placement, position| {
        const identity = windows.items[placement.index].identity;
        const applied = native.platform_frame(identity, placement.target, 0);
        var actual: Rect = undefined;
        const read = native.platform_read_frame(identity, &actual);
        if (!applied or !read or @abs(actual.left - placement.target.left) > 8 or @abs(actual.top - placement.target.top) > 8 or @abs(actual.width - placement.target.width) > 8 or @abs(actual.height - placement.target.height) > 8) {
            for (placements[0 .. position + 1]) |rollback| _ = native.platform_frame(windows.items[rollback.index].identity, rollback.original, 0);
            displays.items[displaySlot].workspace = previousWorkspace;
            deriveGoals();
            transition_error = "Workspace placement rejected. Previous workspace restored; use restore if an app refused rollback.";
            return false;
        }
    }
    for (placements[0..count]) |placement| {
        var window = &windows.items[placement.index];
        if (placement.parked and !window.parked) window.floating_frame = placement.original;
        window.parked = placement.parked;
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
    if (pending.cancelled) return;
    const slot = displayIndex(pending.display);
    if (slot) |displaySlot| {
        _ = commitWorkspace(displaySlot, pending.workspace);
    } else transition_error = "Display disconnected during workspace capture";
    transition = null;
    if (covered) native.huen_scene_finish(pending.generation);
}
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    const command = parseCommand(std.mem.span(commandText)) catch |err| return failure(@errorName(err));
    switch (command) {
        .status => return json(.{ .running = true, .suspended = suspended, .window_count = windows.items.len, .display_count = displays.items.len, .workspace_backend = "offscreen-parking", .filter = std.mem.span(native.platform_filter()), .scene_capture_allowed = native.huen_scene_capture_allowed(), .transition_pending = transition != null, .transition_error = transition_error }),
        .windows => {
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, stale: bool, frame: Rect };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(allocator);
            for (windows.items) |*window| items.append(allocator, .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focused == window.identity, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .stale = window.observation.stale, .frame = window.observation.frame }) catch return failure("OutOfMemory");
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
            native.platform_restore();
            native.platform_border(0, 0, 0);
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
    native.platform_restore();
    native.platform_border(0, 0, 0);
}
