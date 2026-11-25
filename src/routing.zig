const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const session = @import("session.zig");
const selector = @import("selector.zig");
const monitor = @import("monitor.zig");
const reply = @import("reply.zig");
const journal = @import("journal.zig");
const desktop = @import("desktop.zig");
const placer = @import("placer.zig");
const scene = @import("scene.zig");
const focus = @import("focus.zig");
const text = native.text;
const Rect = desktop.Rect;
const Display = desktop.Display;
const Config = desktop.Config;

// `shown` caches whether the workspace was active on its display at the start of the tick, so a
// workspace on a display that just vanished keeps that fact until routing moves it. `shown_when_lost`
// keeps it while the workspace waits on a fallback display, so a reconnect shows it again.
const Placement = struct { display: ?u32 = null, home: [128]u8 = @splat(0), shown: bool = false, shown_when_lost: bool = false };
var placements: [10]Placement = @splat(.{});
var global_previous: ?usize = null;

// The most recently selected display that had a placed workspace. With global routing, an empty
// selected display resolves "current workspace" from this display.
var current_display: ?u32 = null;
var routing_blocked = false;

fn applyLayoutDefaults(candidate: *const Config) void {
    var remap: [10]?usize = @splat(null);
    var claimed: [10]bool = @splat(false);
    for (desktop.config().workspaces[0..desktop.config().workspace_count], 0..) |*previous, old_index| for (candidate.workspaces[0..candidate.workspace_count], 0..) |*next, new_index| {
        if (!claimed[new_index] and std.mem.eql(u8, text(&previous.name), text(&next.name))) {
            remap[old_index] = new_index;
            claimed[new_index] = true;
            break;
        }
    };
    for (&desktop.layouts().roots) |*slot| if (slot.*) |*state| {
        const index = state.workspace;
        const next_index = remap[index] orelse {
            desktop.layouts().discard(state);
            slot.* = null;
            continue;
        };
        const previous = desktop.config().workspaces[index];
        const next = candidate.workspaces[next_index];
        state.workspace = next_index;
        if (previous.layout != next.layout or previous.ratio != next.ratio) {
            desktop.layouts().discard(state);
            state.layout = next.layout;
            state.ratio = next.ratio;
        }
    };
    for (desktop.windows()) |*window| window.workspace = remap[window.workspace] orelse @min(window.workspace, candidate.workspace_count - 1);
    for (desktop.displays()) |*display| {
        display.workspace = remap[display.workspace] orelse @min(display.workspace, candidate.workspace_count - 1);
        display.previous_workspace = remapPrevious(display.previous_workspace, display.workspace, &remap);
    }
    var remapped: [10]Placement = @splat(.{});
    for (remapped[0..candidate.workspace_count]) |*placement| placement.display = owner();
    for (placements[0..desktop.config().workspace_count], remap[0..desktop.config().workspace_count]) |placement, next_index| if (next_index) |index| {
        remapped[index] = placement;
    };
    // A reload returns workspaces with a monitor field to configuration placement. Leaving global
    // routing clears every runtime home.
    for (remapped[0..candidate.workspace_count], candidate.workspaces[0..candidate.workspace_count]) |*placement, *workspace| {
        if (candidate.workspace_monitors == null or workspace.monitor.count > 0) placement.home = @splat(0);
    }
    placements = remapped;
    const current = for (0..candidate.workspace_count) |workspace| {
        if (shownWorkspace(workspace)) break workspace;
    } else 0;
    global_previous = remapPrevious(global_previous, current, &remap);
}

fn remapPrevious(previous: ?usize, current: usize, remap: []const ?usize) ?usize {
    const next = remap[previous orelse return null] orelse return null;
    return if (next == current) null else next;
}

fn previousWorkspace(display_slot: usize) *?usize {
    return if (desktop.config().workspace_monitors != null) &global_previous else &desktop.displays()[display_slot].previous_workspace;
}

