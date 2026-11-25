const std = @import("std");
const native = @import("native.zig");
const journal = @import("journal.zig");
const world = @import("world.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const reload = @import("reload.zig");
const hotkeys = @import("hotkeys.zig");
const gestures = @import("gestures.zig");
const commands = @import("command.zig");
const session = @import("session.zig");
const monitor = @import("monitor.zig");
const reply = @import("reply.zig");
const focus = @import("focus.zig");
const edits = @import("edits.zig");
const recovery = @import("recovery.zig");
const recall = @import("recall.zig");
const checkpoint = @import("checkpoint.zig");
const text = native.text;
const Rect = world.Rect;
const Display = world.Display;

const StatusPresentation = union(enum) {
    disabled,
    visible: struct { display_identity: ?u32, content: native.WMStatusPresentation },
};
var published_status: StatusPresentation = .disabled;
var status_active = false;
fn statusText(destination: []u8, source: []const u8, scalar_limit: usize) void {
    @memset(destination, 0);
    var length: usize = 0;
    var scalars: usize = 0;
    while (length < source.len and scalars < scalar_limit) : (scalars += 1) {
        const width = std.unicode.utf8ByteSequenceLength(source[length]) catch break;
        if (length + width > source.len or length + width >= destination.len) break;
        length += width;
    }
    @memcpy(destination[0..length], source[0..length]);
}
pub fn present() void {
    journal.flushTransition();
    gestures.publish();
    publishStatus();
}
pub fn publishStatus() void {
    if (!status_active) return;
    const next: StatusPresentation = if (!world.config().status_bar.enabled) .disabled else status: {
        var presentation = std.mem.zeroes(native.WMStatusPresentation);
        const display: ?Display = if (world.displays().len > 0) world.displays()[world.activeDisplay()] else null;
        // With global routing, a display that has no workspace placed on it shows a dash.
        const placed: ?usize = if (display) |current| routing.placedWorkspace(current) else null;
        const workspace_index = placed orelse 0;
        const name = if (placed != null) text(&world.config().workspaces[workspace_index].name) else "No workspace";
        var index_buffer: [8]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buffer, "{d}", .{workspace_index + 1}) catch unreachable;
        var label_buffer: [80]u8 = undefined;
        const label = if (world.isSuspended()) "Paused" else if (display == null) "Huen WM" else if (placed == null) "—" else switch (world.config().status_bar.label) {
            .name => name,
            .index => index_text,
            .index_and_name => if (std.mem.eql(u8, name, index_text)) name else std.fmt.bufPrint(&label_buffer, "{s}  {s}", .{ index_text, name }) catch unreachable,
        };
        // A dot marks a workspace that holds an urgent window, and the title while any workspace does.
        var urgent: [10]bool = @splat(false);
        var alert = false;
        for (world.windows()) |window| if (window.urgent) {
            urgent[window.workspace] = true;
            alert = true;
        };
        const shown = if (hotkeys.activeMode() != 0 and !world.isSuspended()) text(&world.config().modes[hotkeys.activeMode()].name) else label;
        switch (world.config().status_bar.style) {
            .text => statusText(&presentation.title, shown, 24),
            .badge => statusText(&presentation.badge, shown, 24),
        }
        if (alert) {
            const mark = " •";
            @memcpy(presentation.title[text(&presentation.title).len..][0..mark.len], mark);
        }
        var tooltip_buffer: [512]u8 = undefined;
        const tooltip = std.fmt.bufPrint(&tooltip_buffer, "Huen WM · {s} · {s} · Mode {s}{s}", .{
            if (display) |current| text(&current.name) else "No display",
            name,
            text(&world.config().modes[hotkeys.activeMode()].name),
            if (journal.lastError() != null) " · Workspace switch failed" else "",
        }) catch unreachable;
        statusText(&presentation.tooltip, tooltip, 255);
        for (world.config().workspaces[0..world.config().workspace_count], 0..) |*workspace, index| {
            const row = &presentation.rows[index];
            var row_buffer: [96]u8 = undefined;
            var number_buffer: [8]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buffer, "{d}", .{index + 1}) catch unreachable;
            const workspace_name = text(&workspace.name);
            const mark = if (urgent[index]) " •" else "";
            const title = if (std.mem.eql(u8, number, workspace_name)) std.fmt.bufPrint(&row_buffer, "{s}{s}", .{ workspace_name, mark }) catch unreachable else std.fmt.bufPrint(&row_buffer, "{s}  {s}{s}", .{ number, workspace_name, mark }) catch unreachable;
            statusText(&row.title, title, 79);
            _ = std.fmt.bufPrint(&row.command, "workspace {d}", .{index + 1}) catch unreachable;
            row.checked = placed == index;
            row.enabled = display != null and !world.isSuspended() and !scene.pending();
        }
        const reload_row = &presentation.rows[world.config().workspace_count];
        statusText(&reload_row.title, "Reload configuration", 79);
        statusText(&reload_row.command, "reload", 127);
        reload_row.enabled = !world.isSuspended() and !scene.pending() and !reload.inFlight();
        const quit_row = &presentation.rows[world.config().workspace_count + 1];
        statusText(&quit_row.title, "Quit", 79);
        statusText(&quit_row.command, "quit", 127);
        quit_row.enabled = true;
        presentation.row_count = world.config().workspace_count + 2;
        break :status .{ .visible = .{ .display_identity = if (display) |current| current.identity else null, .content = presentation } };
    };
    if (std.meta.eql(next, published_status)) return;
    published_status = next;
    switch (next) {
        .disabled => native.platform_status_present(null),
        .visible => |*presentation| native.platform_status_present(&presentation.content),
    }
}

