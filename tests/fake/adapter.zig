//! The native adapter's exports, backed by the fake world. This is the only mock in the suite.
const std = @import("std");
const abi = @import("abi.zig");
const model = @import("world.zig");

const world = &model.current;
const allocator = model.allocator;

export fn platform_monotonic() f64 {
    return world.clock;
}

export fn platform_config_path() [*:0]const u8 {
    return "/tests/config.lua";
}

export fn platform_filter() [*:0]const u8 {
    return "";
}

export fn platform_error(message: [*:0]const u8) void {
    _ = message;
}

export fn platform_border(identity: u64, width: f64, color: u32) void {
    _ = identity;
    _ = width;
    _ = color;
}

export fn platform_status_present(presentation: ?*const anyopaque) void {
    _ = presentation;
}

export fn platform_bindings(bindings: [*]const abi.Binding, count: usize) bool {
    _ = bindings;
    _ = count;
    return true;
}

export fn platform_rebind() bool {
    return true;
}

export fn platform_drag_active(active: bool) void {
    if (!active) world.scan_needed = true;
}

export fn platform_config_changed() void {
    world.scan_needed = true;
}

/// Literal substring match. The real adapter compiles an NSRegularExpression.
export fn platform_regex_match(pattern: [*:0]const u8, text: [*]const u8, length: usize) c_int {
    return @intFromBool(std.mem.indexOf(u8, text[0..length], std.mem.span(pattern)) != null);
}

export fn platform_displays(output: [*]abi.Display, capacity: usize) usize {
    const count = @min(capacity, world.displays.items.len);
    for (world.displays.items[0..count], output[0..count]) |display, *slot| {
        slot.* = .{ .identity = display.identity, .frame = display.frame, .full_bounds = display.full_bounds, .name = undefined, .built_in = display.built_in };
        model.copyText(&slot.name, display.name);
    }
    return count;
}

fn copyRecords(output: [*]abi.Window, capacity: usize) usize {
    const count = @min(capacity, world.records.items.len);
    for (world.records.items[0..count], output[0..count]) |entry, *slot| slot.* = entry.observation;
    return count;
}

/// The last scan's observations. Only a tick scans.
export fn platform_windows(output: [*]abi.Window, capacity: usize) usize {
    return copyRecords(output, capacity);
}

/// Scans first when something changed since the last scan or it is over 2 s old.
export fn platform_refresh_windows(output: [*]abi.Window, capacity: usize) usize {
    if (world.scan_needed or world.clock - world.last_scan > 2) world.scan();
    return copyRecords(output, capacity);
}

export fn platform_read_frame(identity: u64, frame: *abi.Rect) bool {
    if (world.record(identity) == null) return false;
    frame.* = (world.window(identity) orelse return false).frame;
    return true;
}

/// Writes at once: the fake screen has no animation. A visible goal within 2 points, or a verified placement at
/// the exact frame, is not written again, as in native/platform.m.
export fn platform_frame(identity: u64, frame: abi.Rect, duration: f64, intent: abi.FrameIntent) bool {
    _ = duration;
    const entry = world.record(identity) orelse return false;
    if (entry.observation.stale or entry.observation.minimized or entry.observation.fullscreen) return false;
    const truth = world.window(identity) orelse return false;
    const near = model.framesNear(truth.frame, frame, if (intent == .verified_placement) 0 else 2);
    if (!near) entry.changed = true;
    const applied = near or world.writeFrame(identity, frame);
    if (applied and intent == .verified_placement) entry.observation.onscreen = true;
    return applied;
}

/// Writes every window the manager changed back to the frame the adapter first observed.
export fn platform_restore() usize {
    var outstanding: usize = 0;
    for (world.records.items) |*entry| {
        if (!entry.changed) continue;
        const restored = world.writeFrame(entry.identity, entry.original) and if (world.window(entry.identity)) |truth| model.framesNear(truth.frame, entry.original, 2) else false;
        if (restored) entry.changed = false else outstanding += 1;
    }
    return outstanding;
}

/// Makes `frame` the restore geometry, writes it, and stores the readback, as native/platform.m does.
export fn platform_adopt_original(identity: u64, frame: abi.Rect, actual: *abi.Rect) bool {
    const entry = world.record(identity) orelse return false;
    entry.original = frame;
    _ = world.writeFrame(identity, frame);
    const truth = world.window(identity) orelse return false;
    actual.* = truth.frame;
    entry.observation.frame = truth.frame;
    entry.changed = !model.framesNear(truth.frame, frame, 2);
    return !entry.changed;
}

