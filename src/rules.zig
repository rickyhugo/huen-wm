const std = @import("std");

pub const Title = struct {
    kind: enum { literal, glob },
    pattern: [256:0]u8 = @splat(0),
};
pub const Geometry = struct { left: f64, top: f64, width: f64, height: f64 };
pub const Rule = struct {
    bundle: [256:0]u8 = @splat(0),
    title: ?Title = null,
    floating: ?bool = null,
    workspace: ?usize = null,
    geometry: ?Geometry = null,
};
pub const Facts = struct { bundle: []const u8, title: []const u8, title_complete: bool = true };
pub const Decision = struct {
    floating: ?bool = null,
    workspace: ?usize = null,
    geometry: ?Geometry = null,
};

pub fn resolve(rules: []const Rule, facts: Facts) Decision {
    var decision: Decision = .{};
    for (rules) |*rule| {
        if (!std.mem.eql(u8, std.mem.sliceTo(&rule.bundle, 0), facts.bundle)) continue;
        if (rule.title) |*title| {
            if (!facts.title_complete or !std.unicode.utf8ValidateSlice(facts.title)) continue;
            const pattern = std.mem.sliceTo(&title.pattern, 0);
            const matched = switch (title.kind) {
                .literal => std.mem.eql(u8, pattern, facts.title),
                .glob => globMatches(pattern, facts.title),
            };
            if (!matched) continue;
        }
        if (rule.floating) |floating| decision.floating = floating;
        if (rule.workspace) |workspace| decision.workspace = workspace;
        if (rule.geometry) |geometry| {
            decision.geometry = geometry;
            decision.floating = true;
        }
    }
    return decision;
}

fn scalarEnd(value: []const u8, offset: usize) usize {
    return offset + (std.unicode.utf8ByteSequenceLength(value[offset]) catch unreachable);
}

fn globMatches(pattern: []const u8, title: []const u8) bool {
    var pattern_offset: usize = 0;
    var title_offset: usize = 0;
    var star_pattern: ?usize = null;
    var star_title: usize = 0;
    while (title_offset < title.len) {
        if (pattern_offset < pattern.len and pattern[pattern_offset] == '*') {
            pattern_offset += 1;
            star_pattern = pattern_offset;
            star_title = title_offset;
        } else if (pattern_offset < pattern.len and pattern[pattern_offset] == '?') {
            pattern_offset += 1;
            title_offset = scalarEnd(title, title_offset);
        } else if (pattern_offset < pattern.len and std.mem.eql(u8, pattern[pattern_offset..scalarEnd(pattern, pattern_offset)], title[title_offset..scalarEnd(title, title_offset)])) {
            pattern_offset = scalarEnd(pattern, pattern_offset);
            title_offset = scalarEnd(title, title_offset);
        } else if (star_pattern) |restart| {
            star_title = scalarEnd(title, star_title);
            title_offset = star_title;
            pattern_offset = restart;
        } else return false;
    }
    while (pattern_offset < pattern.len and pattern[pattern_offset] == '*') pattern_offset += 1;
    return pattern_offset == pattern.len;
}
