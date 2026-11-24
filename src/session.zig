const std = @import("std");

pub const max_bytes = 4 * 1024 * 1024;
pub const max_windows = 1024;
pub const max_nodes = 2047;
pub const max_roots = 320;
pub const max_edges = 2046;
pub const max_homes = 10;
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
pub extern "c" fn huen_session_display_uuid(display: u32, output: [*]u8, capacity: usize) bool;
pub extern "c" fn huen_session_boot_identity(output: [*]u8, capacity: usize) bool;
pub extern "c" fn huen_session_read(stem: [*:0]const u8, hash: [*:0]const u8, output: [*]u8, capacity: usize, used: *usize) c_int;
pub extern "c" fn huen_session_write(stem: [*:0]const u8, hash: [*:0]const u8, bytes: [*]const u8, length: usize, durable: bool) bool;
pub extern "c" fn huen_journal_append(line: [*]const u8, length: usize) bool;

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
// A runtime workspace home set by an explicit workspace move. Checkpoints written before homes
// existed omit the field and restore without homes.
pub const Home = struct {
    workspace: []const u8,
    occurrence: LogicalIndex = 0,
    display_hint: []const u8,
};
pub const Snapshot = struct {
    version: u32,
    clean: bool = false,
    scope: Scope,
    windows: []const Window,
    nodes: []const NodeShape,
    roots: []const Root,
    homes: []const Home = &.{},
};
pub const Diagnostic = enum { none, ready, rejected };
pub const Rejection = enum { storage, schema, scope, unclean };
pub const Loaded = struct {
    diagnostic: Diagnostic,
    rejection: ?Rejection = null,
    parsed: ?std.json.Parsed(Snapshot) = null,
};

pub fn load(allocator: std.mem.Allocator, scope: Scope) Loaded {
    const hash = scopeHash(scope) catch return .{ .diagnostic = .rejected, .rejection = .scope };
    const bytes = allocator.alloc(u8, max_bytes) catch return .{ .diagnostic = .rejected, .rejection = .storage };
    defer allocator.free(bytes);
    var used: usize = 0;
    switch (huen_session_read("session", &hash, bytes.ptr, bytes.len, &used)) {
        0 => {},
        1 => return .{ .diagnostic = .none },
        else => return .{ .diagnostic = .rejected, .rejection = .storage },
    }
    const parsed = std.json.parseFromSlice(Snapshot, allocator, bytes[0..used], .{ .allocate = .alloc_always, .max_value_len = max_bytes }) catch
        return .{ .diagnostic = .rejected, .rejection = .schema };
    const rejection: Rejection = rejection: {
        validate(parsed.value) catch break :rejection .schema;
        const saved = parsed.value.scope;
        if (!std.mem.eql(u8, saved.config, scope.config) or !std.mem.eql(u8, saved.filter, scope.filter) or !std.mem.eql(u8, saved.boot, scope.boot)) break :rejection .scope;
        if (parsed.value.clean) return .{ .diagnostic = .ready, .parsed = parsed };
        break :rejection .unclean;
    };
    parsed.deinit();
    return .{ .diagnostic = .rejected, .rejection = rejection };
}

pub fn save(allocator: std.mem.Allocator, checkpoint: Snapshot) !void {
    const hash = try scopeHash(checkpoint.scope);
    const bytes = try std.json.Stringify.valueAlloc(allocator, checkpoint, .{});
    defer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.TooLarge;
    if (!huen_session_write("session", &hash, bytes.ptr, bytes.len, true)) return error.Storage;
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

pub fn scopeHash(scope: Scope) ![64:0]u8 {
    try validateScope(scope);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("HuenWM-session-v1\x00");
    hasher.update(scope.config);
    hasher.update("\x00");
    hasher.update(scope.filter);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower) ++ [_:0]u8{};
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
        checkpoint.roots.len > max_roots or checkpoint.homes.len > max_homes) return error.Capacity;
    for (checkpoint.homes, 0..) |home, home_index| {
        if (!textValid(home.workspace, 64, false) or !textValid(home.display_hint, 128, false)) return error.InvalidHome;
        for (checkpoint.homes[0..home_index]) |previous| {
            if (previous.occurrence == home.occurrence and std.mem.eql(u8, previous.workspace, home.workspace)) return error.DuplicateHome;
        }
    }
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
    for (checkpoint.nodes) |*node| {
        const children: []const LogicalIndex = switch (node.*) {
            .leaf => continue,
            .split => |*split| if (ratioValid(split.ratio)) &split.children else return error.InvalidRatio,
            .group => |group| if (group.children.len >= 2 and group.children.len <= max_windows and group.selected < group.children.len) group.children else return error.InvalidGroup,
        };
        for (children) |child| {
            if (child >= checkpoint.nodes.len or parents[child]) return error.DuplicateParent;
            parents[child] = true;
            edge_count += 1;
            if (edge_count > max_edges) return error.Capacity;
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
            const children: []const LogicalIndex = switch (checkpoint.nodes[index]) {
                .leaf => |window| {
                    if (window >= checkpoint.windows.len or leaves[window] or
                        checkpoint.windows[window].floating or checkpoint.windows[window].root != root_index)
                        return error.InvalidLeaf;
                    leaves[window] = true;
                    continue;
                },
                .split => |*split| &split.children,
                .group => |group| group.children,
            };
            for (children) |child| {
                if (pending == max_nodes) return error.Capacity;
                stack[pending] = child;
                pending += 1;
            }
        }
        if (root.selection) |selection| {
            if (selection >= checkpoint.nodes.len or owners[selection] != @as(LogicalIndex, @intCast(root_index))) return error.InvalidSelection;
        }
    }
    for (owners[0..checkpoint.nodes.len]) |owner| if (owner == null) return error.OrphanNode;
}
