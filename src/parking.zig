const std = @import("std");
const native = @import("native.zig");
const session = @import("session.zig");
const Rect = native.WMRect;

pub const max_records = 1024;
pub const max_bytes = 1024 * 1024;
// `token` is the launch date of the application, so a reused pid cannot match.
pub const Record = struct { bundle: []const u8, pid: c_int, token: f64, original: Rect, corners: [2]Rect };
pub const Journal = struct { version: u32, records: []const Record };
pub const Recovery = struct { index: usize, original: Rect };

pub fn corners(frame: Rect, area: Rect) [2]Rect {
    var right = frame;
    right.top = area.top + area.height - 1;
    right.left = area.left + area.width - 1;
    var left = right;
    left.left = area.left + 1 - right.width;
    return .{ right, left };
}

fn rectValid(rect: Rect) bool {
    return std.math.isFinite(rect.left) and std.math.isFinite(rect.top) and @abs(rect.left) <= 1_000_000 and @abs(rect.top) <= 1_000_000 and
        rect.width > 0 and rect.height > 0 and rect.width <= 1_000_000 and rect.height <= 1_000_000;
}

pub fn valid(record: Record) bool {
    return record.pid > 0 and std.math.isFinite(record.token) and record.token > 0 and
        record.bundle.len > 0 and record.bundle.len < 256 and std.mem.indexOfScalar(u8, record.bundle, 0) == null and std.unicode.utf8ValidateSlice(record.bundle) and
        rectValid(record.original) and rectValid(record.corners[0]) and rectValid(record.corners[1]);
}

pub fn encode(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
    if (records.len > max_records) return error.Capacity;
    for (records) |record| if (!valid(record)) return error.InvalidRecord;
    const bytes = try std.json.Stringify.valueAlloc(allocator, Journal{ .version = 1, .records = records }, .{});
    if (bytes.len > max_bytes) {
        allocator.free(bytes);
        return error.TooLarge;
    }
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Journal) {
    if (bytes.len > max_bytes) return error.TooLarge;
    const parsed = try std.json.parseFromSlice(Journal, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = max_bytes });
    errdefer parsed.deinit();
    if (parsed.value.version != 1) return error.Version;
    if (parsed.value.records.len > max_records) return error.Capacity;
    for (parsed.value.records) |record| if (!valid(record)) return error.InvalidRecord;
    return parsed;
}

// macOS can clamp the vertical position of a parked window, so the top is not compared.
pub fn match(records: []const Record, observed: []const native.WMWindow, output: []Recovery) []Recovery {
    var claimed: [max_records]bool = @splat(false);
    var count: usize = 0;
    for (observed, 0..) |*window, index| {
        if (count == output.len) break;
        for (records, claimed[0..records.len]) |record, *used| {
            if (used.* or record.pid != window.pid or record.token != window.process_token or !std.mem.eql(u8, record.bundle, std.mem.sliceTo(&window.bundle, 0))) continue;
            const parked = for (record.corners) |corner| {
                if (@abs(window.frame.width - corner.width) <= 2 and @abs(window.frame.height - corner.height) <= 2 and @abs(window.frame.left - corner.left) <= 2) break true;
            } else false;
            if (!parked) continue;
            used.* = true;
            output[count] = .{ .index = index, .original = record.original };
            count += 1;
            break;
        }
    }
    return output[0..count];
}

fn journalHash(filter: []const u8) [64:0]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("HuenWM-parked-v1\x00");
    hasher.update(filter);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower) ++ [_:0]u8{};
}

pub fn load(allocator: std.mem.Allocator, filter: []const u8) !?std.json.Parsed(Journal) {
    const hash = journalHash(filter);
    const bytes = try allocator.alloc(u8, max_bytes);
    defer allocator.free(bytes);
    var used: usize = 0;
    switch (session.huen_session_read("parked", &hash, bytes.ptr, bytes.len, &used)) {
        0 => {},
        1 => return null,
        else => return error.Storage,
    }
    return try decode(allocator, bytes[0..used]);
}

// The journal only has to outlive this process. A record whose application ended with the machine can never match, so the write is not durable.
pub const Writer = struct {
    written: ?[]u8 = null,

    pub fn save(self: *Writer, allocator: std.mem.Allocator, filter: []const u8, records: []const Record) !void {
        const bytes = try encode(allocator, records);
        if (self.written) |previous| if (std.mem.eql(u8, previous, bytes)) {
            allocator.free(bytes);
            return;
        };
        const hash = journalHash(filter);
        if (!session.huen_session_write("parked", &hash, bytes.ptr, bytes.len, false)) {
            allocator.free(bytes);
            return error.Storage;
        }
        if (self.written) |previous| allocator.free(previous);
        self.written = bytes;
    }
};
