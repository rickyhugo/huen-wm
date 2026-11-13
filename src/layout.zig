const std = @import("std");
const commands = @import("command.zig");
pub const Rect = @import("native.zig").WMRect;
const Axis = commands.Axis;
pub const Handle = u16;
pub const NodeRef = struct { slot: Handle, generation: u64 };
pub const Branch = struct { axis: Axis, ratio: f64, children: [2]Handle };
pub const Group = struct { mode: commands.GroupMode, first: Handle, last: Handle, selected: Handle, count: u16 };
pub const Node = struct {
    generation: u64 = 0,
    parent: ?Handle = null,
    previous: ?Handle = null,
    next: ?Handle = null,
    last_child: ?Handle = null,
    content: union(enum) { free, leaf: u64, branch: Branch, group: Group } = .free,
    active: bool = false,
    visible: bool = false,
    frame: Rect = std.mem.zeroes(Rect),
    minimum: [2]f64 = .{ 0, 0 },
};

pub const Member = struct { identity: u64, display: u32, workspace: usize, active: bool, tiled: bool, area: Rect };
pub const WorkspaceLayout = struct {
    display: u32,
    workspace: usize,
    layout: commands.Layout,
    ratio: f64,
    root: ?Handle = null,
    fullscreen: ?u64 = null,
    last_focused: ?u64 = null,
    selection: ?NodeRef = null,
    projection_gap: f64 = 0,
    projected_layout: ?commands.Layout = null,
};
pub const Visibility = union(enum) { visible: Rect, hidden_by_group, unavailable };
pub const Header = struct { group: NodeRef, child: NodeRef, rect: Rect, selected: bool, eligible: bool, revision: u64 };
pub const Boundary = struct { node: NodeRef, axis: Axis, rect: Rect, revision: u64 };
pub const Hit = union(enum) { tile: NodeRef, header: Header, boundary: Boundary };
pub const Drop = enum { left, right, up, down, join, swap };
pub const ResizePreview = struct { boundary: Boundary, ratio: f64, applied_delta: f64 };
pub const MovePreview = struct { source: NodeRef, target: NodeRef, placement: Drop, rect: Rect, revision: u64 };
pub const Snapshot = struct {
    nodes: [2047]Node,
    roots: [320]?WorkspaceLayout,
};

