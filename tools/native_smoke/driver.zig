//! The run state, the recorded result, and the steps every mode shares: commands, bounded waits, preflight, and cleanup.
const std = @import("std");
const system = @import("system.zig");
const values = @import("values.zig");
const Error = system.Error;
const Value = values.Value;
const Frame = values.Frame;
const Frames = values.Frames;
const Titles = values.Titles;

pub const fixture_bundle = "dev.huen-wm.fixture";
pub const workflow_gap = 12;
const command_timeout = 15;

pub const Options = struct {
    app: []const u8,
    fixture: []const u8,
    output: []const u8,
    timeout: f64 = 12,
    scenes: bool = false,
    workflow: bool = false,
    owner: bool = false,
    monitors: bool = false,
    global: bool = false,
    monitor_moves: bool = false,
    global_restart: bool = false,
};

/// What a bounded wait reads on each attempt.
pub const Source = enum { fixture, doctor, windows, status, status_optional, reload, session, workflow, routing, spread, landing, pointer, selection, managers, fixtures };

/// What a command reply must contain.
pub const Expectation = union(enum) {
    accepted,
    unchanged,
    rejected: []const u8,
    targets: []const u8,
    monitor: struct { display: i64, workspace: ?i64 = null, target: ?[]const u8 = null },
    focused_monitor: struct { display: i64, changed: bool },
};

