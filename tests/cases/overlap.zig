const std = @import("std");
const suite = @import("../manager.zig");
const Manager = suite.Manager;
const Rect = suite.Rect;
const expect = suite.expect;

/// Two windows whose applications refuse less than 900 points of width. 900 + 8 + 900 > 1424, so they cannot stand side by side.
fn widePair(manager: *Manager, same_application: bool) !struct { first: u64, second: u64 } {
    const notes = manager.addApp("com.example.notes");
    const other = if (same_application) notes else manager.addApp("com.example.editor");
    const first = manager.addWindow(notes, .{ .title = "Notes", .minimum = .{ .width = 900, .height = 300 } });
    const second = manager.addWindow(other, .{ .title = "Other", .minimum = .{ .width = 900, .height = 300 } });
    try manager.start();
    manager.tick(24);
    return .{ .first = first, .second = second };
}

pub fn @"two windows that each refuse less than 900 points overlap by 16 points instead of floating"(manager: *Manager) !void {
    const pair = try widePair(manager, false);
    const usable = manager.world.displays.items[0].frame;
    for ([_]u64{ pair.first, pair.second }) |identity| {
        const report = try manager.report(identity);
        const frame = manager.frame(identity);
        try expect(!report.floating and frame.width >= 900 and suite.inside(frame, usable), "window {d} tiled, at least 900 wide and inside the display, got floating={} ({d}, {d}, {d}, {d})", .{ identity, report.floating, frame.left, frame.top, frame.width, frame.height });
    }
    const first = manager.frame(pair.first);
    const second = manager.frame(pair.second);
    const offset = @abs(first.left - second.left);
    try expect(offset == 16 and first.top == second.top and first.width == second.width and first.height == second.height, "frames 16 points apart on the horizontal axis only, got ({d}, {d}, {d}, {d}) and ({d}, {d}, {d}, {d})", .{ first.left, first.top, first.width, first.height, second.left, second.top, second.width, second.height });
}

/// The native adapter does not report a window as on screen when another window of its application has a frame within
/// 4 points, and the manager does not move a window that is not on screen. A workspace switch shows whether it still does.
pub fn @"two overlapped windows of one application still leave the screen with their workspace"(manager: *Manager) !void {
    const pair = try widePair(manager, true);
    manager.tick(20);
    try manager.run("workspace 2");
    manager.tick(2);
    for ([_]u64{ pair.first, pair.second }) |identity| try expect(manager.atCorner(identity), "window {d} hidden with its workspace", .{identity});
}

pub fn @"focus right and left move between two overlapped windows"(manager: *Manager) !void {
    const pair = try widePair(manager, false);
    const leading = if (manager.frame(pair.first).left < manager.frame(pair.second).left) pair.first else pair.second;
    const trailing = if (leading == pair.first) pair.second else pair.first;
    manager.userFocus(leading);
    manager.tick(1);
    try manager.run("focus right");
    try expect(manager.world.focused == trailing, "focus right to reach window {d}, got {d}", .{ trailing, manager.world.focused });
    try manager.run("focus left");
    try expect(manager.world.focused == leading, "focus left to return to window {d}, got {d}", .{ leading, manager.world.focused });
}

pub fn @"closing one of two overlapped windows gives the other the full area"(manager: *Manager) !void {
    const pair = try widePair(manager, false);
    manager.closeWindow(pair.first);
    manager.tick(16);
    try suite.expectFrame(manager.frame(pair.second), .{ .left = 8, .top = 33, .width = 1424, .height = 859 }, "the remaining window on the full area");
}

pub fn @"a third window beside two overlapped windows gets a tile clear of both"(manager: *Manager) !void {
    const pair = try widePair(manager, false);
    const terminal = manager.addApp("com.example.terminal");
    const third = manager.addWindow(terminal, .{ .title = "Terminal" });
    manager.tick(24);
    const usable = manager.world.displays.items[0].frame;
    const frame = manager.frame(third);
    try expect(!(try manager.report(third)).floating and suite.inside(frame, usable), "the third window tiled inside the display, got ({d}, {d}, {d}, {d})", .{ frame.left, frame.top, frame.width, frame.height });
    for ([_]u64{ pair.first, pair.second }) |identity| {
        const other = manager.frame(identity);
        try expect(@import("../fake/world.zig").intersection(frame, other) == null, "the third window clear of window {d}, got ({d}, {d}, {d}, {d}) and ({d}, {d}, {d}, {d})", .{ identity, frame.left, frame.top, frame.width, frame.height, other.left, other.top, other.width, other.height });
        try expect(!(try manager.report(identity)).floating and other.width >= 900, "window {d} still tiled at least 900 wide, got width {d}", .{ identity, other.width });
    }
}