pub fn recordPrevious(display_slot: usize, from: usize, workspace: usize) void {
    if (from != workspace) previousWorkspace(display_slot).* = from;
}

// With global routing, an empty display uses the active workspace of the most recently selected
// display that had one, else the lowest shown workspace.
pub fn currentWorkspace(display_slot: usize) usize {
    const display = desktop.displays()[display_slot];
    if (placedWorkspace(display)) |workspace| return workspace;
    if (current_display) |identity| if (desktop.displayIndex(identity)) |index| if (placedWorkspace(desktop.displays()[index])) |workspace| return workspace;
    for (0..desktop.config().workspace_count) |workspace| if (shownWorkspace(workspace)) return workspace;
    return @min(display.workspace, desktop.config().workspace_count - 1);
}

pub fn trackCurrentDisplay() void {
    const identity = desktop.selected() orelse return;
    const index = desktop.displayIndex(identity) orelse return;
    if (placedWorkspace(desktop.displays()[index]) != null) current_display = identity;
}

pub fn view(display_slot: usize) selector.View {
    var occupied: selector.Occupancy = .empty;
    const display = desktop.displays()[display_slot];
    for (desktop.windows()) |window| if (window.eligible() and (desktop.config().workspace_monitors != null or window.display == display.identity)) occupied.set(window.workspace);
    // `workspace N` from an empty display does not flip to the previous workspace, except in owner
    // mode, where the owner's workspace is the current one for every display.
    const back_and_forth = desktop.config().workspace_back_and_forth and (placedWorkspace(display) != null or owner() != null);
    return .{ .config = desktop.config(), .current = currentWorkspace(display_slot), .previous = previousWorkspace(display_slot).*, .occupied = occupied, .back_and_forth = back_and_forth };
}

pub fn resolveWorkspace(selection: commands.WorkspaceSelector, display_slot: usize) !usize {
    return selector.resolve(selection, view(display_slot));
}

pub fn owner() ?u32 {
    const first = placements[0].display orelse return null;
    for (placements[1..desktop.config().workspace_count]) |placement| if (placement.display != first) return null;
    return first;
}

// The display's active workspace, or null when global routing places no workspace on it.
pub fn placedWorkspace(display: Display) ?usize {
    if (desktop.config().workspace_monitors == null or placements[display.workspace].display == display.identity) return display.workspace;
    return null;
}

pub fn shownWorkspace(workspace: usize) bool {
    const identity = placements[workspace].display orelse return false;
    if (desktop.displayIndex(identity)) |index| return desktop.displays()[index].workspace == workspace;
    return placements[workspace].shown;
}

pub fn resolve() [10]?u32 {
    var resolved: [10]?u32 = @splat(null);
    const preferences = desktop.config().workspace_monitors orelse return resolved;
    var fallback: [2]commands.MonitorSelector = undefined;
    for (preferences.order[0..preferences.count], fallback[0..preferences.count]) |preference, *selection| selection.* = .{ .class = switch (preference) {
        .external => .external,
        .@"built-in" => .@"built-in",
    } };
    var screens: [monitor.capacity]monitor.Screen = undefined;
    const available = desktop.monitorScreens(&screens);
    for (desktop.config().workspaces[0..desktop.config().workspace_count], placements[0..desktop.config().workspace_count], resolved[0..desktop.config().workspace_count]) |*workspace, *placement, *destination| {
        const home = text(&placement.home);
        const home_display: ?u32 = if (home.len == 0) null else for (desktop.displays()) |display| {
            var uuid: [64]u8 = @splat(0);
            if (session.huen_session_display_uuid(display.identity, &uuid, uuid.len) and std.mem.eql(u8, text(&uuid), home)) break display.identity;
        } else null;
        destination.* = monitor.place(available, .{ .home = home_display, .monitors = workspace.monitor.slice(), .fallback = fallback[0..preferences.count], .current = placement.display });
    }
    return resolved;
}

pub const Activation = struct { display: u32, workspace: usize };

