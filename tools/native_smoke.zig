//! Check native fixture observations against the installed manager's CLI.
//! `zig build native-smoke -- --output DIR [options]`; docs/native-smoke.md describes the modes.
const std = @import("std");
const system = @import("native_smoke/system.zig");
const values = @import("native_smoke/values.zig");
const driver = @import("native_smoke/driver.zig");
const single = @import("native_smoke/single.zig");
const modes = @import("native_smoke/modes.zig");

const program = "native-smoke";
const usage =
    \\usage: native-smoke [-h] [--app APP] [--fixture FIXTURE] --output OUTPUT
    \\                    [--timeout TIMEOUT] [--scenes] [--workflow] [--owner]
    \\                    [--monitors] [--global] [--monitor-moves]
    \\                    [--global-restart]
    \\
;
const help =
    \\
    \\Check native fixture observations against the installed manager's CLI.
    \\
    \\options:
    \\  -h, --help          show this help message and exit
    \\  --app APP
    \\  --fixture FIXTURE
    \\  --output OUTPUT     New directory for JSON and logs
    \\  --timeout TIMEOUT   Seconds per bounded observation
    \\  --scenes            Require captured snapshots with 0.12-second scenes; not
    \\                      visual proof
    \\  --workflow          Check keyboard workflow commands on one display instead
    \\  --owner             Check workspace_monitors owner routing on two displays
    \\                      instead
    \\  --monitors          Check focus-monitor selectors on two displays instead
    \\  --global            Check per-workspace monitor placement on two displays
    \\                      instead
    \\  --monitor-moves     Check window and workspace moves between two displays
    \\                      instead
    \\  --global-restart    Check that a moved workspace returns to its home after a
    \\                      restart
    \\
;
const exclusive_names = "--workflow, --owner, --monitors, --global, --monitor-moves, and --global-restart";

const Flag = enum { help, app, fixture, output, timeout, scenes, workflow, owner, monitors, global, monitor_moves, global_restart };
const flag_names = [_]struct { []const u8, Flag }{
    .{ "--help", .help },
    .{ "--app", .app },
    .{ "--fixture", .fixture },
    .{ "--output", .output },
    .{ "--timeout", .timeout },
    .{ "--scenes", .scenes },
    .{ "--workflow", .workflow },
    .{ "--owner", .owner },
    .{ "--monitors", .monitors },
    .{ "--global", .global },
    .{ "--monitor-moves", .monitor_moves },
    .{ "--global-restart", .global_restart },
};

const Usage = error{Usage};
var usage_message: []const u8 = "";

fn reject(comptime format: []const u8, arguments: anytype) Usage {
    usage_message = std.fmt.allocPrint(system.allocator, format, arguments) catch "out of memory";
    return error.Usage;
}

/// Resolves an option by exact name, else by unique prefix, as argparse does.
fn lookup(name: []const u8) Usage!?Flag {
    if (std.mem.eql(u8, name, "-h")) return .help;
    for (flag_names) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
    if (!std.mem.startsWith(u8, name, "--")) return null;
    var found: ?Flag = null;
    var matches: std.ArrayList([]const u8) = .empty;
    for (flag_names) |entry| if (std.mem.startsWith(u8, entry[0], name)) {
        found = entry[1];
        matches.append(system.allocator, entry[0]) catch {};
    };
    if (matches.items.len > 1) return reject("ambiguous option: {s} could match {s}", .{ name, std.mem.join(system.allocator, ", ", matches.items) catch "" });
    return found;
}

fn flagName(flag: Flag) []const u8 {
    for (flag_names) |entry| if (entry[1] == flag) return entry[0];
    unreachable;
}

fn looksLikeNegativeNumber(argument: []const u8) bool {
    if (argument.len < 2 or argument[0] != '-') return false;
    _ = std.fmt.parseFloat(f64, argument[1..]) catch return false;
    return std.ascii.isDigit(argument[1]) or argument[1] == '.';
}

const Parsed = union(enum) { help, options: driver.Options };

