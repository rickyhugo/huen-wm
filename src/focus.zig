const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const tiling = @import("layout.zig");
const history = @import("history.zig");
const selector = @import("selector.zig");
const monitor = @import("monitor.zig");
const reply = @import("reply.zig");
const journal = @import("journal.zig");
const desktop = @import("desktop.zig");
const placer = @import("placer.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const discovery = @import("discovery.zig");
const Rect = desktop.Rect;
const Window = desktop.Window;
const Direction = commands.Direction;

var focused: ?u64 = null;
var focus_history: history.Ring = .{};
var last_observed_focus: ?u64 = null;
var last_pointer: ?native.WMPoint = null;

// Activating another application completes after `verify` returns, so a moving pointer asks for the same window once per
// half second instead of on every tick until a scan sees the new focus.
const hover_retry = 0.5;
var hover_request: ?u64 = null;
var hover_requested: f64 = -std.math.inf(f64);

// When the window that had focus last went away, so focus that macOS then hands to another window is not taken for a request.
var focus_lost: f64 = -std.math.inf(f64);

// A workspace switch within about 250 ms of an activation makes the applications involved wait on WindowServer for 300
// to 500 ms. Every AX call to them times out meanwhile, so their windows go stale and block placement.
const activation_settle = 0.3;
var activated: f64 = -std.math.inf(f64);

fn warpInto(bounds: Rect) void {
    if (bounds.width <= 0 or bounds.height <= 0) return;
    var point: native.WMPoint = undefined;
    if (!native.platform_pointer(&point)) return;
    if (point.left >= bounds.left and point.left < bounds.left + bounds.width and point.top >= bounds.top and point.top < bounds.top + bounds.height) return;
    const destination: native.WMPoint = .{ .left = bounds.left + bounds.width / 2, .top = bounds.top + bounds.height / 2 };
    if (native.platform_warp_pointer(destination)) last_pointer = destination else native.platform_error("Mouse warp failed");
}

fn warpTo(identity: u64) void {
    if (!desktop.config().focus_follows_mouse) return;
    const index = desktop.windowIndex(identity) orelse return;
    warpInto(desktop.windows()[index].observation.frame);
}

pub fn select(identity: u32) void {
    if (desktop.selected() == identity) return;
    desktop.setSelected(identity);
    routing.trackCurrentDisplay();
    if (!desktop.config().mouse_follows_monitor) return;
    const index = desktop.displayIndex(identity) orelse return;
    warpInto(desktop.displays()[index].full_bounds);
}

pub fn followPointer() void {
    var point: native.WMPoint = undefined;
    if (!native.platform_pointer(&point)) return;
    const previous = last_pointer;
    last_pointer = point;
    if (previous == null) return;
    if (previous.?.left == point.left and previous.?.top == point.top) return;
    if (!desktop.config().focus_follows_mouse or desktop.isSuspended() or scene.pending() or routing.blocked() or native.platform_pointer_buttons()) return;
    const window_id = native.platform_window_at(point);
    if (window_id == 0) return;
    for (desktop.windows()) |window| {
        if (window.observation.public_window_id != window_id) continue;
        if (!window.visible() or window.parked or !window.eligible() or focused == window.identity) return;
        const now = native.platform_monotonic();
        if (hover_request == window.identity and now - hover_requested < hover_retry) return;
        hover_request = window.identity;
        hover_requested = now;
        _ = verify(window.identity);
        return;
    }
}

fn rememberFocus(identity: u64) void {
    const index = desktop.windowIndex(identity) orelse return;
    const window = desktop.windows()[index];
    focus_history.push(identity);
    var members: [1024]tiling.Member = undefined;
    desktop.layouts().rememberFocus(desktop.workspaceLayout(window.display, window.workspace), identity, desktop.layoutMembers(&members)) catch |err| {
        journal.setError(@errorName(err));
    };
}

pub fn verify(identity: u64) bool {
    activated = native.platform_monotonic();
    if (!native.platform_focus(identity) or native.platform_focused_window() != identity) return false;
    focused = identity;
    last_observed_focus = identity;
    rememberFocus(identity);
    if (desktop.windowIndex(identity)) |index| {
        desktop.windows()[index].urgent = false;
        select(desktop.windows()[index].display);
    }
    return true;
}

// Records a native focus change. A command leaves an activation request to the next tick, and so does a tick during a
// workspace transition. A tick reads focus from the last scan, and a scan of one application leaves the focus of the
// others as it was, so a tick confirms a request against live focus.
pub fn observe(observed: ?u64, settle: bool) void {
    focused = observed;
    if (observed) |identity| if (desktop.windowIndex(identity)) |slot| if (desktop.windows()[slot].visible()) {
        desktop.windows()[slot].urgent = false;
    };
    if (observed == last_observed_focus) return;
    const previous = last_observed_focus;
    // A request is focus that an application took for a window on a hidden workspace, as when a link opens in a browser there.
    // A new window that a rule placed there is not a request. Neither is focus that macOS moves there because the focused
    // window went away, nor focus that comes back to the window that had it last, such as one that a command sent there.
    const requested = if (observed) |identity| requested: {
        if (desktop.isSuspended() or (focus_history.count > 0 and focus_history.entries[0] == identity)) break :requested false;
        const window = desktop.windows()[desktop.windowIndex(identity) orelse break :requested false];
        const slot = desktop.displayIndex(window.display) orelse break :requested false;
        if (!window.eligible() or window.workspace == desktop.displays()[slot].workspace) break :requested false;
        const now = native.platform_monotonic();
        if (now - window.discovered < 1.0) break :requested false;
        const asked = if (previous) |holder| focusable(holder) else now - focus_lost > 1.0;
        break :requested asked and (!settle or native.platform_focused_window() == identity);
    } else false;
    if (requested and (!settle or scene.pending())) return;
    if (previous) |holder| if (!focusable(holder)) {
        focus_lost = native.platform_monotonic();
    };
    last_observed_focus = observed;
    const identity = observed orelse return;
    // Like Hyprland's `focus_on_activate`: follows the request to the window's workspace, or marks the window urgent and
    // asks for focus to return to the window that had it. routing.Activation of another application completes later, so the
    // next observation records the returned focus.
    if (requested) {
        const taker = &desktop.windows()[desktop.windowIndex(identity).?];
        taker.urgent = true;
        const decision = desktop.ruleDecision(&taker.observation);
        if (decision.focus_on_activate orelse desktop.config().focus_on_activate) {
            _ = scene.jump(identity, desktop.activeDisplay());
        } else if (previous) |holder_identity| if (desktop.windowIndex(holder_identity)) |holder_index| {
            const holder = desktop.windows()[holder_index];
            if (holder.visible() and !holder.parked and native.platform_focus(holder.identity)) {
                focused = previous;
                return;
            }
        };
    }
    const window = desktop.windows()[desktop.windowIndex(identity) orelse return];
    rememberFocus(identity);
    if (desktop.displayIndex(window.display) != null) select(window.display);
}

pub fn readingOrder(display: u32, kind: ?commands.WindowKind, output: []u64) []u64 {
    const Entry = struct {
        floating: bool,
        frame: Rect,
        identity: u64,
        fn lessThan(_: void, first: @This(), second: @This()) bool {
            if (first.floating != second.floating) return !first.floating;
            if (first.frame.top != second.frame.top) return first.frame.top < second.frame.top;
            if (first.frame.left != second.frame.left) return first.frame.left < second.frame.left;
            return first.identity < second.identity;
        }
    };
    var entries: [1024]Entry = undefined;
    var count: usize = 0;
    for (desktop.windows()) |window| {
        if (window.display != display or !window.visible() or window.parked) continue;
        if (kind) |wanted| if ((wanted == .floating) != window.floating) continue;
        entries[count] = .{ .floating = window.floating, .frame = window.targetFrame(), .identity = window.identity };
        count += 1;
    }
    std.mem.sort(Entry, entries[0..count], {}, Entry.lessThan);
    for (entries[0..count], 0..) |entry, index| output[index] = entry.identity;
    return output[0..count];
}

// How far the candidate's center lies ahead of the source's in `direction`, and how far it lies off that line.
fn offsets(source: *const Window, candidate: *const Window, direction: Direction) [2]f64 {
    const from = if (source.floating) source.floating_frame else source.goal;
    const to = if (candidate.floating) candidate.floating_frame else candidate.goal;
    const horizontal = to.left + to.width / 2 - from.left - from.width / 2;
    const vertical = to.top + to.height / 2 - from.top - from.height / 2;
    return switch (direction) {
        .left => .{ -horizontal, @abs(vertical) },
        .right => .{ horizontal, @abs(vertical) },
        .up => .{ -vertical, @abs(horizontal) },
        .down => .{ vertical, @abs(horizontal) },
    };
}

pub fn neighbor(sourceIndex: usize, direction: Direction) ?usize {
    var best: f64 = std.math.inf(f64);
    var result: ?usize = null;
    for (desktop.windows(), 0..) |candidate, index| {
        if (index == sourceIndex or !candidate.visible() or candidate.parked) continue;
        const forward, const cross = offsets(&desktop.windows()[sourceIndex], &candidate, direction);
        if (forward <= 1) continue;
        const score = forward + cross * 2;
        if (score < best) {
            best = score;
            result = index;
        }
    }
    return result;
}

pub fn focusable(identity: u64) bool {
    const window = desktop.windows()[desktop.windowIndex(identity) orelse return false];
    return window.eligible() and desktop.displayIndex(window.display) != null;
}

fn focusWorkspaceTarget(displayIdentity: u32, focus_target: ?u64) ?u64 {
    discovery.refresh();
    if (!placer.deriveGoals()) return null;
    const index = desktop.displayIndex(displayIdentity) orelse return null;
    const state = desktop.workspaceLayout(displayIdentity, desktop.displays()[index].workspace);
    var members: [1024]tiling.Member = undefined;
    var verified: ?u64 = null;
    if (focus_target orelse desktop.layouts().focusCandidate(state, desktop.layoutMembers(&members))) |identity| {
        const window = desktop.windows()[desktop.windowIndex(identity) orelse return null];
        if (!window.visible() or window.parked) {
            const transaction = placer.Transaction.begin(.{ .display = displayIdentity }) catch |err| {
                journal.setError(@errorName(err));
                return null;
            };
            defer transaction.deinit();
            desktop.layouts().reveal(state, identity) catch |err| {
                journal.setError(transaction.abort(err));
                return null;
            };
            if (!transaction.commit()) return null;
        }
        if (!verify(identity)) return null;
        verified = identity;
    }
    select(displayIdentity);
    return verified;
}

pub fn focusWorkspace(displayIdentity: u32, focus_target: ?u64) void {
    _ = focusWorkspaceTarget(displayIdentity, focus_target);
}

pub fn observeCommandState() void {
    discovery.refresh();
    const observed_focus = native.platform_focused_window();
    observe(if (observed_focus != 0) observed_focus else null, false);
    routing.trackCurrentDisplay();
}

pub fn toMonitor(selection: commands.MonitorSelector, slot: usize) reply.Reply {
    const display = &desktop.displays()[slot];
    var screens: [monitor.capacity]monitor.Screen = undefined;
    const target = monitor.resolve(selection, desktop.monitorScreens(&screens), display.identity) catch |err| return reply.failure(@errorName(err));
    const changed = desktop.selected() != target;
    if (focusWorkspaceTarget(target, null)) |identity| warpTo(identity);
    return reply.json(.{ .ok = true, .accepted = true, .changed = changed, .monitor = target, .verified = desktop.selected() == target, .focused = focused });
}

pub fn cycle(request: commands.Cycle, slot: usize) reply.Reply {
    const display = &desktop.displays()[slot];
    var identities: [1024]u64 = undefined;
    const target = selector.cycleTarget(readingOrder(display.identity, request.kind, &identities), focused, request.step) orelse return reply.failure("NoWindowToCycle");
    const verified = verify(target);
    if (verified) warpTo(target);
    return reply.json(.{ .ok = true, .accepted = true, .verified = verified, .target = target });
}

pub fn jumpBack(prefer_urgent: bool, slot: usize) reply.Reply {
    const urgent: ?u64 = if (prefer_urgent) for (desktop.windows()) |window| {
        if (window.urgent and focusable(window.identity)) break window.identity;
    } else null else null;
    const target = urgent orelse focus_history.pick(focused, focusable) orelse return reply.failure("NoPreviousWindow");
    const response = scene.jump(target, slot);
    if (focused == target) warpTo(target);
    return response;
}

pub fn toward(source_index: usize, request: commands.Focus) reply.Reply {
    const source = &desktop.windows()[source_index];
    const target = if (request.wrap) wrapped: {
        var forward_target: ?usize = null;
        var forward_score = std.math.inf(f64);
        var wrap_target = source_index;
        var wrap_distance: f64 = 0;
        var wrap_cross = std.math.inf(f64);
        for (desktop.windows(), 0..) |candidate, index| {
            if (index == source_index or !candidate.visible() or candidate.parked or candidate.display != source.display or candidate.workspace != source.workspace) continue;
            const forward, const cross = offsets(source, &candidate, request.direction);
            const score = forward + cross * 2;
            if (forward > 1 and (score < forward_score or (score == forward_score and (forward_target == null or candidate.identity < desktop.windows()[forward_target.?].identity)))) {
                forward_target = index;
                forward_score = score;
            }
            if (forward < wrap_distance or (forward == wrap_distance and (cross < wrap_cross or (cross == wrap_cross and candidate.identity < desktop.windows()[wrap_target].identity)))) {
                wrap_target = index;
                wrap_distance = forward;
                wrap_cross = cross;
            }
        }
        break :wrapped forward_target orelse wrap_target;
    } else neighbor(source_index, request.direction) orelse return reply.failure("NoWindowInDirection");
    const identity = desktop.windows()[target].identity;
    const verified = verify(identity);
    if (verified) warpTo(identity);
    return reply.json(.{ .ok = true, .accepted = true, .verified = verified, .target = identity });
}

pub fn current() ?u64 {
    return focused;
}

pub fn settled(now: f64) bool {
    return now - activated >= activation_settle;
}

pub fn dropMissing() void {
    if (focused) |identity| if (desktop.windowIndex(identity) == null) {
        focused = null;
    };
}

pub fn dropIfHidden() void {
    if (focused) |identity| if (desktop.windowIndex(identity)) |index| if (!desktop.windows()[index].visible()) {
        focused = null;
    };
}

pub fn rename(ghost: u64, successor: u64) void {
    focus_history.rename(ghost, successor);
    if (last_observed_focus == ghost) last_observed_focus = successor;
}

pub fn forget(identity: u64) void {
    focus_history.forget(identity);
}
