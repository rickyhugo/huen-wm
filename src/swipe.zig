const std = @import("std");
const commands = @import("command.zig");

pub const travel = 0.15;
// A lift that the tap missed, as when macOS disabled it, must not leave the recognizer spent.
pub const stale = 0.5;

pub const Recognizer = struct {
    fingers: u32 = 3,
    state: union(enum) { armed, tracking: struct { horizontal: f64, vertical: f64 }, spent } = .armed,
    last: f64 = -std.math.inf(f64),

    /// Positions are the mean normalized touch position, from 0 to 1. Fingers moving left step to the next workspace.
    pub fn sample(self: *Recognizer, fingers: u32, horizontal: f64, vertical: f64, now: f64) ?commands.Step {
        if (now - self.last > stale) self.state = .armed;
        self.last = now;
        if (fingers == 0) {
            self.state = .armed;
            return null;
        }
        switch (self.state) {
            .spent => return null,
            .armed => {
                if (fingers == self.fingers) self.state = .{ .tracking = .{ .horizontal = horizontal, .vertical = vertical } };
                return null;
            },
            .tracking => |origin| {
                if (fingers != self.fingers) {
                    self.state = .spent;
                    return null;
                }
                const across = horizontal - origin.horizontal;
                if (@abs(across) < travel or @abs(across) < 2 * @abs(vertical - origin.vertical)) return null;
                self.state = .spent;
                return if (across < 0) .next else .previous;
            },
        }
    }
};
