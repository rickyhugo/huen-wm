//! The seam is `layout.Store`: the tiled windows of a workspace go in with `sync` and `arrange`, and each window's
//! tile comes out of `goal`. The area is a display's usable area inside the gap.
const std = @import("std");
const layout = @import("layout");

const Rect = layout.Rect;
const Kind = @FieldType(layout.WorkspaceLayout, "layout");

var store: layout.Store = .{};
var tiles_buffer: [32]Rect = undefined;

/// Windows open one at a time, and each new window has focus when the next one opens.
fn tiles(kind: Kind, count: usize, area: Rect, ratio: f64, gap: f64) ![]const Rect {
    store = .{};
    const state = store.ensureWorkspace(1, 0, kind, ratio);
    var members: [32]layout.Member = undefined;
    for (0..count) |index| {
        members[index] = .{ .identity = index + 1, .display = 1, .workspace = 0, .active = true, .tiled = true, .area = area };
        try store.sync(members[0 .. index + 1], if (index == 0) null else index, gap);
        store.arrange(state, area, gap);
    }
    for (0..count) |index| tiles_buffer[index] = store.goal(index + 1) orelse return error.WindowWithoutTile;
    return tiles_buffer[0..count];
}

/// Tiles that grow by half the gap on each side fill the area grown the same way exactly once: no tile leaves the
/// area, no two tiles are closer than the gap, and no space is left over.
fn expectFilled(found: []const Rect, area: Rect, gap: f64) !void {
    var covered: f64 = 0;
    for (found, 0..) |tile, index| {
        if (tile.left < area.left - 0.01 or tile.top < area.top - 0.01 or tile.left + tile.width > area.left + area.width + 0.01 or tile.top + tile.height > area.top + area.height + 0.01) return error.TileOutsideArea;
        for (found[index + 1 ..]) |other| {
            const across = @max(other.left - (tile.left + tile.width), tile.left - (other.left + other.width));
            const down = @max(other.top - (tile.top + tile.height), tile.top - (other.top + other.height));
            if (@max(across, down) < gap - 0.01) return error.TilesCloserThanGap;
        }
        covered += (tile.width + gap) * (tile.height + gap);
    }
    if (@abs(covered - (area.width + gap) * (area.height + gap)) > 1) return error.AreaNotFilled;
}

const landscape: Rect = .{ .left = 20, .top = 45, .width = 1400, .height = 800 };
const portrait: Rect = .{ .left = 20, .top = 45, .width = 800, .height = 1400 };

fn expectEveryCountFills(kind: Kind) !void {
    for ([_]Rect{ landscape, portrait }) |area| for ([_]f64{ 0.3, 0.5, 0.7 }) |ratio| for ([_]f64{ 0, 8, 20 }) |gap| for (1..9) |count| {
        expectFilled(try tiles(kind, count, area, ratio, gap), area, gap) catch |err| {
            std.debug.print("{d} windows in {d} by {d} at ratio {d} and gap {d}\n", .{ count, area.width, area.height, ratio, gap });
            return err;
        };
    };
}

test "dwindle tiles of 1 to 8 windows fill the area with the gap between them" {
    try expectEveryCountFills(.dwindle);
}

test "master tiles of 1 to 8 windows fill the area with the gap between them" {
    try expectEveryCountFills(.master);
}

// The first split is at the workspace ratio: 0.75 * 1400 = 1050 points. The second window's tile is 350 by 800, so
// the third window splits its height in half.
test "the third dwindle window takes the lower half of the second window's tile" {
    const expected = [_]Rect{
        .{ .left = 20, .top = 45, .width = 1050, .height = 800 },
        .{ .left = 1070, .top = 45, .width = 350, .height = 400 },
        .{ .left = 1070, .top = 445, .width = 350, .height = 400 },
    };
    for (try tiles(.dwindle, 3, landscape, 0.75, 0), expected, 1..) |found, wanted, window| {
        if (@abs(found.left - wanted.left) < 0.01 and @abs(found.top - wanted.top) < 0.01 and @abs(found.width - wanted.width) < 0.01 and @abs(found.height - wanted.height) < 0.01) continue;
        std.debug.print("window {d} at ({d}, {d}, {d}, {d}), expected ({d}, {d}, {d}, {d})\n", .{ window, found.left, found.top, found.width, found.height, wanted.left, wanted.top, wanted.width, wanted.height });
        return error.TestUnexpectedResult;
    }
}

test "no dwindle tile of 1 to 24 windows is under 80 points wide or high" {
    for (1..25) |count| for (try tiles(.dwindle, count, landscape, 0.5, 8)) |tile| {
        if (tile.width >= 80 and tile.height >= 80) continue;
        std.debug.print("{d} windows: a tile of {d} by {d}\n", .{ count, tile.width, tile.height });
        return error.TileUnderMinimum;
    };
}
