const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const reply = @import("reply.zig");
const journal = @import("journal.zig");
const world = @import("world.zig");
const placer = @import("placer.zig");
const routing = @import("routing.zig");
const focus = @import("focus.zig");
const presenter = @import("presenter.zig");

const Transition = struct { display: u32, workspace: usize, from: usize, generation: u64, focus_target: ?u64 };
const SnapshotPresentation = enum { idle, pending, instant, captured, fallback };
var transition: ?Transition = null;
var generation: u64 = 0;
var snapshot_presentation: SnapshotPresentation = .idle;
pub fn cancel() void {
    if (transition != null) snapshot_presentation = .idle;
    transition = null;
    native.huen_scene_cancel();
}
fn commitWorkspace(displaySlot: usize, workspace: usize, from: usize, focus_target: ?u64) bool {
    const displayIdentity = world.displays()[displaySlot].identity;
    if (world.displayBlocked(displayIdentity)) {
        journal.setError("Native fullscreen window blocks this display");
        return false;
    }
    const transaction = placer.Transaction.begin(.{ .display = displayIdentity }) catch |err| {
        journal.setError(@errorName(err));
        return false;
    };
    defer transaction.deinit();
    world.displays()[displaySlot].workspace = workspace;
    var members: [1024]tiling.Member = undefined;
    const state = world.workspaceLayout(displayIdentity, workspace);
    if (focus_target orelse world.layouts().focusCandidate(state, world.layoutMembers(&members))) |identity| world.layouts().reveal(state, identity) catch |err| {
        journal.setError(transaction.abort(err));
        return false;
    };
    if (!transaction.commit()) return false;
    routing.recordPrevious(displaySlot, from, workspace);
    focus.focusWorkspace(displayIdentity, focus_target);
    journal.setError(null);
    native.platform_config_changed();
    return true;
}
fn sceneReady(context: ?*anyopaque, covered: bool) callconv(.c) void {
    const callbackGeneration = @intFromPtr(context orelse return);
    const request = transition orelse return;
    if (callbackGeneration != request.generation) return;
    defer presenter.publishStatus();
    defer journal.flushTransition();
    native.platform_settle_budget_begin();
    snapshot_presentation = if (covered) .captured else .fallback;
    if (world.displayIndex(request.display)) |displaySlot| {
        _ = commitWorkspace(displaySlot, request.workspace, request.from, request.focus_target);
    } else journal.setError("Display disconnected during workspace capture");
    transition = null;
    if (covered) native.huen_scene_finish(request.generation);
}
pub fn switchTo(display_slot: usize, workspace: usize, from: usize, focus_target: ?u64) [*:0]const u8 {
    const destination = world.displays()[display_slot];
    if (workspace == destination.workspace) {
        focus.focusWorkspace(destination.identity, focus_target);
        return reply.json(.{ .ok = true, .changed = false });
    }
    generation += 1;
    if (world.config().duration == 0 or !native.huen_scene_capture_allowed()) {
        snapshot_presentation = .instant;
        if (!commitWorkspace(display_slot, workspace, from, focus_target)) return reply.failure(journal.lastError() orelse "WorkspacePlacementFailed");
        return reply.json(.{ .ok = true });
    }
    snapshot_presentation = .pending;
    transition = .{ .display = destination.identity, .workspace = workspace, .from = from, .generation = generation, .focus_target = focus_target };
    native.huen_scene_begin(destination.identity, generation, world.config().duration, sceneReady, @ptrFromInt(generation));
    return reply.json(.{ .ok = true, .accepted = true, .generation = generation });
}
// Global mode: show `workspace` on its display and select that display. `from` is the
// selected display's workspace and becomes the global previous workspace.
pub fn show(workspace: usize, from: usize, focus_target: ?u64) [*:0]const u8 {
    const resolved = routing.resolve();
    const owner = resolved[workspace] orelse return reply.failure("NoWorkspaceOwner");
    const destination_slot = world.displayIndex(owner).?;
    var migration = routing.placementsChange(resolved);
    for (world.windows()) |window| if (window.display != resolved[window.workspace].?) {
        migration = true;
    };
    if (migration) {
        markInstant();
        if (!routing.route(resolved, &.{.{ .display = owner, .workspace = workspace }}, null)) return reply.failure(journal.lastError() orelse "MonitorRoutingFailed");
        routing.recordPrevious(destination_slot, from, workspace);
        focus.focusWorkspace(owner, focus_target);
        native.platform_config_changed();
        return reply.json(.{ .ok = true, .monitor = owner, .verified = world.selected() == owner, .target = focus_target });
    }
    if (!routing.reroute()) return reply.failure(journal.lastError() orelse "MonitorRoutingFailed");
    if (world.displays()[destination_slot].workspace != workspace) return switchTo(destination_slot, workspace, from, focus_target);
    focus.focusWorkspace(owner, focus_target);
    const verified = world.selected() == owner and (focus_target == null or focus.current() == focus_target);
    if (verified) routing.recordPrevious(destination_slot, from, workspace);
    return reply.json(.{ .ok = true, .changed = false, .monitor = owner, .verified = verified, .target = focus_target });
}
pub fn jump(identity: u64, display_slot: usize) [*:0]const u8 {
    const window = world.windows()[world.windowIndex(identity).?];
    if (world.config().workspace_monitors != null) return show(window.workspace, routing.currentWorkspace(display_slot), identity);
    const slot = world.displayIndex(window.display).?;
    if (window.workspace != world.displays()[slot].workspace) return switchTo(slot, window.workspace, world.displays()[slot].workspace, identity);
    focus.focusWorkspace(window.display, identity);
    return reply.json(.{ .ok = true, .verified = focus.current() == identity, .target = identity });
}

pub fn visit(selection: commands.WorkspaceSelector, slot: usize) reply.Reply {
    const display = &world.displays()[slot];
    const workspace = routing.resolveWorkspace(selection, slot) catch |err| return reply.failure(@errorName(err));
    if (world.config().workspace_monitors == null) return switchTo(slot, workspace, display.workspace, null);
    return show(workspace, routing.currentWorkspace(slot), null);
}

pub fn pending() bool {
    return transition != null;
}

// A display change invalidates the snapshot a pending transition waits on.
pub fn invalidate() void {
    generation += 1;
    cancel();
}

pub fn markInstant() void {
    generation += 1;
    snapshot_presentation = .instant;
}

pub fn presentation() SnapshotPresentation {
    return snapshot_presentation;
}

pub fn generationCount() u64 {
    return generation;
}
