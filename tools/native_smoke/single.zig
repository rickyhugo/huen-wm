//! The default checks and the keyboard workflow checks.
const std = @import("std");
const system = @import("system.zig");
const values = @import("values.zig");
const driver = @import("driver.zig");
const Error = system.Error;
const Value = values.Value;
const Frame = values.Frame;
const Frames = values.Frames;
const Titles = values.Titles;
const Smoke = driver.Smoke;
const workflow_gap = driver.workflow_gap;

/// Tiling, focus, a move, floating return, layout with resize, workspace parking and return, reload, and restore.
pub fn exercise(smoke: *Smoke) Error!void {
    try smoke.preflight();
    try smoke.launchFixture(&.{"--spread"});
    const original = try smoke.fixtureReady("Huen Fixture Alpha");
    const original_frames = try values.frames(original);
    var original_screens: Frames = .empty;
    for (original_frames.keys(), original_frames.values()) |title, frame| {
        for (try values.screens(original)) |screen| {
            if (values.contains(screen.visible_frame, frame, 0, 3)) break try original_screens.put(system.allocator, title, screen.visible_frame);
        } else return system.fail("No display contains fixture window '{s}'", .{title});
    }
    try smoke.config(12);
    try smoke.startManager();
    _ = try smoke.wait("fixture-only management", .windows, driver.FixtureOnly{ .single_display = false }, true);
    const tiled = try smoke.wait("native tiling", .fixture, NativeTiling{ .original_frames = original_frames, .original_screens = original_screens }, true);
    try smoke.snapshot("monitors", try smoke.cli(&.{"monitors"}));
    try smoke.snapshot("workspaces", try smoke.cli(&.{"workspaces"}));
    var focused = try values.keyTitle(tiled) orelse return system.fail("Fixture has no native key window", .{});
    const tiled_frames = try values.frames(tiled);
    const active_frame = try values.frameOf(tiled_frames, focused);
    const active_screen = for (try values.screens(tiled)) |screen| {
        if (values.contains(screen.visible_frame, active_frame, 0, 3)) break screen.visible_frame;
    } else return system.fail("No display contains the focused window", .{});
    var peers: std.ArrayList([]const u8) = .empty;
    for (tiled_frames.keys(), tiled_frames.values()) |title, frame| if (!std.mem.eql(u8, title, focused) and values.contains(active_screen, frame, 0, 3)) try peers.append(system.allocator, title);
    if (peers.items.len == 0) return system.fail("Need two fixture windows on the focused display", .{});
    const target_frame = try values.frameOf(tiled_frames, peers.items[0]);
    const horizontal_delta = target_frame.left - active_frame.left;
    const vertical_delta = target_frame.top - active_frame.top;
    const direction = if (@abs(horizontal_delta) >= @abs(vertical_delta))
        (if (horizontal_delta > 0) "right" else "left")
    else
        (if (vertical_delta > 0) "down" else "up");
    _ = try smoke.cli(&.{ "focus", direction });
    const focused_report = try smoke.wait("native focus changes", .fixture, driver.KeyIn{ .titles = peers.items }, true);
    focused = (try values.keyTitle(focused_report)).?;
    const before_move = try values.frameOf(try values.frames(focused_report), focused);
    _ = try smoke.cli(&.{ "move", "down" });
    _ = try smoke.wait("native move is 40 points", .fixture, try single(focused, before_move.moved(before_move.left, before_move.top + 40)), true);
    _ = try smoke.cli(&.{"toggle-floating"});
    _ = try smoke.wait("return to tiled", .fixture, Tiled{ .gap = 12 }, true);
    _ = try smoke.cli(&.{ "layout", "master" });
    _ = try smoke.cli(&.{ "resize", "0.1" });
    const layout_report = try smoke.wait("layout and resize change native frames", .fixture, Tiled{ .gap = 12, .changed_from = tiled_frames }, true);
    const before_workspace = try values.frames(layout_report);
    var active_titles: std.ArrayList([]const u8) = .empty;
    var other_titles: usize = 0;
    for (before_workspace.keys(), before_workspace.values()) |title, frame| {
        if (values.contains(active_screen, frame, 0, 3)) try active_titles.append(system.allocator, title) else other_titles += 1;
    }
    try smoke.record("multi_display_covered", .{ .bool = other_titles > 0 });
    const expected_presentation = if (smoke.options.scenes) "captured" else "instant";
    const before_workspace_generation = try values.number(try values.get(try smoke.cli(&.{"status"}), "snapshot_generation"));
    _ = try smoke.cli(&.{ "workspace", "2" });
    _ = try smoke.wait("workspace preserves size at one-point vertical strip on active display only", .fixture, CornerParked{ .before = before_workspace, .active_screen = active_screen, .active_titles = active_titles.items }, true);
    _ = try smoke.wait("workspace transition settles", .status, Settled{ .presentation = expected_presentation, .generation = before_workspace_generation }, true);
    const before_return_generation = try values.number(try values.get(try smoke.cli(&.{"status"}), "snapshot_generation"));
    _ = try smoke.cli(&.{ "workspace", "1" });
    _ = try smoke.wait("workspace returns native frames", .fixture, AllClose{ .expected = before_workspace, .tolerance = 2 }, true);
    _ = try smoke.wait("return transition settles", .status, Settled{ .presentation = expected_presentation, .generation = before_return_generation }, true);
    const before_valid_reload = try reloadRequest(smoke);
    try smoke.config(32);
    _ = try smoke.wait("valid automatic reload completes", .reload, Reloaded{ .after = before_valid_reload, .state = "ready" }, true);
    const reloaded = try smoke.wait("valid reload changes native gap", .fixture, Tiled{ .gap = 32, .changed_from = before_workspace }, true);
    const reloaded_frames = try values.frames(reloaded);
    const before_invalid_reload = try reloadRequest(smoke);
    try system.writeText(smoke.config_path, "return {gap='invalid'}\n");
    _ = try smoke.wait("invalid automatic reload fails", .reload, Reloaded{ .after = before_invalid_reload, .state = "failed" }, true);
    const before_invalid_move = try smoke.wait("invalid reload preserves native frames", .fixture, AllClose{ .expected = reloaded_frames, .tolerance = 3 }, true);
    focused = try values.keyTitle(before_invalid_move) orelse return system.fail("Fixture lost native focus after workspace return", .{});
    const invalid_frame = try values.frameOf(try values.frames(before_invalid_move), focused);
    _ = try smoke.cli(&.{ "move", "down" });
    _ = try smoke.wait("commands survive invalid reload", .fixture, try single(focused, invalid_frame.moved(invalid_frame.left, invalid_frame.top + 40)), true);
    _ = try smoke.cli(&.{"toggle-floating"});
    _ = try smoke.wait("invalid reload retains native layout", .fixture, AllClose{ .expected = reloaded_frames, .tolerance = 3 }, true);
    _ = try smoke.cli(&.{"restore"});
    _ = try smoke.wait("restore original native frames before stop", .fixture, driver.Restored{ .original = original_frames }, true);
    try smoke.record("passed", .{ .bool = true });
}

