const commands = @import("command.zig");
pub const Axis = commands.Axis;
pub const Rect = @import("native.zig").WMRect;

pub const tolerance: f64 = 2;

pub const Ceiling = struct {
    accepted: f64,
    largest_refused: f64,

    pub fn binds(self: Ceiling, offer: f64) bool {
        return offer > self.accepted + tolerance and offer <= self.largest_refused + tolerance;
    }
};

pub const Span = struct {
    minimum: f64 = 0,
    ceiling: ?Ceiling = null,

    fn take(self: Span, offer: f64) f64 {
        const ceiling = self.ceiling orelse return offer;
        return if (ceiling.binds(offer)) ceiling.accepted else offer;
    }
};

pub const Bounds = struct {
    spans: [2]Span = .{ .{}, .{} },

    pub fn minimumAt(self: Bounds, axis: Axis) f64 {
        return self.spans[@backingInt(axis)].minimum;
    }

    pub fn ceilingAt(self: Bounds, axis: Axis) ?Ceiling {
        return self.spans[@backingInt(axis)].ceiling;
    }

    pub fn learn(self: Bounds, requested: [2]f64, accepted: [2]f64, usable: [2]f64) Bounds {
        var next = self;
        for (&next.spans, requested, accepted, usable) |*span, offer, answer, limit| {
            if (answer > offer + tolerance) {
                const learned = @min(answer, limit);
                if (learned > span.minimum) span.minimum = learned;
                if (span.ceiling) |existing| if (span.minimum > existing.accepted) {
                    span.ceiling = null;
                };
            } else if (answer < offer - tolerance) {
                const capped = @max(1, @min(answer, limit));
                var largest_refused = offer;
                if (span.ceiling) |existing| if (@abs(offer - existing.accepted) <= tolerance or @abs(capped - existing.accepted) <= tolerance) {
                    largest_refused = @max(existing.largest_refused, offer);
                };
                span.ceiling = .{ .accepted = capped, .largest_refused = largest_refused };
                if (span.minimum > capped) span.minimum = capped;
            } else if (span.ceiling) |existing| if (offer > existing.accepted + tolerance) {
                span.ceiling = null;
            };
        }
        return next;
    }

    pub fn fit(self: Bounds, slot: Rect) Rect {
        const width = self.spans[0].take(slot.width);
        const height = self.spans[1].take(slot.height);
        return .{
            .left = slot.left + @floor((slot.width - width) / 2),
            .top = slot.top + @floor((slot.height - height) / 2),
            .width = width,
            .height = height,
        };
    }
};