export fn platform_settle_budget_begin() void {}

export fn platform_focus(identity: u64) bool {
    const entry = world.record(identity) orelse return false;
    if (entry.observation.minimized or entry.observation.stale or world.window(identity) == null) return false;
    world.focused = identity;
    world.raise(identity);
    return true;
}

export fn platform_focused_window() u64 {
    const identity = world.focused;
    if (identity == 0 or world.window(identity) == null) return 0;
    const entry = world.record(identity) orelse return 0;
    return if (entry.observation.stale) 0 else identity;
}

export fn platform_session_attributes(identity: u64, output: *abi.SessionAttributes) bool {
    const entry = world.record(identity) orelse return false;
    if (entry.observation.stale or entry.observation.minimized) return false;
    const truth = world.window(identity) orelse return false;
    const owner = world.app(truth.pid) orelse return false;
    output.* = std.mem.zeroes(abi.SessionAttributes);
    output.pid = owner.pid;
    output.kind = 1;
    output.launch = owner.launch;
    model.copyText(&output.bundle, owner.bundle);
    model.copyText(&output.value, truth.key);
    model.copyText(&output.role, "AXWindow");
    model.copyText(&output.subrole, "AXStandardWindow");
    return true;
}

export fn platform_input_rect_unobscured(window_id: u32, frame: abi.Rect) bool {
    _ = frame;
    return window_id != 0;
}

export fn platform_pointer(point: *abi.Point) bool {
    point.* = world.pointer;
    return true;
}

export fn platform_warp_pointer(point: abi.Point) bool {
    world.pointer = point;
    return true;
}

export fn platform_pointer_buttons() bool {
    return world.pointer_buttons;
}

/// Presses the close button: the application closes the window at once. Its record goes at the next scan.
export fn platform_close(identity: u64, track: bool, process_token: *f64) bool {
    const entry = world.record(identity) orelse return false;
    if (world.focused != identity or entry.observation.stale or entry.observation.minimized) return false;
    const owner = world.app(entry.observation.pid) orelse return false;
    if (!world.removeWindow(identity)) return false;
    if (track) {
        world.closing = .{ .identity = identity, .token = owner.launch };
        process_token.* = owner.launch;
    }
    return true;
}

export fn platform_close_state(identity: u64, pid: c_int, process_token: f64) c_int {
    const closing = world.closing orelse return -1;
    if (closing.identity != identity or closing.token != process_token) return -1;
    const owner = world.app(pid) orelse return -1;
    if (owner.launch != process_token) return -1;
    if (world.window(identity) != null) return 0;
    for (world.windows.items) |member| if (member.pid == pid) return 1;
    return 2;
}

export fn platform_close_cancel() void {
    world.closing = null;
}

export fn platform_terminate_if_empty(identity: u64, pid: c_int, process_token: f64) bool {
    if (platform_close_state(identity, pid, process_token) != 2) return false;
    world.terminate(pid);
    return true;
}

export fn platform_launch(bundle: [*:0]const u8, new_instance: bool, hidden: bool) u64 {
    _ = bundle;
    _ = new_instance;
    _ = hidden;
    return 0;
}

export fn platform_launch_status() abi.LaunchStatus {
    return std.mem.zeroes(abi.LaunchStatus);
}

export fn platform_exec(shell: [*:0]const u8) bool {
    _ = shell;
    return true;
}

/// The adapter's timer then calls wm_shutdown until it returns true. The manager driver's tick does that.
export fn platform_quit() void {
    world.stopping = true;
}

/// The application's launch date while it runs, else 0.
export fn platform_process_token(pid: c_int) f64 {
    return if (world.app(pid)) |owner| owner.launch else 0;
}

export fn huen_input_configure(enabled: bool, carbon_modifiers: u32) abi.InputAvailability {
    _ = carbon_modifiers;
    world.input = if (enabled) .available else .disabled;
    return world.input;
}

export fn huen_input_status() abi.InputAvailability {
    return world.input;
}

