const std = @import("std");
const commands = @import("command.zig");
const configuration = @import("config.zig");

pub const Occupancy = std.bit_set.IntegerBitSet(10);
pub const View = struct {
    config: *const configuration.ConfigCandidate,
    current: usize,
    previous: ?usize,
    occupied: Occupancy,
};

pub fn resolve(selection: commands.WorkspaceSelector, view: View) !usize {
    return switch (selection) {
        .index => |index| index,
        .name => |name| view.config.workspaceIndex(name.text()) orelse error.UnknownWorkspaceName,
        .previous => view.previous orelse error.NoPreviousWorkspace,
        .relative => |relative| switch (relative.scope) {
            .all => wrap(view.current, relative.offset, view.config.workspace_count),
            .occupied => occupiedStep(view, relative.offset),
        },
        .empty => |search| emptyWorkspace(view, search) orelse error.NoEmptyWorkspace,
    };
}

fn wrap(position: usize, offset: i8, count: usize) usize {
    return @intCast(@mod(@as(isize, @intCast(position)) + offset, @as(isize, @intCast(count))));
}

fn occupiedStep(view: View, offset: i8) usize {
    var members: [10]usize = undefined;
    var count: usize = 0;
    var position: usize = 0;
    for (0..view.config.workspace_count) |index| {
        if (index != view.current and !view.occupied.isSet(index)) continue;
        if (index == view.current) position = count;
        members[count] = index;
        count += 1;
    }
    return members[wrap(position, offset, count)];
}

fn emptyWorkspace(view: View, search: commands.EmptySearch) ?usize {
    const count = view.config.workspace_count;
    const start: usize = switch (search) {
        .first => 0,
        .next => 1,
    };
    for (start..count) |distance| {
        const index = switch (search) {
            .first => distance,
            .next => (view.current + distance) % count,
        };
        if (!view.occupied.isSet(index)) return index;
    }
    return null;
}
