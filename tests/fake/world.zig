const std = @import("std");
const abi = @import("abi.zig");

pub const allocator = std.heap.c_allocator;
pub const Rect = abi.Rect;

pub const Size = struct { width: f64, height: f64 };
pub const Display = struct { identity: u32, frame: Rect, full_bounds: Rect, name: []const u8, built_in: bool };
pub const App = struct { pid: i32, bundle: []const u8, launch: f64 };
/// What an application holds about one of its windows: the frame the fake screen shows.
pub const Window = struct {
    identity: u64,
    pid: i32,
    frame: Rect,
    title: []const u8,
    /// The AXIdentifier that session continuity matches across restarts.
    key: []const u8,
    minimized: bool = false,
    stacking: u64 = 0,
    /// The application clamps a smaller written size up to this one.
    minimum: ?Size = null,
};
pub const File = struct { name: []const u8, bytes: []const u8 };

pub const Layout = enum { dwindle, master };
pub const PatternKind = enum { literal, glob, regex };
pub const Geometry = struct { left: f64, top: f64, width: f64, height: f64 };
pub const WireWorkspace = struct { name: []const u8, layout: Layout = .dwindle, ratio: f64 = 0.5, monitor: ?[]const []const u8 = null };
pub const WireBinding = struct { key: u32, modifiers: u32, command: []const u8 };
pub const WireMode = struct { name: []const u8, bindings: []const WireBinding = &.{} };
pub const WireTitle = struct { kind: PatternKind, pattern: []const u8 };
pub const WireRule = struct { bundle: []const u8, bundle_kind: PatternKind = .literal, title: ?WireTitle = null, floating: ?bool = null, workspace: ?usize = null, geometry: ?Geometry = null, centered: bool = false, focus_on_activate: ?bool = null };
/// The Lua worker's output: `WireConfig` in src/config.zig. Field names must match it.
pub const Config = struct {
    workspace_monitors: ?[]const []const u8 = null,
    mouse_follows_monitor: bool = false,
    focus_follows_mouse: bool = true,
    workspace_back_and_forth: bool = false,
    focus_on_activate: bool = false,
    placement_memory: bool = true,
    status_bar: struct { enabled: bool = true, label: enum { name, index, index_and_name } = .name, style: enum { text, badge } = .text } = .{},
    session: struct { enabled: bool = false } = .{},
    mouse: struct { enabled: bool = false, modifiers: u32 = 4096 | 2048 } = .{},
    swipe: struct { enabled: bool = false, fingers: u32 = 3 } = .{},
    floating_size: struct { width: f64 = 0.5, height: f64 = 0.5 } = .{},
    single_window_max_width: f64 = 0,
    gap: f64 = 8,
    border_width: f64 = 2,
    border_color: u32 = 0x9bafff,
    border_single_window: bool = true,
    duration: f64 = 0,
    workspaces: []const WireWorkspace = &.{ .{ .name = "1" }, .{ .name = "2" }, .{ .name = "3" }, .{ .name = "4" } },
    modes: []const WireMode = &.{.{ .name = "main" }},
    rules: []const WireRule = &.{},
};

/// The adapter's per-process record of a window. Records start empty in every manager process; a scan creates them.
pub const Record = struct {
    identity: u64,
    observation: abi.Window,
    /// The frame that restore writes back.
    original: Rect,
    changed: bool = false,
};

/// The part of the world that a restarted manager process meets again.
const Saved = struct {
    clock: f64,
    displays: []const Display,
    apps: []const App,
    windows: []const Window,
    files: []const File,
    focused: u64,
    next_identity: u64,
    next_pid: i32,
    next_stacking: u64,
    config: Config,
    remembered: []const Rect,
};

