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
const json = reply.json;
const failure = reply.failure;
const allocator = std.heap.c_allocator;
const Rect = native.WMRect;
const Layout = commands.Layout;
const Direction = commands.Direction;
const parseCommand = commands.parse;
var active_mode: usize = 0;
var shortcut_buffer: [64]commands.WorkspaceSelector = undefined;
var workspace_shortcuts: std.ArrayList(commands.WorkspaceSelector) = .initBuffer(&shortcut_buffer);
var hotkey_watch: delivery.Watch = .{};
var hotkey_recovery: struct { missed: usize = 0, rebinds: usize = 0, rebound: f64 = -std.math.inf(f64) } = .{};
var swipe_recognizer: swipe.Recognizer = .{};
var gestures_enabled = false;
const StatusPresentation = union(enum) {
    disabled,
    visible: struct { display_identity: ?u32, content: native.WMStatusPresentation },
};
var published_status: StatusPresentation = .disabled;
var status_active = false;
var pointer_controls: pointer.Controls = .{};
// A modified drag that moves or resizes a floating window. A resize moves the edges nearest the press, as in Hyprland.
const FloatingDrag = struct { gesture_id: u64, identity: u64, origin: interaction.Point, frame: Rect, from_left: bool, from_top: bool };
var floating_drag: ?FloatingDrag = null;
fn pointerWindows(output: []pointer.Window) []pointer.Window {
    for (world.windows(), 0..) |window, index| {
        const hit = window.visible() and !window.parked and !window.managedFullscreen() and !world.displayBlocked(window.display) and window.observation.hit_eligible and window.observation.motion == .idle;
        output[index] = .{
            .identity = window.identity,
            .public_id = window.observation.public_window_id,
            .goal = window.goal,
            .eligible = hit and !window.floating and world.framesNear(window.observation.frame, window.targetFrame(), 2),
            .title = text(&world.windows()[index].observation.title),
            .floating = if (hit and window.floating) window.observation.frame else null,
            .focused = focus.current() == window.identity,
        };
    }
    return output[0..world.windows().len];
}
fn publishPointer() void {
    // A new publication cancels the active gesture, and the dragged window's hit changes with every update.
    if (!world.isInitialized() or pointer_controls.stop_deadline != null or floating_drag != null) return;
    var observed: [1024]pointer.Window = undefined;
    var active: [32]*tiling.WorkspaceLayout = undefined;
    for (world.displays(), 0..) |display, index| active[index] = world.workspaceLayout(display.identity, display.workspace);
    pointer_controls.publish(world.layouts(), pointerWindows(&observed), active[0..world.displays().len], !world.isSuspended() and !scene.pending() and !routing.blocked(), world.config().border_color, world.config().border_width) catch |err| {
        pointer_controls.error_message = @errorName(err);
        interaction.huen_groups_clear();
    };
}
export fn wm_input_poll() void {
    if (!world.isInitialized()) return;
    if (world.isSuspended() or pointer_controls.stop_deadline != null) {
        // The end of an active drag is discarded below, and an active drag pauses scans.
        floating_drag = null;
        native.platform_drag_active(false);
        var discarded: interaction.Event = undefined;
        for (0..64) |_| if (!interaction.huen_input_poll(&discarded)) break;
        return;
    }
    var sample: interaction.Event = undefined;
    var count: usize = 0;
    poll: while (count < 64 and interaction.huen_input_poll(&sample)) : (count += 1) {
        if (sample.gesture == .move_floating or sample.gesture == .resize_floating) {
            switch (sample.kind) {
                .start => {
                    if (sample.generation != pointer_controls.generation) continue;
                    const window = world.windows()[world.windowIndex(sample.target.window_identity) orelse continue];
                    if (!window.floating or window.parked or !window.visible() or window.managedFullscreen()) continue;
                    const frame = window.observation.frame;
                    floating_drag = .{
                        .gesture_id = sample.gesture_id,
                        .identity = window.identity,
                        .origin = sample.origin,
                        .frame = frame,
                        .from_left = sample.origin.left < frame.left + frame.width / 2,
                        .from_top = sample.origin.top < frame.top + frame.height / 2,
                    };
                    _ = focus.verify(window.identity);
                    // The border stays hidden from the press to the release, so it never trails the window.
                    native.platform_drag_active(true);
                },
                .update, .end, .cancel => {
                    const drag = floating_drag orelse continue;
                    if (drag.gesture_id != sample.gesture_id) continue;
                    if (sample.kind != .update) floating_drag = null;
                    defer if (floating_drag == null) {
                        native.platform_config_changed();
                        native.platform_drag_active(false);
                        publishPointer();
                    };
                    const window = &world.windows()[world.windowIndex(drag.identity) orelse continue];
                    if (!window.floating) continue;
                    if (sample.kind != .cancel and !sample.crossed_threshold) continue;
                    const frame = if (sample.kind == .cancel) drag.frame else dragged: {
                        const horizontal = sample.point.left - drag.origin.left;
                        const vertical = sample.point.top - drag.origin.top;
                        var dragged = drag.frame;
                        if (sample.gesture == .move_floating) {
                            dragged.left += horizontal;
                            dragged.top += vertical;
                            break :dragged dragged;
                        }
                        dragged.width = @max(tiling.minimum_tile_extent, drag.frame.width + if (drag.from_left) -horizontal else horizontal);
                        dragged.height = @max(tiling.minimum_tile_extent, drag.frame.height + if (drag.from_top) -vertical else vertical);
                        if (drag.from_left) dragged.left = drag.frame.left + drag.frame.width - dragged.width;
                        if (drag.from_top) dragged.top = drag.frame.top + drag.frame.height - dragged.height;
                        break :dragged dragged;
                    };
                    window.floating_frame = frame;
                    window.floating_restore = false;
                    _ = native.platform_frame(window.identity, frame, 0, .visible_goal);
                },
                .group_select => {},
            }
            continue;
        }
        if (sample.kind == .start or sample.kind == .end or sample.kind == .group_select) {
            refreshObservations();
            if (!placer.deriveGoals()) continue;
        }
        var observed: [1024]pointer.Window = undefined;
        const edit = pointer_controls.event(world.layouts(), pointerWindows(&observed), sample, world.config().gap, world.config().border_color, world.config().border_width) catch |err| {
            pointer_controls.error_message = @errorName(err);
            interaction.huen_groups_preview(null);
            continue;
        } orelse continue;
        var handle = world.layouts().resolve(switch (edit) {
            .group => |selection| selection.group,
            .drop => |preview| preview.source,
            .resize => |preview| preview.boundary.node,
        }) catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        while (world.layouts().nodes[handle].parent) |parent| handle = parent;
        const state = for (&world.layouts().roots) |*slot| {
            if (slot.*) |*layout| if (layout.root == handle) break layout;
        } else {
            pointer_controls.error_message = "StaleNode";
            continue :poll;
        };
        const transaction = placer.Transaction.begin(.{ .display = state.display }) catch |err| {
            pointer_controls.error_message = @errorName(err);
            continue;
        };
        defer transaction.deinit();
        const result: anyerror!?u64 = switch (edit) {
            .group => |selection| world.layouts().selectGroupChild(state, selection.group, selection.child),
            .drop => |preview| drop: {
                const representative = world.layouts().representative(preview.source) catch |err| break :drop err;
                world.layouts().commitDrop(state, preview) catch |err| break :drop err;
                break :drop representative;
            },
            // Clearing bounds during the drag would move the published boundaries and cancel the gesture, so the release retries the rest.
            .resize => |preview| resize: {
                const requested = if (preview.boundary.axis == .width) sample.point.left - sample.origin.left else sample.point.top - sample.origin.top;
                world.layouts().commitResize(preview, world.config().gap) catch |err| break :resize err;
                if (@abs(requested - preview.applied_delta) <= size_bounds.tolerance or !placer.forgetWorkspaceBounds(state.display, state.workspace)) break :resize null;
                if (!placer.deriveGoals()) break :resize error.LayoutProjectionFailed;
                var boundary = preview.boundary;
                boundary.revision = world.layouts().revision;
                const retry = world.layouts().previewResize(boundary, requested - preview.applied_delta, world.config().gap) catch |err| break :resize err;
                world.layouts().commitResize(retry, world.config().gap) catch |err| break :resize err;
                break :resize null;
            },
        };
        const target = result catch |err| {
            pointer_controls.error_message = transaction.abort(err);
            continue;
        };
        if (!transaction.commit()) continue;
        if (target) |identity| if (!focus.verify(identity)) {
            pointer_controls.error_message = "HeaderFocusRejected";
        };
        native.platform_config_changed();
    }
    if (pointer_controls.revision != world.layouts().revision) publishPointer();
}
fn statusText(destination: []u8, source: []const u8, scalar_limit: usize) void {
    @memset(destination, 0);
    var length: usize = 0;
    var scalars: usize = 0;
    while (length < source.len and scalars < scalar_limit) : (scalars += 1) {
        const width = std.unicode.utf8ByteSequenceLength(source[length]) catch break;
        if (length + width > source.len or length + width >= destination.len) break;
        length += width;
    }
    @memcpy(destination[0..length], source[0..length]);
}
fn publishState() void {
    journal.flushTransition();
    publishPointer();
    publishStatus();
}
pub fn publishStatus() void {
    if (!status_active) return;
    const next: StatusPresentation = if (!world.config().status_bar.enabled) .disabled else status: {
        var presentation = std.mem.zeroes(native.WMStatusPresentation);
        const display: ?Display = if (world.displays().len > 0) world.displays()[world.activeDisplay()] else null;
        // With global routing, a display that has no workspace placed on it shows a dash.
        const placed: ?usize = if (display) |current| routing.placedWorkspace(current) else null;
        const workspace_index = placed orelse 0;
        const name = if (placed != null) text(&world.config().workspaces[workspace_index].name) else "No workspace";
        var index_buffer: [8]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buffer, "{d}", .{workspace_index + 1}) catch unreachable;
        var label_buffer: [80]u8 = undefined;
        const label = if (world.isSuspended()) "Paused" else if (display == null) "Huen WM" else if (placed == null) "—" else switch (world.config().status_bar.label) {
            .name => name,
            .index => index_text,
            .index_and_name => if (std.mem.eql(u8, name, index_text)) name else std.fmt.bufPrint(&label_buffer, "{s}  {s}", .{ index_text, name }) catch unreachable,
        };
        // A dot marks a workspace that holds an urgent window, and the title while any workspace does.
        var urgent: [10]bool = @splat(false);
        var alert = false;
        for (world.windows()) |window| if (window.urgent) {
            urgent[window.workspace] = true;
            alert = true;
        };
        const shown = if (active_mode != 0 and !world.isSuspended()) text(&world.config().modes[active_mode].name) else label;
        switch (world.config().status_bar.style) {
            .text => statusText(&presentation.title, shown, 24),
            .badge => statusText(&presentation.badge, shown, 24),
        }
        if (alert) {
            const mark = " •";
            @memcpy(presentation.title[text(&presentation.title).len..][0..mark.len], mark);
        }
        var tooltip_buffer: [512]u8 = undefined;
        const tooltip = std.fmt.bufPrint(&tooltip_buffer, "Huen WM · {s} · {s} · Mode {s}{s}", .{
            if (display) |current| text(&current.name) else "No display",
            name,
            text(&world.config().modes[active_mode].name),
            if (journal.lastError() != null) " · Workspace switch failed" else "",
        }) catch unreachable;
        statusText(&presentation.tooltip, tooltip, 255);
        for (world.config().workspaces[0..world.config().workspace_count], 0..) |*workspace, index| {
            const row = &presentation.rows[index];
            var row_buffer: [96]u8 = undefined;
            var number_buffer: [8]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buffer, "{d}", .{index + 1}) catch unreachable;
            const workspace_name = text(&workspace.name);
            const mark = if (urgent[index]) " •" else "";
            const title = if (std.mem.eql(u8, number, workspace_name)) std.fmt.bufPrint(&row_buffer, "{s}{s}", .{ workspace_name, mark }) catch unreachable else std.fmt.bufPrint(&row_buffer, "{s}  {s}{s}", .{ number, workspace_name, mark }) catch unreachable;
            statusText(&row.title, title, 79);
            _ = std.fmt.bufPrint(&row.command, "workspace {d}", .{index + 1}) catch unreachable;
            row.checked = placed == index;
            row.enabled = display != null and !world.isSuspended() and !scene.pending();
        }
        const reload_row = &presentation.rows[world.config().workspace_count];
        statusText(&reload_row.title, "Reload configuration", 79);
        statusText(&reload_row.command, "reload", 127);
        reload_row.enabled = !world.isSuspended() and !scene.pending() and !reload.inFlight();
        const quit_row = &presentation.rows[world.config().workspace_count + 1];
        statusText(&quit_row.title, "Quit", 79);
        statusText(&quit_row.command, "quit", 127);
        quit_row.enabled = true;
        presentation.row_count = world.config().workspace_count + 2;
        break :status .{ .visible = .{ .display_identity = if (display) |current| current.identity else null, .content = presentation } };
    };
    if (std.meta.eql(next, published_status)) return;
    published_status = next;
    switch (next) {
        .disabled => native.platform_status_present(null),
        .visible => |*presentation| native.platform_status_present(&presentation.content),
    }
}
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
    if (!native.platform_bindings(&world.config().modes[0].bindings, world.config().modes[0].binding_count)) return false;
    active_mode = 0;
    status_active = true;
    configureInput();
    publishStatus();
    return true;
}
fn configureInput() void {
    pointer_controls.configure(world.config().mouse.enabled, world.config().mouse.modifiers);
    if (gestures_enabled == world.config().swipe.enabled) return;
    gestures_enabled = world.config().swipe.enabled;
    native.huen_observe_gestures(gestures_enabled);
}
export fn wm_config_poll() void {
    // Cancelled requests must still drain while shutdown waits for the worker.
    if (scene.pending() and reload.waiting()) return;
    const candidate = reload.take() orelse return;
    if (!native.platform_bindings(&candidate.modes[0].bindings, candidate.modes[0].binding_count)) return reload.reject("HotkeyCollision");
    hotkey_watch.forgetPresses();
    routing.adoptConfig(&candidate);
    configureInput();
    checkpoint.configure();
    active_mode = 0;
    reload.settle();
    if (world.displays().len > 0) _ = routing.reroute();
    native.platform_config_changed();
    placer.reconcile();
    publishStatus();
}
const replacement_grace = 0.5;
fn replaces(ghost: Window, successor: Window) bool {
    const vanished = ghost.vanished orelse return false;
    return successor.vanished == null and successor.observation.pid == ghost.observation.pid and @abs(successor.discovered - vanished) <= replacement_grace and world.framesNear(successor.discovered_frame, ghost.observation.frame, 4);
}
export fn wm_tick() void {
    edits.pollClose();
    if (!world.isInitialized()) return;
    defer publishState();
    var observedDisplays: [32]native.WMDisplay = undefined;
    const displayCount = native.platform_displays(&observedDisplays, observedDisplays.len);
    var updated: [monitor.capacity]Display = undefined;
    var topology_changed = displayCount != world.displays().len;
    routing.cacheShown();
    for (observedDisplays[0..displayCount], updated[0..displayCount]) |observation, *display| {
        const previous: ?Display = if (world.displayIndex(observation.identity)) |index| world.displays()[index] else null;
        if (previous == null or !std.meta.eql(previous.?.full_bounds, observation.full_bounds) or !std.meta.eql(previous.?.frame, observation.frame) or previous.?.built_in != observation.built_in) topology_changed = true;
        display.* = .{ .identity = observation.identity, .frame = observation.frame, .full_bounds = observation.full_bounds, .name = observation.name, .built_in = observation.built_in, .workspace = if (previous) |known| known.workspace else 0, .previous_workspace = if (previous) |known| known.previous_workspace else null };
    }
    if (topology_changed) {
        if (world.displays().len != 0) placer.noteTopologyChange();
        scene.invalidate();
        workspace_shortcuts.clearRetainingCapacity();
    }
    world.replaceDisplays(updated[0..displayCount]);
    if (world.displays().len == 0) return;
    recall.load();
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_windows(&observed, observed.len);
    var recovered: [1024]parking.Recovery = undefined;
    const recoveries = recovery.recover(observed[0..count], &recovered);
    var observed_focus: ?u64 = null;
    for (observed[0..count]) |observation| {
        if (observation.focused) observed_focus = observation.identity;
        if (world.windowIndex(observation.identity)) |index| {
            var window = &world.windows()[index];
            window.observation = observation;
            if (window.vanished != null) {
                window.vanished = null;
                window.parked = window.vanished_parked;
                window.vanished_parked = false;
            }
            if (world.displayIndex(window.display) != null and !scene.pending() and window.floating and !window.managedFullscreen() and !window.parked and !observation.stale and observation.motion == .idle) {
                if (window.floating_restore) {
                    if (world.framesNear(observation.frame, window.floating_frame, 2)) window.floating_restore = false;
                } else window.floating_frame = observation.frame;
            }
            continue;
        }
        if (world.windows().len == 1024) continue;
        var best: f64 = std.math.inf(f64);
        var displaySlot: usize = 0;
        for (world.displays(), 0..) |candidate, slot| {
            const horizontal = observation.frame.left + observation.frame.width / 2 - candidate.frame.left - candidate.frame.width / 2;
            const vertical = observation.frame.top + observation.frame.height / 2 - candidate.frame.top - candidate.frame.height / 2;
            const distance = horizontal * horizontal + vertical * vertical;
            if (distance < best) {
                best = distance;
                displaySlot = slot;
            }
        }
        const display = world.displays()[displaySlot].identity;
        // With global routing, a window on an empty display joins the current workspace.
        const joined = routing.placedWorkspace(world.displays()[displaySlot]) orelse routing.currentWorkspace(displaySlot);
        var window: Window = .{ .identity = observation.identity, .observation = observation, .display = display, .workspace = joined, .parking_frame = observation.frame, .floating_frame = observation.frame, .goal = observation.frame, .discovered_frame = observation.frame };
        const decision = world.ruleDecision(&observation);
        window.floating = decision.floating orelse false;
        if (decision.workspace) |workspace| window.workspace = workspace;
        if (window.floating and (decision.geometry != null or decision.centered)) {
            const destination = routing.resolve()[window.workspace] orelse display;
            const area = world.displayArea(destination);
            var frame = observation.frame;
            if (decision.geometry) |geometry| frame = .{ .left = area.left + geometry.left, .top = area.top + geometry.top, .width = geometry.width, .height = geometry.height };
            // A centered window keeps its size, so an application with a fixed window size still accepts the placement.
            if (decision.centered) {
                frame.left = area.left + (area.width - frame.width) / 2;
                frame.top = area.top + (area.height - frame.height) / 2;
            }
            window.floating_frame = world.boundedFloating(frame, area);
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
        world.addWindow(window);
    }
    var now: ?f64 = null;
    for (world.windows()) |*window| {
        if (window.vanished != null) continue;
        for (observed[0..count]) |observation| {
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
    while (index < world.windows().len) {
        const vanished = world.windows()[index].vanished orelse {
            index += 1;
            continue;
        };
        const successor_index = search: {
            var found: ?usize = null;
            for (world.windows(), 0..) |candidate, candidate_index| if (replaces(world.windows()[index], candidate)) {
                if (found != null) break :search null;
                found = candidate_index;
            };
            const successor = world.windows()[found orelse break :search null];
            for (world.windows(), 0..) |other, other_index| if (other_index != index and replaces(other, successor)) break :search null;
            break :search found;
        };
        // The successor takes the ghost's slot because the master layout orders its stack by slot.
        if (successor_index) |successor_slot| {
            const ghost = world.windows()[index];
            var successor = world.windows()[successor_slot];
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
            world.layouts().replaceIdentity(ghost.identity, successor.identity);
            focus.rename(ghost.identity, successor.identity);
            world.replaceWithSuccessor(index, successor_slot, successor);
            continue;
        }
        if (now == null) now = native.platform_monotonic();
        if (now.? - vanished > replacement_grace) {
            // The window can still sit at its corner, as when its application stops being a regular application.
            if (world.windows()[index].vanished_parked) recovery.orphan(&world.windows()[index], now.?);
            // An application can take seconds to exit after its windows close, so the entry waits for `settle` to see the exit.
            const gone = world.windows()[index];
            recall.rememberClosed(gone, now.?);
            world.layouts().forgetIdentity(world.windows()[index].identity);
            focus.forget(world.windows()[index].identity);
            world.removeWindow(index);
        } else index += 1;
    }
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
pub fn refreshObservations() void {
    var observed: [1024]native.WMWindow = undefined;
    const count = native.platform_refresh_windows(&observed, observed.len);
    for (world.windows()) |*window| {
        window.observation.stale = true;
        for (observed[0..count]) |observation| if (observation.identity == window.identity) {
            window.observation = observation;
            break;
        };
    }
}
export fn wm_hotkey_poll() void {
    const now = native.platform_monotonic();
    // macOS can stop delivering registered hotkeys without an error.
    if (hotkey_watch.overdue(now)) |command| {
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
        wm_hotkey(&command);
    }
    if (focus.settled(now)) placeShortcuts();
}
export fn wm_hotkey_pressed(slot: u32, command: [*:0]const u8) void {
    hotkey_watch.pressed(slot, std.mem.span(command), native.platform_monotonic());
}
export fn wm_hotkey_delivered(slot: u32, command: [*:0]const u8) void {
    if (hotkey_watch.delivered(slot, native.platform_monotonic())) wm_hotkey(command);
}
export fn wm_swipe(fingers: u32, horizontal: f64, vertical: f64) void {
    if (!world.isInitialized() or !world.config().swipe.enabled) return;
    swipe_recognizer.fingers = world.config().swipe.fingers;
    const step = swipe_recognizer.sample(fingers, horizontal, vertical, native.platform_monotonic()) orelse return;
    if (world.isSuspended() or scene.pending() or native.platform_pointer_buttons()) return;
    var point: native.WMPoint = undefined;
    if (native.platform_pointer(&point)) for (world.displays()) |display| {
        const bounds = display.full_bounds;
        if (point.left < bounds.left or point.left >= bounds.left + bounds.width or point.top < bounds.top or point.top >= bounds.top + bounds.height) continue;
        focus.select(display.identity);
        break;
    };
    wm_hotkey(if (step == .next) "workspace occupied+1" else "workspace occupied-1");
}
fn placeShortcuts() void {
    if (workspace_shortcuts.items.len == 0) return;
    defer workspace_shortcuts.clearRetainingCapacity();
    if (world.isSuspended() or world.displays().len == 0 or scene.pending()) return;
    defer publishState();
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
export fn wm_hotkey(commandText: [*:0]const u8) void {
    const command = parseCommand(std.mem.span(commandText), world.config().workspace_count) catch return;
    if (command != .workspace or world.isSuspended() or scene.pending() or world.displays().len == 0 or (world.config().duration != 0 and native.huen_scene_capture_allowed())) {
        _ = wm_command(commandText);
        return;
    }
    if (workspace_shortcuts.items.len == workspace_shortcuts.capacity) placeShortcuts();
    workspace_shortcuts.appendAssumeCapacity(command.workspace);
}
export fn wm_command(commandText: [*:0]const u8) [*:0]const u8 {
    defer publishState();
    const command = parseCommand(std.mem.span(commandText), world.config().workspace_count) catch |err| return failure(@errorName(err));
    switch (command) {
        .status, .windows, .monitors, .workspaces, .wrong => {},
        .quit, .restore => workspace_shortcuts.clearRetainingCapacity(),
        else => placeShortcuts(),
    }
    switch (command) {
        .status => {
            const launch = native.platform_launch_status();
            var placed_rows: [10]routing.Placed = undefined;
            const placed = routing.placed(&placed_rows);
            return json(.{
                .running = true,
                .suspended = world.isSuspended(),
                .active_mode = text(&world.config().modes[active_mode].name),
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
                .hotkeys = .{ .watchdog = if (native.huen_observe_active()) "active" else "unavailable", .missed = hotkey_recovery.missed, .rebinds = hotkey_recovery.rebinds },
                .mouse = .{ .availability = interaction.huen_input_status(), .generation = pointer_controls.generation, .err_message = pointer_controls.error_message, .forced_stop = pointer_controls.forced_stop },
                .session = checkpoint.status(),
                .parking_recovery = recovery.status(),
                .placement_memory = recall.status(),
                .config_reload = reload.status(),
            });
        },
        .mode => |name| {
            const index = world.config().modeIndex(name.text()) orelse return failure("UnknownMode");
            const mode = &world.config().modes[index];
            if (!native.platform_bindings(&mode.bindings, mode.binding_count)) return failure("HotkeyCollision");
            hotkey_watch.forgetPresses();
            active_mode = index;
            return json(.{ .ok = true, .active_mode = text(&mode.name) });
        },
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
export fn wm_shutdown() bool {
    checkpoint.freeze();
    world.markSuspended();
    edits.cancelClose(false);
    status_active = false;
    native.platform_status_present(null);
    reload.cancel();
    if (reload.inFlight()) return false;
    if (!pointer_controls.stop(native.platform_monotonic())) return false;
    if (pointer_controls.forced_stop) native.platform_error("Input release drain exceeded 250 ms; tap teardown forced");
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
