const suite = @import("../manager.zig");
const Manager = suite.Manager;
const Rect = suite.Rect;
const expect = suite.expect;
const expectFrame = suite.expectFrame;

// The built-in display's usable area is (0, 25, 1440, 875). The gap of 8 points insets it to (8, 33, 1424, 859).
// Two halves at ratio 0.5 keep 8 points between them: (1424 - 8) / 2 = 708 points each.
const whole: Rect = .{ .left = 8, .top = 33, .width = 1424, .height = 859 };
const left_half: Rect = .{ .left = 8, .top = 33, .width = 708, .height = 859 };
const right_half: Rect = .{ .left = 724, .top = 33, .width = 708, .height = 859 };

/// Two tiled windows of one application, with the window on the right half focused.
fn halves(manager: *Manager) !struct { left: u64, right: u64 } {
    const editor = manager.addApp("com.example.editor");
    const first = manager.addWindow(editor, .{ .title = "First" });
    const second = manager.addWindow(editor, .{ .title = "Second" });
    try manager.start();
    manager.tick(3);
    const first_on_left = manager.frame(first).left < manager.frame(second).left;
    const left = if (first_on_left) first else second;
    const right = if (first_on_left) second else first;
    manager.userFocus(right);
    manager.tick(2);
    return .{ .left = left, .right = right };
}

pub fn @"swap left exchanges the tiles of two windows"(manager: *Manager) !void {
    const pair = try halves(manager);
    try manager.run("swap left");
    manager.tick(4);
    try expectFrame(manager.frame(pair.right), left_half, "the focused window on the left half");
    try expectFrame(manager.frame(pair.left), right_half, "the other window on the right half");
}

/// Managed fullscreen fills the usable area without the gap.
pub fn @"fullscreen fills the display's usable area with the focused window"(manager: *Manager) !void {
    const pair = try halves(manager);
    try manager.run("fullscreen");
    manager.tick(4);
    try expectFrame(manager.frame(pair.right), .{ .left = 0, .top = 25, .width = 1440, .height = 875 }, "the focused window");
}

pub fn @"fullscreen a second time returns the window to its tile"(manager: *Manager) !void {
    const pair = try halves(manager);
    try manager.run("fullscreen");
    manager.tick(4);
    try manager.run("fullscreen");
    manager.tick(4);
    try expectFrame(manager.frame(pair.right), right_half, "the focused window");
}

/// The ratio 0.6 gives the left window 0.6 * (1424 - 8) = 849.6 points and the right window 566.4.
pub fn @"resize 0.1 moves the split between two windows to ratio 0.6"(manager: *Manager) !void {
    const pair = try halves(manager);
    try manager.run("resize 0.1");
    manager.tick(4);
    try expectFrame(manager.frame(pair.left), .{ .left = 8, .top = 33, .width = 849.6, .height = 859 }, "the left window");
    try expectFrame(manager.frame(pair.right), .{ .left = 865.6, .top = 33, .width = 566.4, .height = 859 }, "the right window");
}

/// Half of the area inside the gap is 712 by 429.5 points. Centered in (8, 33, 1424, 859), it starts at (364, 247.75).
pub fn @"toggle-floating floats a window that never floated at half the area inside the gap, centered"(manager: *Manager) !void {
    const pair = try halves(manager);
    try manager.run("toggle-floating");
    manager.tick(4);
    try expectFrame(manager.frame(pair.right), .{ .left = 364, .top = 247.75, .width = 712, .height = 429.5 }, "the floating window");
}

/// The master column is 708 points wide. The three stack rows share the height: (859 - 2 * 8) / 3 = 281 points each.
/// Dwindle never gives four windows three equal rows.
pub fn @"layout master gives one window the left half and stacks the other three on the right"(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    var members: [4]u64 = undefined;
    for (&members, [_][]const u8{ "First", "Second", "Third", "Fourth" }) |*member, title| member.* = manager.addWindow(editor, .{ .title = title });
    try manager.start();
    manager.tick(3);
    try manager.run("layout master");
    manager.tick(4);
    var master: usize = 0;
    var rows = [_]usize{ 0, 0, 0 };
    for (members) |member| {
        const frame = manager.frame(member);
        master += @intFromBool(suite.near(frame, left_half));
        for (&rows, [_]f64{ 33, 322, 611 }) |*row, top| row.* += @intFromBool(suite.near(frame, .{ .left = 724, .top = top, .width = 708, .height = 281 }));
    }
    try expect(master == 1 and rows[0] == 1 and rows[1] == 1 and rows[2] == 1, "one window on each of the master tile and the three stack rows, got {d} and {any}", .{ master, rows });
}

pub fn @"move-to-workspace 2 shows workspace 2 with the moved window alone on it"(manager: *Manager) !void {
    const pair = try halves(manager);
    try manager.run("move-to-workspace 2");
    manager.tick(8);
    const shown = try manager.shownWorkspace();
    try expect(shown == 2, "workspace 2 shown, got {d}", .{shown});
    try expectFrame(manager.frame(pair.right), whole, "the moved window");
}

pub fn @"workspace previous returns to the workspace shown before the last switch"(manager: *Manager) !void {
    _ = try halves(manager);
    try manager.run("workspace 3");
    manager.tick(8);
    try manager.run("workspace 2");
    manager.tick(8);
    try manager.run("workspace previous");
    manager.tick(8);
    const shown = try manager.shownWorkspace();
    try expect(shown == 3, "workspace 3 shown, got {d}", .{shown});
}

pub fn @"close closes the focused window and the other window gets the whole area"(manager: *Manager) !void {
    const pair = try halves(manager);
    try manager.run("close");
    manager.tick(4);
    try expect(manager.world.window(pair.right) == null, "the focused window closed", .{});
    try expectFrame(manager.frame(pair.left), whole, "the other window");
}

/// A gap of 20 points insets the usable area to (20, 45, 1400, 835), and two halves are (1400 - 20) / 2 = 690 points wide.
pub fn @"reload applies a changed gap to the tiles"(manager: *Manager) !void {
    const pair = try halves(manager);
    manager.world.config.gap = 20;
    try manager.run("reload");
    manager.tick(8);
    try expectFrame(manager.frame(pair.left), .{ .left = 20, .top = 45, .width = 690, .height = 835 }, "the left window");
    try expectFrame(manager.frame(pair.right), .{ .left = 730, .top = 45, .width = 690, .height = 835 }, "the right window");
}