pub const World = struct {
    clock: f64 = 1000,
    step: f64 = 0.0625,
    displays: std.ArrayList(Display) = .empty,
    apps: std.ArrayList(App) = .empty,
    windows: std.ArrayList(Window) = .empty,
    files: std.ArrayList(File) = .empty,
    focused: u64 = 0,
    next_identity: u64 = 1,
    next_pid: i32 = 501,
    next_stacking: u64 = 1,
    pointer: abi.Point = .{ .left = 720, .top = 450 },
    config: Config = .{},
    /// Frames a case keeps for the process after a restart.
    remembered: std.ArrayList(Rect) = .empty,
    restarted: bool = false,

    records: std.ArrayList(Record) = .empty,
    scan_needed: bool = true,
    last_scan: f64 = -std.math.inf(f64),
    /// Size and position writes that reached an application.
    frame_writes: usize = 0,
    journal: std.ArrayList([]const u8) = .empty,
    tile_hits: std.ArrayList(abi.HitRegion) = .empty,
    boundary_hits: std.ArrayList(abi.HitRegion) = .empty,
    input: abi.InputAvailability = .disabled,
    observe_active: bool = false,
    pointer_buttons: bool = false,
    closing: ?struct { identity: u64, token: f64 } = null,
    stopping: bool = false,
    stopped: bool = false,

    pub fn window(self: *World, identity: u64) ?*Window {
        for (self.windows.items) |*candidate| if (candidate.identity == identity) return candidate;
        return null;
    }

    pub fn app(self: *World, pid: i32) ?*App {
        for (self.apps.items) |*candidate| if (candidate.pid == pid) return candidate;
        return null;
    }

    pub fn record(self: *World, identity: u64) ?*Record {
        for (self.records.items) |*candidate| if (candidate.identity == identity) return candidate;
        return null;
    }

    pub fn raise(self: *World, identity: u64) void {
        const target = self.window(identity) orelse return;
        target.stacking = self.next_stacking;
        self.next_stacking += 1;
    }

    /// An AX size and position write. The application clamps the size to its minimum and keeps the origin.
    pub fn writeFrame(self: *World, identity: u64, frame: Rect) bool {
        const target = self.window(identity) orelse return false;
        if (target.minimized) return false;
        var accepted = frame;
        if (target.minimum) |minimum| {
            accepted.width = @max(accepted.width, minimum.width);
            accepted.height = @max(accepted.height, minimum.height);
        }
        self.frame_writes += 1;
        target.frame = accepted;
        return true;
    }

    /// scanWindows in native/platform.m: drops records of vanished windows, then observes every window,
    /// applications in launch order and each application's windows front to back.
    pub fn scan(self: *World) void {
        self.scan_needed = false;
        self.last_scan = self.clock;
        var index: usize = 0;
        while (index < self.records.items.len) {
            if (self.window(self.records.items[index].identity) == null) {
                _ = self.records.orderedRemove(index);
            } else index += 1;
        }
        for (self.apps.items) |owner| {
            var members: std.ArrayList(*Window) = .empty;
            defer members.deinit(allocator);
            for (self.windows.items) |*candidate| if (candidate.pid == owner.pid) members.append(allocator, candidate) catch @panic("out of memory");
            std.mem.sort(*Window, members.items, {}, frontFirst);
            for (members.items) |member| self.observe(owner, member.*, members.items);
        }
    }

    fn frontFirst(_: void, first: *Window, second: *Window) bool {
        return first.stacking > second.stacking;
    }

    fn observe(self: *World, owner: App, truth: Window, siblings: []const *Window) void {
        const entry = self.record(truth.identity) orelse created: {
            self.records.append(allocator, .{ .identity = truth.identity, .observation = std.mem.zeroes(abi.Window), .original = truth.frame }) catch @panic("out of memory");
            break :created &self.records.items[self.records.items.len - 1];
        };
        // native/platform.m pairs an AX window with on-screen bounds only when no other window of its
        // application has a frame within 4 points, so two such windows are both not on screen.
        var matching: usize = 0;
        for (siblings) |sibling| matching += @intFromBool(framesNear(sibling.frame, truth.frame, 4));
        var in_front: u32 = 0;
        for (self.windows.items) |member| in_front += @intFromBool(member.stacking > truth.stacking and !member.minimized and self.listed(member.frame));
        var observation = entry.observation;
        observation.identity = truth.identity;
        observation.pid = truth.pid;
        observation.frame = truth.frame;
        observation.stale = false;
        observation.minimized = truth.minimized;
        observation.fullscreen = false;
        observation.onscreen = matching == 1 and !truth.minimized and self.listed(truth.frame);
        observation.public_window_id = if (observation.onscreen) @truncate(truth.identity) else 0;
        observation.hit_eligible = observation.public_window_id != 0;
        observation.focused = self.focused == truth.identity;
        observation.title_complete = true;
        observation.process_token = owner.launch;
        observation.stack_order = if (self.listed(truth.frame) and !truth.minimized) in_front else std.math.maxInt(u32);
        copyText(&observation.bundle, owner.bundle);
        copyText(&observation.title, truth.title);
        entry.observation = observation;
    }

    /// WindowServer lists a window that touches any display.
    fn listed(self: *World, frame: Rect) bool {
        for (self.displays.items) |display| if (intersection(frame, display.full_bounds) != null) return true;
        return false;
    }

    /// The largest contact a frame keeps with any display's usable area: the shorter side of the intersection.
    pub fn contact(self: *World, frame: Rect) f64 {
        var best: f64 = 0;
        for (self.displays.items) |display| if (intersection(frame, display.frame)) |shared| {
            best = @max(best, @min(shared.width, shared.height));
        };
        return best;
    }

    pub fn removeWindow(self: *World, identity: u64) bool {
        for (self.windows.items, 0..) |member, index| if (member.identity == identity) {
            // macOS hands focus to the application's frontmost remaining window when the focused one goes away.
            if (self.focused == identity) {
                self.focused = 0;
                var best: u64 = 0;
                for (self.windows.items) |other| if (other.pid == member.pid and other.identity != identity and !other.minimized and other.stacking > best) {
                    best = other.stacking;
                    self.focused = other.identity;
                };
            }
            _ = self.windows.orderedRemove(index);
            self.scan_needed = true;
            return true;
        };
        return false;
    }

    pub fn terminate(self: *World, pid: i32) void {
        for (self.apps.items, 0..) |owner, index| if (owner.pid == pid) {
            _ = self.apps.orderedRemove(index);
            break;
        };
        var cursor: usize = 0;
        while (cursor < self.windows.items.len) {
            if (self.windows.items[cursor].pid == pid) {
                if (self.focused == self.windows.items[cursor].identity) self.focused = 0;
                _ = self.windows.orderedRemove(cursor);
            } else cursor += 1;
        }
        self.scan_needed = true;
    }

    pub fn file(self: *World, name: []const u8) ?*File {
        for (self.files.items) |*candidate| if (std.mem.eql(u8, candidate.name, name)) return candidate;
        return null;
    }

    pub fn save(self: *World, path: [:0]const u8) !void {
        const encoded = try std.json.Stringify.valueAlloc(allocator, Saved{
            .clock = self.clock,
            .displays = self.displays.items,
            .apps = self.apps.items,
            .windows = self.windows.items,
            .files = self.files.items,
            .focused = self.focused,
            .next_identity = self.next_identity,
            .next_pid = self.next_pid,
            .next_stacking = self.next_stacking,
            .config = self.config,
            .remembered = self.remembered.items,
        }, .{});
        const stream = std.c.fopen(path, "wb") orelse return error.StateFileUnwritable;
        defer _ = std.c.fclose(stream);
        if (std.c.fwrite(encoded.ptr, 1, encoded.len, stream) != encoded.len) return error.StateFileUnwritable;
    }

    /// Records stay empty: the loaded world meets a new manager process.
    pub fn load(self: *World, path: [:0]const u8) !void {
        const stream = std.c.fopen(path, "rb") orelse return error.StateFileMissing;
        defer _ = std.c.fclose(stream);
        var bytes: std.ArrayList(u8) = .empty;
        var chunk: [65536]u8 = undefined;
        while (true) {
            const amount = std.c.fread(&chunk, 1, chunk.len, stream);
            if (amount == 0) break;
            try bytes.appendSlice(allocator, chunk[0..amount]);
        }
        const saved = (try std.json.parseFromSlice(Saved, allocator, bytes.items, .{ .allocate = .alloc_always })).value;
        self.clock = saved.clock;
        try self.displays.appendSlice(allocator, saved.displays);
        try self.apps.appendSlice(allocator, saved.apps);
        try self.windows.appendSlice(allocator, saved.windows);
        try self.files.appendSlice(allocator, saved.files);
        try self.remembered.appendSlice(allocator, saved.remembered);
        self.focused = saved.focused;
        self.next_identity = saved.next_identity;
        self.next_pid = saved.next_pid;
        self.next_stacking = saved.next_stacking;
        self.config = saved.config;
        self.restarted = true;
    }
};

