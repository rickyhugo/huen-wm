const std = @import("std");

pub const Layout = enum { dwindle, master };
pub const Direction = enum { left, right, up, down };
pub const Axis = enum { width, height };
pub const Orientation = enum { horizontal, vertical, toggle };
pub const Selection = enum { parent, child };
pub const GroupMode = enum { tabbed, stacked };
pub const Group = union(enum) { join: Direction, tabbed, stacked, split, next, previous };
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
pub const Step = enum { next, previous };
pub const WindowKind = enum { tiled, floating };
pub const Cycle = struct { step: Step, kind: ?WindowKind = null };
pub const Offset = struct { horizontal: f64, vertical: f64 };
pub const RelativeScope = enum { all, occupied };
pub const EmptySearch = enum { first, next };
pub const WorkspaceSelector = union(enum) {
    index: usize,
    name: Name,
    previous,
    relative: struct { scope: RelativeScope, offset: i8 },
    empty: EmptySearch,
};
pub const MonitorClass = enum { @"built-in", external };
pub const MonitorSelector = union(enum) {
    direction: Direction,
    step: Step,
    class: MonitorClass,
    name: Name,
};
pub const Launch = struct { bundle: Name, new_instance: bool = false, hidden: bool = false };
pub const Command = union(enum) {
    status,
    windows,
    monitors,
    workspaces,
    reload,
    quit,
    restore,
    focus: Focus,
    focus_last,
    focus_urgent,
    cycle: Cycle,
    mode: Name,
    launch: Launch,
    exec_and_forget: []const u8,
    close: bool,
    swap: Direction,
    swap_cycle: Step,
    move: Direction,
    tilemove: Direction,
    select: Selection,
    group: Group,
    resize: f64,
    resize_points: struct { axis: Axis, delta: f64 },
    resize_by: Offset,
    move_by: Offset,
    center,
    split: Orientation,
    fullscreen,
    toggle_floating,
    layout: Layout,
    workspace: WorkspaceSelector,
    send_to_workspace: WorkspaceSelector,
    move_to_workspace: WorkspaceSelector,
    focus_monitor: MonitorSelector,
    send_to_monitor: MonitorSelector,
    move_to_monitor: MonitorSelector,
    move_workspace_to_monitor: MonitorSelector,
    swap_monitor_workspaces: MonitorSelector,
};

fn pointDelta(value: []const u8) !f64 {
    const delta = try std.fmt.parseFloat(f64, value);
    if (!std.math.isFinite(delta) or @abs(delta) > 10000) return error.InvalidPointDelta;
    return delta;
}

pub fn parseMonitorSelector(value: []const u8) !MonitorSelector {
    if (std.mem.startsWith(u8, value, "name:")) return .{ .name = Name.init(value["name:".len..]) catch return error.InvalidMonitorName };
    if (std.meta.stringToEnum(Direction, value)) |direction| return .{ .direction = direction };
    if (std.meta.stringToEnum(Step, value)) |step| return .{ .step = step };
    if (std.meta.stringToEnum(MonitorClass, value)) |class| return .{ .class = class };
    return error.InvalidMonitorSelector;
}

