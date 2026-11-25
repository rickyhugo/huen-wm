const suite = @import("../manager.zig");
const Manager = suite.Manager;
const Rect = suite.Rect;
const expect = suite.expect;
const expectFrame = suite.expectFrame;

// The external display's usable area is (1440, 25, 1920, 1055). The gap of 8 points insets it to (1448, 33, 1904, 1039).
const on_external: Rect = .{ .left = 1800, .top = 200, .width = 800, .height = 600 };

pub fn @"a window that opens on the external display fills that display"(manager: *Manager) !void {
    manager.connectExternal();
    const editor = manager.addApp("com.example.editor");
    _ = manager.addWindow(editor, .{ .title = "Built-in" });
    const far = manager.addWindow(editor, .{ .title = "External", .frame = on_external });
    try manager.start();
    manager.tick(8);
    try expectFrame(manager.frame(far), .{ .left = 1448, .top = 33, .width = 1904, .height = 1039 }, "the window on the external display");
}

/// One window on each display, with the built-in display's window focused.
fn windowPerDisplay(manager: *Manager) !struct { near: u64, far: u64 } {
    manager.connectExternal();
    const editor = manager.addApp("com.example.editor");
    const far = manager.addWindow(editor, .{ .title = "External", .frame = on_external });
    const near = manager.addWindow(editor, .{ .title = "Built-in" });
    try manager.start();
    manager.tick(8);
    return .{ .near = near, .far = far };
}

pub fn @"a workspace switch on the built-in display leaves the external display's window in place"(manager: *Manager) !void {
    const pair = try windowPerDisplay(manager);
    try manager.run("workspace 2");
    manager.tick(8);
    try expect(manager.atCorner(pair.near), "the built-in display's window out of sight", .{});
    try expectFrame(manager.frame(pair.far), .{ .left = 1448, .top = 33, .width = 1904, .height = 1039 }, "the window on the external display");
}

/// Two windows on the external display split it: (1904 - 8) / 2 = 948 points each.
pub fn @"move-to-monitor moves the focused window to the other display's workspace"(manager: *Manager) !void {
    const pair = try windowPerDisplay(manager);
    try manager.run("move-to-monitor external");
    manager.tick(8);
    try expectHalves(manager, pair.near, pair.far, external_left, external_right, "the external display");
}

/// The built-in display shows workspace 1, so the window from the external display's workspace 3 stays out of sight until workspace 3 shows.
pub fn @"a window of a disconnected display shows on the built-in display under its workspace number"(manager: *Manager) !void {
    const pair = try windowPerDisplay(manager);
    manager.userFocus(pair.far);
    manager.tick(2);
    try manager.run("move-to-workspace 3");
    manager.tick(8);
    manager.disconnectExternal();
    manager.tick(8);
    const hidden = (try manager.report(pair.far)).workspace == 3 and manager.atCorner(pair.far);
    try manager.run("workspace 3");
    manager.tick(8);
    try expect(hidden, "the window on workspace 3 and out of sight before workspace 3 shows", .{});
    try expectFrame(manager.frame(pair.far), .{ .left = 8, .top = 33, .width = 1424, .height = 859 }, "the window on the built-in display");
}

/// `workspace_monitors` puts every workspace on the external display. Both windows open on the built-in display.
fn ownerPair(manager: *Manager) !struct { first: u64, second: u64 } {
    manager.connectExternal();
    manager.world.config.workspace_monitors = &.{ "external", "built-in" };
    const editor = manager.addApp("com.example.editor");
    const first = manager.addWindow(editor, .{ .title = "First" });
    const second = manager.addWindow(editor, .{ .title = "Second" });
    try manager.start();
    manager.tick(8);
    return .{ .first = first, .second = second };
}

fn expectHalves(manager: *Manager, first: u64, second: u64, left: Rect, right: Rect, comptime display: []const u8) !void {
    const leftmost = if (manager.frame(first).left < manager.frame(second).left) first else second;
    try expectFrame(manager.frame(leftmost), left, "one window on the left half of " ++ display);
    try expectFrame(manager.frame(if (leftmost == first) second else first), right, "the other window on the right half of " ++ display);
}

const external_left: Rect = .{ .left = 1448, .top = 33, .width = 948, .height = 1039 };
const external_right: Rect = .{ .left = 2404, .top = 33, .width = 948, .height = 1039 };

pub fn @"with workspace_monitors a window that opens on the built-in display tiles on the external display"(manager: *Manager) !void {
    const pair = try ownerPair(manager);
    try expectHalves(manager, pair.first, pair.second, external_left, external_right, "the external display");
}

// The built-in display's gapped area is (8, 33, 1424, 859), and two halves are (1424 - 8) / 2 = 708 points wide.
const builtin_left: Rect = .{ .left = 8, .top = 33, .width = 708, .height = 859 };
const builtin_right: Rect = .{ .left = 724, .top = 33, .width = 708, .height = 859 };

pub fn @"with workspace_monitors the windows of a disconnected external display tile on the built-in display"(manager: *Manager) !void {
    const pair = try ownerPair(manager);
    manager.disconnectExternal();
    manager.tick(8);
    try expectHalves(manager, pair.first, pair.second, builtin_left, builtin_right, "the built-in display");
}

pub fn @"with workspace_monitors the windows return to the external display when it reconnects"(manager: *Manager) !void {
    const pair = try ownerPair(manager);
    manager.disconnectExternal();
    manager.tick(8);
    manager.connectExternal();
    manager.tick(8);
    try expectHalves(manager, pair.first, pair.second, external_left, external_right, "the external display");
}
