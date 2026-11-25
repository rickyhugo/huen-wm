const std = @import("std");
const suite = @import("../manager.zig");
const Manager = suite.Manager;
const Rect = suite.Rect;
const expect = suite.expect;
const expectFrame = suite.expectFrame;

/// Two editor windows; the second goes to workspace 2.
fn hiddenEditor(manager: *Manager) !u64 {
    const editor = manager.addApp("com.example.editor");
    _ = manager.addWindow(editor, .{ .title = "Shown" });
    const hidden = manager.addWindow(editor, .{ .title = "Hidden" });
    try manager.start();
    manager.tick(3);
    try manager.run("send-to-workspace 2");
    manager.tick(2);
    return hidden;
}

pub fn @"a window on a hidden workspace is not visible on screen"(manager: *Manager) !void {
    const hidden = try hiddenEditor(manager);
    const frame = manager.frame(hidden);
    try expect(manager.atCorner(hidden), "window {d} out of sight, got ({d}, {d}, {d}, {d})", .{ hidden, frame.left, frame.top, frame.width, frame.height });
}

/// Alone on its workspace, the window fills the usable area inside the 8-point gap.
pub fn @"a hidden window returns to its tile when its workspace shows"(manager: *Manager) !void {
    const hidden = try hiddenEditor(manager);
    try manager.run("workspace 2");
    manager.tick(2);
    try expectFrame(manager.frame(hidden), .{ .left = 8, .top = 33, .width = 1424, .height = 859 }, "the window on its tile");
}

pub fn @"quit restores every window to the frame it had before the manager started"(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    const terminal = manager.addApp("com.example.terminal");
    _ = manager.addWindow(editor, .{ .title = "Tiled" });
    _ = manager.addWindow(terminal, .{ .title = "Floating" });
    _ = manager.addWindow(editor, .{ .title = "Hidden" });
    var before: [3]Rect = undefined;
    for (manager.world.windows.items, &before) |window, *frame| frame.* = window.frame;
    try manager.start();
    manager.tick(3);
    try manager.run("send-to-workspace 2");
    manager.tick(1);
    manager.userFocus(2);
    manager.tick(1);
    try manager.run("toggle-floating");
    manager.tick(2);
    try manager.run("quit");
    manager.tick(2);
    for (manager.world.windows.items, before) |window, frame| try expectFrame(window.frame, frame, "the frame from before the start");
}

/// Two same-size floating editor windows park on one corner, beside a tiled terminal window, and the process
/// ends without a shutdown. The frames before parking are kept for the next process.
fn parkThenCrash(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    const terminal = manager.addApp("com.example.terminal");
    const first = manager.addWindow(editor, .{ .title = "Editor 1" });
    const second = manager.addWindow(editor, .{ .title = "Editor 2" });
    _ = manager.addWindow(terminal, .{ .title = "Terminal" });
    try manager.start();
    manager.tick(3);
    for ([_]u64{ first, second }) |identity| {
        manager.userFocus(identity);
        manager.tick(1);
        try manager.run("toggle-floating");
        manager.tick(1);
    }
    manager.tick(1);
    for (manager.world.windows.items) |window| try manager.world.remembered.append(suite.allocator, window.frame);
    try manager.run("workspace 2");
    manager.tick(2);
    const shared = std.meta.eql(manager.frame(first), manager.frame(second));
    try expect(shared and manager.atCorner(first), "both editor windows parked at one corner frame", .{});
}

pub fn @"after a crash with parked windows the next manager leaves no window at a corner"(manager: *Manager) !void {
    if (!manager.world.restarted) return parkThenCrash(manager);
    try manager.start();
    manager.tick(3);
    for (manager.world.windows.items) |window| try expect(!manager.atCorner(window.identity), "window {d} back in sight", .{window.identity});
}

pub fn @"after a crash quit restores the frames from before parking"(manager: *Manager) !void {
    if (!manager.world.restarted) return parkThenCrash(manager);
    try manager.start();
    manager.tick(3);
    try manager.run("quit");
    manager.tick(2);
    for (manager.world.windows.items, manager.world.remembered.items) |window, frame| try expectFrame(window.frame, frame, "the frame from before parking");
}

/// An editor window parks on workspace 2 beside a shown terminal window, and the process crashes.
fn parkThenCrashOnce(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    const terminal = manager.addApp("com.example.terminal");
    const parked = manager.addWindow(editor, .{ .title = "Editor" });
    _ = manager.addWindow(terminal, .{ .title = "Terminal" });
    try manager.start();
    manager.tick(3);
    manager.userFocus(parked);
    manager.tick(1);
    try manager.run("send-to-workspace 2");
    manager.tick(1);
    try expect(manager.atCorner(parked), "the editor window parked before the crash", .{});
}

