const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const delivery = @import("delivery.zig");
const selector = @import("selector.zig");
const reply = @import("reply.zig");
const journal = @import("journal.zig");
const world = @import("world.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const focus = @import("focus.zig");
const presenter = @import("presenter.zig");
const text = native.text;

var active_mode: usize = 0;
var shortcut_buffer: [64]commands.WorkspaceSelector = undefined;
var workspace_shortcuts: std.ArrayList(commands.WorkspaceSelector) = .initBuffer(&shortcut_buffer);
var hotkey_watch: delivery.Watch = .{};
var hotkey_recovery: struct { missed: usize = 0, rebinds: usize = 0, rebound: f64 = -std.math.inf(f64) } = .{};

// Runs the queued workspace shortcuts, merging the ones that land on one display into a single switch.
pub fn flush() void {
    if (workspace_shortcuts.items.len == 0) return;
    defer workspace_shortcuts.clearRetainingCapacity();
    if (world.isSuspended() or world.displays().len == 0 or scene.pending()) return;
    defer presenter.present();
    var remaining = workspace_shortcuts.items;
    while (remaining.len != 0) {
        focus.observeCommandState();
        const slot = world.activeDisplay();
        var view = routing.view(slot);
        const from = view.current;
        const owners = routing.resolve();
        var destination: ?u32 = null;
        while (remaining.len != 0) {
            const target = selector.resolve(remaining[0], view) catch {
                remaining = remaining[1..];
                continue;
            };
            const owner = owners[target] orelse world.displays()[slot].identity;
            if (destination != null and destination != owner) break;
            destination = owner;
            if (target != view.current) view.previous = view.current;
            view.current = target;
            view.back_and_forth = world.config().workspace_back_and_forth;
            remaining = remaining[1..];
        }
        if (destination != null) _ = if (world.config().workspace_monitors != null) scene.show(view.current, from, null) else scene.switchTo(slot, view.current, from, null);
    }
}

pub fn activate() bool {
    if (!native.platform_bindings(&world.config().modes[0].bindings, world.config().modes[0].binding_count)) return false;
    active_mode = 0;
    return true;
}

pub fn bind(source: *const world.Config, index: usize) bool {
    if (!native.platform_bindings(&source.modes[index].bindings, source.modes[index].binding_count)) return false;
    hotkey_watch.forgetPresses();
    return true;
}

pub fn resetMode() void {
    active_mode = 0;
}

pub fn activeMode() usize {
    return active_mode;
}

pub fn selectMode(name: []const u8) reply.Reply {
    const index = world.config().modeIndex(name) orelse return reply.failure("UnknownMode");
    const mode = &world.config().modes[index];
    if (!bind(world.config(), index)) return reply.failure("HotkeyCollision");
    active_mode = index;
    return reply.json(.{ .ok = true, .active_mode = text(&mode.name) });
}

pub const Route = enum { ignored, queued, run };

// Queues a workspace shortcut that can wait for activations to settle. Every other command runs now.
pub fn route(command_text: [*:0]const u8) Route {
    const command = commands.parse(std.mem.span(command_text), world.config().workspace_count) catch return .ignored;
    if (command != .workspace or world.isSuspended() or scene.pending() or world.displays().len == 0 or (world.config().duration != 0 and native.huen_scene_capture_allowed())) {
        return .run;
    }
    if (workspace_shortcuts.items.len == workspace_shortcuts.capacity) flush();
    workspace_shortcuts.appendAssumeCapacity(command.workspace);
    return .queued;
}

pub fn dropShortcuts() void {
    workspace_shortcuts.clearRetainingCapacity();
}

// macOS can stop delivering registered hotkeys without an error. Returns the command to run from its key press.
pub fn overdue(now: f64) ?delivery.Command {
    const command = hotkey_watch.overdue(now) orelse return null;
    hotkey_recovery.missed += 1;
    var buffer: [256:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(&buffer, "macOS did not deliver hotkey \"{s}\"; ran it from the key press", .{text(&command)}) catch {};
    native.platform_error(&buffer);
    _ = journal.append("error", .{ .message = "Hotkey not delivered; ran it from the key press" });
    if (now - hotkey_recovery.rebound >= 5) {
        hotkey_recovery.rebound = now;
        hotkey_recovery.rebinds += 1;
        if (!native.platform_rebind()) {
            native.platform_error("Hotkey re-registration failed");
            _ = journal.append("error", .{ .message = "Hotkey re-registration failed" });
        }
    }
    return command;
}

pub fn pressed(slot: u32, command: []const u8) void {
    hotkey_watch.pressed(slot, command, native.platform_monotonic());
}

pub fn delivered(slot: u32) bool {
    return hotkey_watch.delivered(slot, native.platform_monotonic());
}

pub fn status() struct { watchdog: []const u8, missed: usize, rebinds: usize } {
    return .{ .watchdog = if (native.huen_observe_active()) "active" else "unavailable", .missed = hotkey_recovery.missed, .rebinds = hotkey_recovery.rebinds };
}