fn reloadRequest(smoke: *Smoke) Error!f64 {
    return values.number(try values.get(try values.get(try smoke.cli(&.{"status"}), "config_reload"), "request_id"));
}

fn single(title: []const u8, frame: Frame) Error!driver.Framed {
    var expected: Frames = .empty;
    try expected.put(system.allocator, title, frame);
    return .{ .expected = expected };
}

const NativeTiling = struct {
    original_frames: Frames,
    original_screens: Frames,
    pub fn holds(self: NativeTiling, _: *Smoke, report: Value) Error!bool {
        if (!try Smoke.tiled(report, 12)) return false;
        const observed = try values.frames(report);
        for (observed.keys(), observed.values()) |title, frame| if (!values.contains(try values.frameOf(self.original_screens, title), frame, 12, 3)) return false;
        for (observed.keys(), observed.values()) |title, frame| if (values.closeFrame(frame, try values.frameOf(self.original_frames, title), 3)) return false;
        return true;
    }
};

/// The report is tiled with `gap`, and some frame differs from `changed_from` when given.
const Tiled = struct {
    gap: f64,
    changed_from: ?Frames = null,
    pub fn holds(self: Tiled, _: *Smoke, report: Value) Error!bool {
        if (!try Smoke.tiled(report, self.gap)) return false;
        const previous = self.changed_from orelse return true;
        const observed = try values.frames(report);
        for (observed.keys(), observed.values()) |title, frame| if (!values.closeFrame(frame, try values.frameOf(previous, title), 3)) return true;
        return false;
    }
};

