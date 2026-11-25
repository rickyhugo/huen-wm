//! Drives the exported `wm_*` functions against the fake adapter. Each test case runs in its own process,
//! because the manager keeps its state in globals: `manager-tests NAME [--save STATE | --load STATE]`.
const std = @import("std");
const wm = @import("wm");
const model = @import("fake/world.zig");
const cases = @import("cases.zig");

pub const Rect = model.Rect;
pub const Size = model.Size;
pub const World = model.World;
pub const allocator = model.allocator;

const modules = .{
    @import("cases/tiling.zig"),
    @import("cases/parking.zig"),
    @import("cases/identity.zig"),
    @import("cases/input.zig"),
    @import("cases/layout_check.zig"),
    @import("cases/overlap.zig"),
};

comptime {
    _ = wm;
    _ = @import("fake/adapter.zig");
    @setEvalBranchQuota(100_000);
    for (cases.all) |case| {
        var found = 0;
        for (modules) |module| found += @intFromBool(@hasDecl(module, case.name));
        if (found != 1) @compileError("tests/cases.zig lists \"" ++ case.name ++ "\" but no case module defines it once");
    }
    for (modules) |module| for (std.meta.declarations(module)) |declaration| {
        if (@typeInfo(@TypeOf(@field(module, declaration))) != .@"fn") continue;
        for (cases.all) |case| {
            if (std.mem.eql(u8, case.name, declaration)) break;
        } else @compileError("case \"" ++ declaration ++ "\" is missing from tests/cases.zig");
    };
}

pub fn main(initial: std.process.Init.Minimal) u8 {
    const vector = initial.args.vector;
    if (vector.len != 2 and vector.len != 4) return usage();
    const name = std.mem.span(vector[1]);
    var save: ?[:0]const u8 = null;
    if (vector.len == 4) {
        const flag = std.mem.span(vector[2]);
        const path = std.mem.span(vector[3]);
        if (std.mem.eql(u8, flag, "--save")) save = path else if (std.mem.eql(u8, flag, "--load")) model.current.load(path) catch |err| {
            std.debug.print("{s}: cannot load {s}: {s}\n", .{ name, path, @errorName(err) });
            return 1;
        } else return usage();
    }
    var manager: Manager = .{};
    if (model.current.displays.items.len == 0) model.current.displays.append(allocator, model.builtin_display) catch return 1;
    inline for (cases.all) |case| if (std.mem.eql(u8, case.name, name)) {
        inline for (modules) |module| if (@hasDecl(module, case.name)) {
            @field(module, case.name)(&manager) catch |err| {
                std.debug.print("FAIL {s}{s}: {s}\n", .{ if (model.current.restarted) "(after restart) " else "", name, @errorName(err) });
                return 1;
            };
        };
        if (save) |path| model.current.save(path) catch |err| {
            std.debug.print("{s}: cannot save {s}: {s}\n", .{ name, path, @errorName(err) });
            return 1;
        };
        return 0;
    };
    return usage();
}

fn usage() u8 {
    std.debug.print("usage: manager-tests NAME [--save STATE | --load STATE]\n", .{});
    for (cases.all) |case| std.debug.print("  {s}\n", .{case.name});
    return 2;
}

pub fn expect(holds: bool, comptime format: []const u8, arguments: anytype) !void {
    if (holds) return;
    std.debug.print("expected " ++ format ++ "\n", arguments);
    return error.ExpectationFailed;
}

pub fn expectFrame(actual: Rect, expected: Rect, comptime label: []const u8) !void {
    try expect(model.framesNear(actual, expected, 0.5), label ++ " at ({d}, {d}, {d}, {d}), got ({d}, {d}, {d}, {d})", .{ expected.left, expected.top, expected.width, expected.height, actual.left, actual.top, actual.width, actual.height });
}

pub fn inside(frame: Rect, area: Rect) bool {
    return frame.left >= area.left and frame.top >= area.top and frame.left + frame.width <= area.left + area.width and frame.top + frame.height <= area.top + area.height;
}

pub fn near(first: Rect, second: Rect) bool {
    return model.framesNear(first, second, 0.5);
}

/// One entry of the `windows` reply.
pub const Report = struct {
    id: u64,
    pid: c_int,
    bundle: []const u8,
    title: []const u8,
    display: u32,
    workspace: usize,
    focused: bool,
    floating: bool,
    parked: bool,
    stale: bool,
    frame: Rect,
    placement_error: ?[]const u8,
    parking_exempt: bool,
    minimum: Size,
};

/// The parts of the `status` reply that the cases read.
pub const Status = struct {
    transition_error: ?[]const u8,
    parking_recovery: ?struct { records: usize, recovered: usize, failed: usize },
    placement_memory: struct { entries: usize, claimed: usize },
    hotkeys: struct { missed: usize, rebinds: usize },
};

pub const WindowSpec = struct {
    title: []const u8,
    /// Defaults to a cascade on the first display.
    frame: ?Rect = null,
    minimum: ?Size = null,
};

extern fn wm_initialize(path: [*:0]const u8) bool;
extern fn wm_activate_config() bool;
extern fn wm_config_poll() void;
extern fn wm_tick() void;
extern fn wm_input_poll() void;
extern fn wm_command(command: [*:0]const u8) [*:0]const u8;
extern fn wm_hotkey_pressed(slot: u32, command: [*:0]const u8) void;
extern fn wm_hotkey_delivered(slot: u32, command: [*:0]const u8) void;
extern fn wm_hotkey_poll() void;
extern fn wm_swipe(fingers: u32, horizontal: f64, vertical: f64) void;
extern fn wm_shutdown() bool;

