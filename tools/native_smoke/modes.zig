//! The two-display modes: owner routing, monitor focus, per-workspace monitors, moves between displays, and restart.
const std = @import("std");
const system = @import("system.zig");
const values = @import("values.zig");
const driver = @import("driver.zig");
const displays = @import("displays.zig");
const Error = system.Error;
const Value = values.Value;
const Titles = values.Titles;
const Smoke = driver.Smoke;
const Active = displays.Active;
const Membership = displays.Membership;
const Landing = displays.Landing;
const owners = displays.owner_order;

fn label(comptime format: []const u8, arguments: anytype) Error![]const u8 {
    return std.fmt.allocPrint(system.allocator, format, arguments);
}

fn displayPair(external: i64, built_in: i64) Error!Value {
    return values.object(&.{ .{ "external", values.integer(external) }, .{ "built_in", values.integer(built_in) } });
}

/// `workspace_monitors` owner routing (N1).
pub fn exerciseOwner(smoke: *Smoke) Error!void {
    const original_frames = try displays.startMultiDisplay(smoke, owners, false, false, null);
    const owner = smoke.external;
    const other = smoke.built_in;
    const everyone = smoke.everyone();
    const home = try displays.memberships(everyone, 1);
    try smoke.record("owner_displays", try displayPair(owner, other));
    var resting = try displays.placePointer(smoke, other);
    _ = try displays.routed(smoke, "owner mode migrates every window to the external owner", owner, 1, everyone, &.{});
    _ = try smoke.cli(&.{ "workspace", "2" });
    _ = try displays.routed(smoke, "workspace 2 parks every window on the owner", owner, 2, &.{}, home);
    _ = try smoke.cli(&.{ "workspace", "1" });
    _ = try displays.routed(smoke, "workspace 1 shows every window on the owner", owner, 1, everyone, &.{});
    try displays.selected(smoke, "workspace 1 selects the owner without a pointer warp", owner, resting);
    const sent = try smoke.keyed("workspace 1 focuses a fixture window", everyone);
    const stay = try values.without(everyone, sent);
    const before = try smoke.cli(&.{"status"});
    try smoke.accepted("send-to-workspace 2 is accepted", &.{ "send-to-workspace", "2" });
    const after = try displays.routed(smoke, "send-to-workspace 2 parks only the sent window and keeps workspace 1", owner, 1, stay, &.{.{ .title = sent, .workspace = 2 }});
    const after_status = try values.get(after, "status");
    try smoke.check(
        "send-to-workspace keeps the owner and selected monitor",
        values.sameNumber(try values.get(after_status, "workspace_owner"), @floatFromInt(owner)) and values.same(try values.get(after_status, "selected_monitor"), try values.get(before, "selected_monitor")),
        try values.object(&.{ .{ "before", before }, .{ "after", after_status } }),
    );
    _ = try smoke.cli(&.{ "workspace", "2" });
    _ = try displays.routed(smoke, "workspace 2 shows the sent window", owner, 2, &.{sent}, try displays.memberships(stay, 1));
    _ = try smoke.keyed("workspace 2 focuses the sent window", &.{sent});
    try smoke.accepted("send-to-workspace 1 is accepted", &.{ "send-to-workspace", "1" });
    _ = try displays.routed(smoke, "send-to-workspace 1 returns the window and leaves workspace 2 empty", owner, 2, &.{}, home);
    _ = try smoke.cli(&.{ "workspace", "1" });
    _ = try displays.routed(smoke, "workspace 1 shows every window again", owner, 1, everyone, &.{});

    resting = try displays.placePointer(smoke, owner);
    try displays.reloadMonitors(smoke, "reload makes the built-in display the owner", &.{ "built-in", "external" }, false, false);
    _ = try displays.routed(smoke, "owner change migrates every window to built-in", other, 1, everyone, &.{});
    try displays.selected(smoke, "background routing keeps the selected monitor", owner, resting);
    _ = try smoke.cli(&.{ "workspace", "1" });
    try displays.selected(smoke, "workspace 1 selects the new owner without a pointer warp", other, resting);

    resting = try displays.placePointer(smoke, other);
    try displays.reloadMonitors(smoke, "reload restores the external owner with mouse follow", owners, true, false);
    _ = try displays.routed(smoke, "owner change migrates every window back to external", owner, 1, everyone, &.{});
    try displays.selected(smoke, "background routing does not warp the pointer", other, resting);
    _ = try smoke.cli(&.{ "workspace", "1" });
    try displays.selected(smoke, "workspace 1 selects the owner and warps the pointer", owner, values.center(try displays.boundsOf(smoke, owner)));
    try smoke.restored(original_frames);
    try smoke.record("passed", .{ .bool = true });
}