pub const Smoke = struct {
    options: Options,
    output: []const u8,
    binary: []const u8,
    report_path: []const u8,
    config_path: []const u8,
    result: Value,
    fixture_pid: ?i64 = null,
    manager_started: bool = false,
    aerospace_changed: bool = false,
    aerospace: ?[]const u8,
    display: ?Value = null,
    screen: ?Frame = null,
    identities: std.StringArrayHashMapUnmanaged(Value) = .empty,
    monitors: std.AutoArrayHashMapUnmanaged(i64, Value) = .empty,
    built_in: i64 = 0,
    external: i64 = 0,

    pub fn init(given: Options) Error!Smoke {
        var options = given;
        // `open -a` needs a path it can find from any directory; the default is relative to the repository root.
        options.fixture = try system.absolute(given.fixture);
        const output = try system.createOutput(options.output);
        const app = try system.resolved(options.app);
        return .{
            .options = options,
            .output = output,
            .binary = try std.fs.path.join(system.allocator, &.{ app, "Contents/MacOS/huen-wm" }),
            .report_path = try std.fs.path.join(system.allocator, &.{ output, "fixture.json" }),
            .config_path = try std.fs.path.join(system.allocator, &.{ output, "config.lua" }),
            .aerospace = try system.which("aerospace"),
            .result = try values.object(&.{
                .{ "passed", .{ .bool = false } },
                .{ "checks", try values.array(&.{}) },
                .{ "commands", try values.array(&.{}) },
                .{ "snapshots", try values.object(&.{}) },
                .{ "cleanup_errors", try values.array(&.{}) },
                .{ "scenes", .{ .bool = options.scenes } },
                .{ "workflow", .{ .bool = options.workflow } },
                .{ "owner", .{ .bool = options.owner } },
                .{ "monitors", .{ .bool = options.monitors } },
                .{ "global", .{ .bool = options.global } },
                .{ "monitor_moves", .{ .bool = options.monitor_moves } },
                .{ "global_restart", .{ .bool = options.global_restart } },
            }),
        };
    }

    pub fn record(smoke: *Smoke, key: []const u8, value: Value) Error!void {
        try smoke.result.object.put(system.allocator, key, value);
    }

    fn list(smoke: *Smoke, key: []const u8) *std.json.Array {
        return &smoke.result.object.getPtr(key).?.array;
    }

    pub fn snapshot(smoke: *Smoke, name: []const u8, value: Value) Error!void {
        try smoke.result.object.getPtr("snapshots").?.object.put(system.allocator, name, value);
    }

    pub fn cleanupError(smoke: *Smoke, comptime format: []const u8, arguments: anytype) void {
        const text = std.fmt.allocPrint(system.allocator, format, arguments) catch "OutOfMemory";
        smoke.list("cleanup_errors").append(.{ .string = text }) catch {};
    }

    pub fn cleanupErrors(smoke: *Smoke) usize {
        return smoke.list("cleanup_errors").items.len;
    }

    pub fn path(smoke: *Smoke, name: []const u8) Error![]const u8 {
        return std.fs.path.join(system.allocator, &.{ smoke.output, name });
    }

    pub fn runCommand(smoke: *Smoke, argv: []const []const u8, required: bool) Error!system.Completed {
        const completed = try system.execute(argv, command_timeout);
        try smoke.list("commands").append(try values.object(&.{
            .{ "argv", try values.strings(argv) },
            .{ "returncode", .{ .integer = completed.code } },
            .{ "stdout", .{ .string = completed.stdout } },
            .{ "stderr", .{ .string = completed.stderr } },
        }));
        if (required and completed.code != 0) return system.fail("Command failed: {f}: {s}", .{ values.fmt(try values.strings(argv)), if (completed.stderr.len > 0) completed.stderr else completed.stdout });
        return completed;
    }

    fn invoke(smoke: *Smoke, arguments: []const []const u8, required: bool) Error!?Value {
        const argv = try std.mem.concat(system.allocator, []const u8, &.{ &.{smoke.binary}, arguments });
        const completed = try smoke.runCommand(argv, required);
        const response = try values.parse(completed.stdout) orelse {
            if (required) return system.fail("No JSON from {f}: {s}", .{ values.fmt(try values.strings(arguments)), completed.stdout });
            return null;
        };
        if (required and values.truthy(values.field(response, "error"))) return system.fail("CLI rejected {f}: {f}", .{ values.fmt(try values.strings(arguments)), values.fmt(response) });
        return response;
    }

    /// Runs the manager's CLI and requires a successful JSON reply.
    pub fn cli(smoke: *Smoke, arguments: []const []const u8) Error!Value {
        return (try smoke.invoke(arguments, true)).?;
    }

    pub fn cliOptional(smoke: *Smoke, arguments: []const []const u8) Error!?Value {
        return smoke.invoke(arguments, false);
    }

    pub fn launch(smoke: *Smoke, application: []const u8, label: []const u8, arguments: []const []const u8, foreground: bool) Error!void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(system.allocator, &.{ "open", "-n" });
        if (!foreground) try argv.append(system.allocator, "-g");
        try argv.appendSlice(system.allocator, &.{
            "-a",       application,
            "--stdout", try smoke.path(try std.fmt.allocPrint(system.allocator, "{s}.stdout.log", .{label})),
            "--stderr", try smoke.path(try std.fmt.allocPrint(system.allocator, "{s}.stderr.log", .{label})),
            "--args",
        });
        try argv.appendSlice(system.allocator, arguments);
        _ = try smoke.runCommand(argv.items, true);
    }

    /// Polls `source` until `predicate` holds for 0.35 seconds, and records the check.
    pub fn wait(smoke: *Smoke, name: []const u8, source: Source, predicate: anytype, healthy: bool) Error!Value {
        const deadline = system.now() + smoke.options.timeout;
        var last: ?Value = null;
        var stable_since: ?f64 = null;
        while (system.now() < deadline) {
            last = try smoke.observe(source);
            if (healthy and smoke.manager_started) try smoke.health();
            if (last != null and try predicate.holds(smoke, last.?)) {
                const since = stable_since orelse system.now();
                stable_since = since;
                if (system.now() - since >= 0.35) {
                    try smoke.list("checks").append(try values.object(&.{ .{ "name", .{ .string = name } }, .{ "passed", .{ .bool = true } } }));
                    try smoke.snapshot(name, last.?);
                    system.print("PASS {s}\n", .{name});
                    return last.?;
                }
            } else stable_since = null;
            system.pause(0.08);
        }
        try smoke.list("checks").append(try values.object(&.{ .{ "name", .{ .string = name } }, .{ "passed", .{ .bool = false } }, .{ "last", last orelse .null } }));
        return system.fail("Timed out: {s}; last observation: {f}", .{ name, values.fmt(last orelse .null) });
    }

    fn observe(smoke: *Smoke, source: Source) Error!?Value {
        return switch (source) {
            .fixture => smoke.fixture(),
            .doctor => system.readJson(try smoke.path("doctor.stdout.log")),
            .windows => try smoke.cli(&.{"windows"}),
            .status => try smoke.cli(&.{"status"}),
            .status_optional => smoke.cliOptional(&.{"status"}),
            .reload => try values.get(try smoke.cli(&.{"status"}), "config_reload"),
            .session => try values.get(try smoke.cli(&.{"status"}), "session"),
            .workflow => try smoke.observeWorkflow(),
            .routing => try smoke.observeRouting(),
            .spread => try smoke.observeSpread(),
            .landing => try values.object(&.{ .{ "windows", try smoke.cli(&.{"windows"}) }, .{ "report", try smoke.fixture() orelse .null } }),
            .pointer => (try system.pointerLocation()).json(),
            .selection => try values.object(&.{ .{ "status", try smoke.cli(&.{"status"}) }, .{ "pointer", (try system.pointerLocation()).json() } }),
            .managers => try system.processValue("huen-wm"),
            .fixtures => try system.processValue("HuenFixture"),
        };
    }

    fn observeWorkflow(smoke: *Smoke) Error!Value {
        const listing = try smoke.cli(&.{"workspaces"});
        var active: Value = .null;
        for (try values.items(listing)) |item| if (values.same(try values.get(item, "display"), smoke.display) and values.truthy(try values.get(item, "active"))) {
            active = try values.get(item, "index");
            break;
        };
        return values.object(&.{ .{ "report", try smoke.fixture() orelse .null }, .{ "windows", try smoke.cli(&.{"windows"}) }, .{ "active", active } });
    }

    pub fn observeRouting(smoke: *Smoke) Error!Value {
        return values.object(&.{
            .{ "status", try smoke.cli(&.{"status"}) },
            .{ "windows", try smoke.cli(&.{"windows"}) },
            .{ "workspaces", try smoke.cli(&.{"workspaces"}) },
            .{ "report", try smoke.fixture() orelse .null },
            .{ "pointer", (try system.pointerLocation()).json() },
        });
    }

    fn observeSpread(smoke: *Smoke) Error!Value {
        var observation = try smoke.observeRouting();
        try observation.object.put(system.allocator, "monitors", try smoke.cli(&.{"monitors"}));
        return observation;
    }

    fn health(smoke: *Smoke) Error!void {
        const status = try smoke.cli(&.{"status"});
        const windows = try smoke.cli(&.{"windows"});
        var broken = values.truthy(values.field(status, "transition_error"));
        if (windows == .array) for (windows.array.items) |window| {
            if (values.truthy(values.field(window, "placement_error"))) broken = true;
        };
        if (broken) return system.fail("Native placement/transition error: {f}; {f}", .{ values.fmt(status), values.fmt(windows) });
    }

    pub fn fixture(smoke: *Smoke) Error!?Value {
        return system.readJson(smoke.report_path);
    }

    /// Replaces the configuration in one rename, so the manager never reads a partial file.
    pub fn writeConfig(smoke: *Smoke, content: []const u8) Error!void {
        const replacement = try smoke.path("config.pending");
        try system.writeText(replacement, content);
        try system.rename(replacement, smoke.config_path);
    }

    // Every run turns off placement memory. The fixture's placements file outlives a run, and a window that
    // claims an entry from an earlier run would start floating or on another workspace.
    pub const isolation = "placement_memory=false, ";

    pub fn config(smoke: *Smoke, gap: u32) Error!void {
        const duration = if (smoke.options.scenes) "0.12" else "0";
        try smoke.writeConfig(try std.fmt.allocPrint(system.allocator, "return {{gap={d}, motion_duration={s}, workspaces={{'One','Two'}}, " ++ isolation ++ "bindings={{}}}}\n", .{ gap, duration }));
    }

    pub fn workflowConfig(smoke: *Smoke) Error!void {
        try smoke.writeConfig(std.fmt.comptimePrint("return {{gap={d}, motion_duration=0, workspaces={{'One','Two','Three'}}, workspace_back_and_forth=true, " ++ isolation ++ "bindings={{}}}}\n", .{workflow_gap}));
    }

    pub fn preflight(smoke: *Smoke) Error!void {
        if ((try system.processIdentities("huen-wm")).len > 0 or (try system.processIdentities("HuenFixture")).len > 0)
            return system.fail("Refusing to run while huen-wm or HuenFixture already exists", .{});
        const fixture_executable = try std.fs.path.join(system.allocator, &.{ smoke.options.fixture, "Contents/MacOS/HuenFixture" });
        if (!system.isFile(smoke.binary) or !system.isFile(fixture_executable))
            return system.fail("Build the fixture and select an existing installed manager app first", .{});
        try smoke.launch(smoke.options.app, "doctor", &.{"doctor"}, false);
        const permissions = try smoke.wait("LaunchServices permissions", .doctor, HasField{ .name = "accessibility" }, false);
        if (!values.truthy(try values.get(permissions, "accessibility")) or (smoke.options.scenes and !values.truthy(values.field(permissions, "screen_capture"))))
            return system.fail("Required permissions unavailable: {f}", .{values.fmt(permissions)});
        if ((try system.processIdentities("huen-wm")).len > 0 or (try system.processIdentities("HuenFixture")).len > 0)
            return system.fail("A manager or fixture appeared during preflight; refusing launch", .{});
        if ((try system.processIdentities("AeroSpace")).len == 0) return;
        const aerospace = smoke.aerospace orelse return system.fail("AeroSpace runs but its CLI is unavailable", .{});
        const paused = try smoke.runCommand(&.{ aerospace, "enable", "off", "--fail-if-noop" }, false);
        smoke.aerospace_changed = paused.code == 0;
        if (smoke.aerospace_changed) return;
        if (paused.code != 2 or paused.stdout.len > 0 or paused.stderr.len > 0)
            return system.fail("Cannot pause AeroSpace: {d}; {s}", .{ paused.code, if (paused.stderr.len > 0) paused.stderr else paused.stdout });
        const ready = try smoke.runCommand(&.{ aerospace, "echo", "--", "huen-smoke-ready" }, true);
        if (!std.mem.eql(u8, std.mem.trim(u8, ready.stdout, &std.ascii.whitespace), "huen-smoke-ready"))
            return system.fail("Cannot confirm AeroSpace CLI connection", .{});
    }

    pub fn launchFixture(smoke: *Smoke, arguments: []const []const u8) Error!void {
        const all = try std.mem.concat(system.allocator, []const u8, &.{ &.{ "--report", smoke.report_path }, arguments });
        try smoke.launch(smoke.options.fixture, "fixture", all, true);
    }

    pub fn startManager(smoke: *Smoke) Error!void {
        try smoke.launch(smoke.options.app, "manager", &.{ "start", "--app", fixture_bundle, "--config", smoke.config_path }, false);
        smoke.manager_started = true;
        _ = try smoke.wait("filtered manager ready", .status_optional, ManagerReady{}, false);
    }

    /// Waits for the fixture report to list three windows, and returns it.
    pub fn fixtureReady(smoke: *Smoke, key: ?[]const u8) Error!Value {
        const original = try smoke.wait("fixture ready", .fixture, FixtureReady{ .key = key }, false);
        smoke.fixture_pid = try values.whole(try values.get(original, "process_id"));
        return original;
    }

    pub fn check(smoke: *Smoke, name: []const u8, passed: bool, evidence: Value) Error!void {
        try smoke.list("checks").append(try values.object(&.{ .{ "name", .{ .string = name } }, .{ "passed", .{ .bool = passed } }, .{ "evidence", evidence } }));
        if (!passed) return system.fail("Check failed: {s}; evidence: {f}", .{ name, values.fmt(evidence) });
        system.print("PASS {s}\n", .{name});
    }

    pub fn reply(smoke: *Smoke, name: []const u8, arguments: []const []const u8, expectation: Expectation) Error!Value {
        const response = try smoke.cliOptional(arguments);
        const passed = if (response) |known| known == .object and try smoke.meets(known, expectation) else false;
        try smoke.check(name, passed, try values.object(&.{ .{ "argv", try values.strings(arguments) }, .{ "reply", response orelse .null } }));
        return response.?;
    }

    fn meets(smoke: *Smoke, response: Value, expectation: Expectation) Error!bool {
        const ok = values.isTrue(values.field(response, "ok"));
        return switch (expectation) {
            .accepted => ok,
            .unchanged => ok and values.isFalse(values.field(response, "changed")),
            .rejected => |error_name| values.isTrue(values.field(response, "error")) and values.sameText(values.field(response, "err_message"), error_name),
            .targets => |title| ok and values.same(values.field(response, "target"), try smoke.identity(title)),
            .monitor => |monitor| ok and values.sameNumber(values.field(response, "monitor"), @floatFromInt(monitor.display)) and
                (monitor.workspace == null or values.sameNumber(values.field(response, "workspace"), @floatFromInt(monitor.workspace.?))) and
                (monitor.target == null or values.same(values.field(response, "target"), try smoke.identity(monitor.target.?))) and
                !values.isFalse(values.field(response, "changed")),
            .focused_monitor => |monitor| ok and values.sameNumber(values.field(response, "monitor"), @floatFromInt(monitor.display)) and
                values.same(values.field(response, "changed"), .{ .bool = monitor.changed }),
        };
    }

    pub fn rejected(smoke: *Smoke, name: []const u8, arguments: []const []const u8, error_name: []const u8) Error!void {
        _ = try smoke.reply(name, arguments, .{ .rejected = error_name });
    }

    pub fn targets(smoke: *Smoke, name: []const u8, arguments: []const []const u8, title: []const u8) Error!void {
        _ = try smoke.reply(name, arguments, .{ .targets = title });
    }

    pub fn accepted(smoke: *Smoke, name: []const u8, arguments: []const []const u8) Error!void {
        _ = try smoke.reply(name, arguments, .accepted);
    }

    pub fn identity(smoke: *Smoke, title: []const u8) Error!Value {
        return smoke.identities.get(title) orelse system.fail("Unknown fixture window '{s}'", .{title});
    }

    pub fn everyone(smoke: *Smoke) Titles {
        return smoke.identities.keys();
    }

    pub fn titleOf(smoke: *Smoke, target: ?Value) Error![]const u8 {
        for (smoke.identities.keys(), smoke.identities.values()) |title, known| if (values.same(known, target)) return title;
        return system.fail("No fixture window has identity {f}", .{values.fmt(target orelse .null)});
    }

    pub fn learnIdentities(smoke: *Smoke, managed: Value) Error!void {
        smoke.identities = .empty;
        for (try values.items(managed)) |window| try smoke.identities.put(system.allocator, try values.text(try values.get(window, "title")), try values.get(window, "id"));
    }

    pub fn keyed(smoke: *Smoke, name: []const u8, candidates: Titles) Error![]const u8 {
        const report = try smoke.wait(name, .fixture, KeyIn{ .titles = candidates }, true);
        return (try values.keyTitle(report)).?;
    }

    pub fn restored(smoke: *Smoke, original: Frames) Error!void {
        _ = try smoke.cli(&.{"restore"});
        _ = try smoke.wait("restore original native frames before stop", .fixture, Restored{ .original = original }, true);
    }

    pub fn cleanup(smoke: *Smoke) void {
        var manager_stopped = !smoke.manager_started;
        if (smoke.manager_started) {
            if (smoke.stopManager()) {
                manager_stopped = true;
            } else |err| smoke.cleanupError("Owned manager did not stop: {s}. No hard kill attempted.", .{system.describe(err)});
        }
        smoke.stopFixture() catch |err| smoke.cleanupError("Fixture cleanup failed: {s}", .{system.describe(err)});
        if (!smoke.aerospace_changed) return;
        if (!manager_stopped) return smoke.cleanupError("AeroSpace left disabled because owned manager may still run", .{});
        _ = smoke.runCommand(&.{ smoke.aerospace.?, "enable", "on" }, true) catch |err| smoke.cleanupError("AeroSpace restore failed: {s}", .{system.describe(err)});
    }

    /// Stops the manager this run started, after it proves to be that manager. Never kills it.
    fn stopManager(smoke: *Smoke) Error!void {
        const identities = try system.processIdentities("huen-wm");
        if (identities.len == 0) return;
        const status = try smoke.cli(&.{"status"});
        if (!values.truthy(values.field(status, "running")) or !values.sameText(values.field(status, "filter"), fixture_bundle))
            return system.fail("Refusing cleanup of an unowned manager: {f}", .{values.fmt(status)});
        if (identities.len != 1) return system.fail("Cannot identify the owned manager process", .{});
        const process = try std.fmt.allocPrint(system.allocator, "{d}", .{identities[0]});
        const command = try smoke.runCommand(&.{ "ps", "-ww", "-p", process, "-o", "command=" }, true);
        if (std.mem.indexOf(u8, command.stdout, smoke.config_path) == null)
            return system.fail("Manager does not use this run's config; refusing cleanup", .{});
        _ = smoke.cli(&.{"restore"}) catch |err| smoke.cleanupError("Cleanup restore failed: {s}", .{system.describe(err)});
        _ = try smoke.cli(&.{"stop"});
        _ = try smoke.wait("owned manager stopped", .managers, Empty{}, false);
    }

    fn stopFixture(smoke: *Smoke) Error!void {
        if (smoke.fixture_pid == null) {
            const report = try smoke.fixture();
            if (values.truthy(report) and values.truthy(values.field(report, "ready"))) smoke.fixture_pid = try values.whole(try values.get(report, "process_id"));
        }
        const pid = smoke.fixture_pid orelse return;
        if (std.mem.indexOfScalar(i64, try system.processIdentities("HuenFixture"), pid) == null) return;
        try system.terminate(pid);
        _ = try smoke.wait("owned fixture stopped", .fixtures, Excludes{ .identity = pid }, false);
    }

    /// Whether every report frame lies on a display inside the gap, without overlap, for three windows.
    pub fn tiled(report: Value, gap: f64) Error!bool {
        const observed = try values.frames(report);
        const displays = try values.screens(report);
        if (observed.count() != 3) return false;
        for (observed.values()) |frame| {
            for (displays) |screen| {
                if (values.contains(screen.visible_frame, frame, gap, 3)) break;
            } else return false;
        }
        for (observed.values(), 0..) |first, index| for (observed.values()[index + 1 ..]) |second| if (values.overlaps(first, second, 3)) return false;
        return true;
    }
};