pub fn activate() void {
    status_active = true;
}

pub fn deactivate() void {
    status_active = false;
    native.platform_status_present(null);
}

pub fn reportStatus() reply.Reply {
    const launch = native.platform_launch_status();
    var placed_rows: [10]routing.Placed = undefined;
    const placed = routing.placed(&placed_rows);
    return reply.json(.{
        .running = true,
        .suspended = world.isSuspended(),
        .active_mode = text(&world.config().modes[hotkeys.activeMode()].name),
        .close_state = edits.closeState(),
        .launch = .{ .request_id = launch.request_id, .state = launch.state, .message = text(&launch.message) },
        .window_count = world.windows().len,
        .display_count = world.displays().len,
        .selected_monitor = world.selected(),
        .workspace_owner = routing.owner(),
        .placements = placed,
        .routing_blocked = routing.blocked(),
        .workspace_backend = "corner-parking",
        .filter = std.mem.span(native.platform_filter()),
        .scene_capture_allowed = native.huen_scene_capture_allowed(),
        .snapshot_presentation = scene.presentation(),
        .snapshot_generation = scene.generationCount(),
        .transition_pending = scene.pending(),
        .transition_error = journal.lastError(),
        .hotkeys = hotkeys.status(),
        .mouse = gestures.status(),
        .session = checkpoint.status(),
        .parking_recovery = recovery.status(),
        .placement_memory = recall.status(),
        .config_reload = reload.status(),
    });
}

