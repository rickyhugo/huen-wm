const std = @import("std");

pub const Ring = struct {
    entries: [16]u64 = undefined,
    count: usize = 0,

    pub fn push(self: *Ring, identity: u64) void {
        self.forget(identity);
        const kept: usize = @min(self.count, self.entries.len - 1);
        std.mem.copyBackwards(u64, self.entries[1 .. kept + 1], self.entries[0..kept]);
        self.entries[0] = identity;
        self.count = kept + 1;
    }

    pub fn forget(self: *Ring, identity: u64) void {
        const index = std.mem.indexOfScalar(u64, self.entries[0..self.count], identity) orelse return;
        std.mem.copyForwards(u64, self.entries[index .. self.count - 1], self.entries[index + 1 .. self.count]);
        self.count -= 1;
    }

    pub fn latest(self: *const Ring) ?u64 {
        return if (self.count > 0) self.entries[0] else null;
    }

    pub fn pick(self: *const Ring, current: ?u64, eligible: *const fn (u64) bool) ?u64 {
        for (self.entries[0..self.count]) |identity| if (current != identity and eligible(identity)) return identity;
        return null;
    }
};
