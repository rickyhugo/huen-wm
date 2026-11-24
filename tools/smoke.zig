//! Headless checks of the built binary's CLI, configuration evaluator and socket client.
//! `zig build smoke` passes the binary path. It never starts the manager or touches a window.
const std = @import("std");
const Io = std.Io;

const Smoke = struct {
    io: Io,
    gpa: std.mem.Allocator,
    binary: []const u8,

    const Output = struct { stdout: []u8, stderr: []u8 };

    fn invoke(self: Smoke, arguments: []const []const u8, success: bool) !Output {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.gpa, self.binary);
        try argv.appendSlice(self.gpa, arguments);
        const result = try std.process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
        if (result.term.success() != success) {
            std.debug.print("{any}: {any}\n{s}{s}\n", .{ arguments, result.term, result.stdout, result.stderr });
            return error.UnexpectedExit;
        }
        return .{ .stdout = result.stdout, .stderr = result.stderr };
    }

    fn parse(self: Smoke, text: []const u8) !std.json.Value {
        return (try std.json.parseFromSliceLeaky(std.json.Value, self.gpa, text, .{}));
    }

    fn validate(self: Smoke, config: []const u8, content: []const u8) !Output {
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = config, .data = content });
        return self.invoke(&.{ "validate", "--config", config }, true);
    }

    fn accepts(self: Smoke, config: []const u8, content: []const u8) !void {
        const output = try self.validate(config, content);
        try expect((try self.parse(output.stdout)).object.get("ok").?.bool);
    }

    fn rejects(self: Smoke, config: []const u8, content: []const u8) !Output {
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = config, .data = content });
        return self.invoke(&.{ "validate", "--config", config }, false);
    }
};

fn expect(condition: bool) !void {
    if (!condition) return error.CheckFailed;
}

