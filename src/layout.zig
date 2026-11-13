const std = @import("std");
const commands = @import("command.zig");
const Rect = @import("native.zig").WMRect;
const Axis = commands.Axis;
const Handle = u16;
const Branch = struct { axis: Axis, ratio: f64, children: [2]Handle };
const Node = struct {
    parent: ?Handle = null,
    content: union(enum) { free, leaf: u64, branch: Branch } = .free,
    active: bool = false,
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
};

pub const Store = struct {
    nodes: [2047]Node = @splat(.{}),
    roots: [320]?WorkspaceLayout = @splat(null),

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
    }

    fn release(self: *Store, handle: Handle) void {
        const content = self.nodes[handle].content;
        if (content == .branch) for (content.branch.children) |child| self.release(child);
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
        const parent = self.nodes[handle].parent orelse {
            self.nodes[handle] = .{};
            state.root = null;
            return;
        };
        const branch = self.nodes[parent].content.branch;
        const sibling = branch.children[if (branch.children[0] == handle) @as(usize, 1) else 0];
        const grandparent = self.nodes[parent].parent;
        self.nodes[sibling].parent = grandparent;
        if (grandparent) |ancestor| {
            var children = &self.nodes[ancestor].content.branch.children;
            children[if (children[0] == parent) @as(usize, 0) else 1] = sibling;
        } else state.root = sibling;
        self.nodes[handle] = .{};
        self.nodes[parent] = .{};
    }

    pub fn sync(self: *Store, members: []const Member, focused: ?u64, gap: f64) !void {
        for (&self.roots) |*slot| if (slot.*) |*state| {
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
                while (self.nodes[target].content == .branch) target = self.nodes[target].content.branch.children[1];
                const frame = self.nodes[target].frame;
                const bounds = if (frame.width > 0 and frame.height > 0) frame else member.area;
                const parent = self.nodes[target].parent;
                const branch = available[1];
                self.nodes[branch] = .{ .parent = parent, .content = .{ .branch = .{ .axis = if (bounds.width >= bounds.height) .width else .height, .ratio = if (parent == null) destination.ratio else 0.5, .children = .{ target, added } } } };
                if (parent) |ancestor| {
                    var children = &self.nodes[ancestor].content.branch.children;
                    children[if (children[0] == target) @as(usize, 0) else 1] = branch;
                } else destination.root = branch;
                self.nodes[target].parent = branch;
                self.nodes[added] = .{ .parent = branch, .content = .{ .leaf = member.identity }, .active = member.active };
            } else {
                self.nodes[added] = .{ .content = .{ .leaf = member.identity }, .active = member.active };
                destination.root = added;
            }
            self.arrange(destination, member.area, gap);
        }
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
            .free => unreachable,
        }
    }

    fn project(self: *Store, handle: Handle, frame: Rect, gap: f64) void {
        var node = &self.nodes[handle];
        node.frame = frame;
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
        self.measure(root, gap);
        self.project(root, frame, gap);
    }

    pub fn goal(self: *const Store, identity: u64) ?Rect {
        const handle = self.leaf(identity) orelse return null;
        return if (self.nodes[handle].active) self.nodes[handle].frame else null;
    }

    pub fn orient(self: *Store, identity: u64, orientation: commands.Orientation) !void {
        const handle = self.leaf(identity) orelse return error.WindowNotTiled;
        const parent = self.nodes[handle].parent orelse return error.NoSplit;
        var branch = &self.nodes[parent].content.branch;
        branch.axis = switch (orientation) {
            .horizontal => .width,
            .vertical => .height,
            .toggle => if (branch.axis == .width) .height else .width,
        };
    }

    pub fn resizePoints(self: *Store, identity: u64, axis: Axis, delta: f64, gap: f64) !f64 {
        var child = self.leaf(identity) orelse return error.WindowNotTiled;
        while (self.nodes[child].parent) |parent| {
            const node = &self.nodes[parent];
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
        if (state.layout == .dwindle) if (state.root) |root| if (self.nodes[root].content == .branch) {
            self.nodes[root].content.branch.ratio = state.ratio;
        };
    }

    pub fn swap(self: *Store, first: u64, second: u64) void {
        const first_leaf = self.leaf(first);
        const second_leaf = self.leaf(second);
        if (first_leaf) |handle| self.nodes[handle].content.leaf = second;
        if (second_leaf) |handle| self.nodes[handle].content.leaf = first;
    }
};

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
