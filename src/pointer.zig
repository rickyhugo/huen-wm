const std = @import("std");
const layout = @import("layout.zig");
const bridge = @import("interaction.zig");
const native = @import("native.zig");
const allocator = std.heap.c_allocator;
const none: bridge.NodeRef = .{ .slot = 0, .generation = 0 };

pub const Window = struct {
    identity: u64,
    public_id: u32,
    eligible: bool,
    // The frame the window is placed at. A lone window can be narrower than its layout leaf.
    goal: layout.Rect,
    title: []const u8,
    // The on-screen frame of a floating window that modified drags can move or resize.
    floating: ?layout.Rect = null,
    focused: bool = false,
};
pub const Edit = union(enum) {
    group: struct { group: layout.NodeRef, child: layout.NodeRef },
    drop: layout.MovePreview,
    resize: layout.ResizePreview,
};
const Gesture = struct {
    id: u64,
    generation: u64,
    revision: u64,
    origin: bridge.Point,
    source: layout.NodeRef,
    boundary: ?layout.Boundary,
    display: u32,
    workspace: usize,
};

pub const Controls = struct {
    generation: u64 = 0,
    revision: u64 = 0,
    hits: std.ArrayList(bridge.HitRegion) = .empty,
    gesture: ?Gesture = null,
    ready: bool = false,
    error_message: ?[]const u8 = null,
    stop_deadline: ?f64 = null,
    forced_stop: bool = false,
    scratch: ?*layout.Store = null,

    pub fn configure(self: *Controls, enabled: bool, modifiers: u32) void {
        self.gesture = null;
        _ = bridge.huen_input_configure(enabled, modifiers);
    }

    pub fn stop(self: *Controls, now: f64) bool {
        if (self.stop_deadline == null) {
            self.stop_deadline = now + 0.250;
            self.gesture = null;
            bridge.huen_input_stop();
        }
        const drained = bridge.huen_input_stop_ready();
        if (!drained and now < self.stop_deadline.?) return false;
        self.forced_stop = !drained;
        if (!bridge.huen_input_finish_stop(!drained)) self.error_message = "InputShutdownFailed";
        if (self.scratch) |scratch| allocator.destroy(scratch);
        self.scratch = null;
        return true;
    }

    pub fn publish(self: *Controls, store: *layout.Store, windows: []const Window, active: []const *layout.WorkspaceLayout, ready: bool, color: u32, width: f64) !void {
        var hits: std.ArrayList(bridge.HitRegion) = .empty;
        defer hits.deinit(allocator);
        var headers: std.ArrayList(bridge.HeaderItem) = .empty;
        defer headers.deinit(allocator);
        if (ready) for (active) |state| {
            if (state.fullscreen != null or state.layout != .dwindle) continue;
            for (windows) |window| {
                if (!window.eligible) continue;
                const node = store.nodeForIdentity(window.identity) orelse continue;
                if (!belongs(store, node, state)) continue;
                if (store.goal(window.identity) == null) continue;
                try hits.append(allocator, .{ .kind = .tile, .rect = window.goal, .node = reference(node), .group = none, .boundary = none, .window_identity = window.identity, .window_id = window.public_id });
            }
            var projected_headers: [2047]layout.Header = undefined;
            const header_count = try store.headers(state, &projected_headers);
            var group_safety: [2047]?bool = @splat(null);
            for (projected_headers[0..header_count]) |header| {
                if (header.rect.width <= 0 or header.rect.height <= 0) continue;
                if (group_safety[header.group.slot] == null) {
                    var safe = safeSubtree(store, header.group, windows);
                    const identity = try store.representative(header.group);
                    if (if (identity) |candidate| findWindow(windows, candidate) else null) |window| {
                        for (projected_headers[0..header_count]) |sibling| if (std.meta.eql(sibling.group, header.group) and !native.platform_input_rect_unobscured(window.public_id, sibling.rect)) {
                            safe = false;
                        };
                    } else safe = false;
                    group_safety[header.group.slot] = safe;
                }
                if (!group_safety[header.group.slot].?) continue;
                var item = std.mem.zeroes(bridge.HeaderItem);
                item.group = reference(header.group);
                item.child = reference(header.child);
                item.rect = header.rect;
                item.selected = header.selected;
                item.eligible = header.eligible;
                const identity = try store.labelIdentity(header.child);
                if (findWindow(windows, identity)) |window| {
                    item.window_identity = identity;
                    item.window_id = window.public_id;
                    var length: usize = 0;
                    while (length < window.title.len) {
                        const bytes = std.unicode.utf8ByteSequenceLength(window.title[length]) catch break;
                        if (length + bytes >= item.title.len or length + bytes > window.title.len) break;
                        length += bytes;
                    }
                    @memcpy(item.title[0..length], window.title[0..length]);
                }
                try headers.append(allocator, item);
                try hits.append(allocator, .{ .kind = .header, .rect = item.rect, .node = item.child, .group = item.group, .boundary = none, .window_identity = 0, .window_id = 0 });
            }
            var boundaries: [1023]layout.Boundary = undefined;
            const boundary_count = try store.boundaries(state, 6, &boundaries);
            for (boundaries[0..boundary_count]) |boundary| {
                if (!safeSubtree(store, boundary.node, windows)) continue;
                const identity = (try store.representative(boundary.node)) orelse continue;
                const window = findWindow(windows, identity) orelse continue;
                if (!native.platform_input_rect_unobscured(window.public_id, boundary.rect)) continue;
                try hits.append(allocator, .{ .kind = .boundary, .rect = boundary.rect, .node = none, .group = none, .boundary = reference(boundary.node), .window_identity = 0, .window_id = 0 });
            }
        };
        // Floating hits come last, and the focused one after the others, so they win over the tiles below them.
        if (ready) for ([_]bool{ false, true }) |focused| for (windows) |window| {
            const frame = window.floating orelse continue;
            if (window.focused != focused or window.public_id == 0 or frame.width <= 0 or frame.height <= 0) continue;
            try hits.append(allocator, .{ .kind = .floating, .rect = frame, .node = none, .group = none, .boundary = none, .window_identity = window.identity, .window_id = window.public_id });
        };
        const changed = self.ready != ready or self.revision != store.revision or hits.items.len != self.hits.items.len or for (hits.items, self.hits.items) |next, previous| {
            if (!std.meta.eql(next, previous)) break true;
        } else false;
        if (changed or self.generation == 0) {
            self.generation += 1;
            self.gesture = null;
        }
        if (!bridge.huen_input_publish(&.{ .generation = self.generation, .hits = hits.items.ptr, .hit_count = hits.items.len, .ready = ready, .transitioning = !ready })) return error.InputPublicationRejected;
        for (headers.items) |*item| item.generation = self.generation;
        const headers_published = !ready or bridge.huen_groups_publish(&.{ .generation = self.generation, .items = headers.items.ptr, .item_count = headers.items.len, .border_color = color, .border_width = width });
        if (!ready) bridge.huen_groups_clear();
        self.hits.clearRetainingCapacity();
        try self.hits.appendSlice(allocator, hits.items);
        self.ready = ready;
        self.revision = store.revision;
        if (!headers_published) return error.HeaderPublicationRejected;
    }

    pub fn event(self: *Controls, store: *layout.Store, windows: []const Window, sample: bridge.Event, gap: f64, color: u32, width: f64) !?Edit {
        if (sample.kind == .cancel) {
            self.gesture = null;
            bridge.huen_groups_preview(null);
            return null;
        }
        if (!self.ready or sample.generation != self.generation or self.revision != store.revision) return null;
        if (sample.kind == .group_select) {
            const group = try coreReference(sample.target.group);
            const child = try coreReference(sample.target.node);
            _ = try store.resolve(group);
            _ = try store.resolve(child);
            if (!safeSubtree(store, group, windows) or !unobscured(store, group, windows, sample.target.rect)) return error.ObscuredGroup;
            return .{ .group = .{ .group = group, .child = child } };
        }
        if (sample.kind == .start) {
            const source = try coreReference(if (sample.gesture == .resize) sample.target.boundary else sample.target.node);
            const handle = try store.resolve(source);
            const workspace = for (&store.roots) |*slot| {
                if (slot.*) |*candidate| if (belongs(store, source, candidate)) break candidate;
            } else return error.StaleNode;
            if (!safeSubtree(store, source, windows) or !unobscured(store, source, windows, sample.target.rect)) return error.ObscuredSource;
            var boundary: ?layout.Boundary = null;
            if (sample.gesture == .resize) {
                if (store.nodes[handle].content != .branch) return error.InvalidBoundary;
                boundary = .{ .node = source, .axis = store.nodes[handle].content.branch.axis, .rect = sample.target.rect, .revision = store.revision };
            }
            self.gesture = .{ .id = sample.gesture_id, .generation = sample.generation, .revision = store.revision, .origin = sample.origin, .source = source, .boundary = boundary, .display = workspace.display, .workspace = workspace.workspace };
        }
        const gesture = self.gesture orelse return null;
        if (gesture.id != sample.gesture_id or gesture.generation != sample.generation or gesture.revision != store.revision) {
            self.gesture = null;
            return null;
        }
        if (sample.kind == .end) {
            self.gesture = null;
            if (!sample.crossed_threshold) return null;
        }
        if (!safeSubtree(store, gesture.source, windows)) return error.ObscuredSource;
        const state = store.lookup(gesture.display, gesture.workspace) orelse return error.StaleNode;
        var edit: Edit = undefined;
        var preview_rect: layout.Rect = undefined;
        var preview_kind: bridge.PreviewKind = .insertion;
        if (gesture.boundary) |boundary| {
            const delta = if (boundary.axis == .width) sample.point.left - gesture.origin.left else sample.point.top - gesture.origin.top;
            const preview = try store.previewResize(boundary, delta, gap);
            edit = .{ .resize = preview };
            preview_rect = boundary.rect;
            if (boundary.axis == .width) preview_rect.left += preview.applied_delta else preview_rect.top += preview.applied_delta;
            preview_kind = .resize;
        } else {
            var target: ?bridge.HitRegion = null;
            for (self.hits.items) |hit| {
                if (hit.kind == .boundary or hit.kind == .floating or !(sample.point.left >= hit.rect.left and sample.point.left <= hit.rect.left + hit.rect.width and sample.point.top >= hit.rect.top and sample.point.top <= hit.rect.top + hit.rect.height)) continue;
                if (hit.kind == .header or target == null) target = hit;
            }
            const hit = target orelse return null;
            const target_ref = try coreReference(if (hit.kind == .header) hit.group else hit.node);
            const target_handle = try store.resolve(target_ref);
            var ancestor = try store.resolve(gesture.source);
            while (ancestor != target_handle) ancestor = store.nodes[ancestor].parent orelse break;
            if (ancestor == target_handle) {
                bridge.huen_groups_preview(null);
                return null;
            }
            if (!safeSubtree(store, target_ref, windows) or !unobscured(store, target_ref, windows, hit.rect)) return error.ObscuredTarget;
            const placement: layout.Drop = if (hit.kind == .header) .join else placement: {
                const horizontal = (sample.point.left - hit.rect.left) / hit.rect.width;
                const vertical = (sample.point.top - hit.rect.top) / hit.rect.height;
                if (horizontal > 0.25 and horizontal < 0.75 and vertical > 0.25 and vertical < 0.75) break :placement .swap;
                const nearest = @min(@min(horizontal, 1 - horizontal), @min(vertical, 1 - vertical));
                if (nearest == horizontal) break :placement .left;
                if (nearest == 1 - horizontal) break :placement .right;
                break :placement if (nearest == vertical) .up else .down;
            };
            if (self.scratch == null) self.scratch = try allocator.create(layout.Store);
            const preview = try store.previewDrop(state, gesture.source, target_ref, placement, self.scratch.?);
            edit = .{ .drop = preview };
            preview_rect = preview.rect;
        }
        if (sample.kind == .end) return edit;
        bridge.huen_groups_preview(&.{ .generation = self.generation, .kind = preview_kind, .rect = preview_rect, .border_color = color, .border_width = @max(1, width) });
        return null;
    }
};