const rejected = [_][]const u8{
    "return { gap = -1 }",
    "return { gaps = 12 }",
    "return { motion_duration = 'fast' }",
    "return { workspaces = {} }",
    "return { bindings = {{ mods='alt', key='h', command='workspace 99' }} }",
    "return { bindings = {{ mods='alt', key='h', command='workspace +0' }} }",
    "return { bindings = {{ mods='alt', key='h', command='workspace -11' }} }",
    "return { bindings = {{ mods='alt', key='h', command='workspace occupied' }} }",
    "return { bindings = {{ mods='alt', key='h', command='workspace 1+' }} }",
    "return { bindings = {{ mods='alt', key='h', command='workspace previous 2' }} }",
    "return { bindings = {{ mods='alt', key='h', command='workspace name:' }} }",
    "return { workspaces = {'one'}, bindings = {{ mods='alt', key='h', command='send-to-workspace name:two' }} }",
    "return {bindings={{mods='+alt++',key='h',command='quit'}}}",
    "return { bindings = {{ mods='alt', key='h', command='quit' }, { mods='alt', key='h', command='quit' }} }",
    "while true do end",
    "while true do pcall(function() while true do end end) end",
    "local input=string.rep('a',50000); string.match(input,'^a*a*a*a*a*a*b'); return {}",
    "return setmetatable({}, {__index=function() error('bad field') end})",
    "return setmetatable({}, {__index=function() while true do end end})",
    "return {bindings={oops={key='h',mods='alt',command='quit'}}}",
    "return {bindings={[128]={key='h',mods='alt',command='quit'}}}",
    "return {bindings={[1]={key='h',mods='alt',command='quit'},[999]={}}}",
    "return {rules={oops={bundle='com.apple.Terminal'}}}",
    "return {workspaces={'one',typo='two'}}",
    "return {workspaces={[1]='one',[999]='two'}}",
    "return {['gap\\0typo']=23}",
    "return {bindings={setmetatable({}, {__index=function() error('bad binding') end})}}",
    "return {rules={setmetatable({}, {__index=function() error('bad rule') end})}}",
    "return { gap = string.rep('x', 100000000) }",
    "return os.execute('true')",
    "return { workspace_back_and_forth = 'yes' }",
    "return { status_bar = { style = 'pill' } }",
    "return { bindings = {{ mods='alt', key='h', command='move-to-workspace' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus last 1' }} }",
    "return { bindings = {{ mods='alt', key='h', command='cycle' }} }",
    "return { bindings = {{ mods='alt', key='h', command='cycle sideways' }} }",
    "return { bindings = {{ mods='alt', key='h', command='cycle next both' }} }",
    "return { bindings = {{ mods='alt', key='h', command='cycle next tiled 1' }} }",
    "return { bindings = {{ mods='alt', key='h', command='swap next 1' }} }",
    "return { bindings = {{ mods='alt', key='h', command='center now' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-by 40' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-by nan 0' }} }",
    "return { bindings = {{ mods='alt', key='h', command='resize-by 10001 0' }} }",
    "return { bindings = {{ mods='alt', key='h', command='resize-by 0 20 20' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus --wrap last' }} }",
    "return { workspaces = {'one'}, bindings = {{ mods='alt', key='h', command='move-to-workspace name:two' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-app' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-app com.apple.Terminal' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-app com.apple.Terminal 99' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-app com.apple.Terminal 1 2' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-app com.apple.Terminal sideways' }} }",
    "return { workspaces = {'one'}, bindings = {{ mods='alt', key='h', command='move-app com.apple.Terminal name:two' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus-monitor' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus-monitor sideways' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus-monitor builtin' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus-monitor name:' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus-monitor left 1' }} }",
    "return { bindings = {{ mods='alt', key='h', command='focus-monitor 2' }} }",
    "return { bindings = {{ mods='alt', key='h', command='send-to-monitor' }} }",
    "return { bindings = {{ mods='alt', key='h', command='send-to-monitor sideways' }} }",
    "return { bindings = {{ mods='alt', key='h', command='send-to-monitor name:' }} }",
    "return { bindings = {{ mods='alt', key='h', command='send-to-monitor right 1' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-to-monitor' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-to-monitor sideways' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-to-monitor name:' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-to-monitor right 1' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-workspace-to-monitor' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-workspace-to-monitor sideways' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-workspace-to-monitor name:' }} }",
    "return { bindings = {{ mods='alt', key='h', command='move-workspace-to-monitor right 1' }} }",
    "return { bindings = {{ mods='alt', key='h', command='swap-monitor-workspaces' }} }",
    "return { bindings = {{ mods='alt', key='h', command='swap-monitor-workspaces sideways' }} }",
    "return { bindings = {{ mods='alt', key='h', command='swap-monitor-workspaces name:' }} }",
    "return { bindings = {{ mods='alt', key='h', command='swap-monitor-workspaces right 1' }} }",
    "return {",
};

const named_rejections = [_]struct { []const u8, []const u8 }{
    .{ "return { workspaces = {{ name='1', monitor='built-in' }} }", "MonitorRequiresGlobalWorkspaces" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={} }} }", "EmptyWorkspaceMonitors" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'built-in','external','name:A','name:B','name:C'} }} }", "TooManyWorkspaceMonitors" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external','external'} }} }", "DuplicateMonitor" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'name:DELL','name:DELL'} }} }", "DuplicateMonitor" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor='builtin' }} }", "UnknownMonitor" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor='left' }} }", "RelativeMonitorSelector" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external','next'} }} }", "RelativeMonitorSelector" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor='name:' }} }", "InvalidMonitorName" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external',7} }} }", "ExpectedString" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor={'external',typo='built-in'} }} }", "ExpectedDenseArray" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitors='external' }} }", "UnknownConfigurationField" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ monitor='external' }} }", "ExpectedWorkspaceName" },
    .{ "return { workspace_monitors={'external'}, workspaces = {{ name='1', monitor=true }} }", "ExpectedTable" },
    .{ "return { status_bar = { style = 'pill' } }", "InvalidStatusStyle" },
};

