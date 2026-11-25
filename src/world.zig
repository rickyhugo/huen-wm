const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const rules = @import("rules.zig");
const tiling = @import("layout.zig");
const monitor = @import("monitor.zig");
const text = native.text;

pub const Rect = native.WMRect;
pub const Config = configuration.ConfigCandidate;
// Whether an application moves its window back on screen after it is parked. `escaped` holds when it last did.
pub const Escape = union(enum) { settled, escaped: f64, exempt };
pub const PendingTileWrite = struct { frame: Rect, at: f64, snap_candidate: ?Rect = null };
pub const Window = struct {
    identity: u64,
    observation: native.WMWindow,
    workspace: usize,
    display: u32,
    discovered: f64 = 0,
    floating: bool = false,
    floating_restore: bool = false,
    parked: bool = false,
    urgent: bool = false,
    parking_frame: Rect,
    floating_frame: Rect,
    last_floating_frame: ?Rect = null,
    goal: Rect,
    placement_error: ?[]const u8 = null,
    escape: Escape = .settled,
    parked_at: ?f64 = null,
    bounds: tiling.Bounds = .{},
    placed: ?PendingTileWrite = null,
    discovered_frame: Rect,
    vanished: ?f64 = null,
    vanished_parked: bool = false,
    established: bool = false,

    pub fn eligible(window: Window) bool {
        return !window.observation.minimized and !window.observation.fullscreen and !window.observation.stale and (window.observation.onscreen or window.parked);
    }

    pub fn visible(window: Window) bool {
        if (!window.eligible()) return false;
        if (!window.floating and store.visibility(window.identity) == .hidden_by_group) return false;
        const index = displayIndex(window.display) orelse return false;
        return window.workspace == display_list.items[index].workspace;
    }

    pub fn managedFullscreen(window: Window) bool {
        const state = store.lookup(window.display, window.workspace) orelse return false;
        return state.fullscreen == window.identity;
    }

    pub fn targetFrame(window: Window) Rect {
        if (window.managedFullscreen()) if (displayIndex(window.display)) |index| return display_list.items[index].frame;
        return if (window.floating) window.floating_frame else window.bounds.fit(window.goal);
    }
};
pub const Display = struct {
    identity: u32,
    frame: Rect,
    full_bounds: Rect,
    name: [128]u8,
    built_in: bool,
    workspace: usize = 0,
    previous_workspace: ?usize = null,

    // Where tiles and floating windows go: the frame inset by the configured gap.
    pub fn area(display: Display) Rect {
        return inset(display.frame, loaded_config.gap);
    }
};

var loaded_config: Config = .{};
var store: tiling.Store = .{};
var window_buffer: [1024]Window = undefined;
var window_list: std.ArrayList(Window) = .initBuffer(&window_buffer);
var display_buffer: [monitor.capacity]Display = undefined;
var display_list: std.ArrayList(Display) = .initBuffer(&display_buffer);
var selected_display: ?u32 = null;
var initialized = false;
var suspended = false;

pub fn config() *const Config {
    return &loaded_config;
}

pub fn setConfig(candidate: *const Config) void {
    loaded_config = candidate.*;
}

pub fn layouts() *tiling.Store {
    return &store;
}

// Callers may edit windows in place. Only discovery adds, removes or replaces them.
pub fn windows() []Window {
    return window_list.items;
}

pub fn addWindow(window: Window) void {
    window_list.appendAssumeCapacity(window);
}

// The successor takes the ghost's slot because the master layout orders its stack by slot.
pub fn replaceWithSuccessor(index: usize, successor_slot: usize, successor: Window) void {
    window_list.items[index] = successor;
    _ = window_list.orderedRemove(successor_slot);
}

pub fn removeWindow(index: usize) void {
    _ = window_list.orderedRemove(index);
}

pub fn displays() []Display {
    return display_list.items;
}

pub fn replaceDisplays(updated: []const Display) void {
    display_list.clearRetainingCapacity();
    display_list.appendSliceAssumeCapacity(updated);
}

pub fn selected() ?u32 {
    return selected_display;
}

pub fn setSelected(identity: ?u32) void {
    selected_display = identity;
}