/// Per-workspace monitors (N2).
pub fn exerciseGlobal(smoke: *Smoke) Error!void {
    const original_frames = try displays.startMultiDisplay(smoke, owners, false, true, null);
    const external = smoke.external;
    const built_in = smoke.built_in;
    const everyone = smoke.everyone();
    const both: []const Active = &.{ .{ .display = external, .workspace = 1 }, .{ .display = built_in, .workspace = 3 } };
    const second_shown: []const Active = &.{ .{ .display = external, .workspace = 2 }, .{ .display = built_in, .workspace = 3 } };
    try smoke.record("global_displays", try displayPair(external, built_in));
    const resting = try displays.placePointer(smoke, built_in);
    try displays.spread(smoke, "split config routes workspace One to external", both, &.{});

    try smoke.accepted("workspace 1 is accepted", &.{ "workspace", "1" });
    try displays.selected(smoke, "workspace 1 selects external without a pointer warp", external, resting);
    const sent = try smoke.keyed("workspace 1 focuses a fixture window", everyone);
    const stay = try values.without(everyone, sent);
    const moved: []const Membership = &.{.{ .title = sent, .workspace = 3 }};
    try smoke.accepted("send-to-workspace 3 from external is accepted", &.{ "send-to-workspace", "3" });
    try displays.spread(smoke, "send-to-workspace 3 moves the window to built-in", both, moved);
    try displays.selected(smoke, "send-to-workspace keeps external selected", external, resting);

    try smoke.accepted("workspace 3 is accepted", &.{ "workspace", "3" });
    try displays.spread(smoke, "workspace 3 keeps workspace One visible on external", both, moved);
    try displays.selected(smoke, "workspace 3 selects built-in without a pointer warp", built_in, resting);
    _ = try smoke.keyed("workspace 3 focuses the sent window", &.{sent});
    try smoke.accepted("workspace previous is accepted", &.{ "workspace", "previous" });
    try displays.selected(smoke, "workspace previous returns to external", external, resting);
    _ = try smoke.keyed("workspace previous focuses a workspace One window", stay);

    try smoke.accepted("occupied+1 from external is accepted", &.{ "workspace", "occupied+1" });
    try displays.selected(smoke, "occupied+1 jumps to workspace Three on built-in", built_in, resting);
    _ = try smoke.keyed("occupied+1 focuses the sent window", &.{sent});
    try smoke.accepted("occupied+1 from built-in is accepted", &.{ "workspace", "occupied+1" });
    try displays.selected(smoke, "occupied+1 wraps to workspace One on external", external, resting);
    _ = try smoke.keyed("occupied+1 focuses a workspace One window", stay);

    try smoke.accepted("+1 from external is accepted", &.{ "workspace", "+1" });
    try displays.spread(smoke, "+1 shows workspace Two on external", second_shown, moved);
    try displays.selected(smoke, "+1 keeps external selected", external, resting);
    try smoke.accepted("previous from Two is accepted", &.{ "workspace", "previous" });
    try displays.spread(smoke, "previous shows workspace One on external", both, moved);
    const last = try smoke.keyed("previous focuses a workspace One window", stay);

    try smoke.accepted("workspace 3 before focus last is accepted", &.{ "workspace", "3" });
    _ = try smoke.keyed("workspace 3 focuses the sent window again", &.{sent});
    try smoke.targets("focus last targets the external window", &.{ "focus", "last" }, last);
    try displays.selected(smoke, "focus last selects external", external, resting);
    _ = try smoke.keyed("focus last focuses the external window", &.{last});

    try smoke.accepted("workspace 2 before hidden focus last is accepted", &.{ "workspace", "2" });
    try displays.spread(smoke, "workspace 2 parks workspace One", second_shown, moved);
    try smoke.accepted("workspace 3 before hidden focus last is accepted", &.{ "workspace", "3" });
    _ = try smoke.keyed("workspace 3 focuses the sent window before hidden focus last", &.{sent});
    try displays.selected(smoke, "workspace 3 selects built-in before hidden focus last", built_in, resting);
    try smoke.accepted("focus last to a hidden workspace is accepted", &.{ "focus", "last" });
    try displays.spread(smoke, "focus last shows workspace One on external", both, moved);
    try displays.selected(smoke, "focus last to a hidden workspace selects external", external, resting);
    _ = try smoke.keyed("focus last focuses the hidden window", &.{last});

    try displays.reloadMonitors(smoke, "reload enables mouse follow", owners, true, true);
    try displays.spread(smoke, "reload keeps the split placement", both, moved);
    _ = try displays.placePointer(smoke, external);
    try smoke.accepted("workspace 3 with mouse follow is accepted", &.{ "workspace", "3" });
    try displays.selected(smoke, "workspace 3 warps the pointer to built-in", built_in, values.center(try displays.boundsOf(smoke, built_in)));
    try smoke.accepted("previous with mouse follow is accepted", &.{ "workspace", "previous" });
    try displays.selected(smoke, "workspace previous warps the pointer to external", external, values.center(try displays.boundsOf(smoke, external)));

    try displays.reloadMonitors(smoke, "reload to owner config", owners, false, false);
    _ = try displays.routed(smoke, "owner config routes every window to external", external, 1, stay, moved);
    try smoke.check("owner config does not block routing", values.isFalse(values.field(try smoke.cli(&.{"status"}), "routing_blocked")), try smoke.cli(&.{"status"}));
    try displays.reloadMonitors(smoke, "reload back to split config", owners, false, true);
    try displays.spread(smoke, "split config returns workspace Three to built-in", both, moved);
    try smoke.restored(original_frames);
    try smoke.record("passed", .{ .bool = true });
}

