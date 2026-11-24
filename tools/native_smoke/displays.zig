//! Shared steps of the two-display modes: setup, routing and placement observations, pointer, and monitor selection.
const std = @import("std");
const system = @import("system.zig");
const values = @import("values.zig");
const driver = @import("driver.zig");
const Error = system.Error;
const Value = values.Value;
const Frame = values.Frame;
const Frames = values.Frames;
const Point = values.Point;
const Titles = values.Titles;
const Smoke = driver.Smoke;
const workflow_gap = driver.workflow_gap;

pub const owner_order: []const []const u8 = &.{ "external", "built-in" };

/// A window that belongs to another workspace than the default one.
pub const Membership = struct { title: []const u8, workspace: i64 };
/// The workspace a display shows, or none.
pub const Active = struct { display: i64, workspace: ?i64 };
/// A workspace whose runtime home is a display.
pub const Home = struct { index: i64, display: i64 };
/// Where a window must be, and whether it must be shown.
pub const Landing = struct { title: []const u8, display: i64, workspace: i64, shown: bool };

pub fn memberships(titles: Titles, workspace: i64) Error![]const Membership {
    const result = try system.allocator.alloc(Membership, titles.len);
    for (titles, result) |title, *membership| membership.* = .{ .title = title, .workspace = workspace };
    return result;
}

fn membershipOf(list: []const Membership, title: []const u8, default: i64) i64 {
    for (list) |membership| if (std.mem.eql(u8, membership.title, title)) return membership.workspace;
    return default;
}

fn activeOn(active: []const Active, display: i64) Error!?i64 {
    for (active) |item| if (item.display == display) return item.workspace;
    return system.fail("No active workspace is expected for display {d}", .{display});
}

/// Python formats a float with a trailing `.0` when it is whole.
const PythonFloat = struct {
    number: f64,
    pub fn format(self: PythonFloat, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.number == @trunc(self.number) and @abs(self.number) < 1e16) return writer.print("{d}.0", .{self.number});
        try writer.print("{d}", .{self.number});
    }
};

pub fn describePoint(point: Point) Error![]const u8 {
    return std.fmt.allocPrint(system.allocator, "{{'left': {f}, 'top': {f}}}", .{ PythonFloat{ .number = point.left }, PythonFloat{ .number = point.top } });
}

pub fn monitorConfig(smoke: *Smoke, owners: ?[]const []const u8, follows: bool, split: bool, session_token: ?u32) Error!void {
    var routing: []const u8 = "";
    if (owners) |names| {
        var quoted: std.ArrayList([]const u8) = .empty;
        for (names) |name| try quoted.append(system.allocator, try std.fmt.allocPrint(system.allocator, "'{s}'", .{name}));
        routing = try std.fmt.allocPrint(system.allocator, "workspace_monitors={{{s}}}, ", .{try std.mem.join(system.allocator, ",", quoted.items)});
    }
    const follow = if (follows) "true" else "false";
    const workspaces = if (split)
        "{{name='One',monitor='external'},{name='Two',monitor='external'},{name='Three',monitor='built-in'}}"
    else
        "{'One','Two','Three'}";
    // The token changes the configuration hash, so each restart run reads only its own checkpoint.
    const session = if (session_token) |token| try std.fmt.allocPrint(system.allocator, "session={{enabled=true}}, border_color='#{x:0>6}', ", .{token}) else "";
    try smoke.writeConfig(try std.fmt.allocPrint(system.allocator, "return {{gap={d}, motion_duration=0, workspaces={s}, {s}{s}mouse_follows_monitor={s}, " ++ driver.Smoke.isolation ++ "bindings={{}}}}\n", .{ workflow_gap, workspaces, routing, session, follow }));
}

pub fn reloadMonitors(smoke: *Smoke, name: []const u8, owners: ?[]const []const u8, follows: bool, split: bool) Error!void {
    const before = try values.number(try values.get(try values.get(try smoke.cli(&.{"status"}), "config_reload"), "request_id"));
    try monitorConfig(smoke, owners, follows, split, null);
    _ = try smoke.wait(name, .reload, ReloadReady{ .after = before }, true);
}

