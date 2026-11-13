const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const allocator = std.heap.c_allocator;
const Layout = commands.Layout;
const max_source = 256 * 1024;
const max_response = 128 * 1024;

pub const Workspace = struct { name: [64:0]u8 = @splat(0), layout: Layout = .dwindle, ratio: f64 = 0.55 };
pub const Rule = struct { bundle: [256:0]u8 = @splat(0), floating: bool = false, workspace: ?usize = null };
pub const StatusLabel = enum { name, index, index_and_name };
pub const StatusBar = struct { enabled: bool = true, label: StatusLabel = .name };
pub const Mode = struct {
    name: [64:0]u8 = @splat(0),
    bindings: [128]native.WMBinding = @splat(std.mem.zeroes(native.WMBinding)),
    binding_count: usize = 0,
};
pub const Monitor = enum { external, @"built-in" };
pub const MonitorPreferences = struct { order: [2]Monitor = .{ .external, .@"built-in" }, count: usize };
pub const ConfigCandidate = struct {
    workspace_monitors: ?MonitorPreferences = null,
    mouse_follows_monitor: bool = false,
    status_bar: StatusBar = .{},
    gap: f64 = 12,
    border_width: f64 = 2,
    border_color: u32 = 0x9bafff,
    duration: f64 = 0.12,
    workspaces: [10]Workspace = @splat(.{}),
    workspace_count: usize = 5,
    modes: [8]Mode = @splat(.{}),
    mode_count: usize = 1,
    rules: [64]Rule = @splat(.{}),
    rule_count: usize = 0,

    pub fn modeIndex(self: *const ConfigCandidate, name: []const u8) ?usize {
        for (self.modes[0..self.mode_count], 0..) |*mode, index| if (std.mem.eql(u8, text(&mode.name), name)) return index;
        return null;
    }
};
pub const LoadResult = union(enum) { ready: ConfigCandidate, failed: anyerror };
pub const Completion = struct { generation: u64, result: LoadResult };

extern "c" fn config_worker_run(path: [*:0]const u8, output: [*]u8, capacity: usize, used: *usize, diagnostic: [*]u8, diagnostic_capacity: usize, cancelled: ?*const fn (?*anyopaque) callconv(.c) bool, context: ?*anyopaque) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(descriptor: c_int, output: [*]u8, capacity: usize) isize;
extern "c" fn write(descriptor: c_int, input: [*]const u8, length: usize) isize;
extern "c" fn close(descriptor: c_int) c_int;
extern "c" fn lua_getmetatable(state: *native.lua_State, index: c_int) c_int;
extern "c" fn lua_isinteger(state: *native.lua_State, index: c_int) c_int;
extern "c" fn lua_tointegerx(state: *native.lua_State, index: c_int, valid: ?*c_int) i64;
extern "c" fn lua_pushstring(state: *native.lua_State, value: [*:0]const u8) ?[*:0]const u8;
extern "c" fn lua_rawget(state: *native.lua_State, index: c_int) c_int;
extern "c" fn luaL_loadbufferx(state: *native.lua_State, source: [*]const u8, length: usize, name: [*:0]const u8, mode: [*:0]const u8) c_int;

pub const Request = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    completion: Completion = undefined,
    path: [:0]u8 = undefined,

    pub fn start(self: *Request, path: [*:0]const u8, generation: u64) !void {
        if (self.thread != null) return error.ConfigLoadPending;
        self.path = try allocator.dupeSentinel(u8, std.mem.span(path), 0);
        errdefer allocator.free(self.path);
        self.completion = .{ .generation = generation, .result = undefined };
        self.done.store(false, .release);
        self.cancelled.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn isCancelled(context: ?*anyopaque) callconv(.c) bool {
        const self: *Request = @ptrCast(@alignCast(context.?));
        return self.cancelled.load(.acquire);
    }

    fn run(self: *Request) void {
        self.completion.result = if (evaluate(self.path, isCancelled, self)) |candidate| .{ .ready = candidate } else |err| .{ .failed = err };
        allocator.free(self.path);
        self.done.store(true, .release);
    }

    pub fn take(self: *Request) ?Completion {
        if (self.thread == null or !self.done.load(.acquire)) return null;
        self.thread.?.join();
        self.thread = null;
        return self.completion;
    }

    pub fn cancel(self: *Request) void {
        self.cancelled.store(true, .release);
    }

    pub fn inFlight(self: *const Request) bool {
        return self.thread != null;
    }
};

