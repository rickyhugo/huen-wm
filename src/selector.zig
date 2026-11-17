const std = @import("std");
const commands = @import("command.zig");
const configuration = @import("config.zig");

pub const Occupancy = std.bit_set.IntegerBitSet(10);
pub const View = struct {
    config: *const configuration.ConfigCandidate,
    current: usize,
    previous: ?usize,
    occupied: Occupancy,
    back_and_forth: bool,
};

pub fn resolve(selection: commands.WorkspaceSelector, view: View) !usize {
    const index = switch (selection) {
        .index => |position| position,
        .name => |name| view.config.workspaceIndex(name.text()) orelse return error.UnknownWorkspaceName,
        .previous => return view.previous orelse error.NoPreviousWorkspace,
        .relative => |relative| {
            if (relative.scope == .all) return wrap(view.current, relative.offset, view.config.workspace_count);
            var members: [10]usize = undefined;
            var count: usize = 0;
            var position: usize = 0;
            for (0..view.config.workspace_count) |workspace| {
                if (workspace != view.current and !view.occupied.isSet(workspace)) continue;
                if (workspace == view.current) position = count;
                members[count] = workspace;
                count += 1;
            }
            return members[wrap(position, relative.offset, count)];
        },
        .empty => |search| {
            const count = view.config.workspace_count;
            const origin = if (search == .next) view.current else 0;
            for (@intFromBool(search == .next)..count) |distance| if (!view.occupied.isSet((origin + distance) % count)) return (origin + distance) % count;
            return error.NoEmptyWorkspace;
        },
    };
    if (index != view.current or !view.back_and_forth) return index;
    return view.previous orelse index;
}

pub fn cycleTarget(order: []const u64, current: ?u64, step: commands.Step) ?u64 {
    if (order.len == 0) return null;
    const found = if (current) |identity| std.mem.indexOfScalar(u64, order, identity) else null;
    const position = found orelse return if (step == .next) order[0] else order[order.len - 1];
    return switch (step) {
        .next => order[(position + 1) % order.len],
        .previous => order[(position + order.len - 1) % order.len],
    };
}

fn wrap(position: usize, offset: i8, count: usize) usize {
    return @intCast(@mod(@as(isize, @intCast(position)) + offset, @as(isize, @intCast(count))));
}
