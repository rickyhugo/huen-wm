const std = @import("std");
const session = @import("session.zig");
const layout = @import("layout.zig");
const config_module = @import("config.zig");
const native = @import("native.zig");
const allocator = std.heap.c_allocator;

pub const LiveWindow = struct {
    identity: u64,
    display: u32,
    workspace: usize,
    floating: bool,
    frame: native.WMRect,
    attributes: session.NativeAttributes,
};
pub const Screen = struct { identity: u32, workspace: usize, frame: native.WMRect, hint: [128]u8 };
pub const Assignment = struct { identity: u64, display: u32, workspace: usize, floating: bool, frame: ?native.WMRect };
pub const Active = struct { display: u32, workspace: usize };
pub const Imported = struct {
    store: *layout.Store,
    assignments: []Assignment,
    active: []Active,
    matched: usize,
    missing: usize,
    ambiguous: usize,

    pub fn deinit(self: Imported) void {
        allocator.destroy(self.store);
        allocator.free(self.assignments);
        allocator.free(self.active);
    }
};
pub const Frozen = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: session.Snapshot,

    pub fn deinit(self: *Frozen) void {
        self.arena.deinit();
    }
};

fn text(buffer: anytype) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}
fn screenFor(screens: []const Screen, identity: u32) ?Screen {
    for (screens) |screen| if (screen.identity == identity) return screen;
    return null;
}
fn indexOfWindow(windows: []const LiveWindow, identity: ?u64) ?u16 {
    for (windows, 0..) |window, index| if (identity == window.identity) return @intCast(index);
    return null;
}
fn occurrence(config: *const config_module.ConfigCandidate, workspace: usize) u16 {
    var count: u16 = 0;
    for (config.workspaces[0..workspace]) |previous| if (std.mem.eql(u8, text(&previous.name), text(&config.workspaces[workspace].name))) {
        count += 1;
    };
    return count;
}
fn workspaceIndex(config: *const config_module.ConfigCandidate, name: []const u8, ordinal: u16) ?usize {
    var count: u16 = 0;
    for (config.workspaces[0..config.workspace_count], 0..) |candidate, index| {
        if (!std.mem.eql(u8, name, text(&candidate.name))) continue;
        if (count == ordinal) return index;
        count += 1;
    }
    return null;
}

