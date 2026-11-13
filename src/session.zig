const std = @import("std");

pub const max_bytes = 4 * 1024 * 1024;
pub const max_windows = 1024;
pub const max_nodes = 2047;
pub const max_roots = 320;
pub const max_edges = 2046;
pub const LogicalIndex = u16;
pub const Layout = enum { dwindle, master };
pub const Axis = enum { width, height };
pub const GroupMode = enum { tabbed, stacked };
pub const Scope = struct { config: []const u8, filter: []const u8, boot: []const u8 };
pub const KeyKind = enum { identifier, document };
pub const StableKey = struct {
    bundle: []const u8,
    pid: i32,
    launch: f64,
    kind: KeyKind,
    value: []const u8,
    role: []const u8,
    subrole: []const u8,
};
pub const NativeAttributes = extern struct {
    pid: i32,
    kind: u32,
    launch: f64,
    bundle: [256]u8,
    value: [2048]u8,
    role: [128]u8,
    subrole: [128]u8,

    pub fn key(self: *const NativeAttributes) !StableKey {
        const result = StableKey{
            .bundle = try terminated(&self.bundle),
            .pid = self.pid,
            .launch = self.launch,
            .kind = switch (self.kind) {
                1 => .identifier,
                2 => .document,
                else => return error.InvalidKey,
            },
            .value = try terminated(&self.value),
            .role = try terminated(&self.role),
            .subrole = try terminated(&self.subrole),
        };
        try validateKey(result);
        return result;
    }
};
pub extern "c" fn huen_session_identify(element: *const anyopaque, pid: i32, output: *NativeAttributes) bool;
pub extern "c" fn huen_session_display_uuid(display: u32, output: [*]u8, capacity: usize) bool;
pub extern "c" fn huen_session_boot_identity(output: [*]u8, capacity: usize) bool;
extern "c" fn huen_session_read(hash: [*:0]const u8, output: [*]u8, capacity: usize, used: *usize) c_int;
extern "c" fn huen_session_write(hash: [*:0]const u8, bytes: [*]const u8, length: usize) bool;

pub const Rect = struct { left: f64, top: f64, width: f64, height: f64 };
pub const Window = struct {
    key: StableKey,
    root: LogicalIndex,
    display_hint: []const u8 = "",
    floating: bool = false,
    floating_frame: ?Rect = null,
};
pub const Split = struct {
    axis: Axis,
    ratio: f64,
    children: [2]LogicalIndex,
    selected: u1 = 0,
};
pub const Group = struct {
    mode: GroupMode,
    children: []const LogicalIndex,
    selected: LogicalIndex,
};
pub const NodeShape = union(enum) { leaf: LogicalIndex, split: Split, group: Group };
pub const Root = struct {
    workspace: []const u8,
    occurrence: LogicalIndex = 0,
    display_hint: []const u8 = "",
    active: bool = false,
    default_layout: Layout,
    default_ratio: f64,
    defaults_fingerprint: []const u8,
    layout: Layout,
    ratio: f64,
    node: ?LogicalIndex = null,
    selection: ?LogicalIndex = null,
    focused: ?LogicalIndex = null,
    fullscreen: ?LogicalIndex = null,
};
pub const Snapshot = struct {
    version: u32,
    clean: bool = false,
    scope: Scope,
    windows: []const Window,
    nodes: []const NodeShape,
    roots: []const Root,
};
pub const Diagnostic = enum { none, ready, rejected };
pub const Rejection = enum { storage, schema, scope, unclean };
pub const Loaded = struct {
    diagnostic: Diagnostic,
    rejection: ?Rejection = null,
    parsed: ?std.json.Parsed(Snapshot) = null,

    pub fn snapshot(self: *const Loaded) ?*const Snapshot {
        if (self.parsed) |*parsed| return &parsed.value;
        return null;
    }

    pub fn deinit(self: *Loaded) void {
        if (self.parsed) |*parsed| parsed.deinit();
        self.* = .{ .diagnostic = .none };
    }
};
pub const RecoveryOutcome = enum { clean, failed };

