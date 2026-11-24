//! The pointer-control event tap: one singleton event queue, hit snapshots, and the drag state machine.
//! Built as its own object for the manager executable; `native/interaction.h` declares its exports for Objective-C callers.

const std = @import("std");
const macos = @import("macos.zig");
const interaction = @import("interaction.zig");

const HitRegion = interaction.HitRegion;
const HitKind = interaction.HitKind;
const Event = interaction.Event;
const Availability = interaction.Availability;
const CancelReason = interaction.CancelReason;

extern "c" fn huen_groups_invalidate(generation: u64) void;

const max_hits = 4096;
const queue_capacity = 64;
const queue_admission_limit = 60;
const DragPhase = enum { idle, active, draining };

const State = struct {
    enabled: bool = false,
    stopping: bool = false,
    ready: bool = false,
    transitioning: bool = false,
    modifiers: u32 = 0,
    generation: u64 = 0,
    next_gesture: u64 = 0,
    availability: Availability = .disabled,
    tap: ?macos.CFMachPortRef = null,
    source: ?macos.CFRunLoopSourceRef = null,
    hits: ?[*]HitRegion = null,
    hit_count: usize = 0,
    queue: [queue_capacity]Event = std.mem.zeroes([queue_capacity]Event),
    queue_head: usize = 0,
    queue_count: usize = 0,
    drag: struct {
        phase: DragPhase = .idle,
        down_type: u32 = 0,
        drag_type: u32 = 0,
        up_type: u32 = 0,
        sample: Event = std.mem.zeroes(Event),
    } = .{},
};

var input: State = .{};

fn requireMainThread() void {
    if (macos.pthread_main_np() == 0) @panic("Interaction calls require the main thread");
}

fn monotonicNs() u64 {
    var instant: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC_RAW, &instant);
    return @as(u64, @intCast(instant.sec)) * 1_000_000_000 + @as(u64, @intCast(instant.nsec));
}

fn permissionsAllowed() bool {
    return macos.CGPreflightListenEventAccess() and macos.AXIsProcessTrusted();
}

fn enqueue(event: Event) void {
    if (input.queue_count >= queue_capacity) @panic("Reserved interaction queue exhausted");
    input.queue[(input.queue_head + input.queue_count) % queue_capacity] = event;
    input.queue_count += 1;
}

fn cancelDrag(reason: CancelReason) void {
    if (input.drag.phase != .active) return;
    input.drag.sample.kind = .cancel;
    input.drag.sample.reason = reason;
    input.drag.sample.monotonic_ns = monotonicNs();
    enqueue(input.drag.sample);
    input.drag.phase = .draining;
}

fn cancelUnobservedDrag(reason: CancelReason) void {
    cancelDrag(reason);
    const button = if (input.drag.down_type == macos.EventType.left_mouse_down) macos.mouse_button_left else macos.mouse_button_right;
    if (input.drag.phase == .draining and !macos.CGEventSourceButtonState(macos.combined_session_state, button)) input.drag.phase = .idle;
}

fn contains(rect: interaction.Rect, point: macos.CGPoint) bool {
    return point.horizontal >= rect.left and point.horizontal < rect.left + rect.width and
        point.vertical >= rect.top and point.vertical < rect.top + rect.height;
}

fn sameRef(first: interaction.NodeRef, second: interaction.NodeRef) bool {
    return first.slot == second.slot and first.generation == second.generation;
}

/// Reads the kind as the raw C value, since a snapshot from C may hold a value outside the Zig enum.
fn rawKind(hit: *const HitRegion) c_uint {
    return @as(*const c_uint, @ptrCast(&hit.kind)).*;
}

fn updateSample(event: macos.CGEventRef) void {
    const point = macos.CGEventGetLocation(event);
    input.drag.sample.point = .{ .left = point.horizontal, .top = point.vertical };
    input.drag.sample.monotonic_ns = monotonicNs();
    const horizontal = point.horizontal - input.drag.sample.origin.left;
    const vertical = point.vertical - input.drag.sample.origin.top;
    if (std.math.hypot(horizontal, vertical) >= 4) input.drag.sample.crossed_threshold = true;
}