pub fn freeze(store: *const layout.Store, windows: []const LiveWindow, screens: []const Screen, config: *const config_module.ConfigCandidate, scope: session.Scope) !Frozen {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const temporary = try memory.create(layout.Store);
    temporary.* = store.*;
    for (store.nodes) |node| {
        if (node.content == .leaf and indexOfWindow(windows, node.content.leaf) == null) temporary.removeIdentity(node.content.leaf);
    }
    const nodes = try memory.alloc(session.NodeShape, 2047);
    const roots = try memory.alloc(session.Root, 320);
    const saved_windows = try memory.alloc(session.Window, windows.len);
    var node_map: [2047]?u16 = @splat(null);
    var root_map: [320]?u16 = @splat(null);
    var node_count: usize = 0;
    var root_count: usize = 0;
    for (temporary.nodes, 0..) |node, index| if (node.content != .free) {
        node_map[index] = @intCast(node_count);
        node_count += 1;
    };
    for (temporary.roots, 0..) |slot, index| if (slot) |state| {
        const screen = screenFor(screens, state.display) orelse continue;
        const defaults = config.workspaces[state.workspace];
        root_map[index] = @intCast(root_count);
        roots[root_count] = .{
            .workspace = try memory.dupe(u8, text(&defaults.name)),
            .occurrence = occurrence(config, state.workspace),
            .display_hint = try memory.dupe(u8, text(&screen.hint)),
            .active = screen.workspace == state.workspace,
            .default_layout = @fromBackingInt(@intCast(@backingInt(defaults.layout))),
            .default_ratio = defaults.ratio,
            .defaults_fingerprint = "config-scope-v1",
            .layout = @fromBackingInt(@intCast(@backingInt(state.layout))),
            .ratio = state.ratio,
            .node = if (state.root) |root| node_map[root] else null,
            .selection = if (state.selection) |selection| if (temporary.resolve(selection)) |handle| node_map[handle] else |_| null else null,
            .focused = indexOfWindow(windows, state.last_focused),
            .fullscreen = indexOfWindow(windows, state.fullscreen),
        };
        root_count += 1;
    };
    for (windows, 0..) |window, index| {
        var root_index: ?u16 = null;
        for (temporary.roots, 0..) |slot, slot_index| if (slot) |state| {
            if (state.display == window.display and state.workspace == window.workspace) root_index = root_map[slot_index];
        };
        const screen = screenFor(screens, window.display) orelse return error.MissingDisplay;
        const attributes = try memory.create(session.NativeAttributes);
        attributes.* = window.attributes;
        saved_windows[index] = .{
            .key = try attributes.key(),
            .root = root_index orelse return error.MissingRoot,
            .display_hint = try memory.dupe(u8, text(&screen.hint)),
            .floating = window.floating,
            .floating_frame = if (window.floating) .{ .left = window.frame.left - screen.frame.left, .top = window.frame.top - screen.frame.top, .width = window.frame.width, .height = window.frame.height } else null,
        };
    }
    for (temporary.nodes, 0..) |node, index| {
        const destination = node_map[index] orelse continue;
        nodes[destination] = switch (node.content) {
            .free => unreachable,
            .leaf => |identity| .{ .leaf = indexOfWindow(windows, identity).? },
            .branch => |branch| .{ .split = .{ .axis = @fromBackingInt(@intCast(@backingInt(branch.axis))), .ratio = branch.ratio, .children = .{ node_map[branch.children[0]].?, node_map[branch.children[1]].? }, .selected = if (node.last_child == branch.children[1]) 1 else 0 } },
            .group => |group| group: {
                const children = try memory.alloc(u16, group.count);
                var child = group.first;
                var selected: u16 = 0;
                for (children, 0..) |*output, ordinal| {
                    output.* = node_map[child].?;
                    if (child == group.selected) selected = @intCast(ordinal);
                    if (temporary.nodes[child].next) |next| child = next;
                }
                break :group .{ .group = .{ .mode = @fromBackingInt(@intCast(@backingInt(group.mode))), .children = children, .selected = selected } };
            },
        };
    }
    const snapshot = session.Snapshot{ .version = 1, .clean = true, .scope = .{ .config = try memory.dupe(u8, scope.config), .filter = try memory.dupe(u8, scope.filter), .boot = try memory.dupe(u8, scope.boot) }, .windows = saved_windows, .nodes = nodes[0..node_count], .roots = roots[0..root_count] };
    try session.validate(snapshot);
    return .{ .arena = arena, .snapshot = snapshot };
}