pub fn route(resolved: [10]?u32, forced: []const Activation, send: ?struct { index: usize, display: u32, workspace: usize }) bool {
    const workspace_count = desktop.config().workspace_count;
    var activations: [11]Activation = undefined;
    @memcpy(activations[0..forced.len], forced);
    var count = forced.len;
    scan: for (desktop.displays()) |display| {
        const identity = display.identity;
        for (forced) |activation| if (activation.display == identity) continue :scan;
        const current = display.workspace;
        var gained = false;
        var hosts = false;
        for (resolved[0..workspace_count], placements[0..workspace_count]) |destination, placement| if (destination == identity) {
            hosts = true;
            if (placement.display != identity) gained = true;
        };
        const lost = placements[current].display == identity and resolved[current] != identity;
        if (!hosts or !(gained or lost)) continue;
        const choice = if (placements[current].display == identity and resolved[current] == identity) current else for (0..workspace_count) |workspace| {
            if (resolved[workspace] == identity and placements[workspace].display != identity and shownWorkspace(workspace)) break workspace;
        } else for (0..workspace_count) |workspace| {
            // A reconnected display shows the workspace it showed when it disconnected.
            if (resolved[workspace] == identity and placements[workspace].display != identity and placements[workspace].shown_when_lost) break workspace;
        } else if (resolved[current] == identity) current else for (0..workspace_count) |workspace| {
            if (resolved[workspace] == identity) break workspace;
        } else unreachable;
        activations[count] = .{ .display = identity, .workspace = choice };
        count += 1;
    }
    const transaction = placer.Transaction.begin(.all) catch |err| {
        journal.setError(@errorName(err));
        return false;
    };
    defer transaction.deinit();
    var staged: [1024]u32 = undefined;
    for (activations[0..count]) |activation| if (desktop.displayBlocked(activation.display)) {
        journal.setError("Native fullscreen window blocks routing destination");
        return false;
    };
    for (desktop.windows(), 0..) |window, index| {
        const sent = send != null and send.?.index == index;
        const destination = if (sent) send.?.display else resolved[window.workspace] orelse if (desktop.displayIndex(window.display) == null) desktop.displays()[0].identity else window.display;
        staged[index] = destination;
        if (window.vanished != null) continue;
        if (window.observation.minimized or window.observation.fullscreen or (!window.observation.onscreen and !window.parked)) {
            if (destination != window.display or (window.observation.fullscreen and sent)) {
                journal.setError("Routing deferred for unavailable or native fullscreen window");
                return false;
            }
            continue;
        }
        if (window.observation.stale or desktop.displayBlocked(destination) or desktop.displayBlocked(window.display)) {
            journal.setError("Routing blocked by stale or native fullscreen window");
            return false;
        }
        var original: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &original)) {
            journal.setError("Routing geometry could not be read");
            return false;
        }
    }
    for (&desktop.layouts().roots) |*slot| if (slot.*) |*state| {
        const destination = resolved[state.workspace] orelse if (desktop.displayIndex(state.display) == null) desktop.displays()[0].identity else state.display;
        if (destination == state.display) continue;
        if (desktop.layouts().lookup(destination, state.workspace)) |existing| {
            const defaults = desktop.config().workspaces[state.workspace];
            const empty_default = existing.root == null and existing.fullscreen == null and existing.layout == defaults.layout and existing.ratio == defaults.ratio;
            if (empty_default) {
                existing.* = state.*;
                existing.display = destination;
            } else desktop.layouts().discard(state);
            slot.* = null;
        } else state.display = destination;
    };
    for (activations[0..count]) |activation| desktop.displays()[desktop.displayIndex(activation.display).?].workspace = activation.workspace;
    for (desktop.windows(), staged[0..desktop.windows().len], 0..) |*window, destination, index| {
        if (send) |request| if (request.index == index) {
            window.workspace = request.workspace;
        };
        if (destination == window.display) continue;
        const area = desktop.displayArea(destination);
        // Keeps a floating window's center at the same proportional position in the destination area.
        var relocated = window.floating_frame;
        if (desktop.displayIndex(window.display)) |slot| {
            const previous = desktop.displays()[slot].area();
            relocated.left = area.left + (relocated.left + relocated.width / 2 - previous.left) / previous.width * area.width - relocated.width / 2;
            relocated.top = area.top + (relocated.top + relocated.height / 2 - previous.top) / previous.height * area.height - relocated.height / 2;
        }
        window.floating_frame = desktop.boundedFloating(relocated, area);
        window.parking_frame = desktop.boundedFloating(window.parking_frame, area);
        window.display = destination;
    }
    if (send) |request| desktop.layouts().forgetIdentity(desktop.windows()[request.index].identity);
    if (!transaction.commit()) return false;
    for (&placements, resolved) |*placement, destination| {
        if (destination != placement.display) {
            const lost = if (placement.display) |identity| desktop.displayIndex(identity) == null else false;
            placement.shown_when_lost = lost and (placement.shown or placement.shown_when_lost);
        }
        placement.display = destination;
    }
    routing_blocked = false;
    return true;
}

