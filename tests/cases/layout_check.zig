const std = @import("std");
const suite = @import("../manager.zig");
const abi = @import("../fake/abi.zig");
const Manager = suite.Manager;

extern const huen_test_window_layout: [17]usize;
extern const huen_test_window_layout_count: usize;
extern const huen_test_struct_sizes: [5]usize;

/// The linker matches the fake adapter's symbols by name only, so a mirror that drifts from the C header corrupts memory silently.
pub fn @"the WMWindow mirror matches native/platform.h"(_: *Manager) !void {
    const fields = comptime std.meta.fieldNames(abi.Window);
    try suite.expect(huen_test_window_layout_count == fields.len + 1, "tests/layout.c to list {d} WMWindow fields, got {d}", .{ fields.len, huen_test_window_layout_count - 1 });
    try suite.expect(huen_test_window_layout[0] == @sizeOf(abi.Window), "sizeof(WMWindow) {d}, the mirror has {d}", .{ huen_test_window_layout[0], @sizeOf(abi.Window) });
    inline for (fields, huen_test_window_layout[1..]) |field, offset| {
        try suite.expect(offset == @offsetOf(abi.Window, field), "WMWindow." ++ field ++ " at offset {d}, the mirror has {d}", .{ offset, @offsetOf(abi.Window, field) });
    }
}

pub fn @"the other C struct mirrors match their headers"(_: *Manager) !void {
    const mirrors = [_]struct { []const u8, usize }{
        .{ "WMDisplay", @sizeOf(abi.Display) },
        .{ "WMLaunchStatus", @sizeOf(abi.LaunchStatus) },
        .{ "HuenSessionAttributes", @sizeOf(abi.SessionAttributes) },
        .{ "HuenHitRegion", @sizeOf(abi.HitRegion) },
        .{ "HuenInputSnapshot", @sizeOf(abi.InputSnapshot) },
    };
    for (mirrors, huen_test_struct_sizes) |mirror, size| try suite.expect(mirror[1] == size, "sizeof({s}) {d}, the mirror has {d}", .{ mirror[0], size, mirror[1] });
}