pub fn load(allocator: std.mem.Allocator, scope: Scope) Loaded {
    const hash = scopeHash(scope) catch return .{ .diagnostic = .rejected, .rejection = .scope };
    const bytes = allocator.alloc(u8, max_bytes) catch return .{ .diagnostic = .rejected, .rejection = .storage };
    defer allocator.free(bytes);
    var used: usize = 0;
    switch (huen_session_read(&hash, bytes.ptr, bytes.len, &used)) {
        0 => return decode(allocator, bytes[0..used], scope),
        1 => return .{ .diagnostic = .none },
        else => return .{ .diagnostic = .rejected, .rejection = .storage },
    }
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, scope: Scope) Loaded {
    validateScope(scope) catch return .{ .diagnostic = .rejected, .rejection = .scope };
    if (bytes.len == 0 or bytes.len > max_bytes)
        return .{ .diagnostic = .rejected, .rejection = .schema };
    const parsed = std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = max_bytes }) catch
        return .{ .diagnostic = .rejected, .rejection = .schema };
    validate(parsed.value) catch {
        parsed.deinit();
        return .{ .diagnostic = .rejected, .rejection = .schema };
    };
    if (!sameScope(parsed.value.scope, scope)) {
        parsed.deinit();
        return .{ .diagnostic = .rejected, .rejection = .scope };
    }
    if (!parsed.value.clean) {
        parsed.deinit();
        return .{ .diagnostic = .rejected, .rejection = .unclean };
    }
    return .{ .diagnostic = .ready, .parsed = parsed };
}

pub fn save(allocator: std.mem.Allocator, checkpoint: Snapshot, outcome: RecoveryOutcome) !void {
    if (outcome != .clean or !checkpoint.clean) return error.Unclean;
    try validate(checkpoint);
    if (checkpoint.windows.len == 0) return error.EmptyBootstrap;
    const hash = try scopeHash(checkpoint.scope);
    const bytes = try std.json.Stringify.valueAlloc(allocator, checkpoint, .{});
    defer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.TooLarge;
    if (!huen_session_write(&hash, bytes.ptr, bytes.len)) return error.Storage;
}

fn terminated(bytes: []const u8) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidKey;
    return bytes[0..end];
}

fn textValid(value: []const u8, capacity: usize, empty: bool) bool {
    return value.len < capacity and (empty or value.len > 0) and
        std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}

fn validateScope(scope: Scope) !void {
    if (!textValid(scope.config, 4096, false) or !textValid(scope.filter, 4096, true) or
        !textValid(scope.boot, 128, false)) return error.InvalidScope;
}

fn sameScope(first: Scope, second: Scope) bool {
    return std.mem.eql(u8, first.config, second.config) and
        std.mem.eql(u8, first.filter, second.filter) and std.mem.eql(u8, first.boot, second.boot);
}

pub fn scopeHash(scope: Scope) ![64:0]u8 {
    try validateScope(scope);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("HuenWM-session-v1\x00");
    hasher.update(scope.config);
    hasher.update("\x00");
    hasher.update(scope.filter);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var result: [64:0]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 15];
    }
    result[64] = 0;
    return result;
}

pub fn validateKey(key: StableKey) !void {
    if (key.pid <= 0 or !std.math.isFinite(key.launch) or key.launch <= 0 or
        !textValid(key.bundle, 256, false) or !textValid(key.value, 2048, false) or
        !textValid(key.role, 128, false) or !textValid(key.subrole, 128, true)) return error.InvalidKey;
    if (key.kind == .document and std.mem.indexOfScalar(u8, key.value, ':') == null) return error.InvalidKey;
}

fn ratioValid(ratio: f64) bool {
    return std.math.isFinite(ratio) and ratio > 0 and ratio < 1;
}

