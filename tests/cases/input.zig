const std = @import("std");
const suite = @import("../manager.zig");
const Manager = suite.Manager;
const expect = suite.expect;

/// The observe tap is active. Each run of the bound command adds one mark to the placement journal.
fn hotkeyWorld(manager: *Manager) !void {
    manager.world.observe_active = true;
    try manager.start();
    manager.tick(3);
}

const bound = "wrong hotkey";

fn expectOneRun(manager: *Manager) !void {
    const runs = journalCount(manager, "\"event\":\"mark\",\"note\":\"hotkey\"");
    try expect(runs == 1, "the bound command to run once, got {d} runs", .{runs});
}

pub fn @"a hotkey press that macOS never delivers runs its command once"(manager: *Manager) !void {
    try hotkeyWorld(manager);
    manager.press(0, bound);
    manager.elapse(1.25);
    try expectOneRun(manager);
}

pub fn @"a hotkey press that macOS delivers runs its command once"(manager: *Manager) !void {
    try hotkeyWorld(manager);
    manager.press(0, bound);
    manager.tick(1);
    manager.deliver(0, bound);
    manager.elapse(1.25);
    try expectOneRun(manager);
}

/// The manager runs a press from the key press after 750 ms without a delivery.
pub fn @"a hotkey that macOS delivers after the manager ran it from the key press runs once"(manager: *Manager) !void {
    try hotkeyWorld(manager);
    manager.press(0, bound);
    manager.elapse(0.875);
    manager.deliver(0, bound);
    manager.elapse(0.25);
    try expectOneRun(manager);
}

/// The tap's report of the press waits on the main thread, for longer than the 250 ms a delivery waits for its press.
/// The timer fires before the queued report when the main thread comes back.
pub fn @"a hotkey that macOS delivers 400 ms of a busy main thread before the key press runs once"(manager: *Manager) !void {
    try hotkeyWorld(manager);
    manager.deliver(0, bound);
    manager.advance(0.4);
    manager.tick(1);
    manager.press(0, bound);
    manager.elapse(1.25);
    try expectOneRun(manager);
}

/// The delivery waits on the main thread, for longer than the 1 s a press that already ran waits for its delivery.
/// The timer fires before the queued delivery when the main thread comes back.
pub fn @"a hotkey that macOS delivers 2 s of a busy main thread after the manager ran it from the key press runs once"(manager: *Manager) !void {
    try hotkeyWorld(manager);
    manager.press(0, bound);
    manager.elapse(0.875);
    manager.advance(2);
    manager.tick(1);
    manager.deliver(0, bound);
    manager.elapse(0.25);
    try expectOneRun(manager);
}

/// The timer fires before the queued delivery when the main thread comes back.
pub fn @"a hotkey that a busy main thread holds for 2 s is not reported as missed"(manager: *Manager) !void {
    try hotkeyWorld(manager);
    manager.press(0, bound);
    manager.advance(2);
    manager.tick(1);
    manager.deliver(0, bound);
    manager.elapse(0.25);
    const missed = (try manager.parse(suite.Status, "status")).hotkeys.missed;
    try expect(missed == 0, "no missed hotkey, got {d}", .{missed});
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