const ReloadReady = struct {
    after: f64,
    pub fn holds(self: ReloadReady, _: *Smoke, reload: Value) Error!bool {
        return try values.number(try values.get(reload, "request_id")) > self.after and values.sameText(try values.get(reload, "state"), "ready");
    }
};

/// Starts the fixture and manager on a built-in and an external display, or skips without them.
pub fn startMultiDisplay(smoke: *Smoke, owners: ?[]const []const u8, follows: bool, split: bool, session_token: ?u32) Error!Frames {
    const found = try system.activeDisplays();
    try smoke.record("active_displays", found);
    var built_in_count: usize = 0;
    for (found.array.items) |item| {
        if (values.truthy(values.field(item, "built_in"))) built_in_count += 1;
    }
    const count = found.array.items.len;
    if (count < 2 or built_in_count == count or built_in_count == 0)
        return system.skip("Needs at least two displays, one built-in and one external; found {f}", .{values.fmt(found)});
    try smoke.preflight();
    if (session_token == null) try smoke.launchFixture(&.{"--spread"}) else try smoke.launchFixture(&.{ "--spread", "--identifiers", "unique" });
    const original = try smoke.fixtureReady(null);
    try monitorConfig(smoke, owners, follows, split, session_token);
    try smoke.startManager();
    const managed = try smoke.wait("fixture-only management", .windows, driver.FixtureOnly{ .single_display = false }, true);
    try smoke.learnIdentities(managed);
    const listing = try smoke.cli(&.{"monitors"});
    try smoke.snapshot("monitors", listing);
    smoke.monitors = .empty;
    for (try values.items(listing)) |item| try smoke.monitors.put(system.allocator, try values.whole(try values.get(item, "id")), item);
    var built_in: ?i64 = null;
    var external: ?i64 = null;
    for (smoke.monitors.keys(), smoke.monitors.values()) |identity, monitor| {
        if (values.truthy(try values.get(monitor, "built_in"))) {
            built_in = if (built_in) |known| @min(known, identity) else identity;
        } else external = if (external) |known| @min(known, identity) else identity;
    }
    if (built_in == null or external == null) return system.fail("Manager monitors lack a built-in or external display: {f}", .{values.fmt(listing)});
    smoke.built_in = built_in.?;
    smoke.external = external.?;
    return values.frames(original);
}

pub fn monitorOf(smoke: *Smoke, display: i64) Error!Value {
    return smoke.monitors.get(display) orelse system.fail("Unknown display {d}", .{display});
}

pub fn frameOf(smoke: *Smoke, display: i64) Error!Frame {
    return Frame.read(try values.get(try monitorOf(smoke, display), "frame"));
}

pub fn boundsOf(smoke: *Smoke, display: i64) Error!Frame {
    return Frame.read(try values.get(try monitorOf(smoke, display), "full_bounds"));
}

pub fn classOf(smoke: *Smoke, display: i64) Error![]const u8 {
    return if (values.truthy(try values.get(try monitorOf(smoke, display), "built_in"))) "built-in" else "external";
}

fn managedByTitle(windows: Value) Error!std.StringArrayHashMapUnmanaged(Value) {
    var managed: std.StringArrayHashMapUnmanaged(Value) = .empty;
    for (try values.items(windows)) |window| try managed.put(system.allocator, try values.text(try values.get(window, "title")), window);
    return managed;
}

fn shownOverlap(observed: Frames, shown: Titles) Error!bool {
    for (shown, 0..) |first, index| for (shown[index + 1 ..]) |second| if (values.overlaps(try values.frameOf(observed, first), try values.frameOf(observed, second), 3)) return true;
    return false;
}

