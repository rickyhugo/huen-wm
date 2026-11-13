const std = @import("std");

pub const Layout = enum { dwindle, master };
pub const Direction = enum { left, right, up, down };
pub const Axis = enum { width, height };
pub const Orientation = enum { horizontal, vertical, toggle };
pub const Name = struct {
    bytes: [128:0]u8 = @splat(0),

    pub fn init(value: []const u8) !Name {
        if (value.len == 0 or value.len > 127 or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
        var result: Name = .{};
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn text(self: *const Name) [:0]const u8 {
        return std.mem.sliceTo(&self.bytes, 0);
    }
};
pub const Focus = struct { direction: Direction, wrap: bool = false };
pub const Launch = struct { bundle: Name, new_instance: bool = false };
pub const Command = union(enum) {
    status,
    windows,
    monitors,
    workspaces,
    reload,
    quit,
    restore,
    focus: Focus,
    mode: Name,
    launch: Launch,
    exec_and_forget: []const u8,
    close: bool,
    swap: Direction,
    move: Direction,
    resize: f64,
    resize_points: struct { axis: Axis, delta: f64 },
    split: Orientation,
    fullscreen,
    toggle_floating,
    layout: Layout,
    workspace: usize,
    send_to_workspace: usize,
};

pub fn parse(input: []const u8, workspace_count: usize) !Command {
    if (input.len > 511 or std.mem.indexOfScalar(u8, input, 0) != null or !std.unicode.utf8ValidateSlice(input)) return error.InvalidCommandText;
    var tokens = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const verb = tokens.next() orelse return error.MissingCommand;
    if (std.mem.eql(u8, verb, "exec-and-forget")) {
        const shell = std.mem.trimStart(u8, tokens.rest(), " \t\r\n");
        if (shell.len == 0) return error.MissingArgument;
        return .{ .exec_and_forget = shell };
    }
    var argument = tokens.next();
    if (std.mem.eql(u8, verb, "resize")) {
        const value = argument orelse return error.MissingArgument;
        if (std.meta.stringToEnum(Axis, value)) |axis| {
            const amount = tokens.next() orelse return error.MissingArgument;
            if (tokens.next() != null) return error.ExtraArgument;
            const delta = try std.fmt.parseFloat(f64, amount);
            if (!std.math.isFinite(delta) or @abs(delta) > 10000) return error.InvalidPointDelta;
            return .{ .resize_points = .{ .axis = axis, .delta = delta } };
        }
        if (tokens.next() != null) return error.ExtraArgument;
        const delta = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(delta) or @abs(delta) > 0.5) return error.InvalidRatioDelta;
        return .{ .resize = delta };
    }
    if (std.mem.eql(u8, verb, "launch")) {
        const new_instance = argument != null and std.mem.eql(u8, argument.?, "--new-instance");
        if (new_instance) argument = tokens.next();
        const bundle = try Name.init(argument orelse return error.MissingArgument);
        if (bundle.bytes[0] == '-') return error.UnknownOption;
        for (bundle.text()) |character| if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-') return error.InvalidBundle;
        if (tokens.next() != null) return error.ExtraArgument;
        return .{ .launch = .{ .bundle = bundle, .new_instance = new_instance } };
    }
    if (std.mem.eql(u8, verb, "focus")) {
        const wrap = argument != null and std.mem.eql(u8, argument.?, "--wrap");
        if (wrap) argument = tokens.next();
        const direction = std.meta.stringToEnum(Direction, argument orelse return error.MissingArgument) orelse return error.InvalidDirection;
        if (tokens.next() != null) return error.ExtraArgument;
        return .{ .focus = .{ .direction = direction, .wrap = wrap } };
    }
    if (tokens.next() != null) return error.ExtraArgument;
    if (std.mem.eql(u8, verb, "mode")) return .{ .mode = try Name.init(argument orelse return error.MissingArgument) };
    if (std.mem.eql(u8, verb, "close")) {
        if (argument) |option| {
            if (!std.mem.eql(u8, option, "--quit-if-last-window")) return error.UnknownOption;
        }
        return .{ .close = argument != null };
    }
    inline for (.{ "status", "windows", "monitors", "workspaces", "reload", "quit", "restore", "fullscreen" }) |name| if (std.mem.eql(u8, verb, name)) {
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
    inline for (.{ "swap", "move" }) |name| if (std.mem.eql(u8, verb, name)) return @unionInit(Command, name, std.meta.stringToEnum(Direction, value) orelse return error.InvalidDirection);
    if (std.mem.eql(u8, verb, "layout")) return .{ .layout = std.meta.stringToEnum(Layout, value) orelse return error.InvalidLayout };
    if (std.mem.eql(u8, verb, "split")) return .{ .split = std.meta.stringToEnum(Orientation, value) orelse return error.InvalidOrientation };
    const index = std.fmt.parseInt(usize, value, 10) catch return error.UnknownCommand;
    if (index == 0 or index > workspace_count) return error.InvalidWorkspace;
    if (std.mem.eql(u8, verb, "workspace")) return .{ .workspace = index - 1 };
    if (std.mem.eql(u8, verb, "send-to-workspace")) return .{ .send_to_workspace = index - 1 };
    return error.UnknownCommand;
}
