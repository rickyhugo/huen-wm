const std = @import("std");
const allocator = std.heap.c_allocator;

pub const Reply = [*:0]const u8;
var reply_buffer: ?[:0]u8 = null;

// The reply stays valid until the next one, so the caller can hand it to the socket without copying.
pub fn json(value: anytype) Reply {
    if (reply_buffer) |previous| allocator.free(previous);
    reply_buffer = null;
    const encoded = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return "{\"error\":\"out of memory\"}\n";
    defer allocator.free(encoded);
    reply_buffer = std.fmt.allocPrintSentinel(allocator, "{s}\n", .{encoded}, 0) catch return "{\"error\":\"out of memory\"}\n";
    return reply_buffer.?.ptr;
}

pub fn failure(message: []const u8) Reply {
    return json(.{ .err_message = message, .@"error" = true });
}
