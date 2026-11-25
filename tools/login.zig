//! Installs or removes the per-user launch agent that opens the installed app at GUI login.
//! `mise run login enable|disable|status`, which runs `zig build login -- COMMAND`. It never starts or stops the manager.
const std = @import("std");
const Io = std.Io;

const label = "dev.huen-wm.login";
const Command = enum { enable, disable, status };

fn fail(comptime format: []const u8, arguments: anytype) u8 {
    std.debug.print(format ++ "\n", arguments);
    return 1;
}

fn say(io: Io, gpa: std.mem.Allocator, comptime format: []const u8, arguments: anytype) !void {
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(gpa, format ++ "\n", arguments));
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
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const usage = "Usage: mise run login enable|disable|status";
    if (argv.len != 2) return fail(usage, .{});
    const command = std.meta.stringToEnum(Command, argv[1]) orelse return fail(usage, .{});
    const home = init.environ_map.get("HOME") orelse "";
    if (!std.fs.path.isAbsolute(home)) return fail("HOME must be an absolute path.", .{});
    return run(init.io, init.arena.allocator(), command, home) catch |err| fail("Login startup failed: {s}", .{@errorName(err)});
}

fn run(io: Io, gpa: std.mem.Allocator, command: Command, home: []const u8) !u8 {
    const cwd = Io.Dir.cwd();
    const agents = try std.fs.path.join(gpa, &.{ home, "Library/LaunchAgents" });
    const app = try std.fs.path.join(gpa, &.{ home, "Applications/Huen WM.app" });
    const config = try std.fs.path.join(gpa, &.{ home, ".config/huen-wm/config.lua" });
    const destination = try std.fs.path.join(gpa, &.{ agents, label ++ ".plist" });
    const service = try std.fmt.allocPrint(gpa, "gui/{d}/{s}", .{ std.c.getuid(), label });
    const arguments = [_][]const u8{ "/usr/bin/open", "-g", "-a", app, "--args", "start", "--config", config };
    const installed = if (cwd.statFile(io, destination, .{ .follow_symlinks = false })) |stat| present: {
        if (stat.kind == .sym_link) return fail("Refusing a symlink at {s}", .{destination});
        break :present true;
    } else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    if (installed) matches: {
        // Compares by content, not bytes, so a plist written by an earlier helper or reformatted by macOS still matches.
        const result = try std.process.run(gpa, io, .{ .argv = &.{ "/usr/bin/plutil", "-convert", "json", "-o", "-", destination } });
        const plist = if (result.term.success()) std.json.parseFromSliceLeaky(struct { Label: []const u8, ProgramArguments: []const []const u8, RunAtLoad: bool }, gpa, result.stdout, .{}) catch null else null;
        if (plist) |found| if (std.mem.eql(u8, found.Label, label) and found.RunAtLoad and found.ProgramArguments.len == arguments.len) {
            for (found.ProgramArguments, arguments) |actual, wanted| {
                if (!std.mem.eql(u8, actual, wanted)) break;
            } else break :matches;
        };
        return fail("Refusing an unexpected plist at {s}", .{destination});
    }
    switch (command) {
        .status => if (installed) {
            try say(io, gpa, "Login plist installed at {s}", .{destination});
            try say(io, gpa, "This does not report whether the WM is running.", .{});
        } else try say(io, gpa, "Login startup is not installed.", .{}),
        .enable => {
            if (!isFile(io, try std.fs.path.join(gpa, &.{ app, "Contents/MacOS/huen-wm" }))) return fail("Install the app first: {s}", .{app});
            if (!isFile(io, config)) return fail("Create the configuration first: {s}", .{config});
            try cwd.createDirPath(io, agents);
            var contents: Io.Writer.Allocating = .init(gpa);
            try contents.writer.print(
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                \\<plist version="1.0">
                \\<dict>
                \\    <key>Label</key>
                \\    <string>{s}</string>
                \\    <key>ProgramArguments</key>
                \\    <array>
                \\
            , .{label});
            for (arguments) |argument| {
                try contents.writer.writeAll("        <string>");
                for (argument) |byte| try switch (byte) {
                    '&' => contents.writer.writeAll("&amp;"),
                    '<' => contents.writer.writeAll("&lt;"),
                    '>' => contents.writer.writeAll("&gt;"),
                    else => contents.writer.writeByte(byte),
                };
                try contents.writer.writeAll("</string>\n");
            }
            try contents.writer.writeAll(
                \\    </array>
                \\    <key>RunAtLoad</key>
                \\    <true/>
                \\</dict>
                \\</plist>
                \\
            );
            var suffix: [8]u8 = undefined;
            io.random(&suffix);
            const temporary = try std.fmt.allocPrint(gpa, "{s}/.{s}.{x}.tmp", .{ agents, label, suffix });
            const file = try cwd.createFile(io, temporary, .{ .exclusive = true });
            errdefer cwd.deleteFile(io, temporary) catch {};
            {
                defer file.close(io);
                try file.writeStreamingAll(io, contents.written());
                // Set the mode explicitly, as the umask could leave the agent unreadable to launchd.
                try file.setPermissions(io, .fromMode(0o644));
            }
            try cwd.rename(temporary, cwd, destination, io);
            if (!try launchctl(io, gpa, "enable", service)) return error.LaunchctlEnableFailed;
            try say(io, gpa, "Enabled for the next GUI login. The WM was not started.", .{});
        },
        .disable => if (installed) {
            if (try launchctl(io, gpa, "print", service) and !try launchctl(io, gpa, "bootout", service)) return error.LaunchctlBootoutFailed;
            try cwd.deleteFile(io, destination);
            try say(io, gpa, "Disabled login startup. An already running WM is not stopped.", .{});
        } else try say(io, gpa, "Login startup is already disabled.", .{}),
    }
    return 0;
}