pub fn listWindows() reply.Reply {
    const Item = struct { id: u64, pid: c_int, bundle: []const u8, title: []const u8, display: u32, workspace: usize, focused: bool, urgent: bool, floating: bool, parked: bool, minimized: bool, fullscreen: bool, managed_fullscreen: bool, stale: bool, frame: Rect, placement_error: ?[]const u8, group_hidden: bool, parking_exempt: bool, minimum: struct { width: f64, height: f64 }, maximum: struct { width: ?f64, height: ?f64 } };
    var items: [1024]Item = undefined;
    for (world.windows(), items[0..world.windows().len]) |*window, *item| item.* = .{ .id = window.identity, .pid = window.observation.pid, .bundle = text(&window.observation.bundle), .title = text(&window.observation.title), .display = window.display, .workspace = window.workspace + 1, .focused = focus.current() == window.identity, .urgent = window.urgent, .floating = window.floating, .parked = window.parked, .minimized = window.observation.minimized, .fullscreen = window.observation.fullscreen, .managed_fullscreen = window.managedFullscreen(), .stale = window.observation.stale, .frame = window.observation.frame, .placement_error = window.placement_error, .group_hidden = !window.floating and world.layouts().visibility(window.identity) == .hidden_by_group, .parking_exempt = window.escape == .exempt, .minimum = .{ .width = window.bounds.minimumAt(.width), .height = window.bounds.minimumAt(.height) }, .maximum = .{ .width = if (window.bounds.ceilingAt(.width)) |ceiling| ceiling.accepted else null, .height = if (window.bounds.ceilingAt(.height)) |ceiling| ceiling.accepted else null } };
    return reply.json(items[0..world.windows().len]);
}

pub fn listMonitors() reply.Reply {
    const Item = struct { id: u32, uuid: ?[]const u8, name: []const u8, frame: Rect, full_bounds: Rect, built_in: bool, workspace: ?usize, selected: bool, blocked_by_fullscreen: bool };
    var items: [monitor.capacity]Item = undefined;
    var uuids: [monitor.capacity][64]u8 = undefined;
    const count = world.displays().len;
    for (world.displays(), uuids[0..count], items[0..count]) |*display, *uuid, *item| {
        uuid.* = @splat(0);
        const known = session.huen_session_display_uuid(display.identity, uuid, uuid.len);
        const placed = routing.placedWorkspace(display.*);
        item.* = .{ .id = display.identity, .uuid = if (known) text(uuid) else null, .name = text(&display.name), .frame = display.frame, .full_bounds = display.full_bounds, .built_in = display.built_in, .workspace = if (placed) |workspace| workspace + 1 else null, .selected = world.selected() == display.identity, .blocked_by_fullscreen = world.displayBlocked(display.identity) };
    }
    return reply.json(items[0..count]);
}

pub fn listWorkspaces() reply.Reply {
    const Item = struct { display: u32, index: usize, name: []const u8, active: bool, urgent: bool, layout: commands.Layout };
    var items: [monitor.capacity * 10]Item = undefined;
    var count: usize = 0;
    for (world.displays()) |display| for (world.config().workspaces[0..world.config().workspace_count], 0..) |*workspace, index| {
        if (world.config().workspace_monitors != null and routing.host(index) != display.identity) continue;
        const layout = if (world.layouts().lookup(display.identity, index)) |state| state.layout else workspace.layout;
        const urgent = for (world.windows()) |window| {
            if (window.urgent and window.display == display.identity and window.workspace == index) break true;
        } else false;
        items[count] = .{ .display = display.identity, .index = index + 1, .name = text(&workspace.name), .active = display.workspace == index, .urgent = urgent, .layout = layout };
        count += 1;
    };
    return reply.json(items[0..count]);
}

// Journals a note with a snapshot of the manager's state, for a user to mark when something looks wrong.
pub fn markWrong(note: []const u8) reply.Reply {
    if (!journal.enabled()) return reply.failure("JournalDisabledByFilter");
    var length = @min(note.len, 200);
    while (length < note.len and note[length] & 0xc0 == 0x80) length -= 1;
    const Shown = struct { display: u32, workspace: ?usize };
    var shown: [monitor.capacity]Shown = undefined;
    for (world.displays(), shown[0..world.displays().len]) |display, *item| item.* = .{ .display = display.identity, .workspace = if (routing.placedWorkspace(display)) |workspace| workspace + 1 else null };
    var parked: usize = 0;
    for (world.windows()) |window| parked += @intFromBool(window.parked);
    if (!journal.append("mark", .{ .note = note[0..length], .window_count = world.windows().len, .parked_count = parked, .workspaces = shown[0..world.displays().len], .transition_error = journal.lastError() })) return reply.failure("JournalAppendFailed");
    return reply.json(.{ .ok = true });
}
