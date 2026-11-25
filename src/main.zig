const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const rules = @import("rules.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const size_bounds = @import("bounds.zig");
const pointer = @import("pointer.zig");
const interaction = @import("interaction.zig");
const session = @import("session.zig");
const continuity = @import("continuity.zig");
const selector = @import("selector.zig");
const history = @import("history.zig");
const monitor = @import("monitor.zig");
const parking = @import("parking.zig");
const delivery = @import("delivery.zig");
const swipe = @import("swipe.zig");
const memory = @import("memory.zig");
const reply = @import("reply.zig");
const journal = @import("journal.zig");
const world = @import("world.zig");
const Window = world.Window;
const Display = world.Display;
const Config = world.Config;
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
const json = reply.json;
const failure = reply.failure;
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
pub fn main(initial: std.process.Init.Minimal) u8 {
    const arguments = initial.args.vector;
    if (arguments.len >= 2 and std.mem.eql(u8, std.mem.span(arguments[1]), "--config-worker")) {
        if (arguments.len != 3) return 1;
        return configuration.workerMain(arguments[2]);
    }
    return @intCast(native.platform_main(@intCast(arguments.len), @ptrCast(arguments.ptr)));
}
const text = native.text;
export fn wm_initialize(path: [*:0]const u8) bool {
    const candidate = reload.evaluate(path) orelse return false;
    routing.adoptConfig(&candidate);
    reload.markReady();
    world.markInitialized();
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
    if (world.displays().len > 0) _ = routing.reroute();
    native.platform_config_changed();
    placer.reconcile();
    presenter.publishStatus();
}
export fn wm_tick() void {
    edits.pollClose();
    if (!world.isInitialized()) return;
    defer presenter.present();
    var displays: world.DisplayScan = undefined;
    world.scanDisplays(&displays);
    routing.cacheShown();
    world.stageDisplays(&displays);
    if (displays.changed) {
        if (world.displays().len != 0) placer.noteTopologyChange();
        scene.invalidate();
        hotkeys.dropShortcuts();
    }
    world.commitDisplays(&displays);
    if (world.displays().len == 0) return;
    recall.load();
    var buffer: [1024]native.WMWindow = undefined;
    const observed = discovery.scan(&buffer);
    var recovered: [1024]parking.Recovery = undefined;
    const recoveries = recovery.recover(observed, &recovered);
    const observed_focus = discovery.adopt(observed, recoveries);
    discovery.retire(observed);
    checkpoint.restore();
    if (!world.isSuspended() and !scene.pending()) _ = routing.reroute();
    focus.observe(observed_focus, true);
    focus.dropMissing();
    world.ensureSelection();
    routing.trackCurrentDisplay();
    placer.reconcile();
    if (checkpoint.takeFocusPending()) {
        focus.focusWorkspace(world.displays()[world.activeDisplay()].identity, null);
    }
}
fn swapWindows(source_index: usize, target_index: usize) [*:0]const u8 {
    const source = &world.windows()[source_index];
    const target = &world.windows()[target_index];
    const identity = source.identity;
    const transaction = placer.Transaction.begin(.{ .pair = .{ source.display, target.display } }) catch |err| return failure(@errorName(err));
    defer transaction.deinit();
    world.layouts().swap(source.identity, target.identity);
    if (source.managedFullscreen()) world.workspaceLayout(source.display, source.workspace).fullscreen = null;
    if (target.managedFullscreen()) world.workspaceLayout(target.display, target.workspace).fullscreen = null;
    std.mem.swap(u32, &source.display, &target.display);
    std.mem.swap(usize, &source.workspace, &target.workspace);
    std.mem.swap(Window, source, target);
    if (!transaction.commit()) return failure(journal.lastError() orelse "SwapPlacementFailed");
    return json(.{ .ok = true, .verified = focus.verify(identity) });
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
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    defer presenter.present();
    const command = parseCommand(std.mem.span(commandText), world.config().workspace_count) catch |err| return failure(@errorName(err));
    switch (command) {
        .status, .windows, .monitors, .workspaces, .wrong => {},
        .quit, .restore => hotkeys.dropShortcuts(),
        else => hotkeys.flush(),
    }
    switch (command) {
        .status => {
            const launch = native.platform_launch_status();
            var placed_rows: [10]routing.Placed = undefined;
            const placed = routing.placed(&placed_rows);
            return json(.{
                .running = true,
                .suspended = world.isSuspended(),
                .active_mode = text(&world.config().modes[hotkeys.activeMode()].name),
                .close_state = edits.closeState(),
                .launch = .{ .request_id = launch.request_id, .state = launch.state, .message = text(&launch.message) },
                .window_count = world.windows().len,
                .display_count = world.displays().len,
                .selected_monitor = world.selected(),
                .workspace_owner = routing.owner(),
                .placements = placed,
                .routing_blocked = routing.blocked(),
                .workspace_backend = "corner-parking",
                .filter = std.mem.span(native.platform_filter()),
                .scene_capture_allowed = native.huen_scene_capture_allowed(),
                .snapshot_presentation = scene.presentation(),
                .snapshot_generation = scene.generationCount(),
                .transition_pending = scene.pending(),
                .transition_error = journal.lastError(),
                .hotkeys = hotkeys.status(),
                .mouse = gestures.status(),
                .session = checkpoint.status(),
                .parking_recovery = recovery.status(),
                .placement_memory = recall.status(),
                .config_reload = reload.status(),
            });
        },
        .mode => |name| return hotkeys.selectMode(name.text()),
        .launch => |request| return edits.launch(request),
        .wrong => |note| {
            if (!journal.enabled()) return failure("JournalDisabledByFilter");
            var length = @min(note.len, 200);
            while (length < note.len and note[length] & 0xc0 == 0x80) length -= 1;
            const Shown = struct { display: u32, workspace: ?usize };
            var shown: [monitor.capacity]Shown = undefined;
            for (world.displays(), shown[0..world.displays().len]) |display, *item| item.* = .{ .display = display.identity, .workspace = if (routing.placedWorkspace(display)) |workspace| workspace + 1 else null };
            var parked: usize = 0;
            for (world.windows()) |window| parked += @intFromBool(window.parked);
            if (!journal.append("mark", .{ .note = note[0..length], .window_count = world.windows().len, .parked_count = parked, .workspaces = shown[0..world.displays().len], .transition_error = journal.lastError() })) return failure("JournalAppendFailed");
            return json(.{ .ok = true });
        },
        .exec_and_forget => |shell| return edits.exec(shell),
        .windows => {
            const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, urgent: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, managed_fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8, group_hidden: bool, parking_exempt: bool, minimum: struct { width: f64, height: f64 }, maximum: struct { width: ?f64, height: ?f64 } };
            var items: [1024]Item = undefined;
            for (world.windows(), items[0..world.windows().len]) |*window, *item| item.* = .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focus.current() == window.identity, .urgent = window.urgent, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .managed_fullscreen = window.managedFullscreen(), .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error, .group_hidden = !window.floating and world.layouts().visibility(window.identity) == .hidden_by_group, .parking_exempt = window.escape == .exempt, .minimum = .{ .width = window.bounds.minimumAt(.width), .height = window.bounds.minimumAt(.height) }, .maximum = .{ .width = if (window.bounds.ceilingAt(.width)) |ceiling| ceiling.accepted else null, .height = if (window.bounds.ceilingAt(.height)) |ceiling| ceiling.accepted else null } };
            return json(items[0..world.windows().len]);
        },
        .monitors => {
            const Item = struct { id: u32, uuid: ?[]const u8, name: []const u8, frame: Rect, full_bounds: Rect, built_in: bool, workspace: ?usize, selected: bool, blocked_by_fullscreen: bool };
            var items: [monitor.capacity]Item = undefined;
            var uuids: [monitor.capacity][64]u8 = undefined;
            const count = world.displays().len;
            for (world.displays(), uuids[0..count], items[0..count]) |*display, *uuid, *item| {
                uuid.* = @splat(0);
                const known = session.huen_session_display_uuid(display.identity, uuid, uuid.len);
                const placed = routing.placedWorkspace(display.*);
                item.* = .{ .id = display.identity, .uuid = if (known) text(uuid) else null, .name = text(&display.name), .frame = display.frame, .full_bounds = display.full_bounds, .built_in = display.built_in, .workspace = if (placed) |workspace| workspace + 1 else null, .selected = world.selected() == display.identity, .blocked_by_fullscreen = world.displayBlocked(display.identity) };
            }
            return json(items[0..count]);
        },
        .workspaces => {
            const Item = struct { display: u32, index: usize, name: []const u8, active: bool, urgent: bool, layout: Layout };
            var items: [monitor.capacity * 10]Item = undefined;
            var count: usize = 0;
            for (world.displays()) |display| for (world.config().workspaces[0..world.config().workspace_count], 0..) |*workspace, index| {
                if (world.config().workspace_monitors != null and routing.host(index) != display.identity) continue;
                const layout = if (world.layouts().lookup(display.identity, index)) |state| state.layout else workspace.layout;
                const urgent = for (world.windows()) |window| {
                    if (window.urgent and window.display == display.identity and window.workspace == index) break true;
                } else false;
                items[count] = .{ .display = display.identity, .index = index + 1, .name = text(&workspace.name), .active = display.workspace == index, .urgent = urgent, .layout = layout };
                count += 1;
            };
            return json(items[0..count]);
        },
        .reload => {
            return reload.start();
        },
        .quit, .restore => {
            edits.cancelClose(command == .restore);
            reload.cancel();
            scene.cancel();
            if (command == .quit) {
                native.platform_quit();
                return json(.{ .ok = true });
            }
            checkpoint.freeze();
            world.markSuspended();
            const outstanding = native.platform_restore();
            recall.persist();
            if (outstanding == 0) {
                checkpoint.save(true);
                recovery.settle();
            }
            native.platform_border(0, 0, 0);
            if (outstanding != 0) return json(.{ .@"error" = true, .err_message = "Geometry restoration incomplete. Retry restore after unminimizing or leaving fullscreen.", .outstanding = outstanding, .suspended = true });
            return json(.{ .ok = true, .suspended = true, .note = "Restored live-session geometry. Restart to resume tiling." });
        },
        else => {},
    }
    if (world.isSuspended()) return failure("RuntimeSuspendedRestartToResume");
    if (scene.pending()) return failure("WorkspaceTransitionPending");
    if (world.displays().len == 0) return failure("NoDisplays");
    focus.observeCommandState();
    const displaySlot = world.activeDisplay();
    const display = &world.displays()[displaySlot];
    switch (command) {
        .workspace => |selection| return scene.visit(selection, displaySlot),
        .focus_monitor => |selection| return focus.toMonitor(selection, displaySlot),
        .move_workspace_to_monitor => |selection| return routing.moveWorkspace(selection, displaySlot, false),
        .swap_monitor_workspaces => |selection| return routing.moveWorkspace(selection, displaySlot, true),
        .cycle => |request| return focus.cycle(request, displaySlot),
        .focus_last => return focus.jumpBack(false, displaySlot),
        .focus_urgent => return focus.jumpBack(true, displaySlot),
        .move_app => |request| return routing.moveApp(request, displaySlot),
        .layout => |layout| {
            if (routing.placedWorkspace(display.*) == null) return failure("NoWorkspaceOnMonitor");
            const transaction = placer.Transaction.begin(.{ .display = display.identity }) catch |err| return failure(@errorName(err));
            defer transaction.deinit();
            world.workspaceLayout(display.identity, display.workspace).layout = layout;
            if (!transaction.commit()) return failure(journal.lastError() orelse "LayoutPlacementFailed");
            native.platform_config_changed();
            return json(.{ .ok = true });
        },
        .resize => |delta| {
            if (routing.placedWorkspace(display.*) == null) return failure("NoWorkspaceOnMonitor");
            world.layouts().adjustRatio(world.workspaceLayout(display.identity, display.workspace), delta);
        },
        else => {
            const sourceIndex = world.windowIndex(focus.current() orelse return failure("NoFocusedWindow")) orelse return failure("NoFocusedWindow");
            const source = &world.windows()[sourceIndex];
            if (!source.visible()) return failure("FocusedWindowNotManaged");
            switch (command) {
                .select => |direction| {
                    const state = world.workspaceLayout(source.display, source.workspace);
                    const selection = world.layouts().select(state, source.identity, direction) catch |err| return failure(@errorName(err));
                    const representative = world.layouts().representative(selection) catch |err| return failure(@errorName(err));
                    return json(.{ .ok = true, .selection = selection, .representative = representative });
                },
                .tilemove, .group => {
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    const transaction = placer.Transaction.begin(.{ .display = source.display }) catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    const state = world.workspaceLayout(source.display, source.workspace);
                    const edited: anyerror!?u64 = switch (command) {
                        .tilemove => |direction| if (world.layouts().tilemove(state, source.identity, direction)) null else |err| err,
                        .group => |action| world.layouts().editGroup(state, source.identity, action),
                        else => unreachable,
                    };
                    const target = edited catch |err| return failure(transaction.abort(err));
                    if (!transaction.commit()) return failure(journal.lastError() orelse "GroupPlacementFailed");
                    const verified = if (target) |identity| focus.verify(identity) else true;
                    native.platform_config_changed();
                    return json(.{ .ok = true, .target = target, .verified = verified });
                },
                .split => |orientation| {
                    const state = world.workspaceLayout(source.display, source.workspace);
                    if (state.layout != .dwindle) return failure("SplitRequiresDwindle");
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    world.layouts().orient(source.identity, orientation) catch |err| return failure(@errorName(err));
                },
                .resize_points => |resize| {
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    if (!placer.deriveGoals()) return failure(journal.lastError() orelse "LayoutProjectionFailed");
                    const identity = source.identity;
                    const before = source.goal;
                    var applied = placer.resizeTiled(sourceIndex, resize.axis, resize.delta) catch |err| return failure(@errorName(err));
                    const retried = @abs(resize.delta - applied) > size_bounds.tolerance and placer.forgetWorkspaceBounds(source.display, source.workspace);
                    if (retried) {
                        if (!placer.deriveGoals()) return failure(journal.lastError() orelse "LayoutProjectionFailed");
                        _ = placer.resizeTiled(sourceIndex, resize.axis, resize.delta - applied) catch |err| return failure(@errorName(err));
                    }
                    placer.reconcile();
                    // Placement learns a bound again when the application still refuses, so only the placed goal shows the change.
                    if (retried) if (world.windowIndex(identity)) |index| {
                        const after = world.windows()[index].goal;
                        applied = if (resize.axis == .width) after.width - before.width else after.height - before.height;
                    };
                    native.platform_config_changed();
                    return json(.{ .ok = true, .applied_delta = applied });
                },
                .resize_by => |offset| {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (!source.floating) {
                        if (offset.vertical != 0 and world.workspaceLayout(source.display, source.workspace).layout == .master) return failure("MasterHeightResizeUnsupported");
                        if (!placer.deriveGoals()) return failure(journal.lastError() orelse "LayoutProjectionFailed");
                        const width = if (offset.horizontal != 0) placer.resizeTiled(sourceIndex, .width, offset.horizontal) catch |err| return failure(@errorName(err)) else 0;
                        const height = if (offset.vertical != 0) placer.resizeTiled(sourceIndex, .height, offset.vertical) catch |err| return failure(@errorName(err)) else 0;
                        placer.reconcile();
                        native.platform_config_changed();
                        return json(.{ .ok = true, .applied = .{ .width = width, .height = height } });
                    }
                    const area = world.displayArea(source.display);
                    var frame = source.floating_frame;
                    frame.width = std.math.clamp(frame.width + offset.horizontal, 80, @max(80, area.left + area.width - frame.left));
                    frame.height = std.math.clamp(frame.height + offset.vertical, 80, @max(80, area.top + area.height - frame.top));
                    source.floating_frame = frame;
                },
                .center, .move_by => {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (!source.floating) return failure("WindowNotFloating");
                    const area = world.displayArea(source.display);
                    var frame = source.floating_frame;
                    switch (command) {
                        .center => {
                            frame.left = area.left + (area.width - frame.width) / 2;
                            frame.top = area.top + (area.height - frame.height) / 2;
                        },
                        .move_by => |offset| {
                            frame.left += offset.horizontal;
                            frame.top += offset.vertical;
                        },
                        else => unreachable,
                    }
                    source.floating_frame = world.boundedFloating(frame, area);
                },
                .fullscreen => {
                    const transaction = placer.Transaction.begin(.{ .display = source.display }) catch |err| return failure(@errorName(err));
                    defer transaction.deinit();
                    const state = world.workspaceLayout(source.display, source.workspace);
                    if (source.floating) source.floating_restore = true else world.layouts().reveal(state, source.identity) catch |err| return failure(transaction.abort(err));
                    state.fullscreen = if (state.fullscreen == source.identity) null else source.identity;
                    if (!transaction.commit()) return failure(journal.lastError() orelse "FullscreenPlacementFailed");
                    return json(.{ .ok = true, .verified = focus.verify(source.identity) });
                },
                .close => |quit_if_last| return edits.close(source, quit_if_last),
                .toggle_floating => {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (source.floating) {
                        source.last_floating_frame = source.floating_frame;
                        source.floating = false;
                        source.bounds = .{};
                        source.placed = null;
                    } else {
                        // Like Hyprland: return to the last floating frame, or float at `floating_size`, centered.
                        const area = world.displayArea(source.display);
                        const width = area.width * world.config().floating_size.width;
                        const height = area.height * world.config().floating_size.height;
                        var frame = world.boundedFloating(source.last_floating_frame orelse .{
                            .left = area.left + (area.width - width) / 2,
                            .top = area.top + (area.height - height) / 2,
                            .width = width,
                            .height = height,
                        }, area);
                        // Shifts the frame down and right by the same distance until its top-left corner is clear of every other floating window
                        // on the workspace, so windows floated at the same frame all stay visible. At the area's edge the cascade restarts from the top left.
                        const step = 32;
                        var attempts: usize = 0;
                        while (attempts < world.windows().len) : (attempts += 1) {
                            const taken = for (world.windows()) |other| {
                                if (other.identity != source.identity and other.floating and !other.parked and other.display == source.display and other.workspace == source.workspace and other.visible() and @abs(other.floating_frame.left - frame.left) < step / 2 and @abs(other.floating_frame.top - frame.top) < step / 2) break true;
                            } else false;
                            if (!taken) break;
                            frame.left += step;
                            frame.top += step;
                            if (frame.left + frame.width > area.left + area.width or frame.top + frame.height > area.top + area.height) {
                                frame.left = area.left;
                                frame.top = area.top;
                            }
                        }
                        source.floating = true;
                        source.placed = null;
                        source.floating_frame = frame;
                    }
                },
                .send_to_workspace, .move_to_workspace => |selection| {
                    const resolved = routing.resolve();
                    const workspace = routing.resolveWorkspace(selection, if (world.config().workspace_monitors != null) displaySlot else world.displayIndex(source.display).?) catch |err| return failure(@errorName(err));
                    const destination = resolved[workspace] orelse source.display;
                    if (workspace == source.workspace and destination == source.display) return json(.{ .ok = true, .changed = false });
                    if (command == .send_to_workspace) {
                        if (!routing.route(resolved, &.{}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return failure(journal.lastError() orelse "MonitorRoutingFailed");
                        focus.dropIfHidden();
                        native.platform_config_changed();
                        return json(.{ .ok = true });
                    }
                    const destination_slot = world.displayIndex(destination).?;
                    const from = routing.currentWorkspace(if (world.config().workspace_monitors != null) displaySlot else destination_slot);
                    const identity = source.identity;
                    scene.markInstant();
                    if (!routing.route(resolved, &.{.{ .display = destination, .workspace = workspace }}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return failure(journal.lastError() orelse "MonitorRoutingFailed");
                    routing.recordPrevious(destination_slot, from, workspace);
                    const verified = focus.verify(identity);
                    native.platform_config_changed();
                    return json(.{ .ok = true, .verified = verified, .target = identity });
                },
                .send_to_monitor, .move_to_monitor => |selection| {
                    // Sends a window to the target display's active workspace. Directions are relative to the window's
                    // display. With global routing, a display that has no workspace placed on it rejects the send
                    // instead of placing a workspace there.
                    const origin = source.display;
                    var screens: [monitor.capacity]monitor.Screen = undefined;
                    const target = monitor.resolve(selection, world.monitorScreens(&screens), origin) catch |err| return failure(@errorName(err));
                    const workspace = world.displays()[world.displayIndex(target).?].workspace;
                    if (target == origin) return json(.{ .ok = true, .changed = false, .monitor = target, .workspace = source.workspace + 1 });
                    const resolved = routing.resolve();
                    if (world.config().workspace_monitors != null and resolved[workspace] != target) return failure("NoWorkspaceOnMonitor");
                    if (!routing.route(resolved, &.{.{ .display = target, .workspace = workspace }}, .{ .index = sourceIndex, .display = target, .workspace = workspace })) return failure(journal.lastError() orelse "MonitorRoutingFailed");
                    native.platform_config_changed();
                    if (command == .move_to_monitor) return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = focus.verify(source.identity), .target = source.identity });
                    // The selection stays, so keyboard focus returns to the selected display's candidate.
                    const selected = world.selected() orelse origin;
                    focus.focusWorkspace(selected, null);
                    return json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = world.selected() == selected, .focused = focus.current() });
                },
                .focus => |request| return focus.toward(sourceIndex, request),
                .swap => |direction| return swapWindows(sourceIndex, focus.neighbor(sourceIndex, direction) orelse return failure("NoWindowInDirection")),
                .swap_cycle => |step| {
                    if (source.floating or source.managedFullscreen()) return failure("WindowNotTiled");
                    var identities: [1024]u64 = undefined;
                    const target = selector.cycleTarget(focus.readingOrder(source.display, .tiled, &identities), source.identity, step) orelse return failure("NoWindowToCycle");
                    if (target == source.identity) return json(.{ .ok = true, .changed = false });
                    return swapWindows(sourceIndex, world.windowIndex(target).?);
                },
                .move => |direction| {
                    if (source.managedFullscreen()) return failure("ManagedFullscreenActive");
                    if (!source.floating and !native.platform_read_frame(source.identity, &source.floating_frame)) return failure("WindowGeometryUnavailable");
                    source.floating = true;
                    switch (direction) {
                        .left => source.floating_frame.left -= 40,
                        .right => source.floating_frame.left += 40,
                        .up => source.floating_frame.top -= 40,
                        .down => source.floating_frame.top += 40,
                    }
                },
                else => unreachable,
            }
        },
    }
    placer.reconcile();
    native.platform_config_changed();
    return json(.{ .ok = true });
}
export fn wm_input_poll() void {
    gestures.poll();
}
export fn wm_shutdown() bool {
    checkpoint.freeze();
    world.markSuspended();
    edits.cancelClose(false);
    presenter.deactivate();
    reload.cancel();
    if (reload.inFlight()) return false;
    if (!gestures.release()) return false;
    scene.cancel();
    const outstanding = native.platform_restore();
    recall.persist();
    checkpoint.save(outstanding == 0);
    if (outstanding == 0) recovery.settle() else {
        native.platform_error("Shutdown left unrestored windows; live-session recovery is incomplete");
        _ = journal.append("error", .{ .message = "Shutdown left unrestored windows", .outstanding = outstanding });
    }
    native.platform_border(0, 0, 0);
    return true;
}
