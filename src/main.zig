const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const commands = @import("command.zig");
const parking = @import("parking.zig");
const reply = @import("reply.zig");
const journal = @import("journal.zig");
const desktop = @import("desktop.zig");
const reload = @import("reload.zig");
const edits = @import("edits.zig");
const recovery = @import("recovery.zig");
const recall = @import("recall.zig");
const checkpoint = @import("checkpoint.zig");
const placer = @import("placer.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const focus = @import("focus.zig");
const discovery = @import("discovery.zig");
const hotkeys = @import("hotkeys.zig");
const gestures = @import("gestures.zig");
const presenter = @import("presenter.zig");

pub fn main(initial: std.process.Init.Minimal) u8 {
    const arguments = initial.args.vector;
    if (arguments.len >= 2 and std.mem.eql(u8, std.mem.span(arguments[1]), "--config-worker")) {
        if (arguments.len != 3) return 1;
        return configuration.workerMain(arguments[2]);
    }
    return @intCast(native.platform_main(@intCast(arguments.len), @ptrCast(arguments.ptr)));
}

export fn wm_initialize(path: [*:0]const u8) bool {
    const candidate = reload.evaluate(path) orelse return false;
    routing.adoptConfig(&candidate);
    reload.markReady();
    desktop.markInitialized();
    checkpoint.configure();
    return true;
}

export fn wm_activate_config() bool {
    if (!hotkeys.activate()) return false;
    presenter.activate();
    gestures.configure();
    presenter.publishStatus();
    return true;
}

export fn wm_config_poll() void {
    // Cancelled requests must still drain while shutdown waits for the worker.
    if (scene.pending() and reload.waiting()) return;
    const candidate = reload.take() orelse return;
    if (!hotkeys.bind(&candidate, 0)) return reload.reject("HotkeyCollision");
    routing.adoptConfig(&candidate);
    gestures.configure();
    checkpoint.configure();
    hotkeys.resetMode();
    reload.settle();
    if (desktop.displays().len > 0) _ = routing.reroute();
    native.platform_config_changed();
    placer.reconcile();
    presenter.publishStatus();
}

export fn wm_tick() void {
    edits.pollClose();
    if (!desktop.isInitialized()) return;
    defer presenter.present();
    var displays: desktop.DisplayScan = undefined;
    desktop.scanDisplays(&displays);
    routing.cacheShown();
    desktop.stageDisplays(&displays);
    if (displays.changed) {
        if (desktop.displays().len != 0) placer.noteTopologyChange();
        scene.invalidate();
        hotkeys.dropShortcuts();
    }
    desktop.commitDisplays(&displays);
    if (desktop.displays().len == 0) return;
    recall.load();
    var buffer: [1024]native.WMWindow = undefined;
    const observed = discovery.scan(&buffer);
    var recovered: [1024]parking.Recovery = undefined;
    const recoveries = recovery.recover(observed, &recovered);
    const observed_focus = discovery.adopt(observed, recoveries);
    discovery.retire(observed);
    checkpoint.restore();
    if (!desktop.isSuspended() and !scene.pending()) _ = routing.reroute();
    focus.observe(observed_focus, true);
    focus.dropMissing();
    desktop.ensureSelection();
    routing.trackCurrentDisplay();
    placer.reconcile();
    if (checkpoint.takeFocusPending()) {
        focus.focusWorkspace(desktop.displays()[desktop.activeDisplay()].identity, null);
    }
}

export fn wm_hotkey_poll() void {
    const now = native.platform_monotonic();
    if (hotkeys.overdue(now)) |command| wm_hotkey(&command);
    if (focus.settled(now)) hotkeys.flush();
}

export fn wm_hotkey_pressed(slot: u32, command: [*:0]const u8) void {
    hotkeys.pressed(slot, std.mem.span(command));
}

export fn wm_hotkey_delivered(slot: u32, command: [*:0]const u8) void {
    if (hotkeys.delivered(slot)) wm_hotkey(command);
}

export fn wm_swipe(fingers: u32, horizontal: f64, vertical: f64) void {
    if (gestures.swipe(fingers, horizontal, vertical)) |command| wm_hotkey(command);
}

export fn wm_hotkey(commandText: [*:0]const u8) void {
    if (hotkeys.route(commandText) == .run) _ = wm_command(commandText);
}

export fn wm_command(commandText: [*:0]const u8) reply.Reply {
    defer presenter.present();
    const command = commands.parse(std.mem.span(commandText), desktop.config().workspace_count) catch |err| return reply.failure(@errorName(err));
    switch (command) {
        .status, .windows, .monitors, .workspaces, .wrong => {},
        .quit, .restore => hotkeys.dropShortcuts(),
        else => hotkeys.flush(),
    }
    switch (command) {
        .status => return presenter.reportStatus(),
        .mode => |name| return hotkeys.selectMode(name.text()),
        .launch => |request| return edits.launch(request),
        .wrong => |note| return presenter.markWrong(note),
        .exec_and_forget => |shell| return edits.exec(shell),
        .windows => return presenter.listWindows(),
        .monitors => return presenter.listMonitors(),
        .workspaces => return presenter.listWorkspaces(),
        .reload => return reload.start(),
        .quit => return quit(),
        .restore => return restore(),
        else => {},
    }
    if (desktop.isSuspended()) return reply.failure("RuntimeSuspendedRestartToResume");
    if (scene.pending()) return reply.failure("WorkspaceTransitionPending");
    if (desktop.displays().len == 0) return reply.failure("NoDisplays");
    focus.observeCommandState();
    const slot = desktop.activeDisplay();
    switch (command) {
        .workspace => |selection| return scene.visit(selection, slot),
        .focus_monitor => |selection| return focus.toMonitor(selection, slot),
        .move_workspace_to_monitor => |selection| return routing.moveWorkspace(selection, slot, false),
        .swap_monitor_workspaces => |selection| return routing.moveWorkspace(selection, slot, true),
        .cycle => |request| return focus.cycle(request, slot),
        .focus_last => return focus.jumpBack(false, slot),
        .focus_urgent => return focus.jumpBack(true, slot),
        .move_app => |request| return routing.moveApp(request, slot),
        .layout => |layout| return edits.setLayout(layout, slot),
        .resize => |delta| return edits.adjustRatio(delta, slot),
        else => return edits.run(command, slot),
    }
}

fn quit() reply.Reply {
    edits.cancelClose(false);
    reload.cancel();
    scene.cancel();
    native.platform_quit();
    return reply.json(.{ .ok = true });
}

fn restore() reply.Reply {
    edits.cancelClose(true);
    reload.cancel();
    scene.cancel();
    checkpoint.freeze();
    desktop.markSuspended();
    const outstanding = restoreWindows();
    if (outstanding == 0) {
        checkpoint.save(true);
        recovery.settle();
    }
    native.platform_border(0, 0, 0);
    if (outstanding != 0) return reply.json(.{ .@"error" = true, .err_message = "Geometry restoration incomplete. Retry restore after unminimizing or leaving fullscreen.", .outstanding = outstanding, .suspended = true });
    return reply.json(.{ .ok = true, .suspended = true, .note = "Restored live-session geometry. Restart to resume tiling." });
}

// Returns windows to the geometry they had before the manager, then records where a restarted manager will find them.
fn restoreWindows() usize {
    const outstanding = native.platform_restore();
    recall.persist();
    return outstanding;
}

export fn wm_input_poll() void {
    gestures.poll();
    if (desktop.isInitialized()) focus.followPointer();
}

export fn wm_shutdown() bool {
    checkpoint.freeze();
    desktop.markSuspended();
    edits.cancelClose(false);
    presenter.deactivate();
    reload.cancel();
    if (reload.inFlight()) return false;
    if (!gestures.release()) return false;
    scene.cancel();
    const outstanding = restoreWindows();
    checkpoint.save(outstanding == 0);
    if (outstanding == 0) recovery.settle() else {
        native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
        _ = journal.append("error", .{ .message = "Shutdown left unrestored windows", .outstanding = outstanding });
    }
    native.platform_border(0, 0, 0);
    return true;
}