pub var current: World = .{};

pub const builtin_display: Display = .{ .identity = 1, .frame = .{ .left = 0, .top = 25, .width = 1440, .height = 875 }, .full_bounds = .{ .left = 0, .top = 0, .width = 1440, .height = 900 }, .name = "Built-in Retina Display", .built_in = true };

/// To the right of the built-in display, with the same menu bar height.
pub const external_display: Display = .{ .identity = 2, .frame = .{ .left = 1440, .top = 25, .width = 1920, .height = 1055 }, .full_bounds = .{ .left = 1440, .top = 0, .width = 1920, .height = 1080 }, .name = "DELL U2725QE", .built_in = false };

pub fn framesNear(first: Rect, second: Rect, tolerance: f64) bool {
    return @abs(first.left - second.left) <= tolerance and @abs(first.top - second.top) <= tolerance and @abs(first.width - second.width) <= tolerance and @abs(first.height - second.height) <= tolerance;
}

pub fn intersection(first: Rect, second: Rect) ?Rect {
    const left = @max(first.left, second.left);
    const top = @max(first.top, second.top);
    const width = @min(first.left + first.width, second.left + second.width) - left;
    const height = @min(first.top + first.height, second.top + second.height) - top;
    if (width <= 0 or height <= 0) return null;
    return .{ .left = left, .top = top, .width = width, .height = height };
}

pub fn copyText(destination: []u8, source: []const u8) void {
    @memset(destination, 0);
    const length = @min(source.len, destination.len - 1);
    @memcpy(destination[0..length], source[0..length]);
}