const HasField = struct {
    name: []const u8,
    pub fn holds(self: HasField, _: *Smoke, observed: Value) Error!bool {
        return values.field(observed, self.name) != null;
    }
};

const ManagerReady = struct {
    pub fn holds(_: ManagerReady, _: *Smoke, status: Value) Error!bool {
        return values.truthy(values.field(status, "running")) and values.sameText(values.field(status, "filter"), fixture_bundle);
    }
};

const FixtureReady = struct {
    key: ?[]const u8,
    pub fn holds(self: FixtureReady, _: *Smoke, report: Value) Error!bool {
        if (!values.truthy(values.field(report, "ready")) or (try values.items(try values.get(report, "windows"))).len != 3) return false;
        const key = try values.keyTitle(report);
        if (self.key) |expected| return key != null and std.mem.eql(u8, key.?, expected);
        return key != null;
    }
};

pub const Empty = struct {
    pub fn holds(_: Empty, _: *Smoke, observed: Value) Error!bool {
        return (try values.items(observed)).len == 0;
    }
};

const Excludes = struct {
    identity: i64,
    pub fn holds(self: Excludes, _: *Smoke, observed: Value) Error!bool {
        for (try values.items(observed)) |item| if (values.sameNumber(item, @floatFromInt(self.identity))) return false;
        return true;
    }
};