fn routeMembership() bool {
    const resolved = resolve();
    var needed = placementsChange(resolved);
    for (desktop.windows()) |window| {
        const destination = resolved[window.workspace];
        if (desktop.displayIndex(window.display) == null or (destination != null and window.display != destination.?)) needed = true;
    }
    for (desktop.layouts().roots) |slot| if (slot) |state| {
        const defaults = desktop.config().workspaces[state.workspace];
        const has_state = state.root != null or state.fullscreen != null or state.layout != defaults.layout or state.ratio != defaults.ratio;
        const destination = resolved[state.workspace];
        if (has_state and (desktop.displayIndex(state.display) == null or (destination != null and state.display != destination.?))) needed = true;
    };
    return !needed or route(resolved, &.{}, null);
}

pub fn moveWorkspace(selection: commands.MonitorSelector, slot: usize, swap: bool) reply.Reply {
    const display = &desktop.displays()[slot];
    if (desktop.config().workspace_monitors == null) return reply.failure("RequiresGlobalWorkspaces");
    var screens: [monitor.capacity]monitor.Screen = undefined;
    const target = monitor.resolve(selection, desktop.monitorScreens(&screens), display.identity) catch |err| return reply.failure(@errorName(err));
    const workspace = display.workspace;
    if (placements[workspace].display != display.identity) return reply.failure("NoWorkspaceOnMonitor");
    if (target == display.identity) return reply.json(.{ .ok = true, .changed = false, .monitor = target });
    // Each moved workspace's runtime home becomes its destination display, which shows it.
    var forced: [2]Activation = .{ .{ .display = target, .workspace = workspace }, undefined };
    var count: usize = 1;
    if (swap) {
        const target_workspace = desktop.displays()[desktop.displayIndex(target).?].workspace;
        if (placements[target_workspace].display != target) return reply.failure("NoWorkspaceOnMonitor");
        forced[1] = .{ .display = display.identity, .workspace = target_workspace };
        count = 2;
    }
    const homes = homeSnapshot();
    for (forced[0..count]) |move| {
        const moved = &placements[move.workspace].home;
        moved.* = @splat(0);
        if (session.huen_session_display_uuid(move.display, moved, moved.len)) continue;
        restoreHomes(homes);
        return reply.failure("MonitorUuidUnavailable");
    }
    const resolved = resolve();
    // The vacated display shows the global previous workspace if it is placed there, else its lowest placed one, else nothing.
    if (!swap) {
        const vacated = display.identity;
        const fallback: ?usize = if (global_previous != null and resolved[global_previous.?] == vacated) global_previous else for (0..desktop.config().workspace_count) |candidate| {
            if (resolved[candidate] == vacated) break candidate;
        } else null;
        if (fallback) |shown| {
            forced[1] = .{ .display = vacated, .workspace = shown };
            count = 2;
        }
    }
    scene.markInstant();
    if (!route(resolved, forced[0..count], null)) {
        restoreHomes(homes);
        return reply.failure(journal.lastError() orelse "MonitorRoutingFailed");
    }
    focus.focusWorkspace(target, null);
    native.platform_config_changed();
    return reply.json(.{ .ok = true, .monitor = target, .verified = desktop.selected() == target, .focused = focus.current() });
}

