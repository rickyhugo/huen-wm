const std = @import("std");
const native = @import("native.zig");
const session = @import("session.zig");

var journal_failed = false;
// `last_error` is the last workspace transition or placement failure. `journaled` is the last one written, so a failure
// that repeats every tick is written once.
var last_error: ?[]const u8 = null;
var journaled: ?[]const u8 = null;

pub fn enabled() bool {
    return native.platform_filter()[0] == 0;
}

pub fn append(event: []const u8, fields: anytype) bool {
    if (!enabled()) return false;
    var buffer: [4096]u8 = undefined;
    const line = encode(&buffer, event, fields) catch return false;
    if (session.huen_journal_append(line.ptr, line.len)) return true;
    if (!journal_failed) native.platform_error("Journal append failed; later failures are not reported");
    journal_failed = true;
    return false;
}

fn encode(buffer: []u8, event: []const u8, fields: anytype) ![]const u8 {
    const at = wallSeconds();
    var writer: std.Io.Writer = .fixed(buffer);
    var stream: std.json.Stringify = .{ .writer = &writer };
    try stream.beginObject();
    try stream.objectField("at");
    try stream.write(at);
    try stream.objectField("event");
    try stream.write(event);
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
        try stream.objectField(name);
        try stream.write(@field(fields, name));
    }
    try stream.endObject();
    try writer.writeByte('\n');
    return writer.buffered();
}

pub fn wallSeconds() @FieldType(std.c.timespec, "sec") {
    var clock: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &clock);
    return clock.sec;
}

pub fn setError(message: ?[]const u8) void {
    last_error = message;
}

pub fn lastError() ?[]const u8 {
    return last_error;
}

// A placement failure is journaled with its window, so the transition entry would repeat it.
pub fn placementError(message: []const u8) void {
    last_error = message;
    journaled = message;
}

pub fn flushTransition() void {
    const message = last_error orelse return;
    if (journaled) |previous| if (std.mem.eql(u8, previous, message)) return;
    journaled = message;
    _ = append("transition", .{ .message = message });
}
