const suite = @import("../manager.zig");
const Manager = suite.Manager;
const Rect = suite.Rect;
const expect = suite.expect;
const expectFrame = suite.expectFrame;

// The built-in display's usable area is (0, 25, 1440, 875). The gap of 8 points insets it to (8, 33, 1424, 859).

/// Two halves at ratio 0.5 keep 8 points between them: (1424 - 8) / 2 = 708 points each.
pub fn @"two windows split the display at the configured gap"(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    const first = manager.addWindow(editor, .{ .title = "First" });
    const second = manager.addWindow(editor, .{ .title = "Second" });
    try manager.start();
    manager.tick(3);
    const leftmost = if (manager.frame(first).left < manager.frame(second).left) first else second;
    try expectFrame(manager.frame(leftmost), .{ .left = 8, .top = 33, .width = 708, .height = 859 }, "one window on the left half");
    try expectFrame(manager.frame(if (leftmost == first) second else first), .{ .left = 724, .top = 33, .width = 708, .height = 859 }, "the other window on the right half");
}

/// An application that refuses less than 900 points of width, beside an ordinary window.
fn refusingPair(manager: *Manager) !struct { wide: u64, plain: u64 } {
    const notes = manager.addApp("com.example.notes");
    const editor = manager.addApp("com.example.editor");
    const wide = manager.addWindow(notes, .{ .title = "Notes", .minimum = .{ .width = 900, .height = 300 } });
    const plain = manager.addWindow(editor, .{ .title = "Editor" });
    try manager.start();
    manager.tick(24);
    return .{ .wide = wide, .plain = plain };
}

pub fn @"an application that refuses less than 900 points gets a tile at least 900 wide"(manager: *Manager) !void {
    const pair = try refusingPair(manager);
    const report = try manager.report(pair.wide);
    try expect(!report.floating and manager.frame(pair.wide).width >= 900, "a tiled window at least 900 wide, got floating={} width={d}", .{ report.floating, manager.frame(pair.wide).width });
}

/// 1424 - 900 - 8 = 516 points remain for the neighbour.
pub fn @"the neighbour of a window with a learned minimum gets the rest of the display"(manager: *Manager) !void {
    const pair = try refusingPair(manager);
    try expect(!(try manager.report(pair.plain)).floating, "the neighbour to stay tiled", .{});
    const expected: Rect = if (manager.frame(pair.plain).left < manager.frame(pair.wide).left)
        .{ .left = 8, .top = 33, .width = 516, .height = 859 }
    else
        .{ .left = 916, .top = 33, .width = 516, .height = 859 };
    try expectFrame(manager.frame(pair.plain), expected, "the neighbour beside the 900-point tile");
}

/// (1424 - 1000) / 2 = 212 points on each side of a 1000-point window.
pub fn @"a lone window is centered at single_window_max_width"(manager: *Manager) !void {
    manager.world.config.single_window_max_width = 1000;
    const editor = manager.addApp("com.example.editor");
    const lone = manager.addWindow(editor, .{ .title = "Editor" });
    try manager.start();
    manager.tick(3);
    try expectFrame(manager.frame(lone), .{ .left = 220, .top = 33, .width = 1000, .height = 859 }, "the lone window centered");
}

pub fn @"the mouse tile region of a lone window equals its frame"(manager: *Manager) !void {
    manager.world.config.single_window_max_width = 1000;
    manager.world.config.mouse.enabled = true;
    const editor = manager.addApp("com.example.editor");
    const lone = manager.addWindow(editor, .{ .title = "Editor" });
    try manager.start();
    manager.tick(3);
    const hits = manager.world.tile_hits.items;
    try expect(hits.len == 1 and hits[0].window_identity == lone, "one tile region, for window {d}, got {d}", .{ lone, hits.len });
    try expectFrame(hits[0].rect, manager.frame(lone), "the tile region");
}