/// Every window is on the owner display, `shown` inside its gapped frame, and the others parked off it.
const Routes = struct {
    owner: i64,
    active: i64,
    shown: Titles,
    memberships: []const Membership,

    pub fn holds(self: Routes, smoke: *Smoke, observation: Value) Error!bool {
        const report = try values.get(observation, "report");
        if (!values.truthy(report) or !values.sameNumber(values.field(try values.get(observation, "status"), "workspace_owner"), @floatFromInt(self.owner))) return false;
        const listing = try values.get(observation, "workspaces");
        if (!values.truthy(listing)) return false;
        const owner: f64 = @floatFromInt(self.owner);
        for (try values.items(listing)) |item| if (!values.sameNumber(try values.get(item, "display"), owner)) return false;
        var active_count: usize = 0;
        for (try values.items(listing)) |item| if (values.truthy(try values.get(item, "active"))) {
            active_count += 1;
            if (!values.sameNumber(try values.get(item, "index"), @floatFromInt(self.active))) return false;
        };
        if (active_count != 1) return false;
        const managed = try managedByTitle(try values.get(observation, "windows"));
        const observed = try values.frames(report);
        if (!values.sameTitles(managed.keys(), smoke.everyone()) or !values.sameTitles(values.titlesOf(observed), smoke.everyone())) return false;
        const area = try frameOf(smoke, self.owner);
        for (managed.keys(), managed.values()) |title, window| {
            if (!values.sameNumber(try values.get(window, "display"), owner)) return false;
            if (!values.sameNumber(try values.get(window, "workspace"), @floatFromInt(membershipOf(self.memberships, title, self.active)))) return false;
            if (values.has(self.shown, title)) {
                if (values.truthy(try values.get(window, "parked")) or !values.contains(area, try values.frameOf(observed, title), workflow_gap, 3)) return false;
            } else if (!values.truthy(try values.get(window, "parked")) or values.overlaps(area, try values.frameOf(observed, title), 3)) return false;
        }
        return !try shownOverlap(observed, self.shown);
    }
};

pub fn routed(smoke: *Smoke, name: []const u8, owner: i64, active: i64, shown: Titles, moved: []const Membership) Error!Value {
    return smoke.wait(name, .routing, Routes{ .owner = owner, .active = active, .shown = shown, .memberships = moved }, true);
}

pub fn placePointer(smoke: *Smoke, display: i64) Error!Point {
    const target = values.center(try boundsOf(smoke, display));
    try system.warpPointer(target);
    _ = try smoke.wait(try std.fmt.allocPrint(system.allocator, "pointer placed on display {d}", .{display}), .pointer, Near{ .target = target }, true);
    return target;
}

const Near = struct {
    target: Point,
    pub fn holds(self: Near, _: *Smoke, point: Value) Error!bool {
        return values.near(try Point.read(point), self.target, 2);
    }
};

pub fn selected(smoke: *Smoke, name: []const u8, display: i64, pointer: ?Point) Error!void {
    _ = try smoke.wait(name, .selection, Selected{ .display = display, .pointer = pointer }, true);
}

const Selected = struct {
    display: i64,
    pointer: ?Point,
    pub fn holds(self: Selected, smoke: *Smoke, observation: Value) Error!bool {
        if (!values.sameNumber(values.field(try values.get(observation, "status"), "selected_monitor"), @floatFromInt(self.display))) return false;
        const expected = self.pointer orelse return true;
        return pointerRests(smoke, try Point.read(try values.get(observation, "pointer")), expected);
    }
};

/// A warp lands on a display center; manual pointer drift stays on the expected display.
fn pointerRests(smoke: *Smoke, observed: Point, expected: Point) Error!bool {
    if (values.near(observed, expected, 2)) return true;
    const home = try displayAt(smoke, expected) orelse return false;
    const current = try displayAt(smoke, observed) orelse return false;
    if (current != home) return false;
    for (smoke.monitors.keys()) |identity| if (values.near(observed, values.center(try boundsOf(smoke, identity)), 2)) return false;
    return true;
}

fn displayAt(smoke: *Smoke, point: Point) Error!?i64 {
    for (smoke.monitors.keys()) |identity| if (values.inside(try boundsOf(smoke, identity), point)) return identity;
    return null;
}

pub fn globalHome(smoke: *Smoke, index: i64) i64 {
    return if (index == 3) smoke.built_in else smoke.external;
}

const Pair = struct { first: f64, second: f64 };

fn sortedPairs(pairs: []Pair) []Pair {
    std.mem.sort(Pair, pairs, {}, struct {
        fn before(_: void, left: Pair, right: Pair) bool {
            if (left.first != right.first) return left.first < right.first;
            return left.second < right.second;
        }
    }.before);
    return pairs;
}