/// Every report frame is within `tolerance` of its expected frame.
const AllClose = struct {
    expected: Frames,
    tolerance: f64,
    pub fn holds(self: AllClose, _: *Smoke, report: Value) Error!bool {
        const observed = try values.frames(report);
        for (observed.keys(), observed.values()) |title, frame| if (!values.closeFrame(frame, try values.frameOf(self.expected, title), self.tolerance)) return false;
        return true;
    }
};

const Settled = struct {
    presentation: []const u8,
    generation: f64,
    pub fn holds(self: Settled, _: *Smoke, status: Value) Error!bool {
        return !values.truthy(values.field(status, "transition_pending")) and
            values.sameText(values.field(status, "snapshot_presentation"), self.presentation) and
            try values.number(try values.get(status, "snapshot_generation")) > self.generation;
    }
};

const Reloaded = struct {
    after: f64,
    state: []const u8,
    pub fn holds(self: Reloaded, _: *Smoke, reload: Value) Error!bool {
        if (!(try values.number(try values.get(reload, "request_id")) > self.after)) return false;
        if (!values.sameText(try values.get(reload, "state"), self.state)) return false;
        return !std.mem.eql(u8, self.state, "failed") or values.truthy(try values.get(reload, "err_message"));
    }
};

const CornerParked = struct {
    before: Frames,
    active_screen: Frame,
    active_titles: Titles,

    pub fn holds(self: CornerParked, smoke: *Smoke, report: Value) Error!bool {
        const observed = try values.frames(report);
        const active = self.active_screen;
        var other_screens: std.json.Array = .init(system.allocator);
        var other_bounds: std.ArrayList(Frame) = .empty;
        for (try values.screens(report)) |screen| if (!screen.visible_frame.eql(active)) {
            try other_screens.append(try screen.full_bounds.json());
            try other_bounds.append(system.allocator, screen.full_bounds);
        };
        var evidence: std.json.ObjectMap = .empty;
        var all_parked = true;
        for (self.active_titles) |title| {
            const original = try values.frameOf(self.before, title);
            const actual = try values.frameOf(observed, title);
            const sides = [_]struct { []const u8, Frame }{
                .{ "bottom-right", original.moved(active.right() - 1, active.bottom() - 1) },
                .{ "bottom-left", original.moved(active.left + 1 - original.width, active.bottom() - 1) },
            };
            var observed_side: ?usize = null;
            for (sides, 0..) |side, index| if (@abs(actual.left - side[1].left) <= 2 and @abs(actual.right() - side[1].right()) <= 2) {
                observed_side = index;
                break;
            };
            const horizontal_contact = @max(0, @min(active.right(), actual.right()) - @max(active.left, actual.left));
            const vertical_contact = @max(0, @min(active.bottom(), actual.bottom()) - @max(active.top, actual.top));
            const size_preserved = @abs(actual.width - original.width) <= 2 and @abs(actual.height - original.height) <= 2;
            const strip = observed_side != null and horizontal_contact > 0 and horizontal_contact <= 3 and
                active.top <= actual.top and actual.top <= active.bottom() and actual.bottom() >= active.bottom();
            var intersects = false;
            for (other_bounds.items) |bounds| if (values.overlaps(actual, bounds, 0)) {
                intersects = true;
            };
            try evidence.put(system.allocator, title, try values.object(&.{
                .{ "before", try original.json() },
                .{ "actual", try actual.json() },
                .{ "observed_side", if (observed_side) |index| values.string(sides[index][0]) else .null },
                .{ "desired", if (observed_side) |index| try sides[index][1].json() else .null },
                .{ "corner_contact_points", try values.object(&.{ .{ "horizontal", .{ .float = horizontal_contact } }, .{ "vertical", .{ .float = vertical_contact } } }) },
                .{ "size_preserved", .{ .bool = size_preserved } },
                .{ "one_point_vertical_strip_with_two_point_readback_tolerance", .{ .bool = strip } },
                .{ "intersects_other_display", .{ .bool = intersects } },
            }));
            if (!size_preserved or !strip or intersects) all_parked = false;
        }
        var unchanged = true;
        for (self.before.keys(), self.before.values()) |title, original| {
            if (values.has(self.active_titles, title)) continue;
            if (!values.closeFrame(try values.frameOf(observed, title), original, 2)) unchanged = false;
        }
        try smoke.record("corner_parking", try values.object(&.{
            .{ "visible_frame", try active.json() },
            .{ "other_full_bounds", .{ .array = other_screens } },
            .{ "screen_bounds", try values.get(report, "screens") },
            .{ "windows", .{ .object = evidence } },
            .{ "other_display_frames_unchanged", .{ .bool = unchanged } },
        }));
        return unchanged and all_parked;
    }
};

