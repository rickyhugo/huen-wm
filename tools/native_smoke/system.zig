//! Process-wide services of the native smoke driver: I/O, failure messages, child processes, files, and the pointer.
const std = @import("std");
const values = @import("values.zig");
const Value = values.Value;

pub var io: std.Io = undefined;
pub var allocator: std.mem.Allocator = undefined;
pub var environment: *const std.process.Environ.Map = undefined;

/// `Failed` and `Skipped` carry the message of the latest `fail` or `skip` call.
pub const Error = error{ Failed, Skipped, OutOfMemory };
var message: []const u8 = "";

pub fn fail(comptime format: []const u8, arguments: anytype) Error {
    message = std.fmt.allocPrint(allocator, format, arguments) catch "OutOfMemory";
    return error.Failed;
}

pub fn skip(comptime format: []const u8, arguments: anytype) Error {
    message = std.fmt.allocPrint(allocator, format, arguments) catch "OutOfMemory";
    return error.Skipped;
}

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Failed, error.Skipped => message,
        error.OutOfMemory => "OutOfMemory",
    };
}

pub fn print(comptime format: []const u8, arguments: anytype) void {
    const text = std.fmt.allocPrint(allocator, format, arguments) catch return;
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

pub fn printError(comptime format: []const u8, arguments: anytype) void {
    const text = std.fmt.allocPrint(allocator, format, arguments) catch return;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

/// Monotonic seconds.
pub fn now() f64 {
    const stamp = std.Io.Clock.awake.now(io);
    return @as(f64, @floatFromInt(stamp.nanoseconds)) / std.time.ns_per_s;
}

pub fn pause(seconds: f64) void {
    io.sleep(.fromNanoseconds(@intFromFloat(seconds * std.time.ns_per_s)), .awake) catch {};
}

pub const Completed = struct { code: i64, stdout: []const u8, stderr: []const u8 };

/// Runs `argv` to completion and captures its output. A `timeout` in seconds kills the child when it expires.
pub fn execute(argv: []const []const u8, timeout: ?f64) Error!Completed {
    const limit: std.Io.Timeout = if (timeout) |seconds| .{ .deadline = .fromNow(io, .{ .raw = .fromNanoseconds(@intFromFloat(seconds * std.time.ns_per_s)), .clock = .awake }) } else .none;
    const result = std.process.run(allocator, io, .{ .argv = argv, .timeout = limit }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return fail("Command {f} timed out after {d} seconds", .{ values.fmt(try values.strings(argv)), timeout orelse 0 }),
        else => return fail("Cannot run {f}: {s}", .{ values.fmt(try values.strings(argv)), @errorName(err) }),
    };
    const code: i64 = switch (result.term) {
        .exited => |status| status,
        .signal, .stopped => |signal| -@as(i64, @backingInt(signal)),
        .unknown => -1,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

pub fn processIdentities(name: []const u8) Error![]i64 {
    const completed = try execute(&.{ "pgrep", "-x", name }, null);
    if (completed.code != 0 and completed.code != 1) return fail("Cannot inspect processes for {s}: {s}", .{ name, completed.stderr });
    var identities: std.ArrayList(i64) = .empty;
    var tokens = std.mem.tokenizeAny(u8, completed.stdout, " \t\r\n");
    while (tokens.next()) |token| {
        const identity = std.fmt.parseInt(i64, token, 10) catch return fail("Unexpected pgrep output: {s}", .{completed.stdout});
        try identities.append(allocator, identity);
    }
    return identities.items;
}

pub fn processValue(name: []const u8) Error!Value {
    var array: std.json.Array = .init(allocator);
    for (try processIdentities(name)) |identity| try array.append(.{ .integer = identity });
    return .{ .array = array };
}

pub fn terminate(identity: i64) Error!void {
    std.posix.kill(@intCast(identity), .TERM) catch |err| return fail("Cannot signal process {d}: {s}", .{ identity, @errorName(err) });
}

/// The executable named `name` on PATH, as `shutil.which` finds it.
pub fn which(name: []const u8) Error!?[]const u8 {
    const search = environment.get("PATH") orelse return null;
    var directories = std.mem.tokenizeScalar(u8, search, ':');
    while (directories.next()) |directory| {
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        if (!isFile(candidate)) continue;
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    return null;
}

pub fn isFile(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn absolute(path: []const u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolveAlloc(allocator, &.{path});
    const current = std.process.currentPathAlloc(io, allocator) catch |err| return fail("Cannot read the current directory: {s}", .{@errorName(err)});
    return std.fs.path.resolveAlloc(allocator, &.{ current, path });
}

/// The canonical path when `path` exists, else its absolute form.
pub fn resolved(path: []const u8) Error![]const u8 {
    const full = try absolute(path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, full, allocator) catch full;
}

/// Creates `path` and its missing parents, and fails when `path` exists.
pub fn createOutput(path: []const u8) Error![]const u8 {
    const full = try absolute(path);
    if (std.fs.path.dirname(full)) |parent| std.Io.Dir.cwd().createDirPath(io, parent) catch |err| return fail("Cannot create {s}: {s}", .{ parent, @errorName(err) });
    std.Io.Dir.cwd().createDir(io, full, .default_dir) catch |err| return fail("Cannot create {s}: {s}", .{ full, @errorName(err) });
    return std.Io.Dir.cwd().realPathFileAlloc(io, full, allocator) catch full;
}

/// The parsed JSON in `path`, or null when the file is missing or holds no valid JSON.
pub fn readJson(path: []const u8) Error!?Value {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail("Cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    return values.parse(bytes);
}

pub fn writeText(path: []const u8, content: []const u8) Error!void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch |err| return fail("Cannot write {s}: {s}", .{ path, @errorName(err) });
}

pub fn rename(source: []const u8, target: []const u8) Error!void {
    std.Io.Dir.rename(.cwd(), source, .cwd(), target, io) catch |err| return fail("Cannot replace {s}: {s}", .{ target, @errorName(err) });
}

pub fn randomBelow(bound: u32) u32 {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u32, &bytes, .little) % bound;
}

const GraphicsPoint = extern struct { horizontal: f64, vertical: f64 };
extern "c" fn CGGetActiveDisplayList(capacity: u32, displays: ?[*]u32, count: *u32) i32;
extern "c" fn CGDisplayIsBuiltin(display: u32) u32;
extern "c" fn CGEventCreate(source: ?*anyopaque) ?*anyopaque;
extern "c" fn CGEventGetLocation(event: *anyopaque) GraphicsPoint;
extern "c" fn CGWarpMouseCursorPosition(point: GraphicsPoint) i32;
extern "c" fn CFRelease(object: *anyopaque) void;

pub fn activeDisplays() Error!Value {
    var identities: [32]u32 = undefined;
    var count: u32 = 0;
    if (CGGetActiveDisplayList(identities.len, &identities, &count) != 0) return fail("Cannot list active displays", .{});
    var array: std.json.Array = .init(allocator);
    for (identities[0..count]) |identity| try array.append(try values.object(&.{
        .{ "id", .{ .integer = identity } },
        .{ "built_in", .{ .bool = CGDisplayIsBuiltin(identity) != 0 } },
    }));
    return .{ .array = array };
}

pub fn pointerLocation() Error!values.Point {
    const event = CGEventCreate(null) orelse return fail("Cannot read the pointer location", .{});
    defer CFRelease(event);
    const location = CGEventGetLocation(event);
    return .{ .left = location.horizontal, .top = location.vertical };
}

pub fn warpPointer(point: values.Point) Error!void {
    if (CGWarpMouseCursorPosition(.{ .horizontal = point.left, .vertical = point.top }) != 0) return fail("Cannot warp the pointer to {f}", .{values.fmt(point.json())});
}