const maximum_config =
    \\local keys={'a','s','d','f','h','g','z','x','c','v','b','q','w'}
    \\local modifiers={'alt','ctrl','shift','cmd','alt+ctrl','alt+shift','alt+cmd','ctrl+shift','ctrl+cmd','shift+cmd'}
    \\local bindings, rules = {}, {}
    \\for index=1,128 do
    \\    bindings[index]={key=keys[(index-1)%13+1],mods=modifiers[math.floor((index-1)/13)+1],command=COMMAND}
    \\end
    \\for index=1,64 do rules[index]={bundle=BUNDLE} end
    \\return {bindings=bindings,rules=rules}
    \\
;

fn checkConfigurations(smoke: Smoke, config: []const u8) !void {
    for (rejected) |content| _ = try smoke.rejects(config, content);
    try smoke.accepts(config, "return {bindings={{mods='alt',key='tab',command='focus last'},{mods='alt',key='n',command='cycle next'},{mods='alt+shift',key='n',command='cycle previous floating'},{mods='ctrl',key='n',command='cycle next tiled'},{mods='alt',key='j',command='swap next'},{mods='alt',key='k',command='swap previous'},{mods='alt',key='c',command='center'},{mods='alt',key='left',command='move-by -40 0'},{mods='alt',key='right',command='resize-by 40 -20.5'}}}");
    try smoke.accepts(config, "local settings = { gap = 9, layout = 'master', motion_duration = 0, workspace_back_and_forth = true }; return settings");
    try smoke.accepts(config, "return { status_bar = { enabled = true, label = 'index', style = 'badge' } }");
    const missing = try std.fmt.allocPrint(smoke.gpa, "{s}.missing", .{config});
    _ = try smoke.invoke(&.{ "validate", "--config", missing }, false);
    try smoke.accepts(config, "print('user output is not the response'); return {}");
    try smoke.accepts(config, "\xef\xbb\xbf#!/usr/bin/env lua\nreturn {}\n");
    const oversized = try smoke.gpa.alloc(u8, 256 * 1024 + 1);
    @memset(oversized, ' ');
    _ = try smoke.rejects(config, oversized);
    try smoke.accepts(config, "return {bindings={{mods='alt',key='b',command='workspace 1'}},workspaces={'one'}}");

    const keys = "asdfghjk";
    const selectors = [_][]const u8{ "previous", "+1", "-10", "occupied+1", "occupied-2", "empty", "next-empty", "name:web dev" };
    var workspace_config: Io.Writer.Allocating = .init(smoke.gpa);
    try workspace_config.writer.writeAll("return {workspaces={'web dev','mail'},bindings={");
    for (selectors, keys) |selector, key| {
        try workspace_config.writer.print("{{mods='alt',key='{c}',command='workspace {s}'}},{{mods='alt+shift',key='{c}',command='send-to-workspace {s}'}},{{mods='ctrl',key='{c}',command='move-to-workspace {s}'}},", .{ key, selector, key, selector, key, selector });
    }
    try workspace_config.writer.writeAll("}}");
    try smoke.accepts(config, workspace_config.written());
    var app_config: Io.Writer.Allocating = .init(smoke.gpa);
    try app_config.writer.writeAll("return {workspaces={'web dev','mail'},bindings={");
    for (selectors, keys) |selector, key| try app_config.writer.print("{{mods='alt+ctrl',key='{c}',command='move-app com.apple.Terminal {s}'}},", .{ key, selector });
    try app_config.writer.writeAll("}}");
    try smoke.accepts(config, app_config.written());

    const monitor_keys = "asdfghjkl";
    const monitor_selectors = [_][]const u8{ "left", "right", "up", "down", "next", "previous", "built-in", "external", "name:DELL U2725QE" };
    const monitor_verbs = [_][]const u8{ "focus-monitor", "send-to-monitor", "move-to-monitor", "move-workspace-to-monitor", "swap-monitor-workspaces" };
    const monitor_modifiers = [_][]const u8{ "alt", "alt+shift", "ctrl", "ctrl+shift", "alt+ctrl" };
    var monitor_config: Io.Writer.Allocating = .init(smoke.gpa);
    try monitor_config.writer.writeAll("return {bindings={");
    for (monitor_verbs, monitor_modifiers) |verb, modifiers| for (monitor_selectors, monitor_keys) |selector, key| {
        try monitor_config.writer.print("{{mods='{s}',key='{c}',command='{s} {s}'}},", .{ modifiers, key, verb, selector });
    };
    try monitor_config.writer.writeAll("}}");
    try smoke.accepts(config, monitor_config.written());

    for (named_rejections) |rejection| {
        const output = try smoke.rejects(config, rejection[0]);
        if (std.mem.indexOf(u8, output.stderr, rejection[1]) == null) {
            std.debug.print("expected {s} for {s}, got {s}\n", .{ rejection[1], rejection[0], output.stderr });
            return error.CheckFailed;
        }
    }
    try smoke.accepts(config, "return { workspace_monitors={'external','built-in'}, workspaces = {{ name='1', monitor={'name:DELL U2725QE','external'} }, '2', { name='6', monitor='built-in' }, { name='7' }} }");
    try smoke.accepts(config, "warn('@on'); for index=1,1000 do warn(string.rep('x',512)) end; return {}");
    try expect((try smoke.rejects(config, "error(string.rep('x',100000))")).stderr.len < 4200);

    const plain = try std.mem.replaceOwned(u8, smoke.gpa, maximum_config, "COMMAND", "'quit'");
    try smoke.accepts(config, try std.mem.replaceOwned(u8, smoke.gpa, plain, "BUNDLE", "'com.example.app'"));
    const padded = try std.mem.replaceOwned(u8, smoke.gpa, maximum_config, "COMMAND", "string.rep(string.char(9),123)..'quit'");
    const oversized_response = try std.mem.replaceOwned(u8, smoke.gpa, padded, "BUNDLE", "string.rep(string.char(1),255)");
    try expect(std.mem.indexOf(u8, (try smoke.rejects(config, oversized_response)).stderr, "ConfigResponseTooLarge") != null);
}

