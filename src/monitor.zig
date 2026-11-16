const std = @import("std");
const commands = @import("command.zig");
const Rect = @import("native.zig").WMRect;

pub const capacity = 32;
pub const Screen = struct { identity: u32, full_bounds: Rect, built_in: bool, name: []const u8 };

pub fn resolve(selection: commands.MonitorSelector, screens: []const Screen, current: ?u32) !u32 {
    if (screens.len == 0) return error.NoDisplays;
    if (screens.len > capacity) return error.TooManyDisplays;
    return switch (selection) {
        .direction => |direction| directional(screens, current orelse return error.NoSelectedMonitor, direction) orelse error.NoMonitorInDirection,
        .step => |step| stepped(screens, current, step),
        .class => lowestMatching(screens, selection) orelse error.NoMatchingMonitor,
        .name => lowestMatching(screens, selection) orelse error.UnknownMonitorName,
    };
}

pub const Wanted = struct { home: ?u32, monitors: []const commands.MonitorSelector, fallback: []const commands.MonitorSelector, current: ?u32 };

pub fn place(screens: []const Screen, wanted: Wanted) ?u32 {
    if (screens.len == 0) return null;
    if (wanted.home) |identity| if (find(screens, identity) != null) return identity;
    if (preferred(screens, wanted.monitors, wanted.current)) |identity| return identity;
    if (preferred(screens, wanted.fallback, wanted.current)) |identity| return identity;
    if (wanted.current) |identity| if (find(screens, identity) != null) return identity;
    var lowest = screens[0].identity;
    for (screens) |screen| lowest = @min(lowest, screen.identity);
    return lowest;
}

fn preferred(screens: []const Screen, selectors: []const commands.MonitorSelector, current: ?u32) ?u32 {
    for (selectors) |selection| {
        if (current) |identity| if (find(screens, identity)) |screen| if (matches(screen, selection)) return identity;
        if (lowestMatching(screens, selection)) |identity| return identity;
    }
    return null;
}

fn matches(screen: Screen, selection: commands.MonitorSelector) bool {
    return switch (selection) {
        .class => |class| screen.built_in == (class == .@"built-in"),
        .name => |name| std.mem.eql(u8, screen.name, name.text()),
        .direction, .step => false,
    };
}

fn centerLeft(screen: Screen) f64 {
    return screen.full_bounds.left + screen.full_bounds.width / 2;
}

fn centerTop(screen: Screen) f64 {
    return screen.full_bounds.top + screen.full_bounds.height / 2;
}

fn find(screens: []const Screen, identity: u32) ?Screen {
    for (screens) |screen| if (screen.identity == identity) return screen;
    return null;
}

fn directional(screens: []const Screen, current: u32, direction: commands.Direction) ?u32 {
    const source = find(screens, current) orelse return null;
    var best: ?Screen = null;
    var best_primary: f64 = 0;
    var best_perpendicular: f64 = 0;
    for (screens) |screen| {
        if (screen.identity == current) continue;
        const horizontal = centerLeft(screen) - centerLeft(source);
        const vertical = centerTop(screen) - centerTop(source);
        const primary = switch (direction) {
            .left => -horizontal,
            .right => horizontal,
            .up => -vertical,
            .down => vertical,
        };
        if (primary <= 0) continue;
        const perpendicular = @abs(if (direction == .left or direction == .right) vertical else horizontal);
        if (best) |chosen| {
            if (primary > best_primary) continue;
            if (primary == best_primary and perpendicular > best_perpendicular) continue;
            if (primary == best_primary and perpendicular == best_perpendicular and screen.identity > chosen.identity) continue;
        }
        best = screen;
        best_primary = primary;
        best_perpendicular = perpendicular;
    }
    return if (best) |chosen| chosen.identity else null;
}

fn readingLess(_: void, first: Screen, second: Screen) bool {
    if (centerLeft(first) != centerLeft(second)) return centerLeft(first) < centerLeft(second);
    if (centerTop(first) != centerTop(second)) return centerTop(first) < centerTop(second);
    return first.identity < second.identity;
}

fn stepped(screens: []const Screen, current: ?u32, step: commands.Step) u32 {
    var order: [capacity]Screen = undefined;
    @memcpy(order[0..screens.len], screens);
    const sorted = order[0..screens.len];
    std.mem.sort(Screen, sorted, {}, readingLess);
    var position: ?usize = null;
    if (current) |identity| for (sorted, 0..) |screen, index| if (screen.identity == identity) {
        position = index;
    };
    const found = position orelse return if (step == .next) sorted[0].identity else sorted[sorted.len - 1].identity;
    return switch (step) {
        .next => sorted[(found + 1) % sorted.len].identity,
        .previous => sorted[(found + sorted.len - 1) % sorted.len].identity,
    };
}

fn lowestMatching(screens: []const Screen, selection: commands.MonitorSelector) ?u32 {
    var best: ?u32 = null;
    for (screens) |screen| {
        if (!matches(screen, selection)) continue;
        if (best == null or screen.identity < best.?) best = screen.identity;
    }
    return best;
}