/// Whether the listing's (index, display) pairs equal `placement`, where `placement[index - 1]` is the display.
fn listingMatches(listing: Value, placed: [3]i64) Error!bool {
    const listed = try values.items(listing);
    if (listed.len != placed.len) return false;
    var actual: [3]Pair = undefined;
    for (listed, &actual) |item, *pair| pair.* = .{
        .first = values.numeric(try values.get(item, "index")) orelse return false,
        .second = values.numeric(try values.get(item, "display")) orelse return false,
    };
    var expected: [3]Pair = undefined;
    for (placed, &expected, 1..) |display, *pair, index| pair.* = .{ .first = @floatFromInt(index), .second = @floatFromInt(display) };
    for (sortedPairs(&actual), sortedPairs(&expected)) |left, right| if (left.first != right.first or left.second != right.second) return false;
    return true;
}

/// A dictionary built from `entries` in order, compared with Python dictionary equality against `expected`.
fn mappingEquals(keys: []const Value, entries: []const Value, expected: []const Active, skip_empty: bool) bool {
    var distinct: std.ArrayList(usize) = .empty;
    for (keys, 0..) |key, index| {
        for (distinct.items) |*kept| {
            if (!values.same(keys[kept.*], key)) continue;
            kept.* = index;
            break;
        } else distinct.append(system.allocator, index) catch return false;
    }
    var wanted: usize = 0;
    for (expected) |item| {
        if (skip_empty and item.workspace == null) continue;
        wanted += 1;
        const found = for (distinct.items) |index| {
            if (values.sameNumber(keys[index], @floatFromInt(item.display))) break index;
        } else return false;
        if (!values.sameOptional(entries[found], item.workspace)) return false;
    }
    return wanted == distinct.items.len;
}

/// `{item[key]: item[entry] for item in listing if item[filter]}` compared with `expected`.
fn listingMapping(listing: Value, key: []const u8, entry: []const u8, filter: ?[]const u8, expected: []const Active, skip_empty: bool) Error!bool {
    var keys: std.ArrayList(Value) = .empty;
    var entries: std.ArrayList(Value) = .empty;
    for (try values.items(listing)) |item| {
        if (filter) |name| if (!values.truthy(try values.get(item, name))) continue;
        try keys.append(system.allocator, try values.get(item, key));
        try entries.append(system.allocator, try values.get(item, entry));
    }
    return mappingEquals(keys.items, entries.items, expected, skip_empty);
}

/// Checks the expected display, workspace, and parking of every window.
const Lands = struct {
    expected: []const Landing,
    pub fn holds(self: Lands, smoke: *Smoke, observation: Value) Error!bool {
        return lands(smoke, observation, self.expected);
    }
};

fn lands(smoke: *Smoke, observation: Value, expected: []const Landing) Error!bool {
    const report = try values.get(observation, "report");
    if (!values.truthy(report)) return false;
    const managed = try managedByTitle(try values.get(observation, "windows"));
    const observed = try values.frames(report);
    const titles = try system.allocator.alloc([]const u8, expected.len);
    for (expected, titles) |landing, *title| title.* = landing.title;
    if (!values.sameTitles(managed.keys(), titles) or !values.sameTitles(values.titlesOf(observed), titles)) return false;
    for (expected) |landing| {
        const window = managed.get(landing.title).?;
        if (!values.sameNumber(try values.get(window, "display"), @floatFromInt(landing.display)) or !values.sameNumber(try values.get(window, "workspace"), @floatFromInt(landing.workspace))) return false;
        const area = try frameOf(smoke, landing.display);
        const frame = try values.frameOf(observed, landing.title);
        if (landing.shown) {
            if (values.truthy(try values.get(window, "parked")) or !values.contains(area, frame, workflow_gap, 3)) return false;
        } else if (!values.truthy(try values.get(window, "parked")) or values.overlaps(area, frame, 3)) return false;
    }
    return true;
}

pub fn landed(smoke: *Smoke, name: []const u8, expected: []const Landing) Error!void {
    _ = try smoke.wait(name, .landing, Lands{ .expected = expected }, true);
}

