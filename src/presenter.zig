const std = @import("std");
const native = @import("native.zig");
const journal = @import("journal.zig");
const world = @import("world.zig");
const routing = @import("routing.zig");
const scene = @import("scene.zig");
const reload = @import("reload.zig");
const hotkeys = @import("hotkeys.zig");
const gestures = @import("gestures.zig");
const text = native.text;
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
