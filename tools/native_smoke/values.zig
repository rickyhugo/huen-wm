//! JSON values as the driver reads them: field access, Python-style truth and equality, frames, and points.
const std = @import("std");
const system = @import("system.zig");
const Error = system.Error;

pub const Value = std.json.Value;
pub const Titles = []const []const u8;

pub fn parse(bytes: []const u8) Error!?Value {
    return std.json.parseFromSliceLeaky(Value, system.allocator, bytes, .{ .duplicate_field_behavior = .use_last }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

const Formatted = struct {
    value: Value,
    pub fn format(self: Formatted, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(self.value, .{}, writer);
    }
};

/// Formats a value as compact JSON in messages.
pub fn fmt(value: Value) Formatted {
    return .{ .value = value };
}

pub fn encode(value: Value) Error![]const u8 {
    return std.json.Stringify.valueAlloc(system.allocator, value, .{ .whitespace = .indent_2, .escape_unicode = true });
}

pub const Entry = struct { []const u8, Value };

pub fn object(entries: []const Entry) Error!Value {
    var map: std.json.ObjectMap = .empty;
    for (entries) |entry| try map.put(system.allocator, entry[0], entry[1]);
    return .{ .object = map };
}

pub fn array(elements: []const Value) Error!Value {
    var list: std.json.Array = .init(system.allocator);
    try list.appendSlice(elements);
    return .{ .array = list };
}

pub fn strings(elements: []const []const u8) Error!Value {
    var list: std.json.Array = .init(system.allocator);
    for (elements) |item| try list.append(.{ .string = item });
    return .{ .array = list };
}

pub fn string(content: []const u8) Value {
    return .{ .string = content };
}

pub fn integer(amount: i64) Value {
    return .{ .integer = amount };
}

pub fn optionalInteger(amount: ?i64) Value {
    return if (amount) |known| .{ .integer = known } else .null;
}

/// `value[name]` of a JSON object, or null like `dict.get` when the field or the object is missing.
pub fn field(value: ?Value, name: []const u8) ?Value {
    const known = value orelse return null;
    return switch (known) {
        .object => |map| map.get(name),
        else => null,
    };
}

/// `value[name]`, failing like a `KeyError` when the field is missing.
pub fn get(value: ?Value, name: []const u8) Error!Value {
    return field(value, name) orelse fail(value, name);
}

fn fail(value: ?Value, name: []const u8) Error {
    const known = value orelse return system.fail("Missing field '{s}' in null", .{name});
    return system.fail("Missing field '{s}' in {f}", .{ name, fmt(known) });
}

pub fn items(value: ?Value) Error![]Value {
    const known = value orelse return system.fail("Expected a list, found null", .{});
    return switch (known) {
        .array => |list| list.items,
        else => system.fail("Expected a list, found {f}", .{fmt(known)}),
    };
}

pub fn text(value: ?Value) Error![]const u8 {
    const known = value orelse return system.fail("Expected a string, found null", .{});
    return switch (known) {
        .string => |content| content,
        else => system.fail("Expected a string, found {f}", .{fmt(known)}),
    };
}

/// A number in Python's sense, where a boolean counts as 0 or 1.
pub fn numeric(value: Value) ?f64 {
    return switch (value) {
        .integer => |content| @floatFromInt(content),
        .float => |content| content,
        .number_string => |digits| std.fmt.parseFloat(f64, digits) catch null,
        .bool => |flag| if (flag) 1 else 0,
        else => null,
    };
}

pub fn number(value: ?Value) Error!f64 {
    const known = value orelse return system.fail("Expected a number, found null", .{});
    return numeric(known) orelse system.fail("Expected a number, found {f}", .{fmt(known)});
}

pub fn whole(value: ?Value) Error!i64 {
    const known = value orelse return system.fail("Expected an integer, found null", .{});
    return switch (known) {
        .integer => |content| content,
        else => system.fail("Expected an integer, found {f}", .{fmt(known)}),
    };
}

/// Python truthiness.
pub fn truthy(value: ?Value) bool {
    const known = value orelse return false;
    return switch (known) {
        .null => false,
        .bool => |flag| flag,
        .integer => |content| content != 0,
        .float => |content| content != 0,
        .number_string => |digits| (std.fmt.parseFloat(f64, digits) catch 1) != 0,
        .string => |content| content.len > 0,
        .array => |list| list.items.len > 0,
        .object => |map| map.count() > 0,
    };
}

/// Python `is True`.
pub fn isTrue(value: ?Value) bool {
    const known = value orelse return false;
    return known == .bool and known.bool;
}

/// Python `is False`.
pub fn isFalse(value: ?Value) bool {
    const known = value orelse return false;
    return known == .bool and !known.bool;
}

/// Python `==` between decoded JSON values. A missing value equals null.
pub fn same(first: ?Value, second: ?Value) bool {
    const left = first orelse Value.null;
    const right = second orelse Value.null;
    if (numeric(left)) |left_number| if (numeric(right)) |right_number| return left_number == right_number;
    return switch (left) {
        .null => right == .null,
        .string => |content| right == .string and std.mem.eql(u8, content, right.string),
        .array => |list| right == .array and right.array.items.len == list.items.len and for (list.items, right.array.items) |left_item, right_item| {
            if (!same(left_item, right_item)) break false;
        } else true,
        .object => |map| right == .object and right.object.count() == map.count() and for (map.keys(), map.values()) |key, item| {
            const other = right.object.get(key) orelse break false;
            if (!same(item, other)) break false;
        } else true,
        else => false,
    };
}

pub fn sameText(value: ?Value, expected: []const u8) bool {
    const known = value orelse return false;
    return known == .string and std.mem.eql(u8, known.string, expected);
}

pub fn sameNumber(value: ?Value, expected: f64) bool {
    const known = value orelse return false;
    const actual = numeric(known) orelse return false;
    return actual == expected;
}

pub fn sameOptional(value: ?Value, expected: ?i64) bool {
    return same(value, optionalInteger(expected));
}

pub fn has(titles: Titles, title: ?[]const u8) bool {
    const known = title orelse return false;
    for (titles) |candidate| if (std.mem.eql(u8, candidate, known)) return true;
    return false;
}

pub fn without(titles: Titles, removed: []const u8) Error!Titles {
    var kept: std.ArrayList([]const u8) = .empty;
    for (titles) |title| if (!std.mem.eql(u8, title, removed)) try kept.append(system.allocator, title);
    return kept.items;
}

pub fn sameTitles(first: Titles, second: Titles) bool {
    for (first) |title| if (!has(second, title)) return false;
    for (second) |title| if (!has(first, title)) return false;
    return true;
}

pub const Frame = struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,

    pub fn read(value: ?Value) Error!Frame {
        return .{ .left = try number(try get(value, "left")), .top = try number(try get(value, "top")), .width = try number(try get(value, "width")), .height = try number(try get(value, "height")) };
    }

    pub fn json(self: Frame) Error!Value {
        return object(&.{
            .{ "left", .{ .float = self.left } },
            .{ "top", .{ .float = self.top } },
            .{ "width", .{ .float = self.width } },
            .{ "height", .{ .float = self.height } },
        });
    }

    pub fn eql(self: Frame, other: Frame) bool {
        return self.left == other.left and self.top == other.top and self.width == other.width and self.height == other.height;
    }

    pub fn moved(self: Frame, left: f64, top: f64) Frame {
        return .{ .left = left, .top = top, .width = self.width, .height = self.height };
    }

    pub fn right(self: Frame) f64 {
        return self.left + self.width;
    }

    pub fn bottom(self: Frame) f64 {
        return self.top + self.height;
    }
};

pub const Point = struct {
    left: f64,
    top: f64,

    pub fn read(value: ?Value) Error!Point {
        return .{ .left = try number(try get(value, "left")), .top = try number(try get(value, "top")) };
    }

    pub fn json(self: Point) Value {
        var map: std.json.ObjectMap = .empty;
        map.put(system.allocator, "left", .{ .float = self.left }) catch {};
        map.put(system.allocator, "top", .{ .float = self.top }) catch {};
        return .{ .object = map };
    }
};

pub fn closeFrame(actual: Frame, expected: Frame, tolerance: f64) bool {
    return @abs(actual.left - expected.left) <= tolerance and @abs(actual.top - expected.top) <= tolerance and
        @abs(actual.width - expected.width) <= tolerance and @abs(actual.height - expected.height) <= tolerance;
}

pub fn contains(bounds: Frame, frame: Frame, margin: f64, tolerance: f64) bool {
    return frame.left >= bounds.left + margin - tolerance and frame.top >= bounds.top + margin - tolerance and
        frame.right() <= bounds.right() - margin + tolerance and frame.bottom() <= bounds.bottom() - margin + tolerance;
}

pub fn overlaps(first: Frame, second: Frame, tolerance: f64) bool {
    return @min(first.right(), second.right()) - @max(first.left, second.left) > tolerance and
        @min(first.bottom(), second.bottom()) - @max(first.top, second.top) > tolerance;
}

pub fn inset(bounds: Frame, amount: f64) Frame {
    return .{ .left = bounds.left + amount, .top = bounds.top + amount, .width = bounds.width - 2 * amount, .height = bounds.height - 2 * amount };
}

pub fn center(bounds: Frame) Point {
    return .{ .left = bounds.left + bounds.width / 2, .top = bounds.top + bounds.height / 2 };
}

pub fn inside(bounds: Frame, point: Point) bool {
    return bounds.left <= point.left and point.left < bounds.right() and bounds.top <= point.top and point.top < bounds.bottom();
}

pub fn near(first: Point, second: Point, tolerance: f64) bool {
    return @abs(first.left - second.left) <= tolerance and @abs(first.top - second.top) <= tolerance;
}

/// Window frames of a fixture report by title, in report order.
pub const Frames = std.StringArrayHashMapUnmanaged(Frame);

pub fn frames(report: ?Value) Error!Frames {
    var result: Frames = .empty;
    for (try items(try get(report, "windows"))) |window| try result.put(system.allocator, try text(try get(window, "title")), try Frame.read(try get(window, "frame")));
    return result;
}

pub fn frameOf(observed: Frames, title: []const u8) Error!Frame {
    return observed.get(title) orelse system.fail("Missing window '{s}'", .{title});
}

pub fn titlesOf(observed: Frames) Titles {
    return observed.keys();
}

pub fn keyTitle(report: ?Value) Error!?[]const u8 {
    for (try items(try get(report, "windows"))) |window| if (truthy(try get(window, "key"))) return try text(try get(window, "title"));
    return null;
}

pub const Screen = struct { visible_frame: Frame, full_bounds: Frame };

pub fn screens(report: ?Value) Error![]Screen {
    var result: std.ArrayList(Screen) = .empty;
    for (try items(try get(report, "screens"))) |screen| try result.append(system.allocator, .{ .visible_frame = try Frame.read(try get(screen, "visible_frame")), .full_bounds = try Frame.read(try get(screen, "full_bounds")) });
    return result.items;
}

/// Python `round`, which rounds halves to even.
pub fn roundEven(number_value: f64) f64 {
    const floor = @floor(number_value);
    const difference = number_value - floor;
    if (difference > 0.5) return floor + 1;
    if (difference < 0.5) return floor;
    return if (@mod(floor, 2) == 0) floor else floor + 1;
}