/// Per-workspace monitors with One and Two on the external display and Three on the built-in display.
const Spreads = struct {
    active: []const Active,
    memberships: []const Membership,

    pub fn holds(self: Spreads, smoke: *Smoke, observation: Value) Error!bool {
        const status = try values.get(observation, "status");
        const report = try values.get(observation, "report");
        if (!values.truthy(report) or !values.same(values.field(status, "workspace_owner"), null) or values.truthy(values.field(status, "routing_blocked"))) return false;
        var expected: std.json.Array = .init(system.allocator);
        for ([_][]const u8{ "One", "Two", "Three" }, 1..) |name, index| try expected.append(try values.object(&.{
            .{ "index", values.integer(@intCast(index)) },
            .{ "name", values.string(name) },
            .{ "display", values.integer(globalHome(smoke, @intCast(index))) },
            .{ "home", values.string("") },
        }));
        if (!values.same(values.field(status, "placements"), .{ .array = expected })) return false;
        const listing = try values.get(observation, "workspaces");
        if (!try listingMatches(listing, .{ smoke.external, smoke.external, smoke.built_in })) return false;
        if (!try listingMapping(listing, "display", "index", "active", self.active, false)) return false;
        if (!try listingMapping(try values.get(observation, "monitors"), "id", "workspace", null, self.active, false)) return false;
        const managed = try managedByTitle(try values.get(observation, "windows"));
        const observed = try values.frames(report);
        if (!values.sameTitles(managed.keys(), smoke.everyone()) or !values.sameTitles(values.titlesOf(observed), smoke.everyone())) return false;
        var shown: std.ArrayList([]const u8) = .empty;
        for (managed.keys(), managed.values()) |title, window| {
            const workspace = membershipOf(self.memberships, title, 1);
            const display = globalHome(smoke, workspace);
            const area = try frameOf(smoke, display);
            if (!values.sameNumber(try values.get(window, "display"), @floatFromInt(display)) or !values.sameNumber(try values.get(window, "workspace"), @floatFromInt(workspace))) return false;
            if (try activeOn(self.active, display) == workspace) {
                try shown.append(system.allocator, title);
                if (values.truthy(try values.get(window, "parked")) or !values.contains(area, try values.frameOf(observed, title), workflow_gap, 3)) return false;
            } else if (!values.truthy(try values.get(window, "parked")) or values.overlaps(area, try values.frameOf(observed, title), 3)) return false;
        }
        return !try shownOverlap(observed, shown.items);
    }
};

pub fn spread(smoke: *Smoke, name: []const u8, active: []const Active, moved: []const Membership) Error!void {
    _ = try smoke.wait(name, .spread, Spreads{ .active = active, .memberships = moved }, true);
}

/// Workspace placement by index, shown workspaces by display, window memberships, and runtime homes.
const Placed = struct {
    placement: [3]i64,
    active: []const Active,
    memberships: []const Membership,
    homes: []const Home,

    pub fn holds(self: Placed, smoke: *Smoke, observation: Value) Error!bool {
        const status = try values.get(observation, "status");
        const report = try values.get(observation, "report");
        const single = self.placement[0] == self.placement[1] and self.placement[1] == self.placement[2];
        const owner: Value = if (single) values.integer(self.placement[0]) else .null;
        if (!values.truthy(report) or values.truthy(values.field(status, "routing_blocked")) or !values.same(values.field(status, "workspace_owner"), owner)) return false;
        var expected: std.json.Array = .init(system.allocator);
        for ([_][]const u8{ "One", "Two", "Three" }, self.placement, 1..) |name, display, index| {
            var home: Value = values.string("");
            for (self.homes) |item| if (item.index == index) {
                home = try values.get(try monitorOf(smoke, item.display), "uuid");
            };
            try expected.append(try values.object(&.{
                .{ "index", values.integer(@intCast(index)) },
                .{ "name", values.string(name) },
                .{ "display", values.integer(display) },
                .{ "home", home },
            }));
        }
        if (!values.same(values.field(status, "placements"), .{ .array = expected })) return false;
        if (!try listingMapping(try values.get(observation, "monitors"), "id", "workspace", null, self.active, false)) return false;
        const listing = try values.get(observation, "workspaces");
        if (!try listingMatches(listing, self.placement)) return false;
        if (!try listingMapping(listing, "display", "index", "active", self.active, true)) return false;
        var expected_windows: std.ArrayList(Landing) = .empty;
        for (smoke.everyone()) |title| {
            const workspace = membershipOf(self.memberships, title, 1);
            const display = self.placement[@intCast(workspace - 1)];
            try expected_windows.append(system.allocator, .{ .title = title, .display = display, .workspace = workspace, .shown = try activeOn(self.active, display) == workspace });
        }
        return lands(smoke, observation, expected_windows.items);
    }
};