fn parse(arguments: []const []const u8) Usage!Parsed {
    const home = system.environment.get("HOME") orelse "";
    var options: driver.Options = .{
        .app = std.fs.path.join(system.allocator, &.{ home, "Applications/Huen WM.app" }) catch return reject("out of memory", .{}),
        .fixture = "zig-out/fixtures/HuenFixture.app",
        .output = "",
    };
    var output: ?[]const u8 = null;
    var unrecognized: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        const separator = std.mem.indexOfScalar(u8, argument, '=');
        const name = if (separator != null and std.mem.startsWith(u8, argument, "--")) argument[0..separator.?] else argument;
        const flag = (if (argument.len > 1 and argument[0] == '-' and !looksLikeNegativeNumber(argument)) try lookup(name) else null) orelse {
            unrecognized.append(system.allocator, argument) catch {};
            continue;
        };
        const takes_value = switch (flag) {
            .app, .fixture, .output, .timeout => true,
            else => false,
        };
        var value: []const u8 = "";
        if (takes_value) {
            if (name.len < argument.len) {
                value = argument[name.len + 1 ..];
            } else if (index + 1 < arguments.len and (arguments[index + 1].len == 0 or arguments[index + 1][0] != '-' or looksLikeNegativeNumber(arguments[index + 1]))) {
                index += 1;
                value = arguments[index];
            } else return reject("argument {s}: expected one argument", .{flagName(flag)});
        } else if (name.len < argument.len) return reject("argument {s}: ignored explicit argument '{s}'", .{ flagName(flag), argument[name.len + 1 ..] });
        switch (flag) {
            .help => return .help,
            .app => options.app = value,
            .fixture => options.fixture = value,
            .output => output = value,
            .timeout => options.timeout = std.fmt.parseFloat(f64, std.mem.trim(u8, value, &std.ascii.whitespace)) catch return reject("argument --timeout: invalid float value: '{s}'", .{value}),
            .scenes => options.scenes = true,
            .workflow => options.workflow = true,
            .owner => options.owner = true,
            .monitors => options.monitors = true,
            .global => options.global = true,
            .monitor_moves => options.monitor_moves = true,
            .global_restart => options.global_restart = true,
        }
    }
    options.output = output orelse return reject("the following arguments are required: --output", .{});
    if (unrecognized.items.len > 0) return reject("unrecognized arguments: {s}", .{std.mem.join(system.allocator, " ", unrecognized.items) catch ""});
    if (options.timeout <= 0) return reject("--timeout must be positive", .{});
    const chosen = @as(u8, @intFromBool(options.workflow)) + @intFromBool(options.owner) + @intFromBool(options.monitors) +
        @intFromBool(options.global) + @intFromBool(options.monitor_moves) + @intFromBool(options.global_restart);
    if (chosen > 1) return reject(exclusive_names ++ " are exclusive", .{});
    if (options.scenes and chosen > 0) return reject(exclusive_names ++ " use instant switches and exclude --scenes", .{});
    return .{ .options = options };
}

fn exercise(smoke: *driver.Smoke) system.Error!void {
    const options = smoke.options;
    if (options.workflow) return single.exerciseWorkflow(smoke);
    if (options.owner) return modes.exerciseOwner(smoke);
    if (options.monitors) return modes.exerciseMonitors(smoke);
    if (options.global) return modes.exerciseGlobal(smoke);
    if (options.monitor_moves) return modes.exerciseMonitorMoves(smoke);
    if (options.global_restart) return modes.exerciseGlobalRestart(smoke);
    return single.exercise(smoke);
}

pub fn main(initial: std.process.Init) u8 {
    system.io = initial.io;
    system.allocator = initial.arena.allocator();
    system.environment = initial.environ_map;
    const vector = initial.minimal.args.toSlice(system.allocator) catch return 1;
    const arguments = system.allocator.alloc([]const u8, vector.len) catch return 1;
    for (vector, arguments) |argument, *copy| copy.* = argument;
    const parsed = parse(arguments[@min(1, arguments.len)..]) catch {
        system.printError("{s}{s}: error: {s}\n", .{ usage, program, usage_message });
        return 2;
    };
    const options = switch (parsed) {
        .help => {
            system.print("{s}{s}", .{ usage, help });
            return 0;
        },
        .options => |options| options,
    };
    var smoke = driver.Smoke.init(options) catch |err| {
        system.printError("{s}: {s}\n", .{ program, system.describe(err) });
        return 1;
    };
    if (exercise(&smoke)) |_| {} else |err| switch (err) {
        error.Skipped => {
            smoke.record("skipped", values.string(system.describe(err))) catch {};
            system.print("SKIP {s}\n", .{system.describe(err)});
        },
        error.Failed, error.OutOfMemory => {
            const reason = system.describe(err);
            smoke.record("failure", values.string(reason)) catch {};
            smoke.record("traceback", values.string(std.fmt.allocPrint(system.allocator, "error.{s}: {s}\n", .{ @errorName(err), reason }) catch reason)) catch {};
            system.printError("FAIL {s}\n", .{reason});
        },
    }
    smoke.cleanup();
    const passed = values.truthy(values.field(smoke.result, "passed")) and smoke.cleanupErrors() == 0;
    smoke.record("passed", .{ .bool = passed }) catch {};
    const result_path = smoke.path("result.json") catch return 1;
    const encoded = values.encode(smoke.result) catch return 1;
    system.writeText(result_path, std.fmt.allocPrint(system.allocator, "{s}\n", .{encoded}) catch return 1) catch |err| {
        system.printError("{s}: {s}\n", .{ program, system.describe(err) });
        return 1;
    };
    system.print("Results: {s}\n", .{result_path});
    if (values.truthy(values.field(smoke.result, "skipped")) and smoke.cleanupErrors() == 0) return 0;
    return if (passed) 0 else 1;
}
