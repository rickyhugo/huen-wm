const std = @import("std");

pub const Layout = enum { dwindle, master };
pub const Direction = enum { left, right, up, down };
pub const Axis = enum { width, height };
pub const Orientation = enum { horizontal, vertical, toggle };
pub const Command = union(enum) {
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
    resize_points: struct { axis: Axis, delta: f64 },
    split: Orientation,
    fullscreen,
    toggle_floating,
    layout: Layout,
    workspace: usize,
    send_to_workspace: usize,
};

pub fn parse(input: []const u8, workspace_count: usize) !Command {
    var tokens = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const verb = tokens.next() orelse return error.MissingCommand;
    const argument = tokens.next();
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
    if (tokens.next() != null) return error.ExtraArgument;
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
    inline for (.{ "focus", "swap", "move" }) |name| if (std.mem.eql(u8, verb, name)) return @unionInit(Command, name, std.meta.stringToEnum(Direction, value) orelse return error.InvalidDirection);
    if (std.mem.eql(u8, verb, "layout")) return .{ .layout = std.meta.stringToEnum(Layout, value) orelse return error.InvalidLayout };
    if (std.mem.eql(u8, verb, "split")) return .{ .split = std.meta.stringToEnum(Orientation, value) orelse return error.InvalidOrientation };
    const index = std.fmt.parseInt(usize, value, 10) catch return error.UnknownCommand;
    if (index == 0 or index > workspace_count) return error.InvalidWorkspace;
    if (std.mem.eql(u8, verb, "workspace")) return .{ .workspace = index - 1 };
    if (std.mem.eql(u8, verb, "send-to-workspace")) return .{ .send_to_workspace = index - 1 };
    return error.UnknownCommand;
}