pub fn placement(smoke: *Smoke, name: []const u8, placed: [3]i64, active: []const Active, moved: []const Membership, homes: []const Home) Error!void {
    _ = try smoke.wait(name, .spread, Placed{ .placement = placed, .active = active, .memberships = moved, .homes = homes }, true);
}

/// The display `selector` should select from `current`, from the `monitors` geometry, or null without one.
fn expectedMonitor(smoke: *Smoke, selector: []const u8, current: i64) Error!?i64 {
    const directions = [_][]const u8{ "left", "right", "up", "down" };
    for (directions) |direction| if (std.mem.eql(u8, selector, direction)) {
        const source = values.center(try boundsOf(smoke, current));
        const Candidate = struct { primary: f64, perpendicular: f64, identity: i64 };
        var best: ?Candidate = null;
        for (smoke.monitors.values()) |screen| {
            const identity = try values.whole(try values.get(screen, "id"));
            if (identity == current) continue;
            const target = values.center(try Frame.read(try values.get(screen, "full_bounds")));
            const horizontal = target.left - source.left;
            const vertical = target.top - source.top;
            const primary = if (std.mem.eql(u8, direction, "left")) -horizontal else if (std.mem.eql(u8, direction, "right")) horizontal else if (std.mem.eql(u8, direction, "up")) -vertical else vertical;
            if (primary <= 0) continue;
            const across = std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "right");
            const candidate: Candidate = .{ .primary = primary, .perpendicular = @abs(if (across) vertical else horizontal), .identity = identity };
            if (best) |known| {
                const better = candidate.primary < known.primary or (candidate.primary == known.primary and (candidate.perpendicular < known.perpendicular or
                    (candidate.perpendicular == known.perpendicular and candidate.identity < known.identity)));
                if (!better) continue;
            }
            best = candidate;
        }
        return if (best) |known| known.identity else null;
    };
    if (std.mem.eql(u8, selector, "next") or std.mem.eql(u8, selector, "previous")) {
        const Entry = struct { left: f64, top: f64, identity: i64 };
        const order = try system.allocator.alloc(Entry, smoke.monitors.count());
        for (smoke.monitors.values(), order) |screen, *entry| {
            const middle = values.center(try Frame.read(try values.get(screen, "full_bounds")));
            entry.* = .{ .left = middle.left, .top = middle.top, .identity = try values.whole(try values.get(screen, "id")) };
        }
        std.mem.sort(Entry, order, {}, struct {
            fn before(_: void, first: Entry, second: Entry) bool {
                if (first.left != second.left) return first.left < second.left;
                if (first.top != second.top) return first.top < second.top;
                return first.identity < second.identity;
            }
        }.before);
        const position = for (order, 0..) |entry, index| {
            if (entry.identity == current) break index;
        } else return system.fail("Display {d} is not in the monitor order", .{current});
        const step: i64 = if (std.mem.eql(u8, selector, "next")) 1 else -1;
        return order[@intCast(@mod(@as(i64, @intCast(position)) + step, @as(i64, @intCast(order.len))))].identity;
    }
    var best: ?i64 = null;
    const class = std.mem.eql(u8, selector, "built-in") or std.mem.eql(u8, selector, "external");
    const name = if (std.mem.startsWith(u8, selector, "name:")) selector["name:".len..] else selector;
    for (smoke.monitors.values()) |screen| {
        const matches = if (class)
            values.same(try values.get(screen, "built_in"), .{ .bool = std.mem.eql(u8, selector, "built-in") })
        else
            values.sameText(try values.get(screen, "name"), name);
        if (!matches) continue;
        const identity = try values.whole(try values.get(screen, "id"));
        best = if (best) |known| @min(known, identity) else identity;
    }
    return best orelse system.fail("No display matches {s}", .{selector});
}

