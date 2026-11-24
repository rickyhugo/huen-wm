//! Installs or removes the per-user launch agent that opens the installed app at GUI login.
//! `mise run login enable|disable|status`, which runs `zig build login -- COMMAND`. It never starts or stops the manager.
const std = @import("std");
const Io = std.Io;

const label = "dev.huen-wm.login";
const Command = enum { enable, disable, status };

const Paths = struct {
    app: []const u8,
    executable: []const u8,
    config: []const u8,
    agents: []const u8,
    destination: []const u8,
    service: []const u8,
};

fn fail(comptime format: []const u8, arguments: anytype) u8 {
    std.debug.print(format ++ "\n", arguments);
    return 1;
}

fn say(io: Io, gpa: std.mem.Allocator, comptime format: []const u8, arguments: anytype) !void {
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(gpa, format ++ "\n", arguments));
}

fn xmlEscaped(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: Io.Writer.Allocating = .init(gpa);
    for (text) |byte| switch (byte) {
        '&' => try output.writer.writeAll("&amp;"),
        '<' => try output.writer.writeAll("&lt;"),
        '>' => try output.writer.writeAll("&gt;"),
        else => try output.writer.writeByte(byte),
    };
    return output.written();
}

fn definition(gpa: std.mem.Allocator, paths: Paths) ![]const u8 {
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/usr/bin/open</string>
        \\        <string>-g</string>
        \\        <string>-a</string>
        \\        <string>{s}</string>
        \\        <string>--args</string>
        \\        <string>start</string>
        \\        <string>--config</string>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ label, try xmlEscaped(gpa, paths.app), try xmlEscaped(gpa, paths.config) });
}

/// Compares by content, not bytes, so a plist written by an earlier helper or reformatted by macOS still matches.
fn matchesDefinition(io: Io, gpa: std.mem.Allocator, paths: Paths) !bool {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "/usr/bin/plutil", "-convert", "json", "-o", "-", paths.destination } });
    if (!result.term.success()) return false;
    const parsed = std.json.parseFromSliceLeaky(struct { Label: []const u8, ProgramArguments: []const []const u8, RunAtLoad: bool }, gpa, result.stdout, .{}) catch return false;
    const expected = [_][]const u8{ "/usr/bin/open", "-g", "-a", paths.app, "--args", "start", "--config", paths.config };
    if (!std.mem.eql(u8, parsed.Label, label) or !parsed.RunAtLoad or parsed.ProgramArguments.len != expected.len) return false;
    for (parsed.ProgramArguments, expected) |actual, wanted| if (!std.mem.eql(u8, actual, wanted)) return false;
    return true;
}

fn launchctl(io: Io, gpa: std.mem.Allocator, verb: []const u8, service: []const u8) !bool {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/launchctl", verb, service } });
    return result.term.success();
}

fn isFile(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    const usage = "Usage: mise run login enable|disable|status";
    if (argv.len != 2) return fail(usage, .{});
    const command = std.meta.stringToEnum(Command, argv[1]) orelse return fail(usage, .{});
    const home = init.environ_map.get("HOME") orelse return fail("HOME must be an absolute path.", .{});
    if (!std.fs.path.isAbsolute(home)) return fail("HOME must be an absolute path.", .{});
    const agents = try std.fs.path.join(gpa, &.{ home, "Library/LaunchAgents" });
    const app = try std.fs.path.join(gpa, &.{ home, "Applications/Huen WM.app" });
    const paths: Paths = .{
        .app = app,
        .executable = try std.fs.path.join(gpa, &.{ app, "Contents/MacOS/huen-wm" }),
        .config = try std.fs.path.join(gpa, &.{ home, ".config/huen-wm/config.lua" }),
        .agents = agents,
        .destination = try std.fs.path.join(gpa, &.{ agents, label ++ ".plist" }),
        .service = try std.fmt.allocPrint(gpa, "gui/{d}/{s}", .{ std.c.getuid(), label }),
    };
    return run(io, gpa, command, paths) catch |err| fail("Login startup failed: {s}", .{@errorName(err)});
}

fn run(io: Io, gpa: std.mem.Allocator, command: Command, paths: Paths) !u8 {
    const cwd = Io.Dir.cwd();
    const installed = if (cwd.statFile(io, paths.destination, .{ .follow_symlinks = false })) |stat| present: {
        if (stat.kind == .sym_link) return fail("Refusing a symlink at {s}", .{paths.destination});
        break :present true;
    } else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    if (installed and !try matchesDefinition(io, gpa, paths)) return fail("Refusing an unexpected plist at {s}", .{paths.destination});
    switch (command) {
        .status => if (installed) {
            try say(io, gpa, "Login plist installed at {s}", .{paths.destination});
            try say(io, gpa, "This does not report whether the WM is running.", .{});
        } else try say(io, gpa, "Login startup is not installed.", .{}),
        .enable => {
            if (!isFile(io, paths.executable)) return fail("Install the app first: {s}", .{paths.app});
            if (!isFile(io, paths.config)) return fail("Create the configuration first: {s}", .{paths.config});
            try cwd.createDirPath(io, paths.agents);
            var suffix: [8]u8 = undefined;
            io.random(&suffix);
            const temporary = try std.fmt.allocPrint(gpa, "{s}/.{s}.{x}.tmp", .{ paths.agents, label, suffix });
            const contents = try definition(gpa, paths);
            const file = try cwd.createFile(io, temporary, .{ .exclusive = true });
            const written = write: {
                defer file.close(io);
                file.writeStreamingAll(io, contents) catch |err| break :write err;
                // Set the mode explicitly, as the umask could leave the agent unreadable to launchd.
                file.setPermissions(io, .fromMode(0o644)) catch |err| break :write err;
                break :write {};
            };
            written catch |err| {
                cwd.deleteFile(io, temporary) catch {};
                return err;
            };
            cwd.rename(temporary, cwd, paths.destination, io) catch |err| {
                cwd.deleteFile(io, temporary) catch {};
                return err;
            };
            if (!try launchctl(io, gpa, "enable", paths.service)) return error.LaunchctlEnableFailed;
            try say(io, gpa, "Enabled for the next GUI login. The WM was not started.", .{});
        },
        .disable => if (installed) {
            if (try launchctl(io, gpa, "print", paths.service) and !try launchctl(io, gpa, "bootout", paths.service)) return error.LaunchctlBootoutFailed;
            try cwd.deleteFile(io, paths.destination);
            try say(io, gpa, "Disabled login startup. An already running WM is not stopped.", .{});
        } else try say(io, gpa, "Login startup is already disabled.", .{}),
    }
    return 0;
}