fn findWindow(windows: []const Window, identity: u64) ?Window {
    for (windows) |window| if (window.identity == identity) return window;
    return null;
}
fn belongs(store: *const layout.Store, node: layout.NodeRef, state: *const layout.WorkspaceLayout) bool {
    var handle = store.resolve(node) catch return false;
    while (store.nodes[handle].parent) |parent| handle = parent;
    return state.root == handle;
}
fn safeSubtree(store: *const layout.Store, node: layout.NodeRef, windows: []const Window) bool {
    const root = store.resolve(node) catch return false;
    var found = false;
    for (store.nodes, 0..) |candidate, index| {
        if (candidate.content != .leaf or !candidate.visible) continue;
        var handle: layout.Handle = @intCast(index);
        while (handle != root) handle = store.nodes[handle].parent orelse break;
        if (handle != root) continue;
        const window = findWindow(windows, candidate.content.leaf) orelse return false;
        if (!window.eligible) return false;
        found = true;
    }
    return found;
}
fn unobscured(store: *const layout.Store, node: layout.NodeRef, windows: []const Window, frame: layout.Rect) bool {
    const identity = (store.representative(node) catch return false) orelse return false;
    const window = findWindow(windows, identity) orelse return false;
    return native.platform_input_rect_unobscured(window.public_id, frame);
}
fn reference(node: layout.NodeRef) bridge.NodeRef {
    return .{ .slot = node.slot, .generation = node.generation };
}
fn coreReference(node: bridge.NodeRef) !layout.NodeRef {
    if (node.slot >= 2047 or node.generation == 0) return error.StaleNode;
    return .{ .slot = @intCast(node.slot), .generation = node.generation };
}