/// `focus-monitor` selectors (N3).
pub fn exerciseMonitors(smoke: *Smoke) Error!void {
    const original_frames = try displays.startMultiDisplay(smoke, null, true, false, null);
    const everyone = smoke.everyone();
    _ = try smoke.wait("independent mode keeps windows on both displays", .windows, BothDisplays{}, true);
    var first_workspaces: std.ArrayList(Active) = .empty;
    for (smoke.monitors.keys()) |identity| try first_workspaces.append(system.allocator, .{ .display = identity, .workspace = 1 });
    try displays.monitorListing(smoke, "monitors reports uuid, workspace, and selection", first_workspaces.items);
    const external_name = try values.text(try values.get(try displays.monitorOf(smoke, smoke.external), "name"));
    const by_name = try label("name:{s}", .{external_name});
    for ([_][]const u8{ "built-in", by_name, "left", "right", "up", "down", "next", "previous", "external", "built-in", "next" }) |selector| {
        _ = try displays.focusMonitor(smoke, "independent", selector, true);
    }
    try smoke.rejected("focus-monitor name:Missing is unknown", &.{ "focus-monitor", "name:Huen Missing Monitor" }, "UnknownMonitorName");

    try displays.reloadMonitors(smoke, "reload enables the external owner", owners, true, false);
    _ = try displays.routed(smoke, "owner mode migrates every window to external", smoke.external, 1, everyone, &.{});
    _ = try displays.focusMonitor(smoke, "owner", "external", true);
    try displays.monitorListing(smoke, "owner monitors list only the owner workspace", &.{ .{ .display = smoke.external, .workspace = 1 }, .{ .display = smoke.built_in, .workspace = null } });
    _ = try displays.focusMonitor(smoke, "owner", "built-in", true);
    _ = try displays.focusMonitor(smoke, "owner", by_name, true);
    _ = try displays.focusMonitor(smoke, "owner", "next", true);
    _ = try smoke.cli(&.{ "workspace", "2" });
    _ = try displays.routed(smoke, "owner workspace 2 from built-in activates on external", smoke.external, 2, &.{}, try displays.memberships(everyone, 1));
    try displays.selected(smoke, "owner workspace 2 selects external", smoke.external, null);
    _ = try smoke.cli(&.{ "workspace", "1" });
    _ = try displays.routed(smoke, "owner workspace 1 shows every window", smoke.external, 1, everyone, &.{});

    try displays.reloadMonitors(smoke, "reload disables mouse follow", owners, false, false);
    for ([_][]const u8{ "built-in", "external", "previous", "next" }) |selector| {
        _ = try displays.focusMonitor(smoke, "owner without mouse follow", selector, false);
    }
    try smoke.restored(original_frames);
    try smoke.record("passed", .{ .bool = true });
}