pub fn restore(snapshot: *const session.Snapshot, windows: []const LiveWindow, screens: []const Screen, config: *const config_module.ConfigCandidate, owner: ?u32) !Imported {
    var saved_keys: [1024]session.StableKey = undefined;
    var current_keys: [1024]session.StableKey = undefined;
    for (snapshot.windows, 0..) |window, index| saved_keys[index] = window.key;
    for (windows, 0..) |*window, index| current_keys[index] = try window.attributes.key();
    const matches = try session.match(saved_keys[0..snapshot.windows.len], current_keys[0..windows.len]);
    var mapping: [1024]?usize = @splat(null);
    for (matches.pairs[0..matches.count]) |pair| mapping[pair.saved] = pair.current;
    const logical = try allocator.create(layout.Snapshot);
    defer allocator.destroy(logical);
    logical.* = .{ .nodes = @splat(.{}), .roots = @splat(null) };
    for (snapshot.nodes, 0..) |shape, index| {
        logical.nodes[index].generation = 1;
        switch (shape) {
            .leaf => |window_index| logical.nodes[index].content = .{ .leaf = if (mapping[window_index]) |current| windows[current].identity else @as(u64, std.math.maxInt(u64)) - window_index },
            .split => |split| {
                logical.nodes[index].content = .{ .branch = .{ .axis = @fromBackingInt(@intCast(@backingInt(split.axis))), .ratio = split.ratio, .children = split.children } };
                logical.nodes[index].last_child = split.children[split.selected];
                for (split.children) |child| logical.nodes[child].parent = @intCast(index);
            },
            .group => |group| {
                logical.nodes[index].content = .{ .group = .{ .mode = @fromBackingInt(@intCast(@backingInt(group.mode))), .first = group.children[0], .last = group.children[group.children.len - 1], .selected = group.children[group.selected], .count = @intCast(group.children.len) } };
                logical.nodes[index].last_child = group.children[group.selected];
                for (group.children, 0..) |child, ordinal| {
                    logical.nodes[child].parent = @intCast(index);
                    logical.nodes[child].previous = if (ordinal > 0) group.children[ordinal - 1] else null;
                    logical.nodes[child].next = if (ordinal + 1 < group.children.len) group.children[ordinal + 1] else null;
                }
            },
        }
    }
    for (snapshot.roots, 0..) |root, index| {
        logical.roots[index] = .{ .display = @intCast(index + 1), .workspace = 0, .layout = @fromBackingInt(@intCast(@backingInt(root.layout))), .ratio = root.ratio, .root = root.node, .selection = if (root.selection) |selection| .{ .slot = selection, .generation = 1 } else null, .last_focused = mappedIdentity(windows, &mapping, root.focused), .fullscreen = mappedIdentity(windows, &mapping, root.fullscreen) };
    }
    const store = try allocator.create(layout.Store);
    errdefer allocator.destroy(store);
    store.* = .{};
    try store.importSnapshot(logical);
    for (snapshot.windows, 0..) |_, index| if (mapping[index] == null) store.removeIdentity(std.math.maxInt(u64) - index);
    var destinations: [320]?struct { display: u32, workspace: usize } = @splat(null);
    for (&store.roots, 0..) |*slot, index| {
        const state = if (slot.*) |*state| state else continue;
        const root = snapshot.roots[index];
        const workspace = workspaceIndex(config, root.workspace, root.occurrence);
        var display = owner;
        if (display == null) for (screens) |screen| {
            if (std.mem.eql(u8, text(&screen.hint), root.display_hint) and root.display_hint.len != 0) {
                display = screen.identity;
                break;
            }
        };
        if (display == null and screens.len > 0) display = screens[0].identity;
        var valid = workspace != null and display != null;
        if (workspace) |workspace_index| {
            const defaults = config.workspaces[workspace_index];
            if (@backingInt(defaults.layout) != @backingInt(root.default_layout) or defaults.ratio != root.default_ratio) valid = false;
            for (destinations[0..index], 0..) |destination, previous_index| if (destination) |previous| {
                if (previous.display != display or previous.workspace != workspace_index) continue;
                if (!rootHasIntent(snapshot, &mapping, previous_index) and rootHasIntent(snapshot, &mapping, index)) {
                    if (store.roots[previous_index]) |*previous_state| store.discard(previous_state);
                    store.roots[previous_index] = null;
                    destinations[previous_index] = null;
                } else valid = false;
            };
        }
        if (!valid) {
            store.discard(state);
            slot.* = null;
            continue;
        }
        state.display = display.?;
        state.workspace = workspace.?;
        destinations[index] = .{ .display = display.?, .workspace = workspace.? };
    }
    var assignments: std.ArrayList(Assignment) = .empty;
    errdefer assignments.deinit(allocator);
    for (snapshot.windows, 0..) |saved, index| {
        const current = mapping[index] orelse continue;
        const destination = destinations[saved.root] orelse continue;
        const screen = screenFor(screens, destination.display) orelse continue;
        try assignments.append(allocator, .{ .identity = windows[current].identity, .display = destination.display, .workspace = destination.workspace, .floating = saved.floating, .frame = if (saved.floating_frame) |frame| .{ .left = frame.left + screen.frame.left, .top = frame.top + screen.frame.top, .width = frame.width, .height = frame.height } else null });
    }
    var active: std.ArrayList(Active) = .empty;
    errdefer active.deinit(allocator);
    for (snapshot.roots, 0..) |root, index| {
        const destination = destinations[index] orelse continue;
        if (root.active) try active.append(allocator, .{ .display = destination.display, .workspace = destination.workspace });
    }
    const matched = assignments.items.len;
    const owned_assignments = try assignments.toOwnedSlice(allocator);
    errdefer allocator.free(owned_assignments);
    return .{ .store = store, .assignments = owned_assignments, .active = try active.toOwnedSlice(allocator), .matched = matched, .missing = matches.missing, .ambiguous = matches.ambiguous_saved + matches.ambiguous_current };
}

fn mappedIdentity(windows: []const LiveWindow, mapping: []const ?usize, index: ?u16) ?u64 {
    const saved = index orelse return null;
    const current = mapping[saved] orelse return null;
    return windows[current].identity;
}

fn rootHasIntent(snapshot: *const session.Snapshot, mapping: []const ?usize, index: usize) bool {
    const root = snapshot.roots[index];
    if (root.layout != root.default_layout or root.ratio != root.default_ratio) return true;
    for (snapshot.windows, 0..) |window, window_index| {
        if (window.root == index and mapping[window_index] != null) return true;
    }
    return false;
}