pub fn load(path: [*:0]const u8) !ConfigCandidate {
    return evaluate(path, null, null);
}

fn evaluate(path: [*:0]const u8, cancelled: ?*const fn (?*anyopaque) callconv(.c) bool, context: ?*anyopaque) !ConfigCandidate {
    const response = try allocator.alloc(u8, max_response);
    defer allocator.free(response);
    var diagnostic: [4096]u8 = @splat(0);
    var used: usize = 0;
    const result = config_worker_run(path, response.ptr, response.len, &used, &diagnostic, diagnostic.len, cancelled, context);
    if (result != 0) {
        if (diagnostic[0] != 0) native.platform_error(@ptrCast(&diagnostic));
        return switch (result) {
            2 => error.ConfigDeadlineExceeded,
            3 => error.ConfigLoadCancelled,
            else => error.ConfigWorkerFailed,
        };
    }
    return decode(response[0..used]);
}

const WireWorkspace = struct { name: []const u8, layout: Layout, ratio: f64 };
const WireBinding = struct { key: u32, modifiers: u32, command: []const u8 };
const WireMode = struct { name: []const u8, bindings: []const WireBinding };
const WireRule = struct { bundle: []const u8, floating: bool, workspace: ?usize };
const WireConfig = struct {
    workspace_monitors: ?[]const Monitor,
    mouse_follows_monitor: bool,
    status_bar: StatusBar,
    gap: f64,
    border_width: f64,
    border_color: u32,
    duration: f64,
    workspaces: []const WireWorkspace,
    modes: []const WireMode,
    rules: []const WireRule,
};

fn encode(candidate: *const ConfigCandidate) ![]u8 {
    var workspaces: [10]WireWorkspace = undefined;
    var bindings: [8][128]WireBinding = undefined;
    var modes: [8]WireMode = undefined;
    var rules: [64]WireRule = undefined;
    for (candidate.workspaces[0..candidate.workspace_count], 0..) |*workspace, index| workspaces[index] = .{ .name = text(&workspace.name), .layout = workspace.layout, .ratio = workspace.ratio };
    for (candidate.modes[0..candidate.mode_count], 0..) |*mode, mode_index| {
        for (mode.bindings[0..mode.binding_count], 0..) |*binding, index| bindings[mode_index][index] = .{ .key = binding.key, .modifiers = binding.modifiers, .command = text(&binding.command) };
        modes[mode_index] = .{ .name = text(&mode.name), .bindings = bindings[mode_index][0..mode.binding_count] };
    }
    for (candidate.rules[0..candidate.rule_count], 0..) |*rule, index| rules[index] = .{ .bundle = text(&rule.bundle), .floating = rule.floating, .workspace = rule.workspace };
    const buffer = try allocator.alloc(u8, max_response);
    defer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(WireConfig{
        .workspace_monitors = if (candidate.workspace_monitors) |*preferences| preferences.order[0..preferences.count] else null,
        .mouse_follows_monitor = candidate.mouse_follows_monitor,
        .status_bar = candidate.status_bar,
        .gap = candidate.gap,
        .border_width = candidate.border_width,
        .border_color = candidate.border_color,
        .duration = candidate.duration,
        .workspaces = workspaces[0..candidate.workspace_count],
        .modes = modes[0..candidate.mode_count],
        .rules = rules[0..candidate.rule_count],
    }, .{}, &writer) catch return error.ConfigResponseTooLarge;
    return allocator.dupe(u8, writer.buffered());
}