pub const Store = struct {
    nodes: [2047]Node = @splat(.{}),
    roots: [320]?WorkspaceLayout = @splat(null),
    serial: u64 = 1,
    revision: u64 = 1,

    pub fn reference(self: *const Store, handle: Handle) NodeRef {
        return .{ .slot = handle, .generation = self.nodes[handle].generation };
    }

    pub fn resolve(self: *const Store, reference_value: NodeRef) !Handle {
        if (reference_value.slot >= self.nodes.len) return error.StaleNode;
        const node = self.nodes[reference_value.slot];
        if (node.content == .free or node.generation != reference_value.generation) return error.StaleNode;
        return reference_value.slot;
    }

    fn allocate(self: *Store) !Handle {
        for (&self.nodes, 0..) |*node, index| if (node.content == .free) {
            self.serial +%= 1;
            node.* = .{ .generation = self.serial };
            return @intCast(index);
        };
        return error.LayoutCapacityExceeded;
    }

    fn firstChild(self: *const Store, handle: Handle) ?Handle {
        return switch (self.nodes[handle].content) {
            .branch => |branch| branch.children[0],
            .group => |group| group.first,
            else => null,
        };
    }

    fn nextChild(self: *const Store, parent: Handle, child: Handle) ?Handle {
        return switch (self.nodes[parent].content) {
            .branch => |branch| if (branch.children[0] == child) branch.children[1] else null,
            .group => self.nodes[child].next,
            else => null,
        };
    }

    fn replace(self: *Store, state: *WorkspaceLayout, old: Handle, replacement: Handle) void {
        const parent = self.nodes[old].parent;
        self.nodes[replacement].parent = parent;
        if (parent) |ancestor| {
            var node = &self.nodes[ancestor];
            if (node.last_child == old) node.last_child = replacement;
            switch (node.content) {
                .branch => |*branch| branch.children[if (branch.children[0] == old) @as(usize, 0) else 1] = replacement,
                .group => |*group| {
                    const previous = self.nodes[old].previous;
                    const next = self.nodes[old].next;
                    self.nodes[replacement].previous = previous;
                    self.nodes[replacement].next = next;
                    if (previous) |sibling| self.nodes[sibling].next = replacement else group.first = replacement;
                    if (next) |sibling| self.nodes[sibling].previous = replacement else group.last = replacement;
                    if (group.selected == old) group.selected = replacement;
                },
                else => unreachable,
            }
        } else state.root = replacement;
    }

    fn detach(self: *Store, state: *WorkspaceLayout, handle: Handle) void {
        if (self.nodes[handle].parent) |parent| {
            const content = self.nodes[parent].content;
            if (content == .branch) {
                const sibling = content.branch.children[if (content.branch.children[0] == handle) @as(usize, 1) else 0];
                self.replace(state, parent, sibling);
                self.nodes[parent] = .{};
            } else {
                var group = &self.nodes[parent].content.group;
                const previous = self.nodes[handle].previous;
                const next = self.nodes[handle].next;
                if (previous) |sibling| self.nodes[sibling].next = next else group.first = next.?;
                if (next) |sibling| self.nodes[sibling].previous = previous else group.last = previous.?;
                group.count -= 1;
                if (group.selected == handle) group.selected = next orelse group.first;
                if (self.nodes[parent].last_child == handle) self.nodes[parent].last_child = group.selected;
                if (group.count == 1) {
                    const remaining = group.first;
                    self.replace(state, parent, remaining);
                    if (self.nodes[remaining].parent == null or self.nodes[self.nodes[remaining].parent.?].content != .group) {
                        self.nodes[remaining].previous = null;
                        self.nodes[remaining].next = null;
                    }
                    self.nodes[parent] = .{};
                }
            }
        } else state.root = null;
        self.nodes[handle].parent = null;
        self.nodes[handle].previous = null;
        self.nodes[handle].next = null;
        self.revision +%= 1;
    }

    pub fn lookup(self: *Store, display: u32, index: usize) ?*WorkspaceLayout {
        for (&self.roots) |*slot| if (slot.*) |*state| {
            if (state.display == display and state.workspace == index) return state;
        };
        return null;
    }

    pub fn workspace(self: *Store, display: u32, index: usize, default_layout: commands.Layout, default_ratio: f64) *WorkspaceLayout {
        if (self.lookup(display, index)) |state| return state;
        for (&self.roots) |*slot| if (slot.* == null) {
            slot.* = .{ .display = display, .workspace = index, .layout = default_layout, .ratio = default_ratio };
            return &slot.*.?;
        };
        unreachable;
    }

    pub fn discard(self: *Store, state: *WorkspaceLayout) void {
        if (state.root) |root| self.release(root);
        state.root = null;
        state.fullscreen = null;
        state.last_focused = null;
        state.selection = null;
        self.revision +%= 1;
    }

    fn release(self: *Store, handle: Handle) void {
        var child = self.firstChild(handle);
        while (child) |current| {
            child = self.nextChild(handle, current);
            self.release(current);
        }
        self.nodes[handle] = .{};
    }

    fn leaf(self: *const Store, identity: u64) ?Handle {
        for (&self.nodes, 0..) |*node, index| if (node.content == .leaf and node.content.leaf == identity) return @intCast(index);
        return null;
    }

    fn rootOf(self: *const Store, handle: Handle) Handle {
        var current = handle;
        while (self.nodes[current].parent) |parent| current = parent;
        return current;
    }

    fn remove(self: *Store, state: *WorkspaceLayout, handle: Handle) void {
        self.detach(state, handle);
        self.nodes[handle] = .{};
    }

    pub fn sync(self: *Store, members: []const Member, focused: ?u64, gap: f64) !void {
        for (&self.roots) |*slot| if (slot.*) |*state| {
            if (state.last_focused) |identity| {
                var retained = false;
                for (members) |member| if (member.identity == identity and member.display == state.display and member.workspace == state.workspace) {
                    retained = true;
                    break;
                };
                if (!retained) state.last_focused = null;
            }
            if (state.fullscreen) |identity| {
                var retained = false;
                for (members) |member| if (member.identity == identity and member.display == state.display and member.workspace == state.workspace) {
                    retained = true;
                    break;
                };
                if (!retained) state.fullscreen = null;
            }
        };
        for (&self.nodes, 0..) |*node, index| {
            if (node.content != .leaf) continue;
            const root = self.rootOf(@intCast(index));
            for (&self.roots) |*slot| if (slot.*) |*state| {
                if (state.root != root) continue;
                var retained = false;
                for (members) |member| if (member.tiled and member.identity == node.content.leaf and member.display == state.display and member.workspace == state.workspace) {
                    if (node.active != member.active) self.revision +%= 1;
                    node.active = member.active;
                    retained = true;
                    break;
                };
                if (!retained) self.remove(state, @intCast(index));
                break;
            };
        }
        for (members) |member| {
            if (!member.tiled) continue;
            if (self.leaf(member.identity) != null) continue;
            const destination = self.lookup(member.display, member.workspace) orelse return error.MissingLayoutRoot;
            var available: [2]Handle = undefined;
            var count: usize = 0;
            const needed: usize = if (destination.root == null) 1 else 2;
            for (&self.nodes, 0..) |*node, index| if (node.content == .free) {
                available[count] = @intCast(index);
                count += 1;
                if (count == needed) break;
            };
            if (count < needed) return error.LayoutCapacityExceeded;
            const added = available[0];
            if (destination.root) |root| {
                var target = if (focused) |identity| self.leaf(identity) orelse root else root;
                if (self.rootOf(target) != root) target = root;
                while (self.firstChild(target)) |first| target = switch (self.nodes[target].content) {
                    .branch => |branch| branch.children[1],
                    .group => |group| group.selected,
                    else => first,
                };
                const frame = self.nodes[target].frame;
                const bounds = if (frame.width > 0 and frame.height > 0) frame else member.area;
                const branch = available[1];
                self.serial +%= 1;
                self.nodes[branch] = .{ .generation = self.serial, .content = .{ .branch = .{ .axis = if (bounds.width >= bounds.height) .width else .height, .ratio = if (self.nodes[target].parent == null) destination.ratio else 0.5, .children = .{ target, added } } } };
                self.replace(destination, target, branch);
                self.nodes[target].parent = branch;
                self.nodes[target].previous = null;
                self.nodes[target].next = null;
                self.serial +%= 1;
                self.nodes[added] = .{ .generation = self.serial, .parent = branch, .content = .{ .leaf = member.identity }, .active = member.active };
            } else {
                self.serial +%= 1;
                self.nodes[added] = .{ .generation = self.serial, .content = .{ .leaf = member.identity }, .active = member.active };
                destination.root = added;
            }
            self.revision +%= 1;
            self.arrange(destination, member.area, gap);
        }
        for (&self.roots) |*slot| if (slot.*) |*state| {
            if (state.selection) |selection| {
                const handle = self.resolve(selection) catch {
                    state.selection = null;
                    continue;
                };
                if (state.root != self.rootOf(handle)) state.selection = null;
            }
        };
    }

    fn measure(self: *Store, handle: Handle, gap: f64) void {
        var node = &self.nodes[handle];
        switch (node.content) {
            .leaf => node.minimum = if (node.active) .{ 80, 80 } else .{ 0, 0 },
            .branch => |branch| {
                for (branch.children) |child| self.measure(child, gap);
                const first = self.nodes[branch.children[0]];
                const second = self.nodes[branch.children[1]];
                node.active = first.active or second.active;
                if (!first.active) {
                    node.minimum = second.minimum;
                } else if (!second.active) {
                    node.minimum = first.minimum;
                } else {
                    node.minimum = .{ @max(first.minimum[0], second.minimum[0]), @max(first.minimum[1], second.minimum[1]) };
                    const dimension: usize = if (branch.axis == .width) 0 else 1;
                    node.minimum[dimension] = @max(first.minimum[dimension] / branch.ratio, second.minimum[dimension] / (1 - branch.ratio)) + gap;
                }
            },
            .group => |*group| {
                node.active = false;
                node.minimum = .{ 0, 0 };
                var selected_active = false;
                var child: ?Handle = group.first;
                while (child) |current| : (child = self.nodes[current].next) {
                    self.measure(current, gap);
                    const member = self.nodes[current];
                    if (!member.active) continue;
                    if (current == group.selected) selected_active = true;
                    node.active = true;
                }
                if (!selected_active and node.active) {
                    var candidate = group.selected;
                    var remaining: usize = group.count;
                    while (remaining > 0) : (remaining -= 1) {
                        candidate = self.nodes[candidate].next orelse group.first;
                        if (self.nodes[candidate].active) {
                            group.selected = candidate;
                            break;
                        }
                    }
                }
                if (node.active) {
                    node.minimum = self.nodes[group.selected].minimum;
                    node.minimum[1] += 24 * @as(f64, @floatFromInt(if (group.mode == .tabbed) @as(usize, 1) else group.count));
                }
            },
            .free => unreachable,
        }
    }

    fn project(self: *Store, handle: Handle, frame: Rect, gap: f64) void {
        var node = &self.nodes[handle];
        node.frame = frame;
        node.visible = node.active;
        if (node.content == .group) {
            const group = node.content.group;
            const header_height = self.headerHeight(handle);
            var content = frame;
            content.top += header_height;
            content.height = @max(0, content.height - header_height);
            if (self.nodes[group.selected].active) self.project(group.selected, content, gap);
            return;
        }
        if (node.content != .branch) return;
        const branch = node.content.branch;
        const first = branch.children[0];
        const second = branch.children[1];
        if (!self.nodes[first].active or !self.nodes[second].active) {
            if (self.nodes[first].active) self.project(first, frame, gap);
            if (self.nodes[second].active) self.project(second, frame, gap);
            return;
        }
        const halves = split(frame, branch.axis, branch.ratio, gap);
        self.project(first, halves[0], gap);
        self.project(second, halves[1], gap);
    }

    pub fn arrange(self: *Store, state: *WorkspaceLayout, frame: Rect, gap: f64) void {
        const root = state.root orelse return;
        if (!std.meta.eql(self.nodes[root].frame, frame) or state.projection_gap != gap or state.projected_layout != state.layout) self.revision +%= 1;
        state.projection_gap = gap;
        state.projected_layout = state.layout;
        self.clearVisibility(root);
        self.measure(root, gap);
        if (state.layout == .master) {
            var count: usize = 0;
            for (self.nodes, 0..) |node, index| if (node.content == .leaf and node.active and self.rootOf(@intCast(index)) == root) {
                count += 1;
            };
            var ordinal: usize = 0;
            self.projectMaster(root, frame, state.ratio, gap, count, &ordinal);
        } else self.project(root, frame, gap);
    }

    pub fn goal(self: *const Store, identity: u64) ?Rect {
        const handle = self.leaf(identity) orelse return null;
        return if (self.nodes[handle].active and self.nodes[handle].visible) self.nodes[handle].frame else null;
    }

    pub fn orient(self: *Store, identity: u64, orientation: commands.Orientation) !void {
        const handle = self.leaf(identity) orelse return error.WindowNotTiled;
        var ancestor = self.nodes[handle].parent;
        while (ancestor) |current| : (ancestor = self.nodes[current].parent) {
            if (self.nodes[current].content == .branch) break;
        }
        const parent = ancestor orelse return error.NoSplit;
        var branch = &self.nodes[parent].content.branch;
        branch.axis = switch (orientation) {
            .horizontal => .width,
            .vertical => .height,
            .toggle => if (branch.axis == .width) .height else .width,
        };
        self.revision +%= 1;
    }

    pub fn resizePoints(self: *Store, identity: u64, axis: Axis, delta: f64, gap: f64) !f64 {
        var child = self.leaf(identity) orelse return error.WindowNotTiled;
        while (self.nodes[child].parent) |parent| {
            const node = &self.nodes[parent];
            if (node.content != .branch) {
                child = parent;
                continue;
            }
            var branch = &node.content.branch;
            const first = branch.children[0];
            const second = branch.children[1];
            if (branch.axis == axis and self.nodes[first].active and self.nodes[second].active) {
                const dimension: usize = if (axis == .width) 0 else 1;
                const extent = if (axis == .width) node.frame.width else node.frame.height;
                const available = extent - @min(gap, @max(0, extent - 2));
                const minimum = self.nodes[first].minimum[dimension];
                const maximum = available - self.nodes[second].minimum[dimension];
                if (available <= 0 or maximum < minimum) return 0;
                const previous = available * branch.ratio;
                const sign: f64 = if (child == first) 1 else -1;
                const next = std.math.clamp(previous + sign * delta, minimum, maximum);
                branch.ratio = next / available;
                self.revision +%= 1;
                return (next - previous) * sign;
            }
            child = parent;
        }
        return 0;
    }

    pub fn adjustRatio(self: *Store, state: *WorkspaceLayout, delta: f64) void {
        if (state.layout == .dwindle) {
            if (state.root) |root| if (self.nodes[root].content == .branch) {
                state.ratio = self.nodes[root].content.branch.ratio;
            };
        }
        state.ratio = std.math.clamp(state.ratio + delta, 0.1, 0.9);
        self.revision +%= 1;
        if (state.layout == .dwindle) if (state.root) |root| if (self.nodes[root].content == .branch) {
            self.nodes[root].content.branch.ratio = state.ratio;
        };
    }

    fn clearVisibility(self: *Store, handle: Handle) void {
        self.nodes[handle].visible = false;
        var child = self.firstChild(handle);
        while (child) |current| : (child = self.nextChild(handle, current)) self.clearVisibility(current);
    }

    fn projectMaster(self: *Store, handle: Handle, frame: Rect, ratio: f64, gap: f64, count: usize, ordinal: *usize) void {
        var node = &self.nodes[handle];
        node.visible = node.active;
        node.frame = frame;
        if (node.content == .leaf and node.active) {
            if (count > 1) {
                const columns = split(frame, .width, ratio, gap);
                if (ordinal.* == 0) {
                    node.frame = columns[0];
                } else {
                    const rows: f64 = @floatFromInt(count - 1);
                    const spacing = @min(gap, columns[1].height / (2 * rows));
                    node.frame = columns[1];
                    node.frame.height = (columns[1].height - spacing * (rows - 1)) / rows;
                    node.frame.top += @as(f64, @floatFromInt(ordinal.* - 1)) * (node.frame.height + spacing);
                }
            }
            ordinal.* += 1;
            return;
        }
        var child = self.firstChild(handle);
        while (child) |current| : (child = self.nextChild(handle, current)) self.projectMaster(current, frame, ratio, gap, count, ordinal);
    }

    pub fn visibility(self: *const Store, identity: u64) Visibility {
        const handle = self.leaf(identity) orelse return .unavailable;
        const node = self.nodes[handle];
        if (!node.active) return .unavailable;
        return if (node.visible) .{ .visible = node.frame } else .hidden_by_group;
    }

    pub fn nodeForIdentity(self: *const Store, identity: u64) ?NodeRef {
        return self.reference(self.leaf(identity) orelse return null);
    }

    fn contains(self: *const Store, ancestor: Handle, descendant: Handle) bool {
        var current: ?Handle = descendant;
        while (current) |handle| : (current = self.nodes[handle].parent) if (handle == ancestor) return true;
        return false;
    }

    fn eligibleLeaf(self: *const Store, handle: Handle) ?u64 {
        const node = self.nodes[handle];
        if (node.content == .leaf) return if (node.active) node.content.leaf else null;
        if (node.last_child) |child| {
            if (self.eligibleLeaf(child)) |identity| return identity;
        }
        const group_child: ?Handle = if (node.content == .group) node.content.group.selected else null;
        if (group_child) |child| if (node.last_child != child) {
            if (self.eligibleLeaf(child)) |identity| return identity;
        };
        var child = self.firstChild(handle);
        while (child) |current| : (child = self.nextChild(handle, current)) {
            if (node.last_child == current or group_child == current) continue;
            if (self.eligibleLeaf(current)) |identity| return identity;
        }
        return null;
    }

    fn eligibleMember(state: *const WorkspaceLayout, members: []const Member, identity: u64) bool {
        for (members) |member| if (member.identity == identity and member.display == state.display and member.workspace == state.workspace and member.active) return true;
        return false;
    }

    pub fn focusCandidate(self: *const Store, state: *const WorkspaceLayout, members: []const Member) ?u64 {
        if (state.fullscreen) |identity| if (eligibleMember(state, members, identity)) return identity;
        if (state.last_focused) |identity| if (eligibleMember(state, members, identity)) return identity;
        if (state.root) |root| if (self.eligibleLeaf(root)) |identity| return identity;
        for (members) |member| if (member.display == state.display and member.workspace == state.workspace and member.active) return member.identity;
        return null;
    }

    /// Call only after the native adapter independently observed focus.
    pub fn rememberFocus(self: *Store, state: *WorkspaceLayout, identity: u64, members: []const Member) !void {
        if (!eligibleMember(state, members, identity)) return error.IneligibleFocus;
        const handle = self.leaf(identity) orelse {
            state.last_focused = identity;
            state.selection = null;
            return;
        };
        if (state.root != self.rootOf(handle)) return error.WrongWorkspace;
        state.last_focused = identity;
        state.selection = self.reference(handle);
        var child = handle;
        while (self.nodes[child].parent) |parent| {
            self.nodes[parent].last_child = child;
            child = parent;
        }
    }

    pub fn forgetIdentity(self: *Store, identity: u64) void {
        for (&self.roots) |*slot| if (slot.*) |*state| {
            if (state.last_focused == identity) state.last_focused = null;
            if (state.fullscreen == identity) state.fullscreen = null;
        };
    }

    pub fn removeIdentity(self: *Store, identity: u64) void {
        self.forgetIdentity(identity);
        const handle = self.leaf(identity) orelse return;
        const root = self.rootOf(handle);
        for (&self.roots) |*slot| if (slot.*) |*state| {
            if (state.root != root) continue;
            self.remove(state, handle);
            if (state.selection) |selection| {
                _ = self.resolve(selection) catch {
                    state.selection = null;
                    return;
                };
            }
            return;
        };
    }

    pub fn reveal(self: *Store, state: *WorkspaceLayout, identity: u64) !void {
        const handle = self.leaf(identity) orelse return;
        if (state.root != self.rootOf(handle)) return error.WrongWorkspace;
        var child = handle;
        while (self.nodes[child].parent) |parent| {
            if (self.nodes[parent].content == .group) self.nodes[parent].content.group.selected = child;
            self.nodes[parent].last_child = child;
            child = parent;
        }
        self.revision +%= 1;
    }

    pub fn selected(self: *const Store, state: *const WorkspaceLayout, focused: ?u64) !NodeRef {
        if (state.selection) |selection| {
            if (self.resolve(selection)) |handle| {
                if (state.root == self.rootOf(handle)) return selection;
            } else |_| {}
        }
        const identity = focused orelse state.last_focused orelse return error.NoSelection;
        const handle = self.leaf(identity) orelse return error.WindowNotTiled;
        if (state.root != self.rootOf(handle)) return error.WrongWorkspace;
        return self.reference(handle);
    }

    pub fn select(self: *Store, state: *WorkspaceLayout, focused: ?u64, direction: commands.Selection) !NodeRef {
        if (state.layout != .dwindle) return error.ContainerRequiresDwindle;
        const handle = try self.resolve(try self.selected(state, focused));
        const target = switch (direction) {
            .parent => self.nodes[handle].parent orelse return error.NoParent,
            .child => target: {
                if (self.nodes[handle].last_child) |child| if (self.nodes[child].parent == handle and self.eligibleLeaf(child) != null) break :target child;
                var child = self.firstChild(handle);
                while (child) |current| : (child = self.nextChild(handle, current)) if (self.eligibleLeaf(current) != null) break :target current;
                return error.NoChild;
            },
        };
        if (direction == .parent) self.nodes[target].last_child = handle;
        state.selection = self.reference(target);
        return state.selection.?;
    }

    fn editHandles(self: *const Store, state: *const WorkspaceLayout, source_ref: NodeRef, target_ref: NodeRef) !struct { source: Handle, target: Handle } {
        if (state.layout != .dwindle) return error.ContainerRequiresDwindle;
        const source = try self.resolve(source_ref);
        const target = try self.resolve(target_ref);
        if (state.root != self.rootOf(source) or state.root != self.rootOf(target)) return error.WrongWorkspace;
        if (self.contains(source, target) or self.contains(target, source)) return error.LayoutCycle;
        if (self.eligibleLeaf(source) == null or self.eligibleLeaf(target) == null) return error.NoTileTarget;
        return .{ .source = source, .target = target };
    }

    fn append(self: *Store, parent: Handle, child: Handle) void {
        var group = &self.nodes[parent].content.group;
        self.nodes[group.last].next = child;
        self.nodes[child].previous = group.last;
        self.nodes[child].next = null;
        self.nodes[child].parent = parent;
        group.last = child;
        group.selected = child;
        group.count += 1;
        self.nodes[parent].last_child = child;
    }

    pub fn drop(self: *Store, state: *WorkspaceLayout, source_ref: NodeRef, target_ref: NodeRef, placement: Drop) !void {
        const handles = try self.editHandles(state, source_ref, target_ref);
        const source = handles.source;
        const target = handles.target;
        if (placement == .swap) {
            if (self.nodes[source].content != .leaf or self.nodes[target].content != .leaf) return error.SwapRequiresLeaves;
            self.swap(self.nodes[source].content.leaf, self.nodes[target].content.leaf);
            state.selection = target_ref;
            return;
        }
        var free_count: usize = 0;
        for (self.nodes) |node| if (node.content == .free) {
            free_count += 1;
        };
        const existing_group = placement == .join and self.nodes[target].content == .group;
        const collapses = self.nodes[source].parent != null and (self.nodes[self.nodes[source].parent.?].content == .branch or self.nodes[self.nodes[source].parent.?].content.group.count == 2);
        if (!existing_group and free_count == 0 and !collapses) return error.LayoutCapacityExceeded;
        self.detach(state, source);
        if (existing_group) {
            self.append(target, source);
        } else {
            const container = self.allocate() catch unreachable;
            if (placement == .join) {
                self.nodes[container].content = .{ .group = .{ .mode = .tabbed, .first = target, .last = source, .selected = source, .count = 2 } };
            } else {
                const before = placement == .left or placement == .up;
                self.nodes[container].content = .{ .branch = .{
                    .axis = if (placement == .left or placement == .right) .width else .height,
                    .ratio = if (self.nodes[target].parent == null) state.ratio else 0.5,
                    .children = if (before) .{ source, target } else .{ target, source },
                } };
            }
            self.replace(state, target, container);
            self.nodes[target].parent = container;
            self.nodes[target].previous = null;
            self.nodes[target].next = if (placement == .join) source else null;
            self.nodes[source].parent = container;
            self.nodes[source].previous = if (placement == .join) target else null;
            self.nodes[container].last_child = source;
        }
        state.selection = self.reference(source);
        self.revision +%= 1;
    }

    pub fn directionalTarget(self: *const Store, state: *const WorkspaceLayout, source_ref: NodeRef, direction: commands.Direction) !NodeRef {
        const source = try self.resolve(source_ref);
        if (state.root != self.rootOf(source)) return error.WrongWorkspace;
        const frame = self.nodes[source].frame;
        var best: ?Handle = null;
        var best_score = std.math.inf(f64);
        for (self.nodes, 0..) |node, index| {
            if (node.content != .leaf or !node.active or !node.visible) continue;
            const target: Handle = @intCast(index);
            if (self.rootOf(target) != state.root or self.contains(source, target)) continue;
            const horizontal = direction == .left or direction == .right;
            const primary = if (horizontal) node.frame.left + node.frame.width / 2 - frame.left - frame.width / 2 else node.frame.top + node.frame.height / 2 - frame.top - frame.height / 2;
            const forward = if (direction == .left or direction == .up) -primary else primary;
            if (forward <= 0) continue;
            const perpendicular = if (horizontal) node.frame.top + node.frame.height / 2 - frame.top - frame.height / 2 else node.frame.left + node.frame.width / 2 - frame.left - frame.width / 2;
            const score = forward * forward + perpendicular * perpendicular * 4;
            if (score < best_score or (score == best_score and (best == null or node.content.leaf < self.nodes[best.?].content.leaf))) {
                best = target;
                best_score = score;
            }
        }
        return self.reference(best orelse return error.NoTileTarget);
    }

    pub fn tilemove(self: *Store, state: *WorkspaceLayout, focused: ?u64, direction: commands.Direction) !void {
        const source = try self.selected(state, focused);
        const target = try self.directionalTarget(state, source, direction);
        try self.drop(state, source, target, switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        });
    }

    fn selectedGroup(self: *const Store, handle: Handle) ?Handle {
        var current: ?Handle = handle;
        while (current) |ancestor| : (current = self.nodes[ancestor].parent) if (self.nodes[ancestor].content == .group) return ancestor;
        return null;
    }

    pub fn selectGroupChild(self: *Store, state: *WorkspaceLayout, group_ref: NodeRef, child_ref: NodeRef) !?u64 {
        if (state.layout != .dwindle) return error.ContainerRequiresDwindle;
        const parent = try self.resolve(group_ref);
        const child = try self.resolve(child_ref);
        if (state.root != self.rootOf(parent)) return error.WrongWorkspace;
        if (self.nodes[parent].content != .group or self.nodes[child].parent != parent) return error.InvalidGroupChild;
        const identity = self.eligibleLeaf(child) orelse return error.IneligibleFocus;
        self.nodes[parent].content.group.selected = child;
        self.nodes[parent].last_child = child;
        state.selection = child_ref;
        self.revision +%= 1;
        return identity;
    }

    pub fn activateHeader(self: *Store, state: *WorkspaceLayout, header: Header) !?u64 {
        if (header.revision != self.revision) return error.StaleGesture;
        return self.selectGroupChild(state, header.group, header.child);
    }

    pub fn editGroup(self: *Store, state: *WorkspaceLayout, focused: ?u64, action: commands.Group) !?u64 {
        if (state.layout != .dwindle) return error.ContainerRequiresDwindle;
        const source_ref = try self.selected(state, focused);
        var handle = try self.resolve(source_ref);
        switch (action) {
            .join => |direction| {
                var target = try self.resolve(try self.directionalTarget(state, source_ref, direction));
                if (self.selectedGroup(target)) |parent| if (!self.contains(parent, handle)) {
                    target = parent;
                };
                try self.drop(state, source_ref, self.reference(target), .join);
            },
            .tabbed, .stacked => {
                if (self.nodes[handle].content == .leaf) return error.NoContainer;
                const mode: commands.GroupMode = if (action == .tabbed) .tabbed else .stacked;
                switch (self.nodes[handle].content) {
                    .group => |*container| container.mode = mode,
                    .branch => |branch| {
                        const first = branch.children[0];
                        const second = branch.children[1];
                        const selected_child = self.nodes[handle].last_child orelse first;
                        self.nodes[first].previous = null;
                        self.nodes[first].next = second;
                        self.nodes[second].previous = first;
                        self.nodes[second].next = null;
                        self.nodes[handle].content = .{ .group = .{ .mode = mode, .first = first, .last = second, .selected = selected_child, .count = 2 } };
                    },
                    else => return error.NoContainer,
                }
                self.revision +%= 1;
            },
            .split => {
                if (self.nodes[handle].content != .group) return error.NoGroup;
                try self.ungroup(state, handle);
            },
            .next, .previous => {
                handle = self.selectedGroup(handle) orelse return error.NoGroup;
                const container = self.nodes[handle].content.group;
                var child = container.selected;
                var remaining: usize = container.count;
                while (remaining > 0) : (remaining -= 1) {
                    child = if (action == .next) self.nodes[child].next orelse container.first else self.nodes[child].previous orelse container.last;
                    if (self.eligibleLeaf(child) != null) return try self.selectGroupChild(state, self.reference(handle), self.reference(child));
                }
                return error.IneligibleFocus;
            },
        }
        return null;
    }

    fn ungroup(self: *Store, state: *WorkspaceLayout, handle: Handle) !void {
        const container = self.nodes[handle].content.group;
        var available: [1022]Handle = undefined;
        const needed = container.count - 2;
        var free_count: usize = 0;
        for (self.nodes, 0..) |node, index| {
            if (free_count == needed) break;
            if (node.content != .free) continue;
            available[free_count] = @intCast(index);
            free_count += 1;
        }
        if (free_count < needed) return error.LayoutCapacityExceeded;
        const remembered = self.nodes[handle].last_child orelse container.selected;
        var remembered_passed = false;
        var current = handle;
        var child = container.first;
        var remaining = container.count;
        while (remaining >= 2) : (remaining -= 1) {
            const next = self.nodes[child].next.?;
            const tail = if (remaining == 2) next else available[container.count - remaining];
            if (remaining > 2) {
                self.serial +%= 1;
                self.nodes[tail] = .{ .generation = self.serial };
            }
            self.nodes[current].content = .{ .branch = .{ .axis = .width, .ratio = if (current == handle and self.nodes[handle].parent == null) state.ratio else 0.5, .children = .{ child, tail } } };
            self.nodes[current].last_child = if (!remembered_passed and child != remembered) tail else child;
            if (child == remembered) remembered_passed = true;
            self.nodes[child].parent = current;
            self.nodes[child].previous = null;
            self.nodes[child].next = null;
            self.nodes[tail].parent = current;
            if (remaining == 2) {
                self.nodes[tail].previous = null;
                self.nodes[tail].next = null;
            }
            current = tail;
            child = next;
        }
        self.revision +%= 1;
    }

    fn headerHeight(self: *const Store, handle: Handle) f64 {
        const node = self.nodes[handle];
        const container = node.content.group;
        const rows: usize = if (container.mode == .tabbed) 1 else container.count;
        const minimum = self.nodes[container.selected].minimum[1];
        return @min(24 * @as(f64, @floatFromInt(rows)), @max(0, node.frame.height - minimum));
    }

    pub fn headers(self: *const Store, state: *const WorkspaceLayout, output: []Header) !usize {
        if (state.layout != .dwindle) return 0;
        var count: usize = 0;
        for (self.nodes, 0..) |node, index| {
            if (node.content != .group or !node.visible or state.root != self.rootOf(@intCast(index))) continue;
            const container = node.content.group;
            const height = self.headerHeight(@intCast(index));
            var offset: usize = 0;
            var child: ?Handle = container.first;
            while (child) |current| : (child = self.nodes[current].next) {
                if (count == output.len) return error.PresentationCapacityExceeded;
                var rect = node.frame;
                const divisor: f64 = @floatFromInt(container.count);
                const position: f64 = @floatFromInt(offset);
                if (container.mode == .tabbed) {
                    rect.width /= divisor;
                    rect.left += position * rect.width;
                    rect.height = height;
                } else {
                    rect.height = height / divisor;
                    rect.top += position * rect.height;
                }
                output[count] = .{ .group = self.reference(@intCast(index)), .child = self.reference(current), .rect = rect, .selected = current == container.selected, .eligible = self.nodes[current].active, .revision = self.revision };
                count += 1;
                offset += 1;
            }
        }
        return count;
    }

    pub fn representative(self: *const Store, reference_value: NodeRef) !?u64 {
        return self.eligibleLeaf(try self.resolve(reference_value));
    }

    fn rememberedLeaf(self: *const Store, ancestor: Handle) Handle {
        var handle = ancestor;
        while (self.nodes[handle].content != .leaf) {
            const node = self.nodes[handle];
            handle = node.last_child orelse if (node.content == .group) node.content.group.selected else self.firstChild(handle).?;
        }
        return handle;
    }

    pub fn labelIdentity(self: *const Store, reference_value: NodeRef) !u64 {
        return self.nodes[self.rememberedLeaf(try self.resolve(reference_value))].content.leaf;
    }

    pub fn hiddenLeaves(self: *const Store, state: *const WorkspaceLayout, output: []u64) !usize {
        var count: usize = 0;
        for (self.nodes, 0..) |node, index| {
            if (node.content != .leaf or !node.active or node.visible or state.root != self.rootOf(@intCast(index))) continue;
            if (count == output.len) return error.PresentationCapacityExceeded;
            output[count] = node.content.leaf;
            count += 1;
        }
        return count;
    }

    pub fn boundaries(self: *const Store, state: *const WorkspaceLayout, tolerance: f64, output: []Boundary) !usize {
        if (!std.math.isFinite(tolerance) or tolerance < 0 or tolerance > 80) return error.InvalidTolerance;
        if (state.layout != .dwindle) return 0;
        var count: usize = 0;
        for (self.nodes, 0..) |node, index| {
            if (node.content != .branch or !node.visible or state.root != self.rootOf(@intCast(index))) continue;
            const branch = node.content.branch;
            const first = self.nodes[branch.children[0]];
            const second = self.nodes[branch.children[1]];
            if (!first.visible or !second.visible) continue;
            var rect = node.frame;
            if (branch.axis == .width) {
                rect.left = first.frame.left + first.frame.width - tolerance;
                rect.width = @max(0, second.frame.left - first.frame.left - first.frame.width) + 2 * tolerance;
            } else {
                rect.top = first.frame.top + first.frame.height - tolerance;
                rect.height = @max(0, second.frame.top - first.frame.top - first.frame.height) + 2 * tolerance;
            }
            if (count == output.len) return error.PresentationCapacityExceeded;
            output[count] = .{ .node = self.reference(@intCast(index)), .axis = branch.axis, .rect = rect, .revision = self.revision };
            count += 1;
        }
        return count;
    }

    pub fn hitTest(self: *const Store, state: *const WorkspaceLayout, left: f64, top: f64, tolerance: f64) !?Hit {
        if (state.layout != .dwindle) return null;
        var header_buffer: [2047]Header = undefined;
        const header_count = try self.headers(state, &header_buffer);
        for (header_buffer[0..header_count]) |header| if (inside(header.rect, left, top)) return .{ .header = header };
        var boundary_buffer: [1023]Boundary = undefined;
        const boundary_count = try self.boundaries(state, tolerance, &boundary_buffer);
        var best: ?Boundary = null;
        var best_area = std.math.inf(f64);
        for (boundary_buffer[0..boundary_count]) |boundary| if (inside(boundary.rect, left, top)) {
            const area = boundary.rect.width * boundary.rect.height;
            if (area < best_area) {
                best = boundary;
                best_area = area;
            }
        };
        if (best) |boundary| return .{ .boundary = boundary };
        for (self.nodes, 0..) |node, index| {
            if (node.content == .leaf and node.active and node.visible and state.root == self.rootOf(@intCast(index)) and inside(node.frame, left, top)) return .{ .tile = self.reference(@intCast(index)) };
        }
        return null;
    }

    pub fn previewResize(self: *const Store, boundary: Boundary, delta: f64, gap: f64) !ResizePreview {
        if (!std.math.isFinite(delta) or !std.math.isFinite(gap) or gap < 0) return error.InvalidPointDelta;
        if (boundary.revision != self.revision) return error.StaleGesture;
        const handle = try self.resolve(boundary.node);
        const node = self.nodes[handle];
        if (node.content != .branch or node.content.branch.axis != boundary.axis or !node.visible) return error.StaleGesture;
        const branch = node.content.branch;
        const first = self.nodes[branch.children[0]];
        const second = self.nodes[branch.children[1]];
        if (!first.visible or !second.visible) return error.StaleGesture;
        const dimension: usize = if (branch.axis == .width) 0 else 1;
        const extent = if (branch.axis == .width) node.frame.width else node.frame.height;
        const available = extent - @min(gap, @max(0, extent - 2));
        const previous = available * branch.ratio;
        const minimum = first.minimum[dimension];
        const maximum = available - second.minimum[dimension];
        if (available <= 0 or maximum < minimum) return .{ .boundary = boundary, .ratio = branch.ratio, .applied_delta = 0 };
        const next = std.math.clamp(previous + delta, minimum, maximum);
        return .{ .boundary = boundary, .ratio = next / available, .applied_delta = next - previous };
    }

    pub fn commitResize(self: *Store, preview: ResizePreview, gap: f64) !void {
        const checked = try self.previewResize(preview.boundary, preview.applied_delta, gap);
        if (!std.math.isFinite(preview.ratio) or @abs(checked.ratio - preview.ratio) > 0.000001) return error.InvalidPreview;
        const handle = try self.resolve(preview.boundary.node);
        self.nodes[handle].content.branch.ratio = checked.ratio;
        self.revision +%= 1;
    }

    fn pointerDropHandles(self: *const Store, state: *const WorkspaceLayout, source_ref: NodeRef, target_ref: NodeRef, placement: Drop) !struct { source: Handle, target: Handle } {
        const handles = try self.editHandles(state, source_ref, target_ref);
        if (!self.nodes[handles.source].visible or !self.nodes[handles.target].visible) return error.NoTileTarget;
        switch (placement) {
            .join => if (self.nodes[handles.target].content != .group) return error.NoGroup,
            .swap => if (self.nodes[handles.source].content != .leaf or self.nodes[handles.target].content != .leaf) return error.SwapRequiresLeaves,
            else => {},
        }
        return .{ .source = handles.source, .target = handles.target };
    }

    pub fn previewDrop(self: *const Store, state: *const WorkspaceLayout, source_ref: NodeRef, target_ref: NodeRef, placement: Drop, scratch: *Store) !MovePreview {
        if (scratch == self) return error.InvalidPreviewScratch;
        const handles = try self.pointerDropHandles(state, source_ref, target_ref, placement);
        const frame = self.nodes[state.root.?].frame;
        @memcpy(std.mem.asBytes(scratch), std.mem.asBytes(self));
        const projected_state = scratch.lookup(state.display, state.workspace) orelse return error.MissingLayoutRoot;
        projected_state.* = state.*;
        try scratch.drop(projected_state, source_ref, target_ref, placement);
        scratch.arrange(projected_state, frame, state.projection_gap);
        const moved = if (placement == .swap) handles.target else handles.source;
        if (!scratch.nodes[moved].visible) return error.NoTileTarget;
        return .{ .source = source_ref, .target = target_ref, .placement = placement, .rect = scratch.nodes[moved].frame, .revision = self.revision };
    }

    pub fn commitDrop(self: *Store, state: *WorkspaceLayout, preview: MovePreview) !void {
        if (preview.revision != self.revision) return error.StaleGesture;
        _ = try self.pointerDropHandles(state, preview.source, preview.target, preview.placement);
        try self.drop(state, preview.source, preview.target, preview.placement);
    }

    pub fn exportSnapshot(self: *const Store, output: *Snapshot) void {
        output.* = .{ .nodes = self.nodes, .roots = self.roots };
    }

    fn validateNode(snapshot: *const Snapshot, handle: Handle, parent: ?Handle, seen: *[2047]bool) error{InvalidSnapshot}!void {
        if (handle >= snapshot.nodes.len or seen[handle]) return error.InvalidSnapshot;
        seen[handle] = true;
        const node = snapshot.nodes[handle];
        if (node.parent != parent) return error.InvalidSnapshot;
        switch (node.content) {
            .free => return error.InvalidSnapshot,
            .leaf => {},
            .branch => |branch| {
                if (!std.math.isFinite(branch.ratio) or branch.ratio <= 0 or branch.ratio >= 1) return error.InvalidSnapshot;
                for (branch.children) |child| {
                    if (child >= snapshot.nodes.len or snapshot.nodes[child].previous != null or snapshot.nodes[child].next != null) return error.InvalidSnapshot;
                    try validateNode(snapshot, child, handle, seen);
                }
            },
            .group => |container| {
                if (container.count < 2 or container.count > 1024) return error.InvalidSnapshot;
                var previous: ?Handle = null;
                var child: ?Handle = container.first;
                var count: usize = 0;
                var selected_found = false;
                while (child) |current| {
                    if (current >= snapshot.nodes.len or count >= container.count) return error.InvalidSnapshot;
                    if (snapshot.nodes[current].previous != previous) return error.InvalidSnapshot;
                    try validateNode(snapshot, current, handle, seen);
                    if (current == container.selected) selected_found = true;
                    previous = current;
                    child = snapshot.nodes[current].next;
                    count += 1;
                }
                if (count != container.count or previous != container.last or !selected_found) return error.InvalidSnapshot;
            },
        }
        if (node.last_child) |child| {
            if (child >= snapshot.nodes.len or snapshot.nodes[child].parent != handle) return error.InvalidSnapshot;
            switch (node.content) {
                .branch => |branch| if (child != branch.children[0] and child != branch.children[1]) return error.InvalidSnapshot,
                .group => {},
                else => return error.InvalidSnapshot,
            }
        }
    }

    /// Identities must already have been matched to current live windows by the caller.
    pub fn importSnapshot(self: *Store, snapshot: *const Snapshot) !void {
        var seen: [2047]bool = @splat(false);
        for (snapshot.roots, 0..) |slot, index| if (slot) |state| {
            if (state.workspace >= 10 or !std.math.isFinite(state.ratio) or state.ratio < 0.1 or state.ratio > 0.9) return error.InvalidSnapshot;
            for (snapshot.roots[0..index]) |earlier| if (earlier) |other| if (state.display == other.display and state.workspace == other.workspace) return error.InvalidSnapshot;
            if (state.root) |root| {
                if (root >= snapshot.nodes.len or snapshot.nodes[root].previous != null or snapshot.nodes[root].next != null) return error.InvalidSnapshot;
                try validateNode(snapshot, root, null, &seen);
            }
        };
        var leaf_count: usize = 0;
        for (snapshot.nodes, 0..) |node, index| {
            if ((node.content != .free) != seen[index]) return error.InvalidSnapshot;
            if (node.content == .leaf) {
                leaf_count += 1;
                if (leaf_count > 1024 or node.content.leaf == 0) return error.InvalidSnapshot;
                for (snapshot.nodes[0..index]) |earlier| if (earlier.content == .leaf and earlier.content.leaf == node.content.leaf) return error.InvalidSnapshot;
            }
        }
        for (snapshot.roots) |slot| if (slot) |state| if (state.selection) |selection| {
            if (selection.slot >= snapshot.nodes.len or !seen[selection.slot]) return error.InvalidSnapshot;
            var current = selection.slot;
            while (snapshot.nodes[current].parent) |parent| current = parent;
            if (state.root != current) return error.InvalidSnapshot;
        };
        self.nodes = snapshot.nodes;
        self.roots = snapshot.roots;
        for (&self.nodes) |*node| {
            if (node.content == .free) continue;
            self.serial +%= 1;
            node.generation = self.serial;
            node.active = false;
            node.visible = false;
            node.frame = std.mem.zeroes(Rect);
            node.minimum = .{ 0, 0 };
        }
        for (&self.roots) |*slot| if (slot.*) |*state| if (state.selection) |selection| {
            state.selection = self.reference(selection.slot);
        };
        for (&self.roots) |*slot| if (slot.*) |*state| {
            state.projection_gap = 0;
            state.projected_layout = null;
        };
        self.revision +%= 1;
    }

    pub fn swap(self: *Store, first: u64, second: u64) void {
        const first_leaf = self.leaf(first);
        const second_leaf = self.leaf(second);
        var remembered: [2047]?Handle = @splat(null);
        for ([_]?Handle{ first_leaf, second_leaf }) |leaf_handle| {
            var ancestor = if (leaf_handle) |handle| self.nodes[handle].parent else null;
            while (ancestor) |handle| : (ancestor = self.nodes[handle].parent) {
                if (remembered[handle] == null and self.nodes[handle].last_child != null) remembered[handle] = self.rememberedLeaf(handle);
            }
        }
        if (first_leaf) |handle| self.nodes[handle].content.leaf = second;
        if (second_leaf) |handle| self.nodes[handle].content.leaf = first;
        for ([_]?Handle{ first_leaf, second_leaf }) |leaf_handle| {
            var ancestor = if (leaf_handle) |handle| self.nodes[handle].parent else null;
            while (ancestor) |handle| : (ancestor = self.nodes[handle].parent) {
                const original = remembered[handle] orelse continue;
                var child = (if (first_leaf == original) second_leaf else if (second_leaf == original) first_leaf else original) orelse {
                    self.nodes[handle].last_child = null;
                    continue;
                };
                if (!self.contains(handle, child)) {
                    self.nodes[handle].last_child = null;
                    continue;
                }
                while (self.nodes[child].parent) |parent| {
                    self.nodes[parent].last_child = child;
                    if (parent == handle) break;
                    child = parent;
                }
            }
        }
        for (&self.roots) |*slot| if (slot.*) |*state| {
            if (state.last_focused) |identity| {
                const destination = if (identity == first) second_leaf else if (identity == second) first_leaf else null;
                if (destination) |handle| if (state.root != self.rootOf(handle)) {
                    state.last_focused = null;
                };
            }
            if (state.selection) |selection| {
                const original = self.resolve(selection) catch {
                    state.selection = null;
                    continue;
                };
                if (original != first_leaf and original != second_leaf) continue;
                const destination = (if (original == first_leaf) second_leaf else first_leaf) orelse {
                    state.selection = null;
                    continue;
                };
                state.selection = if (state.root == self.rootOf(destination)) self.reference(destination) else null;
            }
        };
        self.revision +%= 1;
    }
};

fn inside(rect: Rect, left: f64, top: f64) bool {
    return left >= rect.left and top >= rect.top and left < rect.left + rect.width and top < rect.top + rect.height;
}

pub fn split(frame: Rect, axis: Axis, ratio: f64, gap: f64) [2]Rect {
    var first = frame;
    var second = frame;
    const spacing = @min(gap, @max(0, (if (axis == .width) frame.width else frame.height) - 2));
    if (axis == .width) {
        first.width = (frame.width - spacing) * ratio;
        second.left += first.width + spacing;
        second.width = frame.width - first.width - spacing;
    } else {
        first.height = (frame.height - spacing) * ratio;
        second.top += first.height + spacing;
        second.height = frame.height - first.height - spacing;
    }
    return .{ first, second };
}
