const std = @import("std");
const native = @import("native.zig");
const session = @import("session.zig");
const continuity = @import("continuity.zig");
const world = @import("world.zig");
const routing = @import("routing.zig");
const allocator = std.heap.c_allocator;
const text = native.text;

var session_config_hash: [64]u8 = @splat(0);
var session_boot: [128]u8 = @splat(0);
var session_loaded = false;
var session_focus_pending = false;
var session_frozen: ?continuity.Frozen = null;
var session_freeze_attempted = false;
var session_save_attempted = false;
pub const Status = struct {
    load: enum { disabled, pending, none, restored, rejected, failed } = .disabled,
    save: enum { idle, frozen, saved, skipped, failed } = .idle,
    matched: usize = 0,
    unmatched: usize = 0,
    ambiguous: usize = 0,
    unavailable: usize = 0,
    errors: usize = 0,
    err_message: ?[]const u8 = null,
};

var session_status: Status = .{};

fn sessionError(message: []const u8) void {
    session_status.err_message = message;
    session_status.errors += 1;
}

pub fn configure() void {
    if (!world.config().session.enabled) return;
    const encoded = std.json.Stringify.valueAlloc(allocator, world.config().*, .{}) catch |err| {
        sessionError(@errorName(err));
        return;
    };
    defer allocator.free(encoded);
    session_config_hash = session.hexDigest(&.{encoded})[0..64].*;
    if (!session.huen_session_boot_identity(&session_boot, session_boot.len)) sessionError("BootIdentityUnavailable");
    if (!session_loaded) session_status.load = .pending;
}

fn sessionScope() session.Scope {
    return .{ .config = &session_config_hash, .filter = std.mem.span(native.platform_filter()), .boot = text(&session_boot) };
}

fn sessionWindows() ![]continuity.LiveWindow {
    var result: std.ArrayList(continuity.LiveWindow) = .empty;
    errdefer result.deinit(allocator);
    session_status.unavailable = 0;
    for (world.windows()) |window| {
        var attributes: session.NativeAttributes = undefined;
        if (window.eligible() and world.displayIndex(window.display) != null and native.platform_session_attributes(window.identity, &attributes)) if (attributes.key()) |_| {
            try result.append(allocator, .{ .identity = window.identity, .display = window.display, .workspace = window.workspace, .floating = window.floating, .frame = window.floating_frame, .attributes = attributes });
            continue;
        } else |_| {};
        session_status.unavailable += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn sessionScreens(output: []continuity.Screen) []continuity.Screen {
    for (world.displays(), 0..) |display, index| {
        output[index] = .{ .identity = display.identity, .workspace = display.workspace, .full_bounds = display.full_bounds, .hint = @splat(0) };
        _ = session.huen_session_display_uuid(display.identity, &output[index].hint, output[index].hint.len);
    }
    return output[0..world.displays().len];
}

pub fn freeze() void {
    if (session_freeze_attempted) return;
    session_freeze_attempted = true;
    if (!world.config().session.enabled) return;
    const current = sessionWindows() catch |err| return saveFailed(err);
    defer allocator.free(current);
    var screens: [32]continuity.Screen = undefined;
    var homes = routing.homeSnapshot();
    session_frozen = continuity.freeze(world.layouts(), current, sessionScreens(&screens), world.config(), homes[0..world.config().workspace_count], sessionScope()) catch |err| return saveFailed(err);
    session_status.save = .frozen;
}

fn saveFailed(err: anyerror) void {
    sessionError(@errorName(err));
    session_status.save = .failed;
}

pub fn save(clean: bool) void {
    if (session_save_attempted or !world.config().session.enabled) return;
    session_save_attempted = true;
    const checkpoint = if (session_frozen) |*frozen| frozen else return;
    defer {
        checkpoint.deinit();
        session_frozen = null;
    }
    if (!clean or checkpoint.snapshot.windows.len == 0) {
        session_status.save = .skipped;
        return;
    }
    session.save(allocator, checkpoint.snapshot) catch |err| return saveFailed(err);
    session_status.save = .saved;
}

// Loads the checkpoint once, on the first tick that has displays and windows.
pub fn restore() void {
    if (!session_loaded) restore: {
        session_loaded = true;
        if (!world.config().session.enabled) break :restore;
        var loaded = session.load(allocator, sessionScope());
        defer if (loaded.parsed) |*parsed| parsed.deinit();
        session_status.load = switch (loaded.diagnostic) {
            .none => .none,
            .ready => .pending,
            .rejected => .rejected,
        };
        if (loaded.rejection) |rejection| sessionError(@tagName(rejection));
        const checkpoint = if (loaded.parsed) |*parsed| &parsed.value else break :restore;
        const current = sessionWindows() catch |err| {
            sessionError(@errorName(err));
            session_status.load = .failed;
            break :restore;
        };
        defer allocator.free(current);
        var screens: [32]continuity.Screen = undefined;
        if (world.config().workspace_monitors != null) routing.seedHomes(continuity.savedHomes(checkpoint, world.config()));
        const imported = continuity.restore(checkpoint, current, sessionScreens(&screens), world.config(), routing.resolve()) catch |err| {
            sessionError(@errorName(err));
            session_status.load = .failed;
            break :restore;
        };
        defer imported.deinit();
        world.layouts().* = imported.store.*;
        for (imported.assignments) |assignment| {
            const window = &world.windows()[world.windowIndex(assignment.identity) orelse continue];
            window.display = assignment.display;
            window.workspace = assignment.workspace;
            window.floating = assignment.floating;
            if (assignment.frame) |frame| {
                const screen = world.displays()[world.displayIndex(assignment.display).?];
                window.floating_frame = world.boundedFloating(frame, screen.area());
                window.floating_restore = true;
            }
        }
        for (imported.active) |active| if (world.displayIndex(active.display)) |slot| {
            world.displays()[slot].workspace = active.workspace;
        };
        session_status.matched = imported.matched;
        session_status.unmatched = checkpoint.windows.len - imported.matched;
        session_status.ambiguous = imported.ambiguous;
        session_status.load = if (imported.matched > 0) .restored else .none;
        session_focus_pending = imported.matched > 0;
    }
}

pub fn takeFocusPending() bool {
    if (!session_focus_pending) return false;
    session_focus_pending = false;
    return true;
}

pub fn status() Status {
    return session_status;
}