pub fn moveApp(request: commands.MoveApp, slot: usize) reply.Reply {
    const resolved = resolve();
    const workspace = resolveWorkspace(request.workspace, slot) catch |err| return reply.failure(@errorName(err));
    var identities: [1024]u64 = undefined;
    var count: usize = 0;
    for (desktop.windows()) |window| if (window.vanished == null and std.mem.eql(u8, text(&window.observation.bundle), request.bundle.text())) {
        identities[count] = window.identity;
        count += 1;
    };
    var moved: usize = 0;
    var first_error: ?[]const u8 = null;
    for (identities[0..count]) |identity| {
        const index = desktop.windowIndex(identity) orelse continue;
        const window = desktop.windows()[index];
        const destination = resolved[workspace] orelse window.display;
        if (workspace == window.workspace and destination == window.display) continue;
        if (route(resolved, &.{}, .{ .index = index, .display = destination, .workspace = workspace })) moved += 1 else if (first_error == null) {
            first_error = journal.lastError() orelse "MonitorRoutingFailed";
        }
    }
    focus.dropIfHidden();
    if (moved > 0) native.platform_config_changed();
    if (first_error) |message| return reply.json(.{ .@"error" = true, .err_message = message, .moved = moved });
    return reply.json(.{ .ok = true, .moved = moved });
}

// Adopts a new config, carrying layouts, windows, displays and placements over to its workspaces.
pub fn adoptConfig(candidate: *const Config) void {
    applyLayoutDefaults(candidate);
    desktop.setConfig(candidate);
}

// Routes the workspaces to the displays they resolve to. Placement stays blocked until a route succeeds.
pub fn reroute() bool {
    routing_blocked = !routeMembership();
    return !routing_blocked;
}

// Whether `resolved` places any workspace on another display than it is on now.
pub fn placementsChange(resolved: [10]?u32) bool {
    var changed = false;
    for (resolved[0..desktop.config().workspace_count], placements[0..desktop.config().workspace_count]) |destination, placement| if (destination != placement.display) {
        changed = true;
    };
    return changed;
}

pub fn blocked() bool {
    return routing_blocked;
}

pub fn cacheShown() void {
    for (&placements, 0..) |*placement, workspace| if (placement.display) |identity| if (desktop.displayIndex(identity)) |index| {
        placement.shown = desktop.displays()[index].workspace == workspace;
    };
}

pub fn host(workspace: usize) ?u32 {
    return placements[workspace].display;
}

pub fn homeSnapshot() [10][128]u8 {
    var homes: [10][128]u8 = undefined;
    for (&homes, placements) |*home, placement| home.* = placement.home;
    return homes;
}

fn restoreHomes(homes: [10][128]u8) void {
    for (&placements, homes) |*placement, home| placement.home = home;
}

// Saved runtime homes are seeded before placement so moved workspaces restore on their homes.
pub fn seedHomes(saved: [10]?[]const u8) void {
    for (saved, &placements) |saved_home, *placement| if (saved_home) |hint| {
        placement.home = @splat(0);
        @memcpy(placement.home[0..hint.len], hint);
    };
}

pub const Placed = struct { index: usize, name: []const u8, display: ?u32, home: []const u8 };

pub fn placed(output: *[10]Placed) []Placed {
    const count = desktop.config().workspace_count;
    for (desktop.config().workspaces[0..count], placements[0..count], output[0..count], 0..) |*workspace, *placement, *item, index| {
        item.* = .{ .index = index + 1, .name = text(&workspace.name), .display = placement.display, .home = text(&placement.home) };
    }
    return output[0..count];
}
