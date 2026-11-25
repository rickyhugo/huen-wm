//! The seam is `delivery.Watch`: the reports of a key press go in, and the count of command runs comes out.
//! The times are from docs/runtime.md. The timer moves the watch's clock by at most 62.5 ms per firing, so a delivery
//! waits 4 firings for its press, a press runs after 12 firings without a delivery, and a press that ran waits 16
//! more firings for its delivery.
const std = @import("std");
const delivery = @import("delivery");

const Kind = enum { press, delivery };
/// A report reaches the main thread before the timer's firing of the same number.
const Report = struct { firing: usize, kind: Kind };

const Order = enum { press_first, delivery_first, never_delivered };
/// How macOS reports one key press: the first report at `start`, the second `apart` firings later.
const Press = struct {
    order: Order,
    start: usize,
    apart: usize,

    fn reports(self: Press) [2]?Report {
        return switch (self.order) {
            .press_first => .{ .{ .firing = self.start, .kind = .press }, .{ .firing = self.start + self.apart, .kind = .delivery } },
            .delivery_first => .{ .{ .firing = self.start, .kind = .delivery }, .{ .firing = self.start + self.apart, .kind = .press } },
            .never_delivered => .{ .{ .firing = self.start, .kind = .press }, null },
        };
    }

    /// The longest time between the two reports that the watch still pairs.
    fn longest(order: Order) usize {
        return switch (order) {
            .press_first => 28,
            .delivery_first => 4,
            .never_delivered => 0,
        };
    }

    fn at(self: Press, kind: Kind) ?usize {
        for (self.reports()) |report| if (report != null and report.?.kind == kind) return report.?.firing;
        return null;
    }
};

/// Runs the timer for `firings` and counts the runs of the command. The main thread is busy for 5 s before the firing `stall`.
fn runs(presses: []const Press, firings: usize, stall: ?usize) usize {
    var watch: delivery.Watch = .{};
    var now: f64 = 1000;
    var count: usize = 0;
    // The timer fired before the first report: the first firing only starts the clock.
    _ = watch.overdue(now);
    for (0..firings) |firing| {
        for ([_]usize{ 0, 1 }) |position| for (presses) |press| {
            const report = press.reports()[position] orelse continue;
            if (report.firing != firing) continue;
            switch (report.kind) {
                .press => watch.pressed(0, "command"),
                .delivery => count += @intFromBool(watch.delivered(0)),
            }
        };
        now += if (stall == firing) 5 else 0.0625;
        count += @intFromBool(watch.overdue(now) != null);
    }
    return count;
}

const quiet = 40;

test "one key press runs its command once, whatever the order and timing of its reports and wherever the main thread stalls" {
    for (std.enums.values(Order)) |order| for (0..Press.longest(order) + 1) |apart| {
        const press: Press = .{ .order = order, .start = 0, .apart = apart };
        for (0..apart + 2) |position| {
            const stall: ?usize = if (position > apart) null else position;
            const count = runs(&.{press}, apart + quiet, stall);
            if (count != 1) {
                std.debug.print("{t}, reports {d} firings apart, stall before firing {?d}: {d} runs\n", .{ order, apart, stall, count });
                return error.TestUnexpectedResult;
            }
        }
    };
}

test "two presses of one key run its command twice, whatever the order and timing of their reports" {
    for (std.enums.values(Order)) |first_order| for (0..Press.longest(first_order) + 1) |first_apart| {
        const first: Press = .{ .order = first_order, .start = 0, .apart = first_apart };
        for (std.enums.values(Order)) |second_order| for (0..Press.longest(second_order) + 1) |second_apart| for (0..33) |start| {
            const second: Press = .{ .order = second_order, .start = start, .apart = second_apart };
            // The tap reports presses in the order of the presses, and Carbon delivers them in that order.
            if (second.at(.press).? < first.at(.press).?) continue;
            if (first.at(.delivery) != null and second.at(.delivery) != null and second.at(.delivery).? < first.at(.delivery).?) continue;
            for ([_]?usize{ null, first.at(.press), first.at(.delivery), second.at(.press), second.at(.delivery) }, 0..) |stall, choice| {
                if (choice != 0 and stall == null) continue;
                const count = runs(&.{ first, second }, start + first_apart + second_apart + quiet, stall);
                if (count != 2) {
                    std.debug.print("{t} {d} apart, then {t} {d} apart from firing {d}, stall before firing {?d}: {d} runs\n", .{ first_order, first_apart, second_order, second_apart, start, stall, count });
                    return error.TestUnexpectedResult;
                }
            }
        };
    };
}