/// The area is 1424 points wide from 8. Three windows in one cascade each give up two steps of 16 points.
pub fn @"three windows that each refuse less than 900 points form a cascade with a strip of each visible"(manager: *Manager) !void {
    const pair = try widePair(manager, true);
    const third = manager.addWindow(manager.world.window(pair.first).?.pid, .{ .title = "Third", .minimum = .{ .width = 900, .height = 300 } });
    manager.tick(24);
    var lefts = [3]f64{ manager.frame(pair.first).left, manager.frame(pair.second).left, manager.frame(third).left };
    std.mem.sort(f64, &lefts, {}, std.sort.asc(f64));
    try expect(lefts[0] == 8 and lefts[1] == 24 and lefts[2] == 40, "left edges at 8, 24 and 40, got {d}, {d} and {d}", .{ lefts[0], lefts[1], lefts[2] });
    for ([_]u64{ pair.first, pair.second, third }) |identity| {
        const report = try manager.report(identity);
        try expect(!report.floating and !report.stale and manager.frame(identity).width == 1392, "window {d} tiled and 1392 wide, got floating={} stale={} width={d}", .{ identity, report.floating, report.stale, manager.frame(identity).width });
    }
}

/// The second window splits a column of 859 points. 500 + 8 + 500 > 859, so the two cannot stand one above the other.
pub fn @"two windows that each refuse less than 500 points of height overlap by 16 points in their column"(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    const notes = manager.addApp("com.example.notes");
    _ = manager.addWindow(editor, .{ .title = "Editor" });
    const upper = manager.addWindow(notes, .{ .title = "Upper", .minimum = .{ .width = 300, .height = 500 } });
    try manager.start();
    manager.tick(8);
    const lower = manager.addWindow(notes, .{ .title = "Lower", .minimum = .{ .width = 300, .height = 500 } });
    manager.tick(24);
    const first = manager.frame(upper);
    const second = manager.frame(lower);
    for ([_]u64{ upper, lower }) |identity| try expect(!(try manager.report(identity)).floating and manager.frame(identity).height >= 500, "window {d} tiled and at least 500 high, got height {d}", .{ identity, manager.frame(identity).height });
    try expect(@abs(first.top - second.top) == 16 and first.left == second.left and first.width == second.width and first.height == second.height, "frames 16 points apart on the vertical axis only, got ({d}, {d}, {d}, {d}) and ({d}, {d}, {d}, {d})", .{ first.left, first.top, first.width, first.height, second.left, second.top, second.width, second.height });
}

/// 1420 + 16 > 1424, so the window is too wide to overlap its neighbour.
pub fn @"a window too wide to overlap its neighbour floats"(manager: *Manager) !void {
    const notes = manager.addApp("com.example.notes");
    const editor = manager.addApp("com.example.editor");
    const wide = manager.addWindow(notes, .{ .title = "Notes", .minimum = .{ .width = 1420, .height = 300 } });
    const plain = manager.addWindow(editor, .{ .title = "Editor" });
    try manager.start();
    manager.tick(24);
    try expect((try manager.report(wide)).floating and !(try manager.report(plain)).floating, "the wide window floating and its neighbour tiled", .{});
}

pub fn @"resize changes nothing on two overlapped windows"(manager: *Manager) !void {
    const pair = try widePair(manager, false);
    const before = [2]Rect{ manager.frame(pair.first), manager.frame(pair.second) };
    const reply = try manager.parse(struct { ok: bool, applied_delta: f64 }, "resize width 100");
    manager.tick(8);
    try expect(reply.ok and reply.applied_delta == 0, "an applied delta of 0, got {d}", .{reply.applied_delta});
    try expect(suite.near(manager.frame(pair.first), before[0]) and suite.near(manager.frame(pair.second), before[1]), "both frames unchanged", .{});
}

/// A frame written on every scan makes the window flicker, so the count of writes is the behavior here.
pub fn @"the manager writes no frame during quiet ticks with two overlapped windows"(manager: *Manager) !void {
    _ = try widePair(manager, true);
    manager.tick(20);
    const before = manager.world.frame_writes;
    manager.tick(60);
    try expect(manager.world.frame_writes == before, "no frame write in 60 quiet ticks, got {d}", .{manager.world.frame_writes - before});
}

/// The pair and the third window stand side by side, so that split is the one boundary the mouse can drag.
pub fn @"the mouse gets no resize boundary between two overlapped windows"(manager: *Manager) !void {
    manager.world.config.mouse.enabled = true;
    _ = try widePair(manager, false);
    const terminal = manager.addApp("com.example.terminal");
    const third = manager.addWindow(terminal, .{ .title = "Terminal" });
    manager.tick(24);
    const hits = manager.world.boundary_hits.items;
    try expect(hits.len == 1, "one boundary region, got {d}", .{hits.len});
    const edge = manager.frame(third).left;
    try expect(hits[0].rect.left < edge and edge - hits[0].rect.left < 30, "the boundary beside the third window at {d}, got {d}", .{ edge, hits[0].rect.left });
}

pub fn @"the master and the stack overlap by 16 points when both refuse less than 900 points"(manager: *Manager) !void {
    const pair = try widePair(manager, false);
    try manager.run("layout master");
    manager.tick(24);
    const first = manager.frame(pair.first);
    const second = manager.frame(pair.second);
    for ([_]u64{ pair.first, pair.second }) |identity| try expect(!(try manager.report(identity)).floating, "window {d} tiled", .{identity});
    try expect(@abs(first.left - second.left) == 16 and first.width == 1408 and second.width == 1408, "two frames 1408 wide and 16 points apart, got ({d}, {d}) and ({d}, {d})", .{ first.left, first.width, second.left, second.width });
}