pub fn validate(checkpoint: Snapshot) !void {
    if (checkpoint.version != 1) return error.Version;
    try validateScope(checkpoint.scope);
    if (checkpoint.windows.len > max_windows or checkpoint.nodes.len > max_nodes or
        checkpoint.roots.len > max_roots) return error.Capacity;
    for (checkpoint.windows) |window| {
        try validateKey(window.key);
        if (window.root >= checkpoint.roots.len or !textValid(window.display_hint, 128, true)) return error.InvalidWindow;
        if (window.floating_frame) |frame| {
            if (!window.floating or !std.math.isFinite(frame.left) or !std.math.isFinite(frame.top) or
                !std.math.isFinite(frame.width) or !std.math.isFinite(frame.height) or
                @abs(frame.left) > 1_000_000 or @abs(frame.top) > 1_000_000 or
                frame.width <= 0 or frame.height <= 0 or frame.width > 1_000_000 or frame.height > 1_000_000)
                return error.InvalidFrame;
        }
    }
    var parents: [max_nodes]bool = @splat(false);
    var owners: [max_nodes]?LogicalIndex = @splat(null);
    var leaves: [max_windows]bool = @splat(false);
    var stack: [max_nodes]LogicalIndex = undefined;
    var edge_count: usize = 0;
    for (checkpoint.nodes) |node| {
        switch (node) {
            .leaf => {},
            .split => |split| {
                if (!ratioValid(split.ratio)) return error.InvalidRatio;
                for (split.children) |child| try claim(child, checkpoint.nodes.len, &parents, &edge_count);
            },
            .group => |group| {
                if (group.children.len < 2 or group.children.len > max_windows or group.selected >= group.children.len)
                    return error.InvalidGroup;
                for (group.children) |child| try claim(child, checkpoint.nodes.len, &parents, &edge_count);
            },
        }
    }
    for (checkpoint.roots, 0..) |root, root_index| {
        if (!textValid(root.workspace, 64, false) or !textValid(root.display_hint, 128, true) or
            !textValid(root.defaults_fingerprint, 128, false) or
            !ratioValid(root.ratio) or !ratioValid(root.default_ratio) or
            root.default_ratio < 0.1 or root.default_ratio > 0.9) return error.InvalidRoot;
        for (checkpoint.roots[0..root_index]) |previous| {
            const same_display = std.mem.eql(u8, previous.display_hint, root.display_hint);
            if (same_display and ((root.active and previous.active) or
                (previous.occurrence == root.occurrence and std.mem.eql(u8, previous.workspace, root.workspace))))
                return error.DuplicateRoot;
        }
        for ([_]?LogicalIndex{ root.focused, root.fullscreen }) |reference| {
            if (reference) |window| {
                if (window >= checkpoint.windows.len or checkpoint.windows[window].root != root_index)
                    return error.InvalidFocus;
            }
        }
        var pending: usize = 0;
        if (root.node) |node| {
            if (node >= checkpoint.nodes.len or parents[node]) return error.InvalidRoot;
            stack[0] = node;
            pending = 1;
        }
        while (pending > 0) {
            pending -= 1;
            const index = stack[pending];
            if (owners[index] != null) return error.Cycle;
            owners[index] = @intCast(root_index);
            switch (checkpoint.nodes[index]) {
                .leaf => |window| {
                    if (window >= checkpoint.windows.len or leaves[window] or
                        checkpoint.windows[window].floating or checkpoint.windows[window].root != root_index)
                        return error.InvalidLeaf;
                    leaves[window] = true;
                },
                .split => |split| {
                    for (split.children) |child| {
                        if (pending == max_nodes) return error.Capacity;
                        stack[pending] = child;
                        pending += 1;
                    }
                },
                .group => |group| {
                    for (group.children) |child| {
                        if (pending == max_nodes) return error.Capacity;
                        stack[pending] = child;
                        pending += 1;
                    }
                },
            }
        }
        if (root.selection) |selection| {
            if (selection >= checkpoint.nodes.len or owners[selection] != @as(LogicalIndex, @intCast(root_index))) return error.InvalidSelection;
        }
    }
    for (owners[0..checkpoint.nodes.len]) |owner| if (owner == null) return error.OrphanNode;
}

fn claim(child: LogicalIndex, count: usize, parents: *[max_nodes]bool, edges: *usize) !void {
    if (child >= count or parents[child]) return error.DuplicateParent;
    parents[child] = true;
    edges.* += 1;
    if (edges.* > max_edges) return error.Capacity;
}

pub const Pair = struct { saved: LogicalIndex, current: LogicalIndex };
pub const MatchResult = struct {
    pairs: [max_windows]Pair = undefined,
    count: usize = 0,
    missing: usize = 0,
    ambiguous_saved: usize = 0,
    ambiguous_current: usize = 0,
};

pub fn equalKey(first: StableKey, second: StableKey) bool {
    return first.pid == second.pid and first.launch == second.launch and first.kind == second.kind and
        std.mem.eql(u8, first.bundle, second.bundle) and std.mem.eql(u8, first.value, second.value) and
        std.mem.eql(u8, first.role, second.role) and std.mem.eql(u8, first.subrole, second.subrole);
}

pub fn match(saved: []const StableKey, current: []const StableKey) !MatchResult {
    if (saved.len > max_windows or current.len > max_windows) return error.Capacity;
    for (saved) |key| try validateKey(key);
    for (current) |key| try validateKey(key);
    var result = MatchResult{};
    for (saved, 0..) |key, saved_index| {
        var saved_count: usize = 0;
        var current_count: usize = 0;
        var current_index: usize = 0;
        for (saved) |candidate| {
            if (equalKey(key, candidate)) saved_count += 1;
        }
        for (current, 0..) |candidate, index| {
            if (equalKey(key, candidate)) {
                current_count += 1;
                current_index = index;
            }
        }
        if (saved_count != 1) {
            result.ambiguous_saved += 1;
        } else if (current_count > 1) {
            result.ambiguous_current += 1;
        } else if (current_count == 0) {
            result.missing += 1;
        } else {
            result.pairs[result.count] = .{ .saved = @intCast(saved_index), .current = @intCast(current_index) };
            result.count += 1;
        }
    }
    return result;
}