fn decode(response: []const u8) !ConfigCandidate {
    const parsed = try std.json.parseFromSlice(WireConfig, allocator, response, .{ .allocate = .alloc_always, .max_value_len = max_response });
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.workspaces.len == 0 or wire.workspaces.len > 10 or wire.modes.len == 0 or wire.modes.len > 8 or wire.rules.len > 64) return error.InvalidCollectionSize;
    var candidate: ConfigCandidate = .{ .gap = wire.gap, .border_width = wire.border_width, .border_color = wire.border_color, .duration = wire.duration, .workspace_count = wire.workspaces.len, .mode_count = wire.modes.len, .rule_count = wire.rules.len };
    candidate.status_bar = wire.status_bar;
    candidate.mouse_follows_monitor = wire.mouse_follows_monitor;
    if (wire.workspace_monitors) |preferences| {
        if (preferences.len == 0 or preferences.len > 2) return error.InvalidMonitorPreferences;
        candidate.workspace_monitors = .{ .count = preferences.len };
        @memcpy(candidate.workspace_monitors.?.order[0..preferences.len], preferences);
    }
    for (wire.workspaces, 0..) |workspace, index| {
        try copyText(&candidate.workspaces[index].name, workspace.name);
        candidate.workspaces[index].layout = workspace.layout;
        candidate.workspaces[index].ratio = workspace.ratio;
    }
    for (wire.modes, 0..) |mode, mode_index| {
        if (mode.bindings.len > 128) return error.InvalidCollectionSize;
        const target = &candidate.modes[mode_index];
        try copyText(&target.name, mode.name);
        target.binding_count = mode.bindings.len;
        for (mode.bindings, 0..) |binding, index| {
            target.bindings[index].key = binding.key;
            target.bindings[index].modifiers = binding.modifiers;
            try copyText(&target.bindings[index].command, binding.command);
        }
    }
    for (wire.rules, 0..) |rule, index| {
        try copyText(&candidate.rules[index].bundle, rule.bundle);
        candidate.rules[index].floating = rule.floating;
        candidate.rules[index].workspace = rule.workspace;
    }
    try validate(&candidate);
    return candidate;
}

fn checkNumber(number: f64, minimum: f64, maximum: f64) !void {
    if (!std.math.isFinite(number) or number < minimum or number > maximum) return error.NumberOutOfRange;
}

fn validate(candidate: *const ConfigCandidate) !void {
    if (candidate.workspace_monitors) |preferences| {
        if (preferences.count == 0 or preferences.count > 2) return error.InvalidMonitorPreferences;
        if (preferences.count == 2 and preferences.order[0] == preferences.order[1]) return error.DuplicateMonitor;
    }
    try checkNumber(candidate.gap, 0, 100);
    try checkNumber(candidate.border_width, 0, 12);
    try checkNumber(candidate.duration, 0, 0.5);
    if (candidate.border_color > 0xffffff) return error.InvalidColor;
    for (candidate.workspaces[0..candidate.workspace_count]) |*workspace| {
        if (text(&workspace.name).len == 0) return error.EmptyWorkspaceName;
        try checkNumber(workspace.ratio, 0.1, 0.9);
    }
    if (!std.mem.eql(u8, text(&candidate.modes[0].name), "main")) return error.MainModeRequired;
    var total_bindings: usize = 0;
    for (candidate.modes[0..candidate.mode_count], 0..) |*mode, mode_index| {
        const name = text(&mode.name);
        if (name.len == 0) return error.EmptyModeName;
        for (name) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return error.InvalidModeName;
        for (candidate.modes[0..mode_index]) |*previous| if (std.mem.eql(u8, text(&previous.name), name)) return error.DuplicateMode;
    }
    for (candidate.modes[0..candidate.mode_count], 0..) |*mode, mode_index| {
        total_bindings += mode.binding_count;
        var escape_to_main = false;
        for (mode.bindings[0..mode.binding_count], 0..) |*binding, index| {
            if (!knownKeyCode(binding.key)) return error.UnknownKey;
            if ((mode_index == 0 and binding.modifiers == 0) or binding.modifiers & ~@as(u32, 256 | 512 | 2048 | 4096) != 0) return error.UnknownModifier;
            const command = try commands.parse(text(&binding.command), candidate.workspace_count);
            if (command == .mode) {
                if (candidate.modeIndex(command.mode.text()) == null) return error.UnknownMode;
                if (binding.key == 0x35 and binding.modifiers == 0 and std.mem.eql(u8, command.mode.text(), "main")) escape_to_main = true;
            }
            for (mode.bindings[0..index]) |previous| if (previous.key == binding.key and previous.modifiers == binding.modifiers) return error.DuplicateBinding;
        }
        if (mode_index != 0 and !escape_to_main) return error.ModeEscapeRequired;
    }
    if (total_bindings > 256) return error.TooManyBindings;
    for (candidate.rules[0..candidate.rule_count]) |rule| if (rule.workspace) |workspace| {
        if (workspace >= candidate.workspace_count) return error.InvalidWorkspace;
    };
}