/// Windows on both displays and none parked.
const BothDisplays = struct {
    pub fn holds(_: BothDisplays, smoke: *Smoke, windows: Value) Error!bool {
        var on_built_in = false;
        var on_external = false;
        for (try values.items(windows)) |window| {
            const display = try values.get(window, "display");
            if (values.sameNumber(display, @floatFromInt(smoke.built_in))) {
                on_built_in = true;
            } else if (values.sameNumber(display, @floatFromInt(smoke.external))) {
                on_external = true;
            } else return false;
        }
        if (!on_built_in or !on_external) return false;
        for (try values.items(windows)) |window| if (values.truthy(try values.get(window, "parked"))) return false;
        return true;
    }
};

/// Where every window must be in independent mode, given the windows that moved and the lone display's workspace.
const Independent = struct {
    home: []const struct { []const u8, i64 },
    crowded: i64,

    fn expect(self: Independent, moved: []const Landing, lone_workspace: i64) Error![]const Landing {
        var result: std.ArrayList(Landing) = .empty;
        for (self.home) |entry| {
            var display = entry[1];
            var workspace: i64 = 1;
            for (moved) |landing| if (std.mem.eql(u8, landing.title, entry[0])) {
                display = landing.display;
                workspace = landing.workspace;
            };
            try result.append(system.allocator, .{ .title = entry[0], .display = display, .workspace = workspace, .shown = display == self.crowded or workspace == lone_workspace });
        }
        return result.items;
    }
};

