const std = @import("std");
const suite = @import("../manager.zig");
const Manager = suite.Manager;
const expect = suite.expect;

/// Two tiled windows with the second focused. `toggle-floating` run once floats it, and run twice tiles it again.
fn hotkeyWorld(manager: *Manager) !u64 {
    manager.world.observe_active = true;
    const editor = manager.addApp("com.example.editor");
    _ = manager.addWindow(editor, .{ .title = "Editor 1" });
    const focused = manager.addWindow(editor, .{ .title = "Editor 2" });
    try manager.start();
    manager.tick(3);
    return focused;
}

pub fn @"a hotkey press that macOS never delivers runs its command once"(manager: *Manager) !void {
    const focused = try hotkeyWorld(manager);
    manager.press(0, "toggle-floating");
    manager.tick(20);
    try expect((try manager.report(focused)).floating, "the focused window floating after one toggle", .{});
}

pub fn @"a hotkey press that macOS delivers runs its command once"(manager: *Manager) !void {
    const focused = try hotkeyWorld(manager);
    manager.press(0, "toggle-floating");
    manager.tick(1);
    manager.deliver(0, "toggle-floating");
    manager.tick(20);
    try expect((try manager.report(focused)).floating, "the focused window floating after one toggle", .{});
}

/// Windows on workspaces 1, 2 and 3, with workspace 1 shown.
fn swipeWorld(manager: *Manager) !void {
    manager.world.observe_active = true;
    manager.world.config.swipe.enabled = true;
    const editor = manager.addApp("com.example.editor");
    _ = manager.addWindow(editor, .{ .title = "One" });
    const two = manager.addWindow(editor, .{ .title = "Two" });
    _ = manager.addWindow(editor, .{ .title = "Three" });
    try manager.start();
    manager.tick(3);
    try manager.run("send-to-workspace 3");
    manager.tick(2);
    manager.userFocus(two);
    manager.tick(1);
    try manager.run("send-to-workspace 2");
    manager.tick(8);
}

pub fn @"a three-finger swipe switches one workspace"(manager: *Manager) !void {
    try swipeWorld(manager);
    manager.swipe(3, -0.2, 0);
    manager.tick(8);
    const shown = try manager.shownWorkspace();
    try expect(shown == 2, "workspace 2 shown, got {d}", .{shown});
}

pub fn @"a vertical three-finger swipe does not switch the workspace"(manager: *Manager) !void {
    try swipeWorld(manager);
    manager.swipe(3, -0.2, 0.15);
    manager.tick(8);
    const shown = try manager.shownWorkspace();
    try expect(shown == 1, "workspace 1 shown, got {d}", .{shown});
}

const secret = "Quarterly-Secret-Plan";

/// A window whose application refuses less than 1430 points of width cannot tile beside another window, so it floats.
fn refusedPlacement(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    const notes = manager.addApp("com.example.notes");
    _ = manager.addWindow(editor, .{ .title = "Editor" });
    _ = manager.addWindow(notes, .{ .title = secret, .minimum = .{ .width = 1430, .height = 450 } });
    try manager.start();
    manager.tick(24);
}

fn journalCount(manager: *Manager, needle: []const u8) usize {
    var count: usize = 0;
    for (manager.world.journal.items) |line| count += @intFromBool(std.mem.indexOf(u8, line, needle) != null);
    return count;
}

pub fn @"the placement journal records a refused placement without the window title"(manager: *Manager) !void {
    try refusedPlacement(manager);
    const placements = journalCount(manager, "\"event\":\"placement\"");
    const titled = journalCount(manager, secret);
    try expect(placements > 0 and titled == 0, "a placement line and no line with the title, got {d} placement lines and {d} titled lines", .{ placements, titled });
}

pub fn @"wrong adds a mark to the placement journal"(manager: *Manager) !void {
    try refusedPlacement(manager);
    try manager.run("wrong did not switch");
    const marks = journalCount(manager, "\"event\":\"mark\",\"note\":\"did not switch\"");
    try expect(marks == 1, "one mark with the note, got {d}", .{marks});
}

pub fn @"a hotkey that macOS delivers after the manager ran it from the key press runs once"(manager: *Manager) !void {
    const focused = try hotkeyWorld(manager);
    manager.press(0, "toggle-floating");
    manager.tick(14);
    manager.deliver(0, "toggle-floating");
    manager.tick(4);
    try expect((try manager.report(focused)).floating, "the focused window floating after one toggle", .{});
}

/// The command's frame write stalls for 300 ms, so the tap's report of the same press runs after it.
pub fn @"a hotkey that macOS delivers before a key press that waits 300 ms on its command runs once"(manager: *Manager) !void {
    const focused = try hotkeyWorld(manager);
    manager.world.write_latency = 0.3;
    manager.deliver(0, "toggle-floating");
    manager.world.write_latency = 0;
    manager.press(0, "toggle-floating");
    manager.tick(20);
    try expect((try manager.report(focused)).floating, "the focused window floating after one toggle", .{});
}

/// Another command holds the main thread after the delivered command returned, so the tap's report waits longer than the lead.
pub fn @"a hotkey that macOS delivers 400 ms of a busy main thread before the key press runs once"(manager: *Manager) !void {
    const focused = try hotkeyWorld(manager);
    manager.deliver(0, "toggle-floating");
    manager.advance(0.4);
    manager.press(0, "toggle-floating");
    manager.tick(20);
    try expect((try manager.report(focused)).floating, "the focused window floating after one toggle", .{});
}

pub fn @"a hotkey that macOS delivers 2 s of a busy main thread after the manager ran it from the key press runs once"(manager: *Manager) !void {
    const focused = try hotkeyWorld(manager);
    manager.press(0, "toggle-floating");
    manager.tick(14);
    manager.advance(2);
    manager.deliver(0, "toggle-floating");
    manager.tick(4);
    try expect((try manager.report(focused)).floating, "the focused window floating after one toggle", .{});
}

/// The timer fires before the queued delivery when the main thread comes back.
pub fn @"a hotkey that a busy main thread holds for 2 s is not reported as missed"(manager: *Manager) !void {
    const focused = try hotkeyWorld(manager);
    manager.press(0, "toggle-floating");
    manager.advance(2);
    manager.tick(1);
    manager.deliver(0, "toggle-floating");
    manager.tick(4);
    const missed = (try manager.parse(suite.Status, "status")).hotkeys.missed;
    try expect((try manager.report(focused)).floating and missed == 0, "the focused window floating and no missed hotkey, got {d} missed", .{missed});
}
