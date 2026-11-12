const std = @import("std");

pub const Layout = enum { dwindle, master };
pub const Direction = enum { left, right, up, down };
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
    toggle_floating,
    layout: Layout,
    workspace: usize,
    send_to_workspace: usize,
};

pub fn parse(input: []const u8, workspace_count: usize) !Command {
    var tokens = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const verb = tokens.next() orelse return error.MissingCommand;
    const argument = tokens.next();
    if (tokens.next() != null) return error.ExtraArgument;
    inline for (.{ "status", "windows", "monitors", "workspaces", "reload", "quit", "restore" }) |name| if (std.mem.eql(u8, verb, name)) {
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