/// Window and workspace moves between displays (N4, N5).
pub fn exerciseMonitorMoves(smoke: *Smoke) Error!void {
    const original_frames = try displays.startMultiDisplay(smoke, null, false, false, null);
    const external = smoke.external;
    const built_in = smoke.built_in;
    try smoke.record("monitor_move_displays", try displayPair(external, built_in));
    const windows = try smoke.wait("independent mode keeps windows on both displays", .windows, BothDisplays{}, true);
    var counts: std.AutoArrayHashMapUnmanaged(i64, std.ArrayList([]const u8)) = .empty;
    for (try values.items(windows)) |window| {
        const entry = try counts.getOrPut(system.allocator, try values.whole(try values.get(window, "display")));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        const title = try values.text(try values.get(window, "title"));
        if (!values.has(entry.value_ptr.items, title)) try entry.value_ptr.append(system.allocator, title);
    }
    var crowded = counts.keys()[0];
    var lone = counts.keys()[0];
    for (counts.keys(), counts.values()) |display, titles| {
        if (titles.items.len > counts.get(crowded).?.items.len) crowded = display;
        if (titles.items.len < counts.get(lone).?.items.len) lone = display;
    }
    const crowded_titles: Titles = counts.get(crowded).?.items;
    const lone_titles: Titles = counts.get(lone).?.items;
    if (crowded_titles.len != 2 or lone_titles.len != 1) {
        var found: std.json.ObjectMap = .empty;
        for (counts.keys(), counts.values()) |display, titles| try found.put(system.allocator, try label("{d}", .{display}), try values.strings(titles.items));
        return system.skip("Needs a 2 and 1 window spread; found {f}", .{values.fmt(.{ .object = found })});
    }
    var home: std.ArrayList(struct { []const u8, i64 }) = .empty;
    for (crowded_titles) |title| try home.append(system.allocator, .{ title, crowded });
    for (lone_titles) |title| try home.append(system.allocator, .{ title, lone });
    const independent: Independent = .{ .home = home.items, .crowded = crowded };
    const crowded_class = try displays.classOf(smoke, crowded);
    const lone_class = try displays.classOf(smoke, lone);

    _ = try displays.focusMonitor(smoke, "independent", crowded_class, false);
    const sent = try smoke.keyed("independent source focuses a window", crowded_titles);
    const other = (try values.without(crowded_titles, sent))[0];
    try displays.monitorReply(smoke, "independent send-to-monitor is accepted", &.{ "send-to-monitor", lone_class }, lone, 1, null);
    try displays.landed(smoke, "independent send-to-monitor lands on the active workspace", try independent.expect(&.{.{ .title = sent, .display = lone, .workspace = 1, .shown = true }}, 1));
    try displays.selected(smoke, "independent send-to-monitor keeps the selection", crowded, null);
    _ = try smoke.keyed("independent send-to-monitor focuses the source candidate", &.{other});
    try smoke.targets("focus last returns to the sent window", &.{ "focus", "last" }, sent);
    try displays.selected(smoke, "focus last selects the sent window display", lone, null);
    try displays.monitorReply(smoke, "independent move-to-monitor back is accepted", &.{ "move-to-monitor", crowded_class }, crowded, 1, sent);
    try displays.landed(smoke, "independent move-to-monitor returns the window", try independent.expect(&.{}, 1));
    try displays.selected(smoke, "independent move-to-monitor selects the target", crowded, null);
    _ = try smoke.keyed("independent move-to-monitor focuses the moved window", &.{sent});

    _ = try displays.focusMonitor(smoke, "independent", lone_class, false);
    try smoke.accepted("independent workspace 2 on the lone display", &.{ "workspace", "2" });
    try displays.landed(smoke, "independent workspace 2 parks the lone display", try independent.expect(&.{}, 2));
    _ = try displays.focusMonitor(smoke, "independent", crowded_class, false);
    const carried = try smoke.keyed("independent carried window is key", crowded_titles);
    try displays.monitorReply(smoke, "independent move-to-monitor onto workspace 2 is accepted", &.{ "move-to-monitor", lone_class }, lone, 2, carried);
    try displays.landed(smoke, "independent move-to-monitor lands on workspace 2", try independent.expect(&.{.{ .title = carried, .display = lone, .workspace = 2, .shown = true }}, 2));
    try displays.selected(smoke, "independent move-to-monitor selects the lone display", lone, null);
    _ = try smoke.keyed("independent move-to-monitor focuses the carried window", &.{carried});
    try displays.monitorReply(smoke, "independent move-to-monitor home is accepted", &.{ "move-to-monitor", crowded_class }, crowded, 1, carried);
    _ = try displays.focusMonitor(smoke, "independent", lone_class, false);
    try smoke.accepted("independent workspace 1 on the lone display", &.{ "workspace", "1" });
    try displays.landed(smoke, "independent layout is restored", try independent.expect(&.{}, 1));
    try smoke.rejected("independent move-workspace-to-monitor needs global routing", &.{ "move-workspace-to-monitor", crowded_class }, "RequiresGlobalWorkspaces");
    try smoke.rejected("independent swap-monitor-workspaces needs global routing", &.{ "swap-monitor-workspaces", crowded_class }, "RequiresGlobalWorkspaces");

    const everyone = smoke.everyone();
    const split: [3]i64 = .{ external, external, built_in };
    const split_active: []const Active = &.{ .{ .display = external, .workspace = 1 }, .{ .display = built_in, .workspace = 3 } };
    try displays.reloadMonitors(smoke, "reload to the split config", owners, false, true);
    try displays.placement(smoke, "split config routes every window to One on external", split, split_active, &.{}, &.{});
    _ = try displays.focusMonitor(smoke, "global", "external", false);
    const global_sent = try smoke.keyed("global source focuses a window", everyone);
    try displays.monitorReply(smoke, "global send-to-monitor built-in is accepted", &.{ "send-to-monitor", "built-in" }, built_in, 3, null);
    try displays.placement(smoke, "global send-to-monitor lands in Three on built-in", split, split_active, &.{.{ .title = global_sent, .workspace = 3 }}, &.{});
    try displays.selected(smoke, "global send-to-monitor keeps external selected", external, null);
    _ = try smoke.keyed("global send-to-monitor focuses an external window", try values.without(everyone, global_sent));
    _ = try displays.focusMonitor(smoke, "global", "built-in", false);
    _ = try smoke.keyed("global focus-monitor built-in focuses the sent window", &.{global_sent});
    try displays.monitorReply(smoke, "global move-to-monitor external is accepted", &.{ "move-to-monitor", "external" }, external, 1, global_sent);
    try displays.placement(smoke, "global move-to-monitor lands in One on external", split, split_active, &.{}, &.{});
    try displays.selected(smoke, "global move-to-monitor selects external", external, null);
    _ = try smoke.keyed("global move-to-monitor focuses the moved window", &.{global_sent});

    try displays.monitorReply(smoke, "move-workspace-to-monitor built-in is accepted", &.{ "move-workspace-to-monitor", "built-in" }, built_in, null, null);
    const moved: [3]i64 = .{ built_in, external, built_in };
    try displays.placement(smoke, "One moves to built-in and external falls back to Two", moved, &.{ .{ .display = external, .workspace = 2 }, .{ .display = built_in, .workspace = 1 } }, &.{}, &.{.{ .index = 1, .display = built_in }});
    try displays.selected(smoke, "move-workspace-to-monitor selects built-in", built_in, null);
    _ = try smoke.keyed("move-workspace-to-monitor focuses a One window", everyone);
    try displays.monitorReply(smoke, "swap-monitor-workspaces external is accepted", &.{ "swap-monitor-workspaces", "external" }, external, null, null);
    const swapped: [3]i64 = .{ external, built_in, built_in };
    try displays.placement(smoke, "swap shows One on external and Two on built-in", swapped, &.{ .{ .display = external, .workspace = 1 }, .{ .display = built_in, .workspace = 2 } }, &.{}, &.{ .{ .index = 1, .display = external }, .{ .index = 2, .display = built_in } });
    try displays.selected(smoke, "swap-monitor-workspaces selects external", external, null);
    try displays.reloadMonitors(smoke, "reload the split config", owners, true, true);
    try displays.placement(smoke, "reload resets homes of workspaces with monitor", split, split_active, &.{}, &.{});

    try displays.reloadMonitors(smoke, "reload to the owner config", owners, false, false);
    const owned: [3]i64 = .{ external, external, external };
    const owned_active: []const Active = &.{ .{ .display = external, .workspace = 1 }, .{ .display = built_in, .workspace = null } };
    try displays.placement(smoke, "owner config routes every workspace to external", owned, owned_active, &.{}, &.{});
    _ = try displays.focusMonitor(smoke, "owner", "external", false);
    try smoke.rejected("owner send-to-monitor to the empty display is rejected", &.{ "send-to-monitor", "built-in" }, "NoWorkspaceOnMonitor");
    try smoke.rejected("owner swap with the empty display is rejected", &.{ "swap-monitor-workspaces", "built-in" }, "NoWorkspaceOnMonitor");
    try displays.monitorReply(smoke, "owner move-workspace-to-monitor built-in is accepted", &.{ "move-workspace-to-monitor", "built-in" }, built_in, null, null);
    const owner_split: [3]i64 = .{ built_in, external, external };
    const owner_split_active: []const Active = &.{ .{ .display = external, .workspace = 2 }, .{ .display = built_in, .workspace = 1 } };
    try displays.placement(smoke, "owner move splits One onto built-in", owner_split, owner_split_active, &.{}, &.{.{ .index = 1, .display = built_in }});
    try displays.reloadMonitors(smoke, "reload the owner config", owners, true, false);
    try displays.placement(smoke, "reload keeps the home of a workspace without monitor", owner_split, owner_split_active, &.{}, &.{.{ .index = 1, .display = built_in }});
    _ = try displays.focusMonitor(smoke, "owner split", "built-in", true);
    try displays.monitorReply(smoke, "move-workspace-to-monitor external is accepted", &.{ "move-workspace-to-monitor", "external" }, external, null, null);
    try displays.placement(smoke, "moving the only built-in workspace leaves built-in empty", owned, owned_active, &.{}, &.{.{ .index = 1, .display = external }});
    try displays.selected(smoke, "the move selects external", external, null);
    _ = try displays.focusMonitor(smoke, "owner", "built-in", true);
    try smoke.rejected("an empty selected display has no workspace to move", &.{ "move-workspace-to-monitor", "external" }, "NoWorkspaceOnMonitor");
    try smoke.rejected("an empty selected display has no layout to change", &.{ "layout", "master" }, "NoWorkspaceOnMonitor");
    try smoke.rejected("an empty selected display has no ratio to resize", &.{ "resize", "0.05" }, "NoWorkspaceOnMonitor");

    try displays.reloadMonitors(smoke, "reload to independent mode", null, false, false);
    var cleared = true;
    for (try values.items(try values.get(try smoke.cli(&.{"status"}), "placements"))) |item| if (!values.sameText(try values.get(item, "home"), "")) {
        cleared = false;
    };
    try smoke.check("independent reload clears every home", cleared, try smoke.cli(&.{"status"}));
    try smoke.restored(original_frames);
    try smoke.record("passed", .{ .bool = true });
}