/// Keyboard workflow commands on one display with workspaces One, Two, and Three.
pub fn exerciseWorkflow(smoke: *Smoke) Error!void {
    try smoke.preflight();
    try smoke.launchFixture(&.{ "--windows", "3" });
    const original_frames = try values.frames(try smoke.fixtureReady(null));
    try smoke.workflowConfig();
    try smoke.startManager();
    const managed = try smoke.wait("fixture-only management on one display", .windows, driver.FixtureOnly{ .single_display = true }, true);
    smoke.display = try values.get((try values.items(managed))[0], "display");
    try smoke.learnIdentities(managed);
    const everyone = smoke.everyone();
    const tiled = try smoke.wait("native tiling on one display", .fixture, OneDisplayTiling{}, true);
    smoke.screen = try OneDisplayTiling.screen(tiled) orelse unreachable;
    try smoke.snapshot("monitors", try smoke.cli(&.{"monitors"}));
    try smoke.snapshot("workspaces", try smoke.cli(&.{"workspaces"}));
    _ = try view(smoke, "all windows shown on workspace 1", 1, everyone, null);

    try smoke.rejected("workspace previous before any switch", &.{ "workspace", "previous" }, "NoPreviousWorkspace");
    _ = try smoke.reply("workspace occupied+1 alone replies unchanged", &.{ "workspace", "occupied+1" }, .unchanged);
    _ = try view(smoke, "workspace occupied+1 alone stays on 1", 1, everyone, null);
    _ = try switchTo(smoke, "workspace -1 wraps from 1 to 3", "-1", 3, &.{}, null);
    _ = try switchTo(smoke, "workspace +1 wraps from 3 to 1", "+1", 1, everyone, null);
    _ = try switchTo(smoke, "workspace 2 parks every window", "2", 2, &.{}, null);
    _ = try switchTo(smoke, "workspace previous returns to 1", "previous", 1, everyone, null);
    _ = try switchTo(smoke, "workspace 2 again", "2", 2, &.{}, null);
    _ = try switchTo(smoke, "workspace 2 on 2 returns to previous with back-and-forth", "2", 1, everyone, null);
    _ = try switchTo(smoke, "workspace name:Two resolves to 2", "name:Two", 2, &.{}, null);
    try smoke.rejected("workspace name:Missing is unknown", &.{ "workspace", "name:Missing" }, "UnknownWorkspaceName");
    _ = try switchTo(smoke, "workspace name:One resolves to 1", "name:One", 1, everyone, null);
    _ = try switchTo(smoke, "workspace empty selects first empty 2", "empty", 2, &.{}, null);
    _ = try switchTo(smoke, "workspace next-empty from 2 selects 3", "next-empty", 3, &.{}, null);
    const returned = try switchTo(smoke, "workspace 1 before focus history", "1", 1, everyone, null);

    const first = try focusedIn(returned, everyone);
    const second = try smoke.titleOf(values.field(try smoke.cli(&.{ "cycle", "next" }), "target") orelse return system.fail("Missing field 'target' in the cycle reply", .{}));
    _ = try view(smoke, "cycle next prepares focus history", 1, everyone, second);
    _ = try smoke.cli(&.{ "focus", "last" });
    _ = try view(smoke, "focus last returns to previous window", 1, everyone, first);
    _ = try smoke.cli(&.{ "focus", "last" });
    _ = try view(smoke, "focus last toggles back", 1, everyone, second);
    try smoke.targets("move-to-workspace 3 targets the focused window", &.{ "move-to-workspace", "3" }, second);
    _ = try view(smoke, "move-to-workspace 3 shows and focuses moved window on 3", 3, &.{second}, second);
    const others = try values.without(everyone, second);
    _ = try smoke.cli(&.{ "focus", "last" });
    _ = try view(smoke, "focus last switches to workspace 1", 1, others, first);
    _ = try smoke.cli(&.{ "focus", "last" });
    _ = try view(smoke, "focus last switches back to workspace 3", 3, &.{second}, second);
    try smoke.targets("cycle next with one window targets it", &.{ "cycle", "next" }, second);
    _ = try view(smoke, "cycle next with one window keeps focus", 3, &.{second}, second);
    _ = try switchTo(smoke, "workspace occupied+1 wraps from 3 to 1", "occupied+1", 1, others, null);
    _ = try switchTo(smoke, "workspace occupied+1 skips empty 2", "occupied+1", 3, &.{second}, null);

    const remaining = try switchTo(smoke, "workspace 1 before filling 2", "1", 1, others, null);
    const third = try focusedIn(remaining, others);
    _ = try smoke.cli(&.{ "move-to-workspace", "2" });
    _ = try view(smoke, "move-to-workspace 2 fills every workspace", 2, &.{third}, third);
    try smoke.rejected("workspace empty with every workspace occupied", &.{ "workspace", "empty" }, "NoEmptyWorkspace");
    try smoke.rejected("workspace next-empty with every workspace occupied", &.{ "workspace", "next-empty" }, "NoEmptyWorkspace");
    _ = try smoke.cli(&.{ "move-to-workspace", "1" });
    _ = try view(smoke, "move-to-workspace 1 regroups", 1, others, third);
    _ = try switchTo(smoke, "workspace 3 before regrouping", "3", 3, &.{second}, second);
    _ = try smoke.cli(&.{ "move-to-workspace", "1" });
    _ = try view(smoke, "all windows regrouped on 1", 1, everyone, second);

    const settled = try smoke.wait("regrouped dwindle tiles settle", .workflow, Shows{ .workspace = 1, .titles = everyone, .tiled = true }, true);
    const tile_frames = try values.frames(try values.get(settled, "report"));
    const order = try readingOrder(smoke, everyone, tile_frames);
    try smoke.record("workflow_reading_order", try values.strings(order));
    var current = try focusedIn(settled, everyone);
    for (1..4) |count| current = try cycleStep(smoke, try std.fmt.allocPrint(system.allocator, "cycle next {d}", .{count}), 1, order, current);
    for (1..4) |count| current = try cycleStep(smoke, try std.fmt.allocPrint(system.allocator, "cycle previous {d}", .{count}), -1, order, current);

    const source = current;
    const neighbor = order[(indexOf(order, source) + 1) % order.len];
    var swapped = try tile_frames.clone(system.allocator);
    try swapped.put(system.allocator, source, try values.frameOf(tile_frames, neighbor));
    try swapped.put(system.allocator, neighbor, try values.frameOf(tile_frames, source));
    _ = try smoke.cli(&.{ "swap", "next" });
    _ = try smoke.wait("swap next exchanges reading-order neighbor frames", .fixture, driver.Framed{ .expected = swapped, .key = source }, true);
    _ = try smoke.cli(&.{ "swap", "previous" });
    _ = try smoke.wait("swap previous restores tile frames", .fixture, driver.Framed{ .expected = tile_frames, .key = source }, true);

    _ = try smoke.cli(&.{"toggle-floating"});
    _ = try smoke.wait("focused window floats", .windows, Floats{ .title = source }, true);
    try smoke.rejected("swap next on floating window", &.{ "swap", "next" }, "WindowNotTiled");
    const area = values.inset(smoke.screen.?, workflow_gap);
    const floating = try values.frameOf(try values.frames(try smoke.fixture()), source);
    _ = try smoke.cli(&.{ "move-by", "10000", "10000" });
    _ = try smoke.wait("move-by stays inside the bottom-right of the visible area", .fixture, try single(source, floating.moved(area.right() - floating.width, area.bottom() - floating.height)), true);
    _ = try smoke.cli(&.{ "move-by", "-10000", "-10000" });
    _ = try smoke.wait("move-by stays inside the top-left of the visible area", .fixture, try single(source, floating.moved(area.left, area.top)), true);
    const centered = floating.moved(area.left + (area.width - floating.width) / 2, area.top + (area.height - floating.height) / 2);
    _ = try smoke.cli(&.{"center"});
    _ = try smoke.wait("center centers in the visible area", .fixture, try single(source, centered), true);
    const shrunk: Frame = .{ .left = centered.left, .top = centered.top, .width = centered.width - 100, .height = centered.height - 60 };
    _ = try smoke.cli(&.{ "resize-by", "-100", "-60" });
    _ = try smoke.wait("resize-by shrinks and keeps top-left", .fixture, try single(source, shrunk), true);
    _ = try smoke.cli(&.{ "resize-by", "10000", "10000" });
    const grown: Frame = .{ .left = shrunk.left, .top = shrunk.top, .width = area.right() - shrunk.left, .height = area.bottom() - shrunk.top };
    _ = try smoke.wait("resize-by grows to the visible edge and keeps top-left", .fixture, try single(source, grown), true);
    const tiled_peer = try smoke.titleOf(values.field(try smoke.cli(&.{ "cycle", "next", "tiled" }), "target") orelse return system.fail("Missing field 'target' in the cycle reply", .{}));
    _ = try smoke.wait("cycle next tiled leaves the floating window", .fixture, driver.Framed{ .expected = .empty, .key = tiled_peer }, true);
    try smoke.rejected("center on tiled window", &.{"center"}, "WindowNotFloating");
    try smoke.rejected("move-by on tiled window", &.{ "move-by", "10", "10" }, "WindowNotFloating");

    _ = try smoke.cli(&.{"restore"});
    _ = try smoke.wait("restore original native frames before stop", .fixture, driver.Restored{ .original = original_frames }, true);
    try smoke.record("passed", .{ .bool = true });
}

