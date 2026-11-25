const std = @import("std");

pub const deadline = 0.75;
pub const lead = 0.25;
pub const late = 1.0;
pub const Command = [128:0]u8;

// Carbon and the event tap report one key press separately, in either order.
const Entry = struct { slot: u32, at: f64, state: union(enum) { pressed: Command, delivered, recovered } };
const State = std.meta.Tag(@FieldType(Entry, "state"));

pub const Watch = struct {
    entries: [16]?Entry = @splat(null),

    pub fn pressed(self: *Watch, slot: u32, command: []const u8, now: f64) void {
        self.expire(now);
        if (self.take(slot, .delivered)) return;
        var captured: Command = @splat(0);
        const length = @min(command.len, captured.len);
        @memcpy(captured[0..length], command[0..length]);
        self.insert(.{ .slot = slot, .at = now, .state = .{ .pressed = captured } });
    }

    /// False means the press already ran from `overdue`.
    pub fn delivered(self: *Watch, slot: u32, now: f64) bool {
        self.expire(now);
        if (self.take(slot, .recovered)) return false;
        if (!self.take(slot, .pressed)) self.insert(.{ .slot = slot, .at = now, .state = .delivered });
        return true;
    }

    /// The tap's report of the press waits on the main thread while the delivered command runs,
    /// so the delivery's `lead` starts when the command returns.
    pub fn ran(self: *Watch, slot: u32, now: f64) void {
        var newest: ?usize = null;
        for (self.entries, 0..) |candidate, index| if (candidate) |entry| {
            if (entry.state != .delivered or entry.slot != slot) continue;
            if (newest == null or entry.at >= self.entries[newest.?].?.at) newest = index;
        };
        if (newest) |index| self.entries[index].?.at = now;
    }

    pub fn overdue(self: *Watch, now: f64) ?Command {
        self.expire(now);
        const index = self.oldest(null, .pressed) orelse return null;
        const entry = self.entries[index].?;
        if (now - entry.at < deadline) return null;
        self.entries[index] = .{ .slot = entry.slot, .at = now, .state = .recovered };
        return entry.state.pressed;
    }

    /// A new binding table can give a slot to another key, so a waiting press must not pair with that key's delivery.
    pub fn forgetPresses(self: *Watch) void {
        for (&self.entries) |*slot| if (slot.*) |entry| if (entry.state == .pressed) {
            slot.* = null;
        };
    }

    fn expire(self: *Watch, now: f64) void {
        for (&self.entries) |*slot| if (slot.*) |entry| switch (entry.state) {
            .pressed => {},
            .delivered => if (now - entry.at > lead) {
                slot.* = null;
            },
            .recovered => if (now - entry.at > late) {
                slot.* = null;
            },
        };
    }

    fn oldest(self: *const Watch, slot: ?u32, state: State) ?usize {
        var result: ?usize = null;
        for (self.entries, 0..) |candidate, index| if (candidate) |entry| {
            if (std.meta.activeTag(entry.state) != state or (slot != null and slot != entry.slot)) continue;
            if (result == null or entry.at < self.entries[result.?].?.at) result = index;
        };
        return result;
    }

    fn take(self: *Watch, slot: u32, state: State) bool {
        self.entries[self.oldest(slot, state) orelse return false] = null;
        return true;
    }

    fn insert(self: *Watch, entry: Entry) void {
        var target: usize = 0;
        for (self.entries, 0..) |candidate, index| {
            const occupant = candidate orelse {
                target = index;
                break;
            };
            if (occupant.at < self.entries[target].?.at) target = index;
        }
        self.entries[target] = entry;
    }
};
