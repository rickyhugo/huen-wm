const std = @import("std");
const native = @import("native.zig");
const journal = @import("journal.zig");
const desktop = @import("desktop.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const focus = @import("focus.zig");
const recovery = @import("recovery.zig");
const recall = @import("recall.zig");
const Window = desktop.Window;

const replacement_grace = 0.5;

fn replaces(ghost: Window, successor: Window) bool {
    const vanished = ghost.vanished orelse return false;
    return successor.vanished == null and successor.observation.pid == ghost.observation.pid and @abs(successor.discovered - vanished) <= replacement_grace and desktop.framesNear(successor.discovered_frame, ghost.observation.frame, 4);
}

pub fn refresh() void {
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_refresh_windows(&observed, observed.len);
    for (desktop.windows()) |*window| {
        window.observation.stale = true;
        for (observed[0..count]) |observation| if (observation.identity == window.identity) {
            window.observation = observation;
            break;
        };
    }
}

pub fn scan(buffer: *[1024]native.WMWindow) []native.WMWindow {
    return buffer[0..native.platform_windows(buffer, buffer.len)];
}

// Updates known windows from the scan and adds new ones. Returns the window the scan reports focused.
pub fn adopt(observed: []const native.WMWindow, recoveries: recovery.Recovered) ?u64 {
    var observed_focus: ?u64 = null;
    for (observed) |observation| {
        if (observation.focused) observed_focus = observation.identity;
        if (desktop.windowIndex(observation.identity)) |index| {
            var window = &desktop.windows()[index];
            window.observation = observation;
            if (window.vanished != null) {
                window.vanished = null;
                window.parked = window.vanished_parked;
                window.vanished_parked = false;
            }
            if (desktop.displayIndex(window.display) != null and !scene.pending() and window.floating and !window.managedFullscreen() and !window.parked and !observation.stale and observation.motion == .idle) {
                if (window.floating_restore) {
                    if (desktop.framesNear(observation.frame, window.floating_frame, 2)) window.floating_restore = false;
                } else window.floating_frame = observation.frame;
            }
            continue;
        }
        if (desktop.windows().len == 1024) continue;
        var best: f64 = std.math.inf(f64);
        var displaySlot: usize = 0;
        for (desktop.displays(), 0..) |candidate, slot| {
            const horizontal = observation.frame.left + observation.frame.width / 2 - candidate.frame.left - candidate.frame.width / 2;
            const vertical = observation.frame.top + observation.frame.height / 2 - candidate.frame.top - candidate.frame.height / 2;
            const distance = horizontal * horizontal + vertical * vertical;
            if (distance < best) {
                best = distance;
                displaySlot = slot;
            }
        }
        const display = desktop.displays()[displaySlot].identity;
        // With global routing, a window on an empty display joins the current workspace.
        const joined = routing.placedWorkspace(desktop.displays()[displaySlot]) orelse routing.currentWorkspace(displaySlot);
        var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = joined, .parking_frame = observation.frame, .floating_frame = observation.frame, .goal = observation.frame, .discovered_frame = observation.frame };
        const decision = desktop.ruleDecision(&observation);
        window.floating = decision.floating orelse false;
        if (decision.workspace) |workspace| window.workspace = workspace;
        if (window.floating and (decision.geometry != null or decision.centered)) {
            const destination = routing.resolve()[window.workspace] orelse display;
            const area = desktop.displayArea(destination);
            var frame = observation.frame;
            if (decision.geometry) |geometry| frame = .{ .left = area.left + geometry.left, .top = area.top + geometry.top, .width = geometry.width, .height = geometry.height };
            // A centered window keeps its size, so an application with a fixed window size still accepts the placement.
            if (decision.centered) {
                frame.left = area.left + (area.width - frame.width) / 2;
                frame.top = area.top + (area.height - frame.height) / 2;
            }
            window.floating_frame = desktop.boundedFloating(frame, area);
            window.floating_restore = true;
        }
        // A recovered window stays owned even when it did not reach its frame or shares it with another window of its application.
        for (recoveries.matches) |match| if (observed[match.index].identity == observation.identity) {
            window.parked = true;
            window.parking_frame = match.original;
        };
        window.discovered = native.platform_monotonic();
        // A window the first scan finds predates the manager, but its application may have launched only moments before.
        window.established = recoveries.first_scan and age: {
            if (observation.process_token == 0) break :age false;
            // The token is a launch date in seconds since 2001.
            break :age @as(f64, @floatFromInt(journal.wallSeconds())) - 978307200 - observation.process_token > 5;
        };
        recall.claim(&window, decision, display);
        desktop.addWindow(window);
    }
    return observed_focus;
}

// Marks windows the scan no longer reports as vanished, hands each to a relaunched successor, and drops the rest after a grace period.
// One clock read serves both passes.
pub fn retire(observed: []const native.WMWindow) void {
    var now: ?f64 = null;
    for (desktop.windows()) |*window| {
        if (window.vanished != null) continue;
        for (observed) |observation| {
            if (observation.identity == window.identity) break;
        } else {
            window.vanished = now orelse native.platform_monotonic();
            now = window.vanished;
            window.observation.stale = true;
            window.observation.onscreen = false;
            window.observation.focused = false;
            window.observation.fullscreen = false;
            window.vanished_parked = window.parked;
            window.parked = false;
            window.urgent = false;
        }
    }
    var index: usize = 0;
    while (index < desktop.windows().len) {
        const vanished = desktop.windows()[index].vanished orelse {
            index += 1;
            continue;
        };
        const successor_index = search: {
            var found: ?usize = null;
            for (desktop.windows(), 0..) |candidate, candidate_index| if (replaces(desktop.windows()[index], candidate)) {
                if (found != null) break :search null;
                found = candidate_index;
            };
            const successor = desktop.windows()[found orelse break :search null];
            for (desktop.windows(), 0..) |other, other_index| if (other_index != index and replaces(other, successor)) break :search null;
            break :search found;
        };
        // The successor takes the ghost's slot because the master layout orders its stack by slot.
        if (successor_index) |successor_slot| {
            const ghost = desktop.windows()[index];
            var successor = desktop.windows()[successor_slot];
            successor.workspace = ghost.workspace;
            successor.display = ghost.display;
            successor.floating = ghost.floating;
            successor.floating_frame = ghost.floating_frame;
            successor.floating_restore = ghost.floating;
            successor.last_floating_frame = ghost.last_floating_frame;
            successor.bounds = ghost.bounds;
            successor.placed = null;
            // The successor appeared at the corner, so that frame must not become the geometry that restore writes back.
            if (ghost.vanished_parked) {
                successor.parking_frame = recovery.restingFrame(ghost.parking_frame);
                successor.parked = true;
                var actual = successor.observation.frame;
                _ = native.platform_adopt_original(successor.identity, successor.parking_frame, &actual);
                successor.observation.frame = actual;
            }
            desktop.layouts().replaceIdentity(ghost.identity, successor.identity);
            focus.rename(ghost.identity, successor.identity);
            desktop.replaceWithSuccessor(index, successor_slot, successor);
            continue;
        }
        if (now == null) now = native.platform_monotonic();
        if (now.? - vanished > replacement_grace) {
            if (desktop.windows()[index].vanished_parked) recovery.orphan(&desktop.windows()[index], now.?);
            const gone = desktop.windows()[index];
            recall.rememberClosed(gone, now.?);
            desktop.layouts().forgetIdentity(desktop.windows()[index].identity);
            focus.forget(desktop.windows()[index].identity);
            desktop.removeWindow(index);
        } else index += 1;
    }
}