const OneDisplayTiling = struct {
    pub fn holds(_: OneDisplayTiling, _: *Smoke, report: Value) Error!bool {
        return try Smoke.tiled(report, workflow_gap) and try screen(report) != null;
    }

    /// The first visible frame that holds every window inside the workflow gap.
    fn screen(report: Value) Error!?Frame {
        const observed = try values.frames(report);
        for (try values.screens(report)) |candidate| {
            for (observed.values()) |frame| {
                if (!values.contains(candidate.visible_frame, frame, workflow_gap, 3)) break;
            } else return candidate.visible_frame;
        }
        return null;
    }
};

/// Workspace `workspace` is active and shows exactly `titles`, every other window parked, and `key` focused when given.
const Shows = struct {
    workspace: i64,
    titles: Titles,
    key: ?[]const u8 = null,
    tiled: bool = false,

    pub fn holds(self: Shows, smoke: *Smoke, observation: Value) Error!bool {
        if (!try shows(smoke, observation, self.workspace, self.titles, self.key)) return false;
        return !self.tiled or try Smoke.tiled(try values.get(observation, "report"), workflow_gap);
    }
};

fn shows(smoke: *Smoke, observation: Value, workspace: i64, titles: Titles, key: ?[]const u8) Error!bool {
    const report = try values.get(observation, "report");
    if (!values.truthy(report) or !values.sameNumber(try values.get(observation, "active"), @floatFromInt(workspace))) return false;
    const observed = try values.frames(report);
    var managed: std.StringArrayHashMapUnmanaged(Value) = .empty;
    for (try values.items(try values.get(observation, "windows"))) |window| try managed.put(system.allocator, try values.text(try values.get(window, "title")), window);
    if (!values.sameTitles(values.titlesOf(observed), smoke.everyone()) or !values.sameTitles(managed.keys(), smoke.everyone())) return false;
    const screen = smoke.screen.?;
    for (smoke.everyone()) |title| {
        const window = managed.get(title).?;
        const frame = try values.frameOf(observed, title);
        if (values.has(titles, title)) {
            if (!values.sameNumber(try values.get(window, "workspace"), @floatFromInt(workspace)) or values.truthy(try values.get(window, "parked")) or !values.contains(screen, frame, workflow_gap, 3)) return false;
        } else if (!values.truthy(try values.get(window, "parked")) or !parked(screen, frame)) return false;
    }
    const expected = key orelse return true;
    const actual = try values.keyTitle(report);
    return actual != null and std.mem.eql(u8, actual.?, expected);
}