/// A runtime workspace home survives a clean restart (N6).
pub fn exerciseGlobalRestart(smoke: *Smoke) Error!void {
    const token = system.randomBelow(0x1000000);
    try smoke.record("session_border_color", values.integer(token));
    const original_frames = try displays.startMultiDisplay(smoke, owners, false, true, token);
    const external = smoke.external;
    const built_in = smoke.built_in;
    const everyone = smoke.everyone();
    try smoke.record("global_restart_displays", try displayPair(external, built_in));
    _ = try smoke.wait("a fresh configuration hash has no checkpoint", .session, SessionLoad{ .state = "none", .matched = null }, true);
    const split: [3]i64 = .{ external, external, built_in };
    try displays.placement(smoke, "split config routes every window to One on external", split, &.{ .{ .display = external, .workspace = 1 }, .{ .display = built_in, .workspace = 3 } }, &.{}, &.{});
    _ = try displays.focusMonitor(smoke, "restart", "external", false);
    try displays.monitorReply(smoke, "move-workspace-to-monitor built-in is accepted", &.{ "move-workspace-to-monitor", "built-in" }, built_in, null, null);
    const moved: [3]i64 = .{ built_in, external, built_in };
    const moved_active: []const Active = &.{ .{ .display = external, .workspace = 2 }, .{ .display = built_in, .workspace = 1 } };
    const homes: []const displays.Home = &.{.{ .index = 1, .display = built_in }};
    try displays.placement(smoke, "One moves to built-in with a runtime home", moved, moved_active, &.{}, homes);
    _ = try smoke.keyed("the move focuses a One window", everyone);

    _ = try smoke.cli(&.{"stop"});
    _ = try smoke.wait("manager stops cleanly", .managers, driver.Empty{}, false);
    smoke.manager_started = false;
    _ = try smoke.wait("stop restores original native frames", .fixture, driver.Restored{ .original = original_frames }, false);

    try smoke.startManager();
    _ = try smoke.wait("restart restores the checkpoint", .session, SessionLoad{ .state = "restored", .matched = smoke.identities.count() }, true);
    try displays.placement(smoke, "restart shows One and its windows on its home built-in", moved, moved_active, &.{}, homes);
    try smoke.restored(original_frames);
    try smoke.record("passed", .{ .bool = true });
}

/// `session.load` is `state`, and with `matched` set, every window matched without errors.
const SessionLoad = struct {
    state: []const u8,
    matched: ?usize,
    pub fn holds(self: SessionLoad, _: *Smoke, session: Value) Error!bool {
        if (!values.sameText(try values.get(session, "load"), self.state)) return false;
        const matched = self.matched orelse return true;
        return values.sameNumber(try values.get(session, "matched"), @floatFromInt(matched)) and values.sameNumber(try values.get(session, "errors"), 0);
    }
};
