const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const size_bounds = @import("bounds.zig");
const parking = @import("parking.zig");
const world = @import("world.zig");
const journal = @import("journal.zig");
const recovery = @import("recovery.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const focus = @import("focus.zig");
const allocator = std.heap.c_allocator;
const text = native.text;
const Rect = world.Rect;
const Window = world.Window;
const Display = world.Display;

const snap_back_window: f64 = 1.0;
const launch_grace: f64 = 1.0;

// macOS moves windows when a display goes away, which must not count as an application moving its own window.
var topology_changed_at: f64 = -std.math.inf(f64);

pub fn resizeTiled(source_index: usize, axis: commands.Axis, delta: f64) !f64 {
    const source = world.windows()[source_index];
    const state = world.workspaceLayout(source.display, source.workspace);
    if (state.layout == .dwindle) return world.layouts().resizePoints(source.identity, axis, delta, world.config().gap);
    if (axis != .width) return error.MasterHeightResizeUnsupported;
    var indices: [1024]usize = undefined;
    var count: usize = 0;
    for (world.windows(), 0..) |window, index| {
        if (window.display != source.display or window.workspace != source.workspace or !window.visible() or window.floating) continue;
        indices[count] = index;
        count += 1;
    }
    if (count < 2) return 0;
    const area = world.displayArea(source.display);
    const available = area.width - tiling.innerGap(area.width, world.config().gap);
    const limits = switch (tiling.leadingRange(available, available * state.ratio, masterSides(indices[0..count]))) {
        .fits => |span| span,
        .overlaps => return 0,
    };
    const sign: f64 = if (indices[0] == source_index) 1 else -1;
    const previous = std.math.clamp(available * state.ratio, limits.lower, limits.upper);
    const next = std.math.clamp(previous + sign * delta, limits.lower, limits.upper);
    state.ratio = next / available;
    return (next - previous) * sign;
}

pub const Transaction = struct {
    pub const Scope = union(enum) { all, display: u32, pair: [2]u32 };
    store: *tiling.Store,
    intent: []Window,
    screens: []Display,
    originals: []?Rect,
    selected: ?u32,
    pub fn begin(scope: Scope) !Transaction {
        const store = try allocator.create(tiling.Store);
        errdefer allocator.destroy(store);
        store.* = world.layouts().*;
        const intent = try allocator.dupe(Window, world.windows());
        errdefer allocator.free(intent);
        const screens = try allocator.dupe(Display, world.displays());
        errdefer allocator.free(screens);
        const originals = try allocator.alloc(?Rect, world.windows().len);
        errdefer allocator.free(originals);
        for (world.windows(), 0..) |window, index| {
            originals[index] = null;
            const included = switch (scope) {
                .all => true,
                .display => |identity| identity == window.display,
                .pair => |identities| identities[0] == window.display or identities[1] == window.display,
            };
            if (!included) continue;
            if (world.displayBlocked(window.display)) return error.NativeFullscreenBlocksPlacement;
            if (window.observation.stale and (window.observation.onscreen or window.parked)) return error.StaleWindowBlocksPlacement;
            if (!window.eligible()) continue;
            var frame: Rect = undefined;
            if (!native.platform_read_frame(window.identity, &frame)) return error.PlacementSnapshotUnreadable;
            originals[index] = frame;
        }
        return .{ .store = store, .intent = intent, .screens = screens, .originals = originals, .selected = world.selected() };
    }
    pub fn deinit(self: Transaction) void {
        allocator.destroy(self.store);
        allocator.free(self.intent);
        allocator.free(self.screens);
        allocator.free(self.originals);
    }
    // `attempted` holds indices into `world.windows()` in the order their placement was attempted.
    fn rollback(self: Transaction, attempted: []const usize) void {
        recovery.save(self.intent);
        var remaining = attempted.len;
        while (remaining > 0) {
            remaining -= 1;
            const identity = world.windows()[attempted[remaining]].identity;
            const original_index = self.identityIndex(identity);
            const original = self.originals[original_index] orelse continue;
            var restored = original;
            if (verifiedFrame(identity, original, null, &restored)) continue;
            const intent = &self.intent[original_index];
            if (!intent.parked) intent.parking_frame = original;
            intent.parked = true;
            intent.parked_at = null;
            intent.placement_error = "Placement rollback rejected; recovery ownership retained";
        }
        world.layouts().* = self.store.*;
        @memcpy(world.windows(), self.intent);
        @memcpy(world.displays(), self.screens);
        world.setSelected(self.selected);
    }
    pub fn abort(self: Transaction, err: anyerror) []const u8 {
        self.rollback(&.{});
        return @errorName(err);
    }
    fn identityIndex(self: Transaction, identity: u64) usize {
        for (self.intent, 0..) |window, index| if (window.identity == identity) return index;
        unreachable;
    }
    // Shows the incoming windows before parking the outgoing ones, back to front, so the desktop never shows through.
    pub fn commit(self: Transaction) bool {
        if (!deriveGoals()) {
            self.rollback(&.{});
            return false;
        }
        var order: [1024]usize = undefined;
        var count: usize = 0;
        for (world.windows(), 0..) |window, index| if (self.originals[self.identityIndex(window.identity)] != null and window.visible()) {
            order[count] = index;
            count += 1;
        };
        const shown = count;
        for (world.windows(), 0..) |window, index| if (self.originals[self.identityIndex(window.identity)] != null and !window.visible()) {
            order[count] = index;
            count += 1;
        };
        std.mem.sort(usize, order[shown..count], {}, backToFront);
        for (order[0..count], 0..) |index, position| {
            const window = &world.windows()[index];
            const outcome = if (window.visible()) placeVisible(window) else parkWindow(window);
            if (outcome == .applied) continue;
            // An application that rejects its tile size must not block every other window. Float it, as reconcile does,
            // and derive goals again so later windows do not receive tiles sized around the rejected one.
            if (outcome == .rolled_back and window.visible() and !window.floating) {
                floatRejectedTile(window);
                if (window.floating and deriveGoals() and placeVisible(window) == .applied) continue;
            }
            self.rollback(order[0 .. position + 1]);
            journal.setError("Placement rejected; reverse rollback attempted; inspect window recovery errors");
            return false;
        }
        journal.setError(null);
        return true;
    }
    // Unknown stack positions are `maxInt(u32)`, so they come first.
    fn backToFront(_: void, first: usize, second: usize) bool {
        return world.windows()[first].observation.stack_order > world.windows()[second].observation.stack_order;
    }
};

fn floatRejectedTile(window: *Window) void {
    if (window.managedFullscreen()) {
        world.workspaceLayout(window.display, window.workspace).fullscreen = null;
        placementFailure(window, "Application rejected managed fullscreen; underlying layout retained");
        return;
    }
    if (window.floating) return;
    window.floating = true;
    window.placed = null;
    window.floating_frame = world.boundedFloating(window.parking_frame, world.displayArea(window.display));
    placementFailure(window, "Application rejected tile; retrying with floating recovery geometry");
}

pub fn deriveGoals() bool {
    for (&world.layouts().roots) |*slot| if (slot.*) |*state| {
        if (world.displayIndex(state.display) == null) {
            world.layouts().discard(state);
            slot.* = null;
        }
    };
    for (world.displays()) |display| for (0..world.config().workspace_count) |workspace| {
        _ = world.workspaceLayout(display.identity, workspace);
    };
    var members: [1024]tiling.Member = undefined;
    world.layouts().sync(world.layoutMembers(&members), focus.current(), world.config().gap) catch |err| {
        journal.setError(@errorName(err));
        return false;
    };
    for (&world.layouts().roots) |*slot| if (slot.*) |*state| {
        const display = world.displays()[world.displayIndex(state.display) orelse continue];
        world.layouts().arrange(state, display.area(), world.config().gap);
    };
    for (world.displays()) |display| {
        if (world.displayBlocked(display.identity)) continue;
        var indices: [1024]usize = undefined;
        var count: usize = 0;
        for (world.windows(), 0..) |window, index| if (window.display == display.identity and window.visible() and !window.floating) {
            indices[count] = index;
            count += 1;
        };
        if (count == 0) continue;
        const workspace = world.workspaceLayout(display.identity, display.workspace);
        const area = display.area();
        if (count == 1) {
            const lone = &world.windows()[indices[0]];
            lone.goal = area;
            if (world.config().single_window_max_width > 0) {
                lone.goal.width = @min(area.width, @max(world.config().single_window_max_width, lone.bounds.minimumAt(.width)));
                lone.goal.left += (area.width - lone.goal.width) / 2;
            }
            continue;
        }
        if (workspace.layout == .master) {
            const columns = tiling.split(area, .width, workspace.ratio, world.config().gap, masterSides(indices[0..count]));
            world.windows()[indices[0]].goal = columns[0];
            const rows: f64 = @floatFromInt(count - 1);
            const spacing = @min(world.config().gap, columns[1].height / (2 * rows));
            const height = (columns[1].height - spacing * (rows - 1)) / rows;
            var bound_height: [1024]?f64 = @splat(null);
            var share = height;
            var required = spacing * (rows - 1);
            for (indices[1..count]) |index| required += rowMinimum(world.windows()[index]);
            var extra: f64 = 0;
            if (required <= columns[1].height) {
                var remaining = columns[1].height - spacing * (rows - 1);
                var unbound = count - 1;
                var settled = false;
                while (!settled) {
                    settled = true;
                    for (indices[1..count], bound_height[1..count]) |index, *fixed| if (fixed.* == null) {
                        const minimum = rowMinimum(world.windows()[index]);
                        const ceiling_height: ?f64 = if (world.windows()[index].bounds.ceilingAt(.height)) |ceiling| if (ceiling.binds(share)) @max(minimum, ceiling.accepted) else null else null;
                        if (minimum > share) {
                            fixed.* = minimum;
                        } else if (ceiling_height) |capped| {
                            fixed.* = capped;
                        } else continue;
                        remaining -= fixed.*.?;
                        unbound -= 1;
                        settled = false;
                    };
                    if (!settled and unbound > 0) share = remaining / @as(f64, @floatFromInt(unbound));
                }
                if (unbound == 0 and remaining > 0) extra = remaining / rows;
            }
            var shift: f64 = 0;
            for (indices[1..count], bound_height[1..count], 0..) |index, fixed, row| {
                var frame = columns[1];
                frame.top += @as(f64, @floatFromInt(row)) * (share + spacing) + shift;
                frame.height = if (fixed) |resolved| resolved + extra else share;
                shift += frame.height - share;
                world.windows()[index].goal = frame;
            }
        } else for (indices[0..count]) |index| {
            if (world.layouts().goal(world.windows()[index].identity)) |frame| world.windows()[index].goal = frame;
        }
    }
    return true;
}

fn rowMinimum(window: Window) f64 {
    return @max(tiling.minimum_tile_extent, window.bounds.minimumAt(.height));
}

fn masterSides(indices: []const usize) [2]tiling.Side {
    var minimums: [2]f64 = @splat(tiling.minimum_tile_extent);
    for (indices, 0..) |index, ordinal| {
        const slot: usize = if (ordinal == 0) 0 else 1;
        minimums[slot] = @max(minimums[slot], world.windows()[index].bounds.minimumAt(.width));
    }
    var stack_ceiling = world.windows()[indices[1]].bounds.ceilingAt(.width);
    for (indices[2..]) |index| stack_ceiling = tiling.combineAcross(stack_ceiling, world.windows()[index].bounds.ceilingAt(.width));
    return .{
        .{ .minimum = minimums[0], .compact = minimums[0], .ceiling = world.windows()[indices[0]].bounds.ceilingAt(.width) },
        .{ .minimum = minimums[1], .compact = minimums[1], .ceiling = stack_ceiling },
    };
}

fn placementFailure(window: *Window, message: []const u8) void {
    const repeated = if (window.placement_error) |previous| std.mem.eql(u8, previous, message) else false;
    window.placement_error = message;
    journal.placementError(message);
    if (repeated) return;
    if (journal.enabled()) {
        var actual: Rect = undefined;
        const readable = native.platform_read_frame(window.identity, &actual);
        _ = journal.append("placement", .{ .window = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .message = message, .workspace = window.workspace + 1, .display = window.display, .goal = window.goal, .target = window.targetFrame(), .actual = if (readable) actual else null });
    }
    var buffer: [256:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(&buffer, "Window {d}: {s}", .{ window.identity, message }) catch return;
    native.platform_error(&buffer);
}

fn parkedFrameAccepted(actual: Rect, target: Rect, displayIdentity: u32) bool {
    const area = world.displays()[world.displayIndex(displayIdentity).?].frame;
    const bottom = area.top + area.height;
    const horizontalContact = world.overlap(actual, area, .horizontal);
    return @abs(actual.width - target.width) <= 2 and @abs(actual.height - target.height) <= 2 and
        @abs(actual.left - target.left) <= 2 and @abs(actual.left + actual.width - target.left - target.width) <= 2 and
        horizontalContact > 0 and horizontalContact <= 3 and
        actual.top >= area.top and actual.top <= bottom and actual.top + actual.height >= bottom and
        !world.overlapsOtherDisplays(actual, displayIdentity);
}

fn verifiedFrame(identity: u64, target: Rect, parkedDisplay: ?u32, actual: *Rect) bool {
    _ = native.platform_frame(identity, target, 0, .verified_placement);
    if (!native.platform_read_frame(identity, actual)) return false;
    return if (parkedDisplay) |displayIdentity| parkedFrameAccepted(actual.*, target, displayIdentity) else world.framesNear(actual.*, target, 2);
}

// A refusal carries the frame the application accepted instead.
const PlacementOutcome = union(enum) { applied, rolled_back: Rect, recovery_required: Rect, unreadable, no_corner };

fn attemptVisibility(window: *Window, target: Rect, parked: bool) PlacementOutcome {
    var original: Rect = undefined;
    if (!native.platform_read_frame(window.identity, &original)) return .unreadable;
    const previouslyParked = window.parked;
    if (!previouslyParked) window.parking_frame = original;
    // A failed AX write can still move the window. Own it before the first write.
    window.parked = true;
    if (parked and !previouslyParked) recovery.save(&.{});
    var accepted = target;
    if (verifiedFrame(window.identity, target, if (parked) window.display else null, &accepted)) {
        window.parked = parked;
        window.parked_at = if (parked) native.platform_monotonic() else null;
        if (parked) window.placed = null;
        window.placement_error = null;
        return .applied;
    }
    var restored = original;
    if (verifiedFrame(window.identity, original, null, &restored)) {
        window.parked = previouslyParked;
        return .{ .rolled_back = accepted };
    }
    window.parked_at = null;
    return .{ .recovery_required = accepted };
}

fn reportPlacementOutcome(window: *Window, outcome: PlacementOutcome) void {
    switch (outcome) {
        .applied => {},
        .rolled_back => placementFailure(window, "Placement rejected; prior geometry verified"),
        .recovery_required => placementFailure(window, "Placement and rollback rejected; recovery ownership retained"),
        .unreadable => placementFailure(window, "Placement geometry unreadable"),
        .no_corner => placementFailure(window, "No parking corner avoids other displays"),
    }
}

fn placeVisible(window: *Window) PlacementOutcome {
    const target = window.targetFrame();
    var outcome = attemptVisibility(window, target, false);
    const refusal: ?Rect = switch (outcome) {
        .rolled_back, .recovery_required => |accepted| accepted,
        else => null,
    };
    if (refusal) |accepted| if (!window.managedFullscreen()) {
        if (!window.floating) {
            if (outcome == .rolled_back and learnBounds(window, target, accepted)) outcome = attemptVisibility(window, window.targetFrame(), false);
        } else if (@abs(accepted.width - target.width) > 2 or @abs(accepted.height - target.height) > 2) {
            // A floating window takes the size its application answered with, or the same refusal would repeat on every attempt.
            // An application that raised its minimum also refuses the rollback to the old size, so both refusals are retried.
            window.floating_frame.width = accepted.width;
            window.floating_frame.height = accepted.height;
            outcome = attemptVisibility(window, window.targetFrame(), false);
        }
    };
    if (outcome == .applied and !window.floating and !window.managedFullscreen()) window.placed = .{ .frame = window.targetFrame(), .at = native.platform_monotonic() };
    reportPlacementOutcome(window, outcome);
    return outcome;
}

// A learned bound can come from a size someone else set during placement, such as a native edge drag, and a minimum never
// lowers itself. A resize it blocks clears it, and placement learns it again if the application still refuses.
pub fn forgetWorkspaceBounds(display: u32, workspace: usize) bool {
    var forgot = false;
    for (world.windows()) |*window| {
        if (window.display != display or window.workspace != workspace or window.floating) continue;
        if (std.meta.eql(window.bounds, size_bounds.Bounds{})) continue;
        window.bounds = .{};
        window.placed = null;
        forgot = true;
    }
    return forgot;
}

fn learnBounds(window: *Window, requested: Rect, accepted: Rect) bool {
    if (!window.established and native.platform_monotonic() - window.discovered < launch_grace) return false;
    const area = world.displays()[world.displayIndex(window.display) orelse return false].area();
    const previous = window.bounds;
    const next = previous.learn(.{ requested.width, requested.height }, .{ accepted.width, accepted.height }, .{ area.width, area.height });
    if (std.meta.eql(next, previous)) return false;
    window.bounds = next;
    if (deriveGoals() and for (world.windows()) |other| {
        if (other.display != window.display or !other.visible() or other.floating or other.managedFullscreen()) continue;
        if (other.goal.width < other.bounds.minimumAt(.width) - 2 or other.goal.height < other.bounds.minimumAt(.height) - 2) break false;
    } else true) return true;
    window.bounds = previous;
    _ = deriveGoals();
    return false;
}

fn parkWindow(window: *Window) PlacementOutcome {
    if (window.escape == .exempt) return .applied;
    const outcome: PlacementOutcome = outcome: {
        var actual: Rect = undefined;
        if (!native.platform_read_frame(window.identity, &actual)) break :outcome .unreadable;
        const area = world.displays()[world.displayIndex(window.display) orelse break :outcome .no_corner].frame;
        // A parked window keeps the size its application gave it, so a corner is never written with a size the application refuses.
        if (window.parked) {
            window.parking_frame.width = actual.width;
            window.parking_frame.height = actual.height;
        }
        const candidates = parking.corners(actual, area);
        if (window.parked) for (candidates) |candidate| if (parkedFrameAccepted(actual, candidate, window.display)) {
            window.placement_error = null;
            return .applied;
        };
        // A frame that only touches the display is a parked strip that a Dock resize exposed.
        const horizontal = world.overlap(actual, area, .horizontal);
        const vertical = world.overlap(actual, area, .vertical);
        if (window.parked and window.parked_at != null and horizontal > 3 and vertical > 3) {
            const now = native.platform_monotonic();
            if (now - topology_changed_at > 2) {
                window.escape = switch (window.escape) {
                    .escaped => |at| if (now - at <= 300) .exempt else .{ .escaped = now },
                    else => .{ .escaped = now },
                };
                // Only a park verified after this one can escape again, so one refusal is not counted twice.
                window.parked_at = null;
                if (window.escape == .exempt) {
                    window.parked = false;
                    placementFailure(window, "Application keeps moving its window back on screen; window is no longer parked");
                    return .applied;
                }
            }
        }
        var attempted: PlacementOutcome = .no_corner;
        for (candidates) |candidate| {
            if (world.overlapsOtherDisplays(candidate, window.display)) continue;
            attempted = attemptVisibility(window, candidate, true);
            if (attempted != .rolled_back) break;
        }
        break :outcome attempted;
    };
    reportPlacementOutcome(window, outcome);
    return outcome;
}

pub fn reconcile() void {
    if (world.isSuspended() or scene.pending() or world.displays().len == 0 or routing.blocked()) return;
    if (!deriveGoals()) return;
    var passes: usize = 0;
    while (true) : (passes += 1) {
        const relayout = place: {
            for (world.windows()) |*window| {
                if (window.visible() and !window.floating and !window.managedFullscreen() and (window.goal.width < tiling.minimum_tile_extent or window.goal.height < tiling.minimum_tile_extent)) {
                    window.floating = true;
                    window.placed = null;
                    window.floating_frame = if (window.parked) window.parking_frame else window.observation.frame;
                    window.goal = window.floating_frame;
                    placementFailure(window, "Tile too crowded; window left floating");
                }
            }
            const now = native.platform_monotonic();
            for (world.windows()) |*window| {
                if (!window.eligible() or world.displayBlocked(window.display)) continue;
                if (!window.visible()) {
                    _ = parkWindow(window);
                    continue;
                }
                const target = window.targetFrame();
                if (window.parked) {
                    const outcome = placeVisible(window);
                    if (outcome == .rolled_back or outcome == .recovery_required) floatRejectedTile(window);
                    continue;
                }
                settle: {
                    if (window.floating or window.managedFullscreen()) break :settle;
                    const placed = if (window.placed) |*active| active else break :settle;
                    if (!world.framesNear(target, placed.frame, size_bounds.tolerance) or now - placed.at > snap_back_window) {
                        window.placed = null;
                        break :settle;
                    }
                    if (now < placed.at or window.observation.motion != .idle) break :settle;
                    const observed = window.observation.frame;
                    if (world.sizesNear(observed, placed.frame, size_bounds.tolerance)) {
                        placed.snap_candidate = null;
                        break :settle;
                    }
                    if (placed.snap_candidate) |previous| if (world.sizesNear(observed, previous, size_bounds.tolerance)) {
                        const requested = placed.frame;
                        window.placed = null;
                        if (learnBounds(window, requested, observed)) break :place true;
                        break :settle;
                    };
                    placed.snap_candidate = observed;
                    native.platform_config_changed();
                    continue;
                }
                const duration = if (window.floating_restore and !window.managedFullscreen()) 0 else world.config().duration;
                const needs_write = !world.framesNear(window.observation.frame, target, size_bounds.tolerance);
                var accepted: Rect = window.observation.frame;
                if (native.platform_frame(window.identity, target, duration, .visible_goal) and (duration != 0 or (native.platform_read_frame(window.identity, &accepted) and world.framesNear(accepted, target, 2)))) {
                    if (!window.floating and !window.managedFullscreen() and needs_write) window.placed = .{ .frame = target, .at = now + duration };
                    continue;
                }
                if (window.managedFullscreen()) {
                    floatRejectedTile(window);
                    continue;
                }
                if (!native.platform_read_frame(window.identity, &accepted)) accepted = window.observation.frame;
                if (!window.floating and learnBounds(window, target, accepted)) break :place true;
                if (now - window.discovered < launch_grace) continue;
                const tiled = !window.floating;
                window.floating = true;
                window.placed = null;
                window.floating_restore = false;
                window.floating_frame = accepted;
                placementFailure(window, "Application rejected layout geometry; window left floating");
                if (tiled) break :place true;
            }
            break :place false;
        };
        if (!relayout or passes == world.windows().len) break;
        if (!deriveGoals()) return;
    }
    var borderIdentity: u64 = 0;
    var borderWidth = world.config().border_width;
    var borderColor = world.config().border_color;
    if (focus.current()) |identity| if (world.windowIndex(identity)) |index| {
        const window = world.windows()[index];
        // Border actions resolve against the current title, so a reload or a title change applies without rediscovery.
        const decision = world.ruleDecision(&window.observation);
        borderWidth = decision.border_width orelse borderWidth;
        borderColor = decision.border_color orelse borderColor;
        if (window.visible() and !window.parked and (decision.border orelse (world.config().border_single_window or for (world.windows()) |other| {
            if (other.identity != window.identity and other.display == window.display and other.workspace == window.workspace and other.visible()) break true;
        } else false))) borderIdentity = identity;
    };
    native.platform_border(borderIdentity, borderWidth, borderColor);
    recovery.save(&.{});
}

pub fn noteTopologyChange() void {
    topology_changed_at = native.platform_monotonic();
}