fn modifiersMatch(event: macos.CGEventRef) bool {
    return macos.carbonModifiers(macos.CGEventGetFlags(event)) == input.modifiers;
}

fn inputCallback(proxy: macos.CGEventTapProxy, event_type: u32, event: macos.CGEventRef, context: ?*anyopaque) callconv(.c) ?macos.CGEventRef {
    _ = proxy;
    _ = context;
    if (event_type == macos.EventType.tap_disabled_by_timeout or event_type == macos.EventType.tap_disabled_by_user_input) {
        cancelUnobservedDrag(.tap_disabled);
        if ((input.enabled or input.drag.phase != .idle) and permissionsAllowed() and input.tap != null) {
            macos.CGEventTapEnable(input.tap.?, true);
            input.availability = if (input.stopping) .stopping else .available;
        } else {
            input.availability = if (!input.enabled and input.drag.phase == .idle)
                (if (input.stopping) .stopping else .disabled)
            else
                .permission_denied;
        }
        return event;
    }
    if (event_type == macos.EventType.key_down) {
        if (input.drag.phase != .active or
            macos.CGEventGetIntegerValueField(event, macos.field_keyboard_keycode) != macos.virtual_key_escape) return event;
        cancelDrag(.escape);
        return null;
    }
    if (input.drag.phase == .draining and event_type == input.drag.down_type) input.drag.phase = .idle;
    if (input.drag.phase != .idle) {
        if (event_type == input.drag.up_type) {
            if (input.drag.phase == .active) {
                updateSample(event);
                if (!modifiersMatch(event)) {
                    cancelDrag(.modifiers);
                } else {
                    input.drag.sample.kind = .end;
                    enqueue(input.drag.sample);
                }
            }
            input.drag.phase = .idle;
            return null;
        }
        if (event_type != input.drag.drag_type) return event;
        if (input.drag.phase != .active) return null;
        if (!modifiersMatch(event)) {
            cancelDrag(.modifiers);
            return null;
        }
        updateSample(event);
        input.drag.sample.kind = .update;
        // Consecutive updates of one gesture coalesce into the newest sample.
        const previous = &input.queue[(input.queue_head + input.queue_count + queue_capacity - 1) % queue_capacity];
        if (input.queue_count != 0 and previous.kind == .update and previous.gesture_id == input.drag.sample.gesture_id) {
            previous.* = input.drag.sample;
        } else if (input.queue_count < queue_capacity - 1) enqueue(input.drag.sample);
        return null;
    }
    if (event_type != macos.EventType.left_mouse_down and event_type != macos.EventType.right_mouse_down) return event;
    if (!input.enabled or input.stopping or !input.ready or input.transitioning or
        input.availability != .available or input.queue_count > queue_admission_limit or !modifiersMatch(event)) return event;
    const left = event_type == macos.EventType.left_mouse_down;
    const point = macos.CGEventGetLocation(event);
    const hits = if (input.hits) |stored| stored[0..input.hit_count] else &[_]HitRegion{};
    if (left) for (hits) |hit| {
        if (hit.kind == .header and contains(hit.rect, point)) return event;
    };
    // Floating hits follow tile and boundary hits, so the last match is the window on top.
    const pressed: HitKind = if (left) .tile else .boundary;
    var found: ?*const HitRegion = null;
    var index = hits.len;
    while (index > 0 and found == null) : (index -= 1) {
        const hit = &hits[index - 1];
        if ((hit.kind == .floating or hit.kind == pressed) and contains(hit.rect, point)) found = hit;
    }
    const hit = found orelse return event;
    input.drag.phase = .active;
    input.drag.down_type = event_type;
    input.drag.drag_type = if (left) macos.EventType.left_mouse_dragged else macos.EventType.right_mouse_dragged;
    input.drag.up_type = if (left) macos.EventType.left_mouse_up else macos.EventType.right_mouse_up;
    input.next_gesture +%= 1;
    if (input.next_gesture == 0) input.next_gesture += 1;
    input.drag.sample = std.mem.zeroes(Event);
    input.drag.sample.kind = .start;
    input.drag.sample.gesture = if (hit.kind == .floating)
        (if (left) .move_floating else .resize_floating)
    else
        (if (left) .reorder else .resize);
    input.drag.sample.generation = input.generation;
    input.drag.sample.gesture_id = input.next_gesture;
    input.drag.sample.monotonic_ns = monotonicNs();
    input.drag.sample.target = hit.*;
    input.drag.sample.origin = .{ .left = point.horizontal, .top = point.vertical };
    input.drag.sample.point = .{ .left = point.horizontal, .top = point.vertical };
    enqueue(input.drag.sample);
    return null;
}

