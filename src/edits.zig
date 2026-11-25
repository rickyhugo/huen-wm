const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const reply = @import("reply.zig");
const world = @import("world.zig");
const size_bounds = @import("bounds.zig");
const selector = @import("selector.zig");
const monitor = @import("monitor.zig");
const journal = @import("journal.zig");
const placer = @import("placer.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const focus = @import("focus.zig");
const Window = world.Window;

pub const CloseState = enum { idle, pending, closed, termination_requested, termination_rejected, expired, cancelled };
const PendingClose = struct { identity: u64, pid: c_int, process_token: f64, deadline: f64 };
var pending_close: ?PendingClose = null;
var close_state: CloseState = .idle;

pub fn pollClose() void {
    const pending = pending_close orelse return;
    const observed = if (native.platform_monotonic() < pending.deadline) native.platform_close_state(pending.identity, pending.pid, pending.process_token) else -1;
    close_state = if (native.platform_monotonic() >= pending.deadline) .expired else if (observed == 2) (if (native.platform_terminate_if_empty(pending.identity, pending.pid, pending.process_token)) .termination_requested else .termination_rejected) else if (observed == 1) .closed else return;
    pending_close = null;
    native.platform_close_cancel();
}

// `cancelled` reports a pending close as cancelled, as `restore` does.
pub fn cancelClose(cancelled: bool) void {
    if (cancelled and pending_close != null) close_state = .cancelled;
    pending_close = null;
    native.platform_close_cancel();
}

pub fn closeState() CloseState {
    return close_state;
}

fn close(source: *const world.Window, quit_if_last: bool) reply.Reply {
    if (pending_close != null) return reply.failure("ClosePending");
    var process_token: f64 = 0;
    if (!native.platform_close(source.identity, quit_if_last, &process_token)) return reply.failure("CloseRejected");
    if (quit_if_last) {
        pending_close = .{ .identity = source.identity, .pid = source.observation.pid, .process_token = process_token, .deadline = native.platform_monotonic() + 5 };
        close_state = .pending;
    }
    return reply.json(.{ .ok = true, .accepted = true });
}

pub fn launch(request: commands.Launch) reply.Reply {
    if (world.isSuspended()) return reply.failure("RuntimeSuspendedRestartToResume");
    const request_id = native.platform_launch(request.bundle.text(), request.new_instance, request.hidden);
    if (request_id == 0) return reply.failure("ApplicationNotFound");
    return reply.json(.{ .ok = true, .accepted = true, .request_id = request_id });
}

pub fn exec(shell: []const u8) reply.Reply {
    if (world.isSuspended()) return reply.failure("RuntimeSuspendedRestartToResume");
    var terminated: [512:0]u8 = @splat(0);
    @memcpy(terminated[0..shell.len], shell);
    if (!native.platform_exec(&terminated)) return reply.failure("ProcessLaunchFailed");
    return reply.json(.{ .ok = true, .accepted = true });
}

pub fn setLayout(layout: commands.Layout, slot: usize) reply.Reply {
    const display = &world.displays()[slot];
    if (routing.placedWorkspace(display.*) == null) return reply.failure("NoWorkspaceOnMonitor");
    const transaction = placer.Transaction.begin(.{ .display = display.identity }) catch |err| return reply.failure(@errorName(err));
    defer transaction.deinit();
    world.workspaceLayout(display.identity, display.workspace).layout = layout;
    if (!transaction.commit()) return reply.failure(journal.lastError() orelse "LayoutPlacementFailed");
    native.platform_config_changed();
    return reply.json(.{ .ok = true });
}

pub fn adjustRatio(delta: f64, slot: usize) reply.Reply {
    const display = &world.displays()[slot];
    if (routing.placedWorkspace(display.*) == null) return reply.failure("NoWorkspaceOnMonitor");
    world.layouts().adjustRatio(world.workspaceLayout(display.identity, display.workspace), delta);
    return settle();
}

// Edits the focused window.
pub fn run(command: commands.Command, slot: usize) reply.Reply {
    const sourceIndex = world.windowIndex(focus.current() orelse return reply.failure("NoFocusedWindow")) orelse return reply.failure("NoFocusedWindow");
    const source = &world.windows()[sourceIndex];
    if (!source.visible()) return reply.failure("FocusedWindowNotManaged");
    switch (command) {
        .select => |direction| {
            const state = world.workspaceLayout(source.display, source.workspace);
            const selection = world.layouts().select(state, source.identity, direction) catch |err| return reply.failure(@errorName(err));
            const representative = world.layouts().representative(selection) catch |err| return reply.failure(@errorName(err));
            return reply.json(.{ .ok = true, .selection = selection, .representative = representative });
        },
        .tilemove, .group => {
            if (source.floating or source.managedFullscreen()) return reply.failure("WindowNotTiled");
            const transaction = placer.Transaction.begin(.{ .display = source.display }) catch |err| return reply.failure(@errorName(err));
            defer transaction.deinit();
            const state = world.workspaceLayout(source.display, source.workspace);
            const edited: anyerror!?u64 = switch (command) {
                .tilemove => |direction| if (world.layouts().tilemove(state, source.identity, direction)) null else |err| err,
                .group => |action| world.layouts().editGroup(state, source.identity, action),
                else => unreachable,
            };
            const target = edited catch |err| return reply.failure(transaction.abort(err));
            if (!transaction.commit()) return reply.failure(journal.lastError() orelse "GroupPlacementFailed");
            const verified = if (target) |identity| focus.verify(identity) else true;
            native.platform_config_changed();
            return reply.json(.{ .ok = true, .target = target, .verified = verified });
        },
        .split => |orientation| {
            const state = world.workspaceLayout(source.display, source.workspace);
            if (state.layout != .dwindle) return reply.failure("SplitRequiresDwindle");
            if (source.floating or source.managedFullscreen()) return reply.failure("WindowNotTiled");
            world.layouts().orient(source.identity, orientation) catch |err| return reply.failure(@errorName(err));
        },
        .resize_points => |resize| {
            if (source.floating or source.managedFullscreen()) return reply.failure("WindowNotTiled");
            if (!placer.deriveGoals()) return reply.failure(journal.lastError() orelse "LayoutProjectionFailed");
            const identity = source.identity;
            const before = source.goal;
            var applied = placer.resizeTiled(sourceIndex, resize.axis, resize.delta) catch |err| return reply.failure(@errorName(err));
            const retried = @abs(resize.delta - applied) > size_bounds.tolerance and placer.forgetWorkspaceBounds(source.display, source.workspace);
            if (retried) {
                if (!placer.deriveGoals()) return reply.failure(journal.lastError() orelse "LayoutProjectionFailed");
                _ = placer.resizeTiled(sourceIndex, resize.axis, resize.delta - applied) catch |err| return reply.failure(@errorName(err));
            }
            placer.reconcile();
            // Placement learns a bound again when the application still refuses, so only the placed goal shows the change.
            if (retried) if (world.windowIndex(identity)) |index| {
                const after = world.windows()[index].goal;
                applied = if (resize.axis == .width) after.width - before.width else after.height - before.height;
            };
            native.platform_config_changed();
            return reply.json(.{ .ok = true, .applied_delta = applied });
        },
        .resize_by => |offset| {
            if (source.managedFullscreen()) return reply.failure("ManagedFullscreenActive");
            if (!source.floating) {
                if (offset.vertical != 0 and world.workspaceLayout(source.display, source.workspace).layout == .master) return reply.failure("MasterHeightResizeUnsupported");
                if (!placer.deriveGoals()) return reply.failure(journal.lastError() orelse "LayoutProjectionFailed");
                const width = if (offset.horizontal != 0) placer.resizeTiled(sourceIndex, .width, offset.horizontal) catch |err| return reply.failure(@errorName(err)) else 0;
                const height = if (offset.vertical != 0) placer.resizeTiled(sourceIndex, .height, offset.vertical) catch |err| return reply.failure(@errorName(err)) else 0;
                placer.reconcile();
                native.platform_config_changed();
                return reply.json(.{ .ok = true, .applied = .{ .width = width, .height = height } });
            }
            const area = world.displayArea(source.display);
            var frame = source.floating_frame;
            frame.width = std.math.clamp(frame.width + offset.horizontal, 80, @max(80, area.left + area.width - frame.left));
            frame.height = std.math.clamp(frame.height + offset.vertical, 80, @max(80, area.top + area.height - frame.top));
            source.floating_frame = frame;
        },
        .center, .move_by => {
            if (source.managedFullscreen()) return reply.failure("ManagedFullscreenActive");
            if (!source.floating) return reply.failure("WindowNotFloating");
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
            const transaction = placer.Transaction.begin(.{ .display = source.display }) catch |err| return reply.failure(@errorName(err));
            defer transaction.deinit();
            const state = world.workspaceLayout(source.display, source.workspace);
            if (source.floating) source.floating_restore = true else world.layouts().reveal(state, source.identity) catch |err| return reply.failure(transaction.abort(err));
            state.fullscreen = if (state.fullscreen == source.identity) null else source.identity;
            if (!transaction.commit()) return reply.failure(journal.lastError() orelse "FullscreenPlacementFailed");
            return reply.json(.{ .ok = true, .verified = focus.verify(source.identity) });
        },
        .close => |quit_if_last| return close(source, quit_if_last),
        .toggle_floating => {
            if (source.managedFullscreen()) return reply.failure("ManagedFullscreenActive");
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
            const workspace = routing.resolveWorkspace(selection, if (world.config().workspace_monitors != null) slot else world.displayIndex(source.display).?) catch |err| return reply.failure(@errorName(err));
            const destination = resolved[workspace] orelse source.display;
            if (workspace == source.workspace and destination == source.display) return reply.json(.{ .ok = true, .changed = false });
            if (command == .send_to_workspace) {
                if (!routing.route(resolved, &.{}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return reply.failure(journal.lastError() orelse "MonitorRoutingFailed");
                focus.dropIfHidden();
                native.platform_config_changed();
                return reply.json(.{ .ok = true });
            }
            const destination_slot = world.displayIndex(destination).?;
            const from = routing.currentWorkspace(if (world.config().workspace_monitors != null) slot else destination_slot);
            const identity = source.identity;
            scene.markInstant();
            if (!routing.route(resolved, &.{.{ .display = destination, .workspace = workspace }}, .{ .index = sourceIndex, .display = destination, .workspace = workspace })) return reply.failure(journal.lastError() orelse "MonitorRoutingFailed");
            routing.recordPrevious(destination_slot, from, workspace);
            const verified = focus.verify(identity);
            native.platform_config_changed();
            return reply.json(.{ .ok = true, .verified = verified, .target = identity });
        },
        .send_to_monitor, .move_to_monitor => |selection| {
            // Sends a window to the target display's active workspace. Directions are relative to the window's
            // display. With global routing, a display that has no workspace placed on it rejects the send
            // instead of placing a workspace there.
            const origin = source.display;
            var screens: [monitor.capacity]monitor.Screen = undefined;
            const target = monitor.resolve(selection, world.monitorScreens(&screens), origin) catch |err| return reply.failure(@errorName(err));
            const workspace = world.displays()[world.displayIndex(target).?].workspace;
            if (target == origin) return reply.json(.{ .ok = true, .changed = false, .monitor = target, .workspace = source.workspace + 1 });
            const resolved = routing.resolve();
            if (world.config().workspace_monitors != null and resolved[workspace] != target) return reply.failure("NoWorkspaceOnMonitor");
            if (!routing.route(resolved, &.{.{ .display = target, .workspace = workspace }}, .{ .index = sourceIndex, .display = target, .workspace = workspace })) return reply.failure(journal.lastError() orelse "MonitorRoutingFailed");
            native.platform_config_changed();
            if (command == .move_to_monitor) return reply.json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = focus.verify(source.identity), .target = source.identity });
            // The selection stays, so keyboard focus returns to the selected display's candidate.
            const selected = world.selected() orelse origin;
            focus.focusWorkspace(selected, null);
            return reply.json(.{ .ok = true, .monitor = target, .workspace = workspace + 1, .verified = world.selected() == selected, .focused = focus.current() });
        },
        .focus => |request| return focus.toward(sourceIndex, request),
        .swap => |direction| return swapWindows(sourceIndex, focus.neighbor(sourceIndex, direction) orelse return reply.failure("NoWindowInDirection")),
        .swap_cycle => |step| {
            if (source.floating or source.managedFullscreen()) return reply.failure("WindowNotTiled");
            var identities: [1024]u64 = undefined;
            const target = selector.cycleTarget(focus.readingOrder(source.display, .tiled, &identities), source.identity, step) orelse return reply.failure("NoWindowToCycle");
            if (target == source.identity) return reply.json(.{ .ok = true, .changed = false });
            return swapWindows(sourceIndex, world.windowIndex(target).?);
        },
        .move => |direction| {
            if (source.managedFullscreen()) return reply.failure("ManagedFullscreenActive");
            if (!source.floating and !native.platform_read_frame(source.identity, &source.floating_frame)) return reply.failure("WindowGeometryUnavailable");
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
    return settle();
}

// The reply of an edit that only changed intent: placement applies it.
fn settle() reply.Reply {
    placer.reconcile();
    native.platform_config_changed();
    return reply.json(.{ .ok = true });
}

fn swapWindows(source_index: usize, target_index: usize) [*:0]const u8 {
    const source = &world.windows()[source_index];
    const target = &world.windows()[target_index];
    const identity = source.identity;
    const transaction = placer.Transaction.begin(.{ .pair = .{ source.display, target.display } }) catch |err| return reply.failure(@errorName(err));
    defer transaction.deinit();
    world.layouts().swap(source.identity, target.identity);
    if (source.managedFullscreen()) world.workspaceLayout(source.display, source.workspace).fullscreen = null;
    if (target.managedFullscreen()) world.workspaceLayout(target.display, target.workspace).fullscreen = null;
    std.mem.swap(u32, &source.display, &target.display);
    std.mem.swap(usize, &source.workspace, &target.workspace);
    std.mem.swap(Window, source, target);
    if (!transaction.commit()) return reply.failure(journal.lastError() orelse "SwapPlacementFailed");
    return reply.json(.{ .ok = true, .verified = focus.verify(identity) });
}