/// What a user and the applications do, and what a caller of the manager observes.
pub const Manager = struct {
    world: *World = &model.current,

    /// wm_initialize and wm_activate_config, as `huen-wm start` does before its first tick.
    pub fn start(_: *Manager) !void {
        if (!wm_initialize("/tests/config.lua") or !wm_activate_config()) return error.StartFailed;
    }

    pub fn addApp(self: *Manager, bundle: []const u8) i32 {
        const pid = self.world.next_pid;
        self.world.next_pid += 1;
        // A launch date in seconds since 2001, years before the test runs, so the process counts as established.
        self.world.apps.append(allocator, .{ .pid = pid, .bundle = bundle, .launch = 700_000_000 + @as(f64, @floatFromInt(pid)) }) catch @panic("out of memory");
        return pid;
    }

    pub fn addWindow(self: *Manager, pid: i32, spec: WindowSpec) u64 {
        const identity = self.world.next_identity;
        self.world.next_identity += 1;
        const area = self.world.displays.items[0].frame;
        const offset: f64 = @floatFromInt(30 * (self.world.windows.items.len % 8));
        var placed = spec.frame orelse Rect{ .left = area.left + 40 + offset, .top = area.top + 40 + offset, .width = 800, .height = 600 };
        if (spec.minimum) |minimum| {
            placed.width = @max(placed.width, minimum.width);
            placed.height = @max(placed.height, minimum.height);
        }
        const key = std.fmt.allocPrint(allocator, "window-{d}", .{identity}) catch @panic("out of memory");
        self.world.windows.append(allocator, .{ .identity = identity, .pid = pid, .frame = placed, .title = spec.title, .key = key, .minimum = spec.minimum }) catch @panic("out of memory");
        self.world.raise(identity);
        // A new window takes focus, as an active application's new window does.
        self.world.focused = identity;
        self.world.scan_needed = true;
        return identity;
    }

    /// The application closes the window by itself.
    pub fn closeWindow(self: *Manager, identity: u64) void {
        _ = self.world.removeWindow(identity);
    }

    pub fn terminateApp(self: *Manager, pid: i32) void {
        self.world.terminate(pid);
    }

    /// The user clicks a window: its application activates and raises it.
    pub fn userFocus(self: *Manager, identity: u64) void {
        self.world.focused = identity;
        self.world.raise(identity);
        self.world.scan_needed = true;
    }

    /// Moves the clock without a timer firing.
    pub fn advance(self: *Manager, seconds: f64) void {
        self.world.clock += seconds;
    }

    /// One adapter timer firing that scans: the clock moves one step, the polls run, a full scan feeds wm_tick,
    /// and a requested quit shuts down.
    pub fn tick(self: *Manager, count: usize) void {
        for (0..count) |_| {
            self.world.clock += self.world.step;
            if (self.world.stopped) continue;
            wm_hotkey_poll();
            wm_config_poll();
            wm_input_poll();
            self.world.scan();
            wm_tick();
            if (self.world.stopping) self.world.stopped = wm_shutdown();
        }
    }

    /// The reply stays valid until the next command.
    pub fn command(_: *Manager, text: []const u8) []const u8 {
        const terminated = allocator.dupeSentinel(u8, text, 0) catch @panic("out of memory");
        defer allocator.free(terminated);
        return std.mem.trimEnd(u8, std.mem.span(wm_command(terminated)), "\n");
    }

    /// Runs a command and fails unless the reply is `ok`.
    pub fn run(self: *Manager, text: []const u8) !void {
        const reply = self.command(text);
        try expect(std.mem.startsWith(u8, reply, "{\"ok\":true"), "`{s}` to succeed, got {s}", .{ text, reply });
    }

    pub fn parse(self: *Manager, comptime Reply: type, text: []const u8) !Reply {
        const reply = try allocator.dupe(u8, self.command(text));
        return (try std.json.parseFromSlice(Reply, allocator, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })).value;
    }

    pub fn windows(self: *Manager) ![]const Report {
        return self.parse([]const Report, "windows");
    }

    pub fn report(self: *Manager, identity: u64) !Report {
        for (try self.windows()) |item| if (item.id == identity) return item;
        std.debug.print("expected window {d} in the windows reply\n", .{identity});
        return error.ExpectationFailed;
    }

    /// The workspace shown on the first display, numbered from 1.
    pub fn shownWorkspace(self: *Manager) !usize {
        const Item = struct { display: u32, index: usize, active: bool };
        for (try self.parse([]const Item, "workspaces")) |item| if (item.active and item.display == self.world.displays.items[0].identity) return item.index;
        return error.NoActiveWorkspace;
    }

    /// Where the fake screen shows the window.
    pub fn frame(self: *Manager, identity: u64) Rect {
        return (self.world.window(identity) orelse @panic("no such window")).frame;
    }

    /// A parked window touches its display by at most a few points.
    pub fn atCorner(self: *Manager, identity: u64) bool {
        return self.world.contact(self.frame(identity)) <= 3;
    }

    /// The observe tap sees a registered combination go down.
    pub fn press(_: *Manager, slot: u32, text: [:0]const u8) void {
        wm_hotkey_pressed(slot, text);
    }

    /// Carbon delivers the hotkey registered in `slot`.
    pub fn deliver(_: *Manager, slot: u32, text: [:0]const u8) void {
        wm_hotkey_delivered(slot, text);
    }

    /// One gesture: `fingers` touch the trackpad, travel by `across` and `down` over four frames, then lift.
    pub fn swipe(self: *Manager, fingers: u32, across: f64, down: f64) void {
        for (0..5) |step| {
            const part: f64 = @as(f64, @floatFromInt(step)) / 4;
            wm_swipe(fingers, 0.5 + across * part, 0.5 + down * part);
            self.advance(0.01);
        }
        wm_swipe(0, 0, 0);
    }
};