fn titlesOn(smoke: *Smoke, display: i64) Error!Titles {
    var titles: std.ArrayList([]const u8) = .empty;
    for (try values.items(try smoke.cli(&.{"windows"}))) |window| {
        if (!values.sameNumber(try values.get(window, "display"), @floatFromInt(display)) or values.truthy(try values.get(window, "parked"))) continue;
        const title = try values.text(try values.get(window, "title"));
        if (!values.has(titles.items, title)) try titles.append(system.allocator, title);
    }
    return titles.items;
}

/// Runs `focus-monitor selector` from a known pointer position, and checks the selection, pointer, and key window.
pub fn focusMonitor(smoke: *Smoke, label: []const u8, selector: []const u8, follows: bool) Error!i64 {
    const current = try values.whole(try values.get(try smoke.cli(&.{"status"}), "selected_monitor"));
    const resting = try placePointer(smoke, current);
    const before_key = try values.keyTitle(try smoke.fixture());
    const expected = try expectedMonitor(smoke, selector, current);
    const name = try std.fmt.allocPrint(system.allocator, "{s}: focus-monitor {s}", .{ label, selector });
    const target_display = expected orelse {
        try smoke.rejected(name, &.{ "focus-monitor", selector }, "NoMonitorInDirection");
        try selected(smoke, try std.fmt.allocPrint(system.allocator, "{s} keeps selection and pointer", .{name}), current, resting);
        return current;
    };
    _ = try smoke.reply(name, &.{ "focus-monitor", selector }, .{ .focused_monitor = .{ .display = target_display, .changed = target_display != current } });
    const target = if (follows and target_display != current) values.center(try boundsOf(smoke, target_display)) else resting;
    try selected(smoke, try std.fmt.allocPrint(system.allocator, "{s} selects {d} with pointer {s}", .{ name, target_display, try describePoint(target) }), target_display, target);
    const shown = try titlesOn(smoke, target_display);
    const candidates: driver.KeyIn = if (shown.len > 0) .{ .titles = shown } else if (before_key) |title| .{ .titles = try system.allocator.dupe([]const u8, &.{title}) } else .{ .titles = &.{}, .none = true };
    _ = try smoke.wait(try std.fmt.allocPrint(system.allocator, "{s} key window", .{name}), .fixture, candidates, true);
    return target_display;
}

/// Checks `monitors`: a 36-character uuid, the expected workspace, and the selected flag of each display.
pub fn monitorListing(smoke: *Smoke, name: []const u8, workspaces: []const Active) Error!void {
    const listing = try smoke.cli(&.{"monitors"});
    try smoke.snapshot(name, listing);
    const status = try smoke.cli(&.{"status"});
    const selected_monitor = try values.get(status, "selected_monitor");
    var passed = listing == .array;
    if (passed) {
        var identities: std.ArrayList(i64) = .empty;
        for (listing.array.items) |item| {
            const identity = values.numeric(try values.get(item, "id")) orelse {
                passed = false;
                break;
            };
            if (identity != @trunc(identity)) {
                passed = false;
                break;
            }
            const whole: i64 = @intFromFloat(identity);
            if (std.mem.indexOfScalar(i64, identities.items, whole) == null) try identities.append(system.allocator, whole);
        }
        if (passed) {
            passed = identities.items.len == smoke.monitors.count();
            for (identities.items) |identity| if (!smoke.monitors.contains(identity)) {
                passed = false;
            };
        }
        if (passed) for (listing.array.items) |item| {
            const uuid = values.field(item, "uuid");
            const identity: i64 = @intFromFloat(values.numeric(try values.get(item, "id")).?);
            const valid = uuid != null and uuid.? == .string and uuid.?.string.len == 36 and
                values.sameOptional(values.field(item, "workspace"), try activeOn(workspaces, identity)) and
                values.same(values.field(item, "selected"), .{ .bool = values.same(try values.get(item, "id"), selected_monitor) });
            if (!valid) {
                passed = false;
                break;
            }
        };
    }
    try smoke.check(name, passed, try values.object(&.{ .{ "monitors", listing }, .{ "selected_monitor", selected_monitor } }));
}

pub fn monitorReply(smoke: *Smoke, name: []const u8, arguments: []const []const u8, display: i64, workspace: ?i64, target: ?[]const u8) Error!void {
    _ = try smoke.reply(name, arguments, .{ .monitor = .{ .display = display, .workspace = workspace, .target = target } });
}