fn parked(screen: Frame, frame: Frame) bool {
    return @min(screen.right(), frame.right()) - @max(screen.left, frame.left) <= 3;
}

fn view(smoke: *Smoke, name: []const u8, workspace: i64, titles: Titles, key: ?[]const u8) Error!Value {
    return smoke.wait(name, .workflow, Shows{ .workspace = workspace, .titles = titles, .key = key }, true);
}

fn switchTo(smoke: *Smoke, name: []const u8, selector: []const u8, workspace: i64, titles: Titles, key: ?[]const u8) Error!Value {
    _ = try smoke.cli(&.{ "workspace", selector });
    return view(smoke, name, workspace, titles, key);
}

fn focusedIn(observation: Value, candidates: Titles) Error![]const u8 {
    const title = try values.keyTitle(try values.get(observation, "report"));
    if (title == null or !values.has(candidates, title)) return system.fail("Expected native focus within {f}: {f}", .{ values.fmt(try values.strings(candidates)), values.fmt(if (title) |known| values.string(known) else .null) });
    return title.?;
}

fn indexOf(order: Titles, title: []const u8) usize {
    for (order, 0..) |candidate, index| if (std.mem.eql(u8, candidate, title)) return index;
    unreachable;
}

/// Titles by rounded top, then rounded left, then window identity.
fn readingOrder(smoke: *Smoke, titles: Titles, tile_frames: Frames) Error![]const []const u8 {
    const Key = struct { title: []const u8, top: f64, left: f64, identity: f64 };
    const keys = try system.allocator.alloc(Key, titles.len);
    for (titles, keys) |title, *key| {
        const frame = try values.frameOf(tile_frames, title);
        key.* = .{ .title = title, .top = values.roundEven(frame.top), .left = values.roundEven(frame.left), .identity = try values.number(try smoke.identity(title)) };
    }
    std.mem.sort(Key, keys, {}, struct {
        fn before(_: void, first: Key, second: Key) bool {
            if (first.top != second.top) return first.top < second.top;
            if (first.left != second.left) return first.left < second.left;
            return first.identity < second.identity;
        }
    }.before);
    const order = try system.allocator.alloc([]const u8, keys.len);
    for (keys, order) |key, *title| title.* = key.title;
    return order;
}

fn cycleStep(smoke: *Smoke, name: []const u8, step: i64, order: Titles, current: []const u8) Error![]const u8 {
    const length: i64 = @intCast(order.len);
    const expected = order[@intCast(@mod(@as(i64, @intCast(indexOf(order, current))) + step, length))];
    const direction = if (step > 0) "next" else "previous";
    try smoke.targets(try std.fmt.allocPrint(system.allocator, "{s} targets {s}", .{ name, expected }), &.{ "cycle", direction }, expected);
    _ = try view(smoke, try std.fmt.allocPrint(system.allocator, "{s} focuses {s}", .{ name, expected }), 1, order, expected);
    return expected;
}

const Floats = struct {
    title: []const u8,
    pub fn holds(self: Floats, _: *Smoke, windows: Value) Error!bool {
        for (try values.items(windows)) |window| if (values.sameText(try values.get(window, "title"), self.title) and values.truthy(try values.get(window, "floating"))) return true;
        return false;
    }
};