export fn huen_input_configure(requested: bool, modifiers: u32) Availability {
    requireMainThread();
    if (input.stopping) return .stopping;
    const all = macos.carbon_command | macos.carbon_shift | macos.carbon_option | macos.carbon_control;
    const enabled = requested and modifiers != 0 and modifiers & ~all == 0;
    if (input.enabled != enabled or input.modifiers != modifiers) cancelDrag(.configuration);
    input.enabled = enabled;
    input.modifiers = modifiers;
    return huen_input_status();
}

fn releaseTap(port: macos.CFMachPortRef) void {
    macos.CFRunLoopRemoveSource(macos.CFRunLoopGetMain(), input.source.?, macos.kCFRunLoopCommonModes);
    macos.CFRelease(input.source.?);
    macos.CFRelease(port);
}

export fn huen_input_status() Availability {
    requireMainThread();
    if (input.tap) |port| if (!macos.CFMachPortIsValid(port)) cancelUnobservedDrag(.tap_disabled);
    if (!input.enabled and input.drag.phase == .idle) {
        if (input.tap) |port| macos.CGEventTapEnable(port, false);
        input.availability = if (input.stopping) .stopping else .disabled;
        return input.availability;
    }
    if (!permissionsAllowed()) {
        cancelUnobservedDrag(.permission);
        input.availability = .permission_denied;
        return input.availability;
    }
    const valid = if (input.tap) |port| macos.CFMachPortIsValid(port) else false;
    if (!valid) {
        if (input.tap) |port| releaseTap(port);
        var mask: u64 = 0;
        for ([_]u32{
            macos.EventType.left_mouse_down,  macos.EventType.left_mouse_up,  macos.EventType.left_mouse_dragged,
            macos.EventType.right_mouse_down, macos.EventType.right_mouse_up, macos.EventType.right_mouse_dragged,
            macos.EventType.key_down,
        }) |event_type| mask |= macos.eventMaskBit(event_type);
        input.tap = macos.CGEventTapCreate(macos.session_event_tap, macos.head_insert_event_tap, macos.tap_option_default, mask, inputCallback, null);
        input.source = if (input.tap) |port| macos.CFMachPortCreateRunLoopSource(null, port, 0) else null;
        if (input.source == null) {
            if (input.tap) |port| macos.CFRelease(port);
            input.tap = null;
            cancelUnobservedDrag(.tap_disabled);
            input.availability = .tap_unavailable;
            return input.availability;
        }
        macos.CFRunLoopAddSource(macos.CFRunLoopGetMain(), input.source.?, macos.kCFRunLoopCommonModes);
        macos.CGEventTapEnable(input.tap.?, true);
    }
    if (!macos.CGEventTapIsEnabled(input.tap.?)) {
        cancelUnobservedDrag(.tap_disabled);
        macos.CGEventTapEnable(input.tap.?, true);
    }
    input.availability = if (input.stopping) .stopping else if (input.enabled) .available else .disabled;
    return input.availability;
}

fn hitValid(hit: *const HitRegion) bool {
    const rect = hit.rect;
    const kind = rawKind(hit);
    if (!std.math.isFinite(rect.left) or !std.math.isFinite(rect.top) or !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height) or
        rect.width <= 0 or rect.height <= 0 or !std.math.isFinite(rect.left + rect.width) or !std.math.isFinite(rect.top + rect.height) or
        kind < @backingInt(HitKind.tile) or kind > @backingInt(HitKind.floating)) return false;
    return switch (hit.kind) {
        .tile => hit.window_identity != 0 and hit.window_id != 0 and hit.node.generation != 0,
        .floating => hit.window_identity != 0 and hit.window_id != 0,
        .boundary => hit.boundary.generation != 0,
        .header => hit.node.generation != 0 and hit.group.generation != 0,
    };
}