/// The fixture's key window is one of `titles`, or there is none when `none` is set.
pub const KeyIn = struct {
    titles: Titles,
    none: bool = false,
    pub fn holds(self: KeyIn, _: *Smoke, report: Value) Error!bool {
        const key = try values.keyTitle(report);
        return if (key) |title| values.has(self.titles, title) else self.none;
    }
};

/// The report lists exactly the original windows, each within 5 points of its original frame.
pub const Restored = struct {
    original: Frames,
    pub fn holds(self: Restored, _: *Smoke, report: Value) Error!bool {
        const observed = try values.frames(report);
        if (!values.sameTitles(values.titlesOf(observed), values.titlesOf(self.original))) return false;
        for (observed.keys(), observed.values()) |title, frame| if (!values.closeFrame(frame, try values.frameOf(self.original, title), 5)) return false;
        return true;
    }
};

/// Every expected window is within 3 points of its frame, and `key` is the key window when given.
pub const Framed = struct {
    expected: Frames,
    key: ?[]const u8 = null,
    pub fn holds(self: Framed, _: *Smoke, report: Value) Error!bool {
        const observed = try values.frames(report);
        for (self.expected.keys(), self.expected.values()) |title, frame| if (!values.closeFrame(try values.frameOf(observed, title), frame, 3)) return false;
        if (self.key) |expected| {
            const key = try values.keyTitle(report);
            return key != null and std.mem.eql(u8, key.?, expected);
        }
        return true;
    }
};

/// The manager manages exactly the three fixture windows, on one display when `single_display` is set.
pub const FixtureOnly = struct {
    single_display: bool,
    pub fn holds(self: FixtureOnly, smoke: *Smoke, windows: Value) Error!bool {
        const managed = try values.items(windows);
        if (managed.len != 3) return false;
        for (managed) |window| if (!values.sameNumber(try values.get(window, "pid"), @floatFromInt(smoke.fixture_pid.?))) return false;
        if (!self.single_display) return true;
        for (managed[1..]) |window| if (!values.same(try values.get(window, "display"), try values.get(managed[0], "display"))) return false;
        return true;
    }
};