fn expectNothingRecovered(manager: *Manager) !void {
    try manager.start();
    manager.tick(1);
    const recovery = (try manager.parse(suite.Status, "status")).parking_recovery orelse return error.ExpectationFailed;
    try expect(recovery.records == 1 and recovery.recovered == 0 and recovery.failed == 0, "1 journal record and no window recovered, got records={d} recovered={d} failed={d}", .{ recovery.records, recovery.recovered, recovery.failed });
}

pub fn @"a parking journal of an application that exited moves no window"(manager: *Manager) !void {
    if (!manager.world.restarted) return parkThenCrashOnce(manager);
    const old = manager.world.windows.items[0];
    manager.terminateApp(old.pid);
    const relaunched = manager.addApp("com.example.editor");
    _ = manager.addWindow(relaunched, .{ .title = "Editor again", .frame = old.frame });
    try expectNothingRecovered(manager);
}

pub fn @"a parking journal of a process with the same pid and another launch date moves no window"(manager: *Manager) !void {
    if (!manager.world.restarted) return parkThenCrashOnce(manager);
    manager.world.app(manager.world.windows.items[0].pid).?.launch += 1;
    try expectNothingRecovered(manager);
}

/// A window that its application moves back to `home` after each park, `interval` seconds apart.
fn escapeTwice(manager: *Manager, interval: f64) !u64 {
    const browser = manager.addApp("com.example.browser");
    const editor = manager.addApp("com.example.editor");
    const mover = manager.addWindow(browser, .{ .title = "Mover" });
    _ = manager.addWindow(editor, .{ .title = "Editor" });
    try manager.start();
    manager.tick(2);
    manager.userFocus(mover);
    manager.tick(1);
    const home = manager.frame(mover);
    try manager.run("send-to-workspace 2");
    manager.tick(1);
    for (0..2) |_| {
        manager.advance(interval);
        manager.world.window(mover).?.frame = home;
        manager.world.scan_needed = true;
        manager.tick(1);
    }
    return mover;
}

pub fn @"a window that moves itself back on screen twice within 300 seconds is no longer parked"(manager: *Manager) !void {
    const mover = try escapeTwice(manager, 3);
    const report = try manager.report(mover);
    try expect(!report.parked and report.parking_exempt, "the window exempt from parking, got parked={} parking_exempt={}", .{ report.parked, report.parking_exempt });
}

pub fn @"a window that moves itself back on screen 301 seconds apart stays parked"(manager: *Manager) !void {
    const mover = try escapeTwice(manager, 301);
    const report = try manager.report(mover);
    try expect(report.parked and !report.parking_exempt and manager.atCorner(mover), "the window parked again, got parked={} parking_exempt={}", .{ report.parked, report.parking_exempt });
}

/// A floating window parks on workspace 2, and then its application refuses less than 900 by 300 points.
/// Its parked frame is 500 by 400, so the size it accepts is 900 by 400.
fn raisedMinimum(manager: *Manager) !u64 {
    manager.world.config.rules = &.{.{ .bundle = "com.example.float", .floating = true }};
    const editor = manager.addApp("com.example.editor");
    const floater = manager.addApp("com.example.float");
    _ = manager.addWindow(editor, .{ .title = "Editor" });
    const window = manager.addWindow(floater, .{ .title = "Floating", .frame = .{ .left = 300, .top = 200, .width = 500, .height = 400 } });
    try manager.start();
    manager.tick(3);
    manager.advance(2);
    manager.tick(2);
    manager.userFocus(window);
    manager.tick(1);
    try manager.run("send-to-workspace 2");
    manager.tick(2);
    manager.world.window(window).?.minimum = .{ .width = 900, .height = 300 };
    manager.tick(2);
    return window;
}

pub fn @"a parked floating window whose application raised its minimum shows at the size it accepts"(manager: *Manager) !void {
    const window = try raisedMinimum(manager);
    try manager.run("workspace 2");
    manager.tick(3);
    const frame = manager.frame(window);
    try expect(!manager.atCorner(window) and frame.width == 900 and frame.height == 400, "the window in sight at 900 by 400, got ({d}, {d}, {d}, {d})", .{ frame.left, frame.top, frame.width, frame.height });
}

pub fn @"switching to the workspace of a window that raised its minimum succeeds"(manager: *Manager) !void {
    _ = try raisedMinimum(manager);
    try manager.run("workspace 2");
    manager.tick(3);
    try expect(try manager.shownWorkspace() == 2, "workspace 2 shown", .{});
}

/// A frame written on every scan makes the window flicker, so the count of writes is the behavior here.
pub fn @"the manager writes no frame during quiet ticks after showing a window that raised its minimum"(manager: *Manager) !void {
    _ = try raisedMinimum(manager);
    try manager.run("workspace 2");
    manager.tick(3);
    const before = manager.world.frame_writes;
    manager.tick(32);
    try expect(manager.world.frame_writes == before, "no frame write in 32 quiet ticks, got {d}", .{manager.world.frame_writes - before});
}
