const std = @import("std");
const Rect = @import("native.zig").WMRect;

pub const capacity = 256;
pub const max_bytes = 1024 * 1024;
// `pid` and `token` name the process that owned the window. A zero token is an entry from the previous manager, which any process may claim.
pub const Entry = struct { bundle: [256]u8 = @splat(0), workspace: [64]u8 = @splat(0), floating: bool = false, floating_frame: Rect, frame: Rect, expires: f64, pid: c_int = 0, token: f64 = 0 };
pub const Process = struct { pid: c_int, token: f64 };
const Persisted = struct { bundle: []const u8, workspace: []const u8, floating: bool, floating_frame: Rect, frame: Rect };
const File = struct { version: u32, entries: []const Persisted };

pub const Memory = struct {
    entries: [capacity]Entry = undefined,
    count: usize = 0,

    pub fn remember(self: *Memory, entry: Entry) void {
        if (self.count == capacity) self.remove(0);
        self.entries[self.count] = entry;
        self.count += 1;
    }

    /// Takes the unexpired entry of `bundle` whose frame is within 4 points of `frame`, else its oldest unexpired entry.
    /// An entry is open to another process only after its own process exited, so a window closed in a running application is never claimed.
    pub fn claim(self: *Memory, bundle: []const u8, frame: Rect, now: f64, claimant: Process, exited: *const fn (Process) bool) ?Entry {
        self.prune(now);
        var chosen: ?usize = null;
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (!std.mem.eql(u8, std.mem.sliceTo(&entry.bundle, 0), bundle)) continue;
            const owner: Process = .{ .pid = entry.pid, .token = entry.token };
            if (owner.token != 0 and (std.meta.eql(owner, claimant) or !exited(owner))) continue;
            if (near(entry.frame, frame)) {
                chosen = index;
                break;
            }
            if (chosen == null) chosen = index;
        }
        const index = chosen orelse return null;
        const entry = self.entries[index];
        self.remove(index);
        return entry;
    }

    pub fn prune(self: *Memory, now: f64) void {
        var index: usize = 0;
        while (index < self.count) {
            if (self.entries[index].expires <= now) self.remove(index) else index += 1;
        }
    }

    fn remove(self: *Memory, index: usize) void {
        std.mem.copyForwards(Entry, self.entries[index .. self.count - 1], self.entries[index + 1 .. self.count]);
        self.count -= 1;
    }
};

fn near(first: Rect, second: Rect) bool {
    return @abs(first.left - second.left) <= 4 and @abs(first.top - second.top) <= 4 and @abs(first.width - second.width) <= 4 and @abs(first.height - second.height) <= 4;
}

pub fn scopeHash(filter: []const u8) [64:0]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("HuenWM-placements-v1\x00");
    hasher.update(filter);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower) ++ [_:0]u8{};
}

pub fn encode(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    const persisted = try allocator.alloc(Persisted, entries.len);
    defer allocator.free(persisted);
    for (entries, persisted) |*entry, *item| item.* = .{ .bundle = std.mem.sliceTo(&entry.bundle, 0), .workspace = std.mem.sliceTo(&entry.workspace, 0), .floating = entry.floating, .floating_frame = entry.floating_frame, .frame = entry.frame };
    return std.json.Stringify.valueAlloc(allocator, File{ .version = 1, .entries = persisted }, .{});
}

/// Replaces the contents of `memory` with the decoded entries, each expiring at `expires`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, expires: f64, memory: *Memory) !void {
    const parsed = try std.json.parseFromSlice(File, allocator, bytes, .{ .max_value_len = max_bytes });
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.entries.len > capacity) return error.InvalidPlacementMemory;
    var decoded: Memory = .{};
    for (parsed.value.entries) |item| {
        var entry: Entry = .{ .floating = item.floating, .floating_frame = item.floating_frame, .frame = item.frame, .expires = expires };
        if (!textValid(item.bundle, entry.bundle.len) or !textValid(item.workspace, entry.workspace.len) or !frameValid(item.frame) or !frameValid(item.floating_frame)) return error.InvalidPlacementMemory;
        @memcpy(entry.bundle[0..item.bundle.len], item.bundle);
        @memcpy(entry.workspace[0..item.workspace.len], item.workspace);
        decoded.remember(entry);
    }
    memory.* = decoded;
}

fn textValid(value: []const u8, size: usize) bool {
    return value.len > 0 and value.len < size and std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}

fn frameValid(frame: Rect) bool {
    for ([_]f64{ frame.left, frame.top, frame.width, frame.height }) |value| if (!std.math.isFinite(value) or @abs(value) > 100000) return false;
    return frame.width > 0 and frame.height > 0;
}