/// Keeps the tile hit regions of the latest publication.
export fn huen_input_publish(snapshot: *const abi.InputSnapshot) bool {
    world.tile_hits.clearRetainingCapacity();
    if (snapshot.hits) |hits| for (hits[0..snapshot.hit_count]) |hit| if (hit.kind == .tile) {
        world.tile_hits.append(allocator, hit) catch return false;
    };
    return true;
}

/// The fake world has no mouse.
export fn huen_input_poll(event: *anyopaque) bool {
    _ = event;
    return false;
}

export fn huen_input_stop() void {
    world.input = .stopping;
}

export fn huen_input_stop_ready() bool {
    return true;
}

export fn huen_input_finish_stop(force: bool) bool {
    _ = force;
    world.input = .disabled;
    return true;
}

export fn huen_groups_publish(presentation: *const anyopaque) bool {
    _ = presentation;
    return true;
}

export fn huen_groups_preview(preview: ?*const anyopaque) void {
    _ = preview;
}

export fn huen_groups_clear() void {}

/// Screen capture is never allowed, so workspace switches commit at once.
export fn huen_scene_capture_allowed() bool {
    return false;
}

export fn huen_scene_begin(display: u32, generation: u64, duration: f64, callback: abi.SceneReady, context: ?*anyopaque) void {
    _ = display;
    _ = generation;
    _ = duration;
    callback(context, false);
}

export fn huen_scene_finish(generation: u64) void {
    _ = generation;
}

export fn huen_scene_cancel() void {}

export fn huen_observe_active() bool {
    return world.observe_active;
}

export fn huen_observe_gestures(enabled: bool) void {
    _ = enabled;
}

/// Answers with the world's config, encoded as the Lua worker would encode it.
export fn config_worker_run(path: [*:0]const u8, output: [*]u8, capacity: usize, used: *usize, diagnostic: [*]u8, diagnostic_capacity: usize, cancelled: abi.ConfigCancelled, context: ?*anyopaque) c_int {
    _ = path;
    _ = cancelled;
    _ = context;
    if (diagnostic_capacity > 0) diagnostic[0] = 0;
    const encoded = std.json.Stringify.valueAlloc(allocator, world.config, .{}) catch return 1;
    defer allocator.free(encoded);
    if (encoded.len > capacity) return 1;
    @memcpy(output[0..encoded.len], encoded);
    used.* = encoded.len;
    return 0;
}

export fn huen_session_display_uuid(display: u32, output: [*]u8, capacity: usize) bool {
    _ = std.fmt.bufPrintSentinel(output[0..capacity], "00000000-0000-0000-0000-{d:0>12}", .{display}, 0) catch return false;
    return true;
}

export fn huen_session_boot_identity(output: [*]u8, capacity: usize) bool {
    _ = std.fmt.bufPrintSentinel(output[0..capacity], "1700000000.000000", .{}, 0) catch return false;
    return true;
}

/// 0 loaded, 1 missing, -1 failure, as native/session.h documents. Files are named by stem and hash.
export fn huen_session_read(stem: [*:0]const u8, hash: [*:0]const u8, output: [*]u8, capacity: usize, used: *usize) c_int {
    used.* = 0;
    const name = std.fmt.allocPrint(allocator, "{s}-{s}", .{ stem, hash }) catch return -1;
    defer allocator.free(name);
    const stored = world.file(name) orelse return 1;
    if (stored.bytes.len == 0 or stored.bytes.len > capacity) return -1;
    @memcpy(output[0..stored.bytes.len], stored.bytes);
    used.* = stored.bytes.len;
    return 0;
}

export fn huen_session_write(stem: [*:0]const u8, hash: [*:0]const u8, bytes: [*]const u8, length: usize, durable: bool) bool {
    _ = durable;
    const copy = allocator.dupe(u8, bytes[0..length]) catch return false;
    const name = std.fmt.allocPrint(allocator, "{s}-{s}", .{ stem, hash }) catch return false;
    if (world.file(name)) |stored| {
        stored.bytes = copy;
        return true;
    }
    world.files.append(allocator, .{ .name = name, .bytes = copy }) catch return false;
    return true;
}

export fn huen_journal_append(line: [*]const u8, length: usize) bool {
    world.journal.append(allocator, allocator.dupe(u8, line[0..length]) catch return false) catch return false;
    return true;
}