pub fn parse(input: []const u8, workspace_count: usize) !Command {
    if (input.len > 511 or std.mem.indexOfScalar(u8, input, 0) != null or std.mem.indexOfAny(u8, input, "\r\n") != null or !std.unicode.utf8ValidateSlice(input)) return error.InvalidCommandText;
    var tokens = std.mem.tokenizeAny(u8, input, " \t");
    const verb = tokens.next() orelse return error.MissingCommand;
    if (std.mem.eql(u8, verb, "exec-and-forget")) {
        const shell = std.mem.trimStart(u8, tokens.rest(), " \t");
        if (shell.len == 0) return error.MissingArgument;
        return .{ .exec_and_forget = shell };
    }
    var argument = tokens.next();
    inline for (.{ .{ "workspace", "workspace" }, .{ "send-to-workspace", "send_to_workspace" }, .{ "move-to-workspace", "move_to_workspace" } }) |verb_tag| if (std.mem.eql(u8, verb, verb_tag[0])) {
        const value = argument orelse return error.MissingArgument;
        if (std.mem.startsWith(u8, value, "name:")) {
            const start = @intFromPtr(value.ptr) - @intFromPtr(input.ptr) + "name:".len;
            return @unionInit(Command, verb_tag[1], .{ .name = try Name.init(std.mem.trimEnd(u8, input[start..], " \t")) });
        }
        if (tokens.next() != null) return error.ExtraArgument;
        return @unionInit(Command, verb_tag[1], selector: {
            if (std.mem.eql(u8, value, "previous")) break :selector .previous;
            if (std.mem.eql(u8, value, "empty")) break :selector .{ .empty = .first };
            if (std.mem.eql(u8, value, "next-empty")) break :selector .{ .empty = .next };
            const occupied = std.mem.startsWith(u8, value, "occupied");
            const offset_text = if (occupied) value["occupied".len..] else value;
            if (offset_text.len > 0 and (offset_text[0] == '+' or offset_text[0] == '-')) {
                const offset = std.fmt.parseInt(i8, offset_text, 10) catch return error.InvalidWorkspaceOffset;
                if (offset == 0 or @abs(offset) > 10) return error.InvalidWorkspaceOffset;
                break :selector .{ .relative = .{ .scope = if (occupied) .occupied else .all, .offset = offset } };
            }
            if (!std.ascii.isDigit(value[0])) return error.InvalidWorkspaceSelector;
            const index = std.fmt.parseInt(usize, value, 10) catch return error.InvalidWorkspaceSelector;
            if (index == 0 or index > workspace_count) return error.InvalidWorkspace;
            break :selector .{ .index = index - 1 };
        });
    };
    inline for (.{ .{ "focus-monitor", "focus_monitor" }, .{ "send-to-monitor", "send_to_monitor" }, .{ "move-to-monitor", "move_to_monitor" }, .{ "move-workspace-to-monitor", "move_workspace_to_monitor" }, .{ "swap-monitor-workspaces", "swap_monitor_workspaces" } }) |verb_tag| if (std.mem.eql(u8, verb, verb_tag[0])) {
        const value = argument orelse return error.MissingArgument;
        if (std.mem.startsWith(u8, value, "name:")) {
            const start = @intFromPtr(value.ptr) - @intFromPtr(input.ptr);
            return @unionInit(Command, verb_tag[1], try parseMonitorSelector(std.mem.trimEnd(u8, input[start..], " \t")));
        }
        if (tokens.next() != null) return error.ExtraArgument;
        return @unionInit(Command, verb_tag[1], try parseMonitorSelector(value));
    };
    if (std.mem.eql(u8, verb, "group")) {
        const action = argument orelse return error.MissingArgument;
        if (std.mem.eql(u8, action, "join")) {
            const direction = std.meta.stringToEnum(Direction, tokens.next() orelse return error.MissingArgument) orelse return error.InvalidDirection;
            if (tokens.next() != null) return error.ExtraArgument;
            return .{ .group = .{ .join = direction } };
        }
        if (tokens.next() != null) return error.ExtraArgument;
        inline for (.{ "tabbed", "stacked", "split", "next", "previous" }) |name| if (std.mem.eql(u8, action, name)) return .{ .group = @unionInit(Group, name, {}) };
        return error.InvalidGroupAction;
    }
    if (std.mem.eql(u8, verb, "resize")) {
        const value = argument orelse return error.MissingArgument;
        if (std.meta.stringToEnum(Axis, value)) |axis| {
            const delta = try pointDelta(tokens.next() orelse return error.MissingArgument);
            if (tokens.next() != null) return error.ExtraArgument;
            return .{ .resize_points = .{ .axis = axis, .delta = delta } };
        }
        if (tokens.next() != null) return error.ExtraArgument;
        const delta = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(delta) or @abs(delta) > 0.5) return error.InvalidRatioDelta;
        return .{ .resize = delta };
    }
    if (std.mem.eql(u8, verb, "launch")) {
        var new_instance = false;
        var hidden = false;
        while (argument) |option| : (argument = tokens.next()) {
            if (std.mem.eql(u8, option, "--new-instance") and !new_instance) new_instance = true else if (std.mem.eql(u8, option, "--hidden") and !hidden) hidden = true else break;
        }
        const bundle = try Name.init(argument orelse return error.MissingArgument);
        if (bundle.bytes[0] == '-') return error.UnknownOption;
        for (bundle.text()) |character| if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-') return error.InvalidBundle;
        if (tokens.next() != null) return error.ExtraArgument;
        return .{ .launch = .{ .bundle = bundle, .new_instance = new_instance, .hidden = hidden } };
    }
    if (std.mem.eql(u8, verb, "focus")) {
        inline for (.{ .{ "last", "focus_last" }, .{ "urgent", "focus_urgent" } }) |target_tag| if (argument != null and std.mem.eql(u8, argument.?, target_tag[0])) {
            if (tokens.next() != null) return error.ExtraArgument;
            return @unionInit(Command, target_tag[1], {});
        };
        const wrap = argument != null and std.mem.eql(u8, argument.?, "--wrap");
        if (wrap) argument = tokens.next();
        const direction = std.meta.stringToEnum(Direction, argument orelse return error.MissingArgument) orelse return error.InvalidDirection;
        if (tokens.next() != null) return error.ExtraArgument;
        return .{ .focus = .{ .direction = direction, .wrap = wrap } };
    }
    inline for (.{ .{ "move-by", "move_by" }, .{ "resize-by", "resize_by" } }) |verb_tag| if (std.mem.eql(u8, verb, verb_tag[0])) {
        const horizontal = try pointDelta(argument orelse return error.MissingArgument);
        const vertical = try pointDelta(tokens.next() orelse return error.MissingArgument);
        if (tokens.next() != null) return error.ExtraArgument;
        return @unionInit(Command, verb_tag[1], .{ .horizontal = horizontal, .vertical = vertical });
    };
    if (std.mem.eql(u8, verb, "cycle")) {
        const step = std.meta.stringToEnum(Step, argument orelse return error.MissingArgument) orelse return error.InvalidStep;
        const kind = if (tokens.next()) |value| std.meta.stringToEnum(WindowKind, value) orelse return error.InvalidWindowKind else null;
        if (tokens.next() != null) return error.ExtraArgument;
        return .{ .cycle = .{ .step = step, .kind = kind } };
    }
    if (tokens.next() != null) return error.ExtraArgument;
    if (std.mem.eql(u8, verb, "mode")) return .{ .mode = try Name.init(argument orelse return error.MissingArgument) };
    if (std.mem.eql(u8, verb, "close")) {
        if (argument) |option| if (!std.mem.eql(u8, option, "--quit-if-last-window")) return error.UnknownOption;
        return .{ .close = argument != null };
    }
    inline for (.{ .{ "status", "status" }, .{ "windows", "windows" }, .{ "monitors", "monitors" }, .{ "workspaces", "workspaces" }, .{ "reload", "reload" }, .{ "quit", "quit" }, .{ "stop", "quit" }, .{ "restore", "restore" }, .{ "recover", "restore" }, .{ "fullscreen", "fullscreen" }, .{ "center", "center" }, .{ "toggle-floating", "toggle_floating" } }) |verb_tag| if (std.mem.eql(u8, verb, verb_tag[0])) {
        if (argument != null) return error.ExtraArgument;
        return @unionInit(Command, verb_tag[1], {});
    };
    const value = argument orelse return error.MissingArgument;
    if (std.mem.eql(u8, verb, "swap")) if (std.meta.stringToEnum(Step, value)) |step| return .{ .swap_cycle = step };
    inline for (.{ "swap", "move", "tilemove" }) |name| if (std.mem.eql(u8, verb, name)) return @unionInit(Command, name, std.meta.stringToEnum(Direction, value) orelse return error.InvalidDirection);
    if (std.mem.eql(u8, verb, "select")) return .{ .select = std.meta.stringToEnum(Selection, value) orelse return error.InvalidSelection };
    if (std.mem.eql(u8, verb, "layout")) return .{ .layout = std.meta.stringToEnum(Layout, value) orelse return error.InvalidLayout };
    if (std.mem.eql(u8, verb, "split")) return .{ .split = std.meta.stringToEnum(Orientation, value) orelse return error.InvalidOrientation };
    return error.UnknownCommand;
}