fn sameHit(first: HitRegion, second: HitRegion) bool {
    return first.kind == second.kind and
        first.rect.left == second.rect.left and first.rect.top == second.rect.top and
        first.rect.width == second.rect.width and first.rect.height == second.rect.height and
        sameRef(first.node, second.node) and sameRef(first.group, second.group) and sameRef(first.boundary, second.boundary) and
        first.window_identity == second.window_identity and first.window_id == second.window_id;
}

export fn huen_input_publish(published: ?*const interaction.Snapshot) bool {
    requireMainThread();
    const snapshot = published orelse return false;
    if (input.stopping or snapshot.generation == 0 or snapshot.hit_count > max_hits or (snapshot.hit_count != 0 and snapshot.hits == null)) return false;
    const hits = if (snapshot.hits) |stored| stored[0..snapshot.hit_count] else &[_]HitRegion{};
    for (hits) |*hit| if (!hitValid(hit)) return false;
    if (snapshot.generation < input.generation or
        (snapshot.generation == input.generation and snapshot.hit_count != input.hit_count)) return false;
    if (snapshot.generation == input.generation) for (hits, 0..) |hit, index| {
        if (!sameHit(hit, input.hits.?[index])) return false;
    };
    var copied: ?[*]HitRegion = null;
    if (hits.len != 0) {
        const memory = std.c.malloc(hits.len * @sizeOf(HitRegion)) orelse return false;
        const destination: [*]HitRegion = @ptrCast(@alignCast(memory));
        @memcpy(destination[0..hits.len], hits);
        copied = destination;
    }
    if (snapshot.generation != input.generation or !snapshot.ready or snapshot.transitioning) {
        cancelDrag(.publication);
        interaction.huen_groups_preview(null);
    }
    std.c.free(input.hits);
    input.hits = copied;
    input.hit_count = hits.len;
    input.generation = snapshot.generation;
    input.ready = snapshot.ready;
    input.transitioning = snapshot.transitioning;
    huen_groups_invalidate(if (input.ready and !input.transitioning) input.generation else 0);
    return true;
}

export fn huen_input_poll(output: ?*Event) bool {
    requireMainThread();
    const event = output orelse return false;
    _ = huen_input_status();
    if (input.queue_count == 0) return false;
    event.* = input.queue[input.queue_head];
    input.queue_head = (input.queue_head + 1) % queue_capacity;
    input.queue_count -= 1;
    if (event.kind == .end or event.kind == .cancel) interaction.huen_groups_preview(null);
    return true;
}

export fn huen_input_generation_ready(generation: u64) bool {
    requireMainThread();
    return !input.stopping and input.ready and !input.transitioning and
        generation != 0 and generation == input.generation;
}

export fn huen_input_select_header(selected: ?*const interaction.HeaderItem) bool {
    requireMainThread();
    const item = selected orelse return false;
    if (!huen_input_generation_ready(item.generation) or
        input.drag.phase != .idle or input.queue_count > queue_admission_limit) return false;
    var event = std.mem.zeroes(Event);
    event.kind = .group_select;
    event.generation = item.generation;
    event.monotonic_ns = monotonicNs();
    event.target = std.mem.zeroes(HitRegion);
    event.target.kind = .header;
    event.target.rect = item.rect;
    event.target.node = item.child;
    event.target.group = item.group;
    event.target.window_identity = item.window_identity;
    event.target.window_id = item.window_id;
    enqueue(event);
    return true;
}

export fn huen_input_stop() void {
    requireMainThread();
    input.stopping = true;
    input.ready = false;
    cancelDrag(.shutdown);
    interaction.huen_groups_clear();
}

export fn huen_input_stop_ready() bool {
    requireMainThread();
    return input.stopping and input.drag.phase == .idle;
}

export fn huen_input_finish_stop(force: bool) bool {
    requireMainThread();
    if (!input.stopping or (!force and !huen_input_stop_ready())) return false;
    if (input.tap) |port| {
        macos.CGEventTapEnable(port, false);
        macos.CFMachPortInvalidate(port);
        releaseTap(port);
    }
    std.c.free(input.hits);
    input = .{};
    return true;
}
