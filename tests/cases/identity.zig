const std = @import("std");
const suite = @import("../manager.zig");
const Manager = suite.Manager;
const Rect = suite.Rect;
const expect = suite.expect;
const expectFrame = suite.expectFrame;

/// Three tiled terminal windows. The application closes the middle one and opens a new window at its frame,
/// `delay` seconds later. Returns the new window and the middle tile.
fn replaceMiddle(manager: *Manager, delay: f64) !struct { successor: u64, tile: Rect } {
    const terminal = manager.addApp("com.example.terminal");
    _ = manager.addWindow(terminal, .{ .title = "Left" });
    const middle = manager.addWindow(terminal, .{ .title = "Middle" });
    _ = manager.addWindow(terminal, .{ .title = "Right" });
    try manager.start();
    manager.tick(4);
    manager.userFocus(middle);
    manager.tick(2);
    const tile = manager.frame(middle);
    manager.closeWindow(middle);
    if (delay > 0) {
        manager.tick(1);
        manager.advance(delay);
        manager.tick(1);
    }
    const successor = manager.addWindow(terminal, .{ .title = "Replacement", .frame = tile });
    manager.tick(13);
    return .{ .successor = successor, .tile = tile };
}

pub fn @"a new window at a closed window's frame within half a second keeps its tile"(manager: *Manager) !void {
    const replaced = try replaceMiddle(manager, 0);
    try expectFrame(manager.frame(replaced.successor), replaced.tile, "the new window on the closed window's tile");
}

pub fn @"a new window at a closed window's frame after one second gets a tile of its own"(manager: *Manager) !void {
    const replaced = try replaceMiddle(manager, 1);
    const frame = manager.frame(replaced.successor);
    try expect(!suite.near(frame, replaced.tile), "the new window away from the closed window's tile, got ({d}, {d}, {d}, {d})", .{ frame.left, frame.top, frame.width, frame.height });
}

/// An anchor window keeps workspace 1 occupied while an editor window goes to workspace 3.
fn editorOnWorkspaceThree(manager: *Manager) !struct { pid: i32, window: u64, frame: Rect } {
    const keep = manager.addApp("com.example.keep");
    _ = manager.addWindow(keep, .{ .title = "Anchor" });
    const editor = manager.addApp("com.example.editor");
    const window = manager.addWindow(editor, .{ .title = "Editor" });
    try manager.start();
    manager.tick(3);
    const frame = manager.frame(window);
    try manager.run("send-to-workspace 3");
    manager.tick(2);
    return .{ .pid = editor, .window = window, .frame = frame };
}

fn relaunchedWorkspace(manager: *Manager) !usize {
    const placed = try editorOnWorkspaceThree(manager);
    manager.terminateApp(placed.pid);
    manager.tick(12);
    const relaunched = manager.addApp("com.example.editor");
    const window = manager.addWindow(relaunched, .{ .title = "Editor again", .frame = placed.frame });
    manager.tick(3);
    return (try manager.report(window)).workspace;
}

pub fn @"a relaunched application's window returns to its workspace"(manager: *Manager) !void {
    const workspace = try relaunchedWorkspace(manager);
    try expect(workspace == 3, "workspace 3, got {d}", .{workspace});
}

pub fn @"a relaunched application's window joins the shown workspace when placement memory is off"(manager: *Manager) !void {
    manager.world.config.placement_memory = false;
    const workspace = try relaunchedWorkspace(manager);
    try expect(workspace == 1, "workspace 1, got {d}", .{workspace});
}

pub fn @"a window closed while its application runs is not remembered"(manager: *Manager) !void {
    const placed = try editorOnWorkspaceThree(manager);
    _ = manager.addWindow(placed.pid, .{ .title = "Still open" });
    manager.tick(3);
    manager.closeWindow(placed.window);
    manager.tick(12);
    const opened = manager.addWindow(placed.pid, .{ .title = "Opened", .frame = placed.frame });
    manager.tick(3);
    const workspace = (try manager.report(opened)).workspace;
    try expect(workspace == 1, "the new window on the shown workspace 1, got {d}", .{workspace});
}

pub fn @"move-app moves every window of an application and no other window"(manager: *Manager) !void {
    const editor = manager.addApp("com.example.editor");
    const other = manager.addApp("com.example.other");
    _ = manager.addWindow(editor, .{ .title = "Editor 1" });
    const second = manager.addWindow(editor, .{ .title = "Editor 2" });
    _ = manager.addWindow(editor, .{ .title = "Editor 3" });
    _ = manager.addWindow(other, .{ .title = "Other" });
    try manager.start();
    manager.tick(3);
    manager.userFocus(second);
    manager.tick(1);
    try manager.run("send-to-workspace 2");
    manager.tick(2);
    try manager.run("move-app com.example.editor 4");
    manager.tick(2);
    for (try manager.windows()) |item| {
        const expected: usize = if (std.mem.eql(u8, item.bundle, "com.example.editor")) 4 else 1;
        try expect(item.workspace == expected, "{s} window {d} on workspace {d}, got {d}", .{ item.bundle, item.id, expected, item.workspace });
    }
}