pub fn ensureSelection() void {
    if (selected_display == null or displayIndex(selected_display.?) == null) selected_display = display_list.items[0].identity;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn markInitialized() void {
    initialized = true;
}

pub fn isSuspended() bool {
    return suspended;
}

pub fn markSuspended() void {
    suspended = true;
}

pub fn workspaceLayout(display: u32, workspace: usize) *tiling.WorkspaceLayout {
    const defaults = loaded_config.workspaces[workspace];
    return store.ensureWorkspace(display, workspace, defaults.layout, defaults.ratio);
}

pub fn displayIndex(identity: u32) ?usize {
    for (display_list.items, 0..) |display, index| if (display.identity == identity) return index;
    return null;
}

pub fn windowIndex(identity: u64) ?usize {
    for (window_list.items, 0..) |window, index| if (window.identity == identity) return index;
    return null;
}

pub fn activeDisplay() usize {
    if (selected_display) |identity| if (displayIndex(identity)) |index| return index;
    return 0;
}

pub fn monitorScreens(output: []monitor.Screen) []monitor.Screen {
    for (display_list.items, output[0..display_list.items.len]) |*display, *screen| screen.* = .{ .identity = display.identity, .full_bounds = display.full_bounds, .built_in = display.built_in, .name = text(&display.name) };
    return output[0..display_list.items.len];
}

pub fn layoutMembers(output: []tiling.Member) []tiling.Member {
    var count: usize = 0;
    for (window_list.items) |window| {
        const display = display_list.items[displayIndex(window.display) orelse continue];
        output[count] = .{ .identity = window.identity, .display = window.display, .workspace = window.workspace, .tiled = !window.floating, .active = window.eligible(), .area = display.area(), .bounds = window.bounds, .vanished = window.vanished != null };
        count += 1;
    }
    return output[0..count];
}

pub fn ruleDecision(observation: *const native.WMWindow) rules.Decision {
    return rules.resolve(loaded_config.rules[0..loaded_config.rule_count], .{ .bundle = text(&observation.bundle), .title = text(&observation.title), .title_complete = observation.title_complete });
}

pub fn displayBlocked(identity: u32) bool {
    for (window_list.items) |window| if (window.display == identity and window.observation.fullscreen) return true;
    return false;
}

pub fn displayArea(identity: u32) Rect {
    return display_list.items[displayIndex(identity).?].area();
}

pub fn overlapsOtherDisplays(frame: Rect, displayIdentity: u32) bool {
    for (display_list.items) |display| {
        if (display.identity == displayIdentity) continue;
        const area = display.full_bounds;
        if (@min(frame.left + frame.width, area.left + area.width) > @max(frame.left, area.left) and
            @min(frame.top + frame.height, area.top + area.height) > @max(frame.top, area.top)) return true;
    }
    return false;
}

fn inset(frame: Rect, gap: f64) Rect {
    const padding = @min(gap, @max(0, (@min(frame.width, frame.height) - 1) / 2));
    return .{ .left = frame.left + padding, .top = frame.top + padding, .width = frame.width - 2 * padding, .height = frame.height - 2 * padding };
}

pub fn boundedFloating(frame: Rect, area: Rect) Rect {
    var bounded = frame;
    bounded.width = @min(frame.width, area.width);
    bounded.height = @min(frame.height, area.height);
    // The sum is taken last, so rounding cannot put the upper bound below the lower one.
    bounded.left = std.math.clamp(frame.left, area.left, area.left + (area.width - bounded.width));
    bounded.top = std.math.clamp(frame.top, area.top, area.top + (area.height - bounded.height));
    return bounded;
}

pub fn framesNear(first: Rect, second: Rect, tolerance: f64) bool {
    return @abs(first.left - second.left) <= tolerance and @abs(first.top - second.top) <= tolerance and @abs(first.width - second.width) <= tolerance and @abs(first.height - second.height) <= tolerance;
}

pub fn sizesNear(first: Rect, second: Rect, tolerance: f64) bool {
    return @abs(first.width - second.width) <= tolerance and @abs(first.height - second.height) <= tolerance;
}

// How far two frames overlap along one axis. Frames that are apart give a negative overlap.
pub fn overlap(first: Rect, second: Rect, comptime axis: enum { horizontal, vertical }) f64 {
    return switch (axis) {
        .horizontal => @min(first.left + first.width, second.left + second.width) - @max(first.left, second.left),
        .vertical => @min(first.top + first.height, second.top + second.height) - @max(first.top, second.top),
    };
}
