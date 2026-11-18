const std = @import("std");
const native = @import("native.zig");

pub const PatternKind = enum { literal, glob, regex };
pub const Title = struct {
    kind: PatternKind,
    pattern: [256:0]u8 = @splat(0),
};
pub const Geometry = struct { left: f64, top: f64, width: f64, height: f64 };
pub const Rule = struct {
    bundle: [256:0]u8 = @splat(0),
    bundle_kind: PatternKind = .literal,
    title: ?Title = null,
    floating: ?bool = null,
    workspace: ?usize = null,
    geometry: ?Geometry = null,
    centered: bool = false,
};
pub const Facts = struct { bundle: []const u8, title: []const u8, title_complete: bool = true };
pub const Decision = struct {
    floating: ?bool = null,
    workspace: ?usize = null,
    geometry: ?Geometry = null,
    centered: bool = false,
};

pub fn resolve(rules: []const Rule, facts: Facts) Decision {
    var decision: Decision = .{};
    for (rules) |*rule| {
        if (!matches(rule.bundle_kind, &rule.bundle, facts.bundle)) continue;
        if (rule.title) |*title| if (!facts.title_complete or !std.unicode.utf8ValidateSlice(facts.title) or !matches(title.kind, &title.pattern, facts.title)) continue;
        if (rule.floating) |floating| decision.floating = floating;
        if (rule.workspace) |workspace| decision.workspace = workspace;
        if (rule.geometry) |geometry| {
            decision.geometry = geometry;
            decision.floating = true;
        }
        if (rule.centered) {
            decision.centered = true;
            decision.floating = true;
        }
    }
    return decision;
}

// Literal and glob patterns cover the whole text. A regular expression matches anywhere in it unless it is anchored.
fn matches(kind: PatternKind, pattern: *const [256:0]u8, text: []const u8) bool {
    const expected = std.mem.sliceTo(pattern, 0);
    switch (kind) {
        .literal => return std.mem.eql(u8, expected, text),
        .regex => return native.platform_regex_match(pattern, text.ptr, text.len) == 1,
        .glob => {},
    }
    var pattern_offset: usize = 0;
    var text_offset: usize = 0;
    var star_pattern: ?usize = null;
    var star_text: usize = 0;
    while (text_offset < text.len) {
        if (pattern_offset < expected.len and expected[pattern_offset] == '*') {
            pattern_offset += 1;
            star_pattern = pattern_offset;
            star_text = text_offset;
        } else if (pattern_offset < expected.len and expected[pattern_offset] == '?') {
            pattern_offset += 1;
            text_offset = scalarEnd(text, text_offset);
        } else if (pattern_offset < expected.len and std.mem.eql(u8, expected[pattern_offset..scalarEnd(expected, pattern_offset)], text[text_offset..scalarEnd(text, text_offset)])) {
            pattern_offset = scalarEnd(expected, pattern_offset);
            text_offset = scalarEnd(text, text_offset);
        } else if (star_pattern) |restart| {
            star_text = scalarEnd(text, star_text);
            text_offset = star_text;
            pattern_offset = restart;
        } else return false;
    }
    while (pattern_offset < expected.len and expected[pattern_offset] == '*') pattern_offset += 1;
    return pattern_offset == expected.len;
}

fn scalarEnd(value: []const u8, offset: usize) usize {
    return offset + (std.unicode.utf8ByteSequenceLength(value[offset]) catch unreachable);
}