pub fn workerMain(path: [*:0]const u8) u8 {
    const candidate = evaluateLua(path) catch |err| {
        native.platform_error(@errorName(err));
        return 1;
    };
    const encoded = encode(&candidate) catch |err| {
        native.platform_error(@errorName(err));
        return 1;
    };
    defer allocator.free(encoded);
    var sent: usize = 0;
    while (sent < encoded.len) {
        const amount = write(3, encoded.ptr + sent, encoded.len - sent);
        if (amount < 0) {
            if (std.c.errno(amount) == .INTR) continue;
            return 1;
        }
        if (amount == 0) return 1;
        sent += @intCast(amount);
    }
    return 0;
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

fn pop(state: *native.lua_State) void {
    native.lua_settop(state, -2);
}

fn plainTable(state: *native.lua_State) !void {
    if (native.lua_type(state, -1) != native.LUA_TTABLE) return error.ExpectedTable;
    if (lua_getmetatable(state, -1) != 0) {
        pop(state);
        return error.ConfigurationMetatable;
    }
}

fn arrayCount(state: *native.lua_State, capacity: usize) !usize {
    try plainTable(state);
    const count = native.lua_rawlen(state, -1);
    if (count > capacity) return error.InvalidCollectionSize;
    var seen: usize = 0;
    native.lua_pushnil(state);
    while (native.lua_next(state, -2) != 0) {
        if (lua_isinteger(state, -2) == 0) return error.ExpectedDenseArray;
        const key = lua_tointegerx(state, -2, null);
        if (key < 1 or key > count) return error.ExpectedDenseArray;
        seen += 1;
        pop(state);
    }
    if (seen != count) return error.ExpectedDenseArray;
    return count;
}

fn checkKeys(state: *native.lua_State, allowed: []const []const u8) !void {
    try plainTable(state);
    native.lua_pushnil(state);
    while (native.lua_next(state, -2) != 0) {
        if (native.lua_type(state, -2) != native.LUA_TSTRING) return error.ExpectedNamedField;
        var length: usize = 0;
        const pointer = native.lua_tolstring(state, -2, &length);
        const key = pointer[0..length];
        if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidConfigurationKey;
        var found = false;
        for (allowed) |name| if (std.mem.eql(u8, name, key)) {
            found = true;
            break;
        };
        if (!found) return error.UnknownConfigurationField;
        pop(state);
    }
}

fn rawField(state: *native.lua_State, key: [*:0]const u8) c_int {
    _ = lua_pushstring(state, key);
    return lua_rawget(state, -2);
}

fn fieldNumber(state: *native.lua_State, key: [*:0]const u8, default: f64, minimum: f64, maximum: f64) !f64 {
    const kind = rawField(state, key);
    defer pop(state);
    if (kind == native.LUA_TNIL) return default;
    if (kind != native.LUA_TNUMBER) return error.ExpectedNumber;
    const number = native.lua_tonumberx(state, -1, null);
    try checkNumber(number, minimum, maximum);
    return number;
}

fn fieldString(state: *native.lua_State, key: [*:0]const u8) !?[]const u8 {
    const kind = rawField(state, key);
    defer pop(state);
    if (kind == native.LUA_TNIL) return null;
    if (kind != native.LUA_TSTRING) return error.ExpectedString;
    var length: usize = 0;
    const pointer = native.lua_tolstring(state, -1, &length);
    return pointer[0..length];
}

fn fieldBool(state: *native.lua_State, key: [*:0]const u8, default: bool) !bool {
    const kind = rawField(state, key);
    defer pop(state);
    if (kind == native.LUA_TNIL) return default;
    if (kind != native.LUA_TBOOLEAN) return error.ExpectedBoolean;
    return native.lua_toboolean(state, -1) != 0;
}

fn keyCode(name: []const u8) !u32 {
    const names = [_][]const u8{ "a", "s", "d", "f", "h", "g", "z", "x", "c", "v", "section", "b", "q", "w", "e", "r", "y", "t", "1", "2", "3", "4", "6", "5", "=", "9", "7", "-", "8", "0", "]", "o", "u", "[", "i", "p", "return", "l", "j", "'", "k", ";", "\\", ",", "/", "n", "m", ".", "tab", "space", "`", "backspace" };
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return @intCast(index);
    if (std.mem.eql(u8, name, "escape")) return 0x35;
    if (std.mem.eql(u8, name, "left")) return 0x7b;
    if (std.mem.eql(u8, name, "right")) return 0x7c;
    if (std.mem.eql(u8, name, "down")) return 0x7d;
    if (std.mem.eql(u8, name, "up")) return 0x7e;
    return error.UnknownKey;
}

fn knownKeyCode(code: u32) bool {
    return code <= 0x33 or code == 0x35 or (code >= 0x7b and code <= 0x7e);
}

fn modifiers(value: []const u8) !u32 {
    if (value.len == 0) return 0;
    var parts = std.mem.splitScalar(u8, value, '+');
    var flags: u32 = 0;
    while (parts.next()) |part| {
        const flag: u32 = if (std.mem.eql(u8, part, "cmd")) 256 else if (std.mem.eql(u8, part, "shift")) 512 else if (std.mem.eql(u8, part, "alt")) 2048 else if (std.mem.eql(u8, part, "ctrl")) 4096 else return error.UnknownModifier;
        if (flags & flag != 0) return error.DuplicateModifier;
        flags |= flag;
    }
    if (flags == 0) return error.ModifierRequired;
    return flags;
}

fn evaluateLua(path: [*:0]const u8) !ConfigCandidate {
    const descriptor = open(path, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (descriptor < 0) return error.ConfigSourceUnavailable;
    defer _ = close(descriptor);
    const source = try allocator.alloc(u8, max_source + 1);
    defer allocator.free(source);
    var used: usize = 0;
    while (used < source.len) {
        const amount = read(descriptor, source.ptr + used, source.len - used);
        if (amount < 0) {
            if (std.c.errno(amount) == .INTR) continue;
            return error.ConfigSourceReadFailed;
        }
        if (amount == 0) break;
        used += @intCast(amount);
    }
    if (used > max_source) return error.ConfigSourceTooLarge;
    const start: usize = if (std.mem.startsWith(u8, source[0..used], "\xef\xbb\xbf")) 3 else 0;
    if (start < used and source[start] == '#') {
        const end = std.mem.indexOfScalarPos(u8, source[0..used], start, '\n') orelse used;
        @memset(source[start..end], ' ');
    }
    var result: ConfigCandidate = .{};
    try copyText(&result.modes[0].name, "main");
    for (&result.workspaces, 0..) |*workspace, index| {
        const name = try std.fmt.bufPrint(&workspace.name, "{d}", .{index + 1});
        workspace.name[name.len] = 0;
    }
    const state = native.platform_lua_open() orelse return error.LuaAllocationFailed;
    defer native.lua_close(state);
    const chunk_name = try std.fmt.allocPrintSentinel(allocator, "@{s}", .{std.mem.span(path)}, 0);
    defer allocator.free(chunk_name);
    if (luaL_loadbufferx(state, source.ptr + start, used - start, chunk_name, "t") != native.LUA_OK or native.lua_pcallk(state, 0, 1, 0, 0, null) != native.LUA_OK) {
        if (native.lua_type(state, -1) == native.LUA_TSTRING) native.platform_error(native.lua_tolstring(state, -1, null));
        return error.LuaConfigurationFailed;
    }
    try checkKeys(state, &.{ "gap", "layout", "master_ratio", "border_width", "border_color", "motion_duration", "workspaces", "bindings", "modes", "rules", "status_bar", "workspace_monitors", "mouse_follows_monitor" });
    result.mouse_follows_monitor = try fieldBool(state, "mouse_follows_monitor", false);
    if (rawField(state, "workspace_monitors") != native.LUA_TNIL) {
        const count = try arrayCount(state, 2);
        if (count == 0) return error.InvalidMonitorPreferences;
        result.workspace_monitors = .{ .count = count };
        for (0..count) |index| {
            if (native.lua_rawgeti(state, -1, @intCast(index + 1)) != native.LUA_TSTRING) return error.ExpectedString;
            var length: usize = 0;
            const value = native.lua_tolstring(state, -1, &length);
            result.workspace_monitors.?.order[index] = std.meta.stringToEnum(Monitor, value[0..length]) orelse return error.UnknownMonitor;
            pop(state);
        }
    }
    pop(state);
    if (rawField(state, "status_bar") != native.LUA_TNIL) {
        try checkKeys(state, &.{ "enabled", "label" });
        result.status_bar.enabled = try fieldBool(state, "enabled", true);
        if (try fieldString(state, "label")) |label| result.status_bar.label = std.meta.stringToEnum(StatusLabel, label) orelse return error.InvalidStatusLabel;
    }
    pop(state);
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
    if (rawField(state, "workspaces") != native.LUA_TNIL) {
        result.workspace_count = try arrayCount(state, 10);
        if (result.workspace_count == 0) return error.InvalidWorkspaceCount;
        for (0..result.workspace_count) |index| {
            if (native.lua_rawgeti(state, -1, @intCast(index + 1)) != native.LUA_TSTRING) return error.ExpectedWorkspaceName;
            var length: usize = 0;
            const name = native.lua_tolstring(state, -1, &length);
            try copyText(&result.workspaces[index].name, name[0..length]);
            pop(state);
        }
    }
    pop(state);
    if (rawField(state, "bindings") != native.LUA_TNIL) {
        try readBindings(state, &result.modes[0]);
    }
    pop(state);
    if (rawField(state, "modes") != native.LUA_TNIL) {
        const count = try arrayCount(state, 7);
        result.mode_count = count + 1;
        for (0..count) |index| {
            _ = native.lua_rawgeti(state, -1, @intCast(index + 1));
            try checkKeys(state, &.{ "name", "bindings" });
            const mode = &result.modes[index + 1];
            try copyText(&mode.name, (try fieldString(state, "name")) orelse return error.MissingModeName);
            if (rawField(state, "bindings") == native.LUA_TNIL) return error.MissingBindings;
            try readBindings(state, mode);
            pop(state);
            pop(state);
        }
    }
    pop(state);
    if (rawField(state, "rules") != native.LUA_TNIL) {
        result.rule_count = try arrayCount(state, 64);
        for (0..result.rule_count) |index| {
            _ = native.lua_rawgeti(state, -1, @intCast(index + 1));
            try checkKeys(state, &.{ "bundle", "floating", "workspace" });
            const rule = &result.rules[index];
            try copyText(&rule.bundle, (try fieldString(state, "bundle")) orelse return error.MissingBundle);
            rule.floating = try fieldBool(state, "floating", false);
            const workspace = try fieldNumber(state, "workspace", 0, 0, @floatFromInt(result.workspace_count));
            if (@floor(workspace) != workspace) return error.InvalidWorkspace;
            if (workspace > 0) rule.workspace = @as(usize, @intFromFloat(workspace)) - 1;
            pop(state);
        }
    }
    try validate(&result);
    return result;
}

fn readBindings(state: *native.lua_State, mode: *Mode) !void {
    mode.binding_count = try arrayCount(state, 128);
    for (0..mode.binding_count) |index| {
        _ = native.lua_rawgeti(state, -1, @intCast(index + 1));
        try checkKeys(state, &.{ "key", "mods", "command" });
        const binding = &mode.bindings[index];
        binding.key = try keyCode((try fieldString(state, "key")) orelse return error.MissingKey);
        binding.modifiers = try modifiers((try fieldString(state, "mods")) orelse return error.MissingModifiers);
        try copyText(&binding.command, (try fieldString(state, "command")) orelse return error.MissingCommand);
        pop(state);
    }
}