/// Serves each reply on a socket at the manager's path, so the client's response validation runs without a manager.
fn checkFakeSocket(smoke: Smoke, socket_path: []const u8) !void {
    const libc = std.c;
    const listener = libc.socket(libc.AF.UNIX, libc.SOCK.STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    defer _ = libc.close(listener);
    var address: libc.sockaddr.un = .{ .family = libc.AF.UNIX, .path = @splat(0) };
    if (socket_path.len >= address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..socket_path.len], socket_path);
    if (libc.bind(listener, @ptrCast(&address), @sizeOf(libc.sockaddr.un)) != 0) return error.BindFailed;
    const cwd = Io.Dir.cwd();
    const owned = try cwd.statFile(smoke.io, socket_path, .{ .follow_symlinks = false });
    // Remove only the socket this check bound, never one a manager started meanwhile.
    defer if (cwd.statFile(smoke.io, socket_path, .{ .follow_symlinks = false })) |current| {
        if (current.inode == owned.inode) cwd.deleteFile(smoke.io, socket_path) catch {};
    } else |_| {};
    if (libc.listen(listener, 8) != 0) return error.ListenFailed;
    const replies = [_]struct { []const u8, bool }{
        .{ "garbage", false }, .{ "{\"ok\":", false },         .{ "{\"ok\":true} trailing", false },
        .{ "null", false },    .{ "{\"error\":true}", false }, .{ "{\"ok\":true}\n", true },
        .{ "[]\n", true },
    };
    for (replies) |reply| {
        var child = try std.process.spawn(smoke.io, .{ .argv = &.{ smoke.binary, "status" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        var ready = [_]std.posix.pollfd{.{ .fd = listener, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&ready, 5000) == 0) {
            child.kill(smoke.io);
            return error.ClientNeverConnected;
        }
        const connection = libc.accept(listener, null, null);
        if (connection < 0) return error.AcceptFailed;
        var request: [512]u8 = undefined;
        _ = libc.recv(connection, &request, request.len, 0);
        _ = libc.send(connection, reply[0].ptr, reply[0].len, 0);
        _ = libc.close(connection);
        const term = try child.wait(smoke.io);
        if (term.success() != reply[1]) {
            std.debug.print("status with reply {s}: {any}\n", .{ reply[0], term });
            return error.CheckFailed;
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) {
        std.debug.print("usage: smoke HUEN_WM_BINARY (run through zig build smoke)\n", .{});
        return 2;
    }
    const smoke: Smoke = .{ .io = init.io, .gpa = init.arena.allocator(), .binary = arguments[1] };

    const help = (try smoke.invoke(&.{"--help"}, true)).stdout;
    for ([_][]const u8{ "send-to-workspace", "move-to-workspace", "focus last", "cycle", "resize-by", "focus-monitor", "send-to-monitor", "move-to-monitor", "move-workspace-to-monitor", "swap-monitor-workspaces", "move-app" }) |command| {
        if (std.mem.indexOf(u8, help, command) == null) {
            std.debug.print("--help does not mention {s}\n", .{command});
            return error.CheckFailed;
        }
    }
    const doctor = (try smoke.parse((try smoke.invoke(&.{"doctor"}, true)).stdout)).object;
    try expect(std.mem.eql(u8, doctor.get("zig").?.string, "0.17.1"));
    try expect(!doctor.get("permission_prompted").?.bool);
    try expect(!doctor.get("screen_capture_required_for_tiling").?.bool);
    try expect((try smoke.parse((try smoke.invoke(&.{ "validate", "--config", "config/example.lua" }, true)).stdout)).object.get("ok").?.bool);
    try expect((try smoke.parse((try smoke.invoke(&.{ "validate", "--config", "config/aerospace.lua" }, true)).stdout)).object.get("ok").?.bool);
    _ = try smoke.invoke(&.{"--config"}, false);
    _ = try smoke.invoke(&.{"--unknown-option"}, false);

    var suffix: [8]u8 = undefined;
    init.io.random(&suffix);
    const directory = try std.fmt.allocPrint(smoke.gpa, ".zig-cache/smoke-{x}", .{suffix});
    try Io.Dir.cwd().createDirPath(init.io, directory);
    defer Io.Dir.cwd().deleteTree(init.io, directory) catch {};
    try checkConfigurations(smoke, try std.fmt.allocPrint(smoke.gpa, "{s}/config.lua", .{directory}));

    const socket_path = doctor.get("socket").?.string;
    var fake_socket_checked = false;
    if (Io.Dir.cwd().statFile(init.io, socket_path, .{ .follow_symlinks = false })) |_| {} else |err| switch (err) {
        error.FileNotFound => {
            try expect(std.mem.indexOf(u8, (try smoke.invoke(&.{"status"}, false)).stderr, "not running") != null);
            try checkFakeSocket(smoke, socket_path);
            fake_socket_checked = true;
        },
        else => return err,
    }
    const accessibility = switch (doctor.get("accessibility").?) {
        .bool => |granted| granted,
        else => false,
    };
    const summary = try std.fmt.allocPrint(smoke.gpa, "{{\"headless_smoke\":\"passed\",\"fake_socket_checked\":{},\"accessibility\":{},\"native_window_smoke\":\"not run\",\"wm_started\":false}}\n", .{ fake_socket_checked, accessibility });
    try Io.File.stdout().writeStreamingAll(init.io, summary);
    return 0;
}
