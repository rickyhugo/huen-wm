const std = @import("std");
const native = @import("native.zig");
const memory = @import("memory.zig");
const session = @import("session.zig");
const rules = @import("rules.zig");
const desktop = @import("desktop.zig");
const recovery = @import("recovery.zig");
const routing = @import("routing.zig");
const allocator = std.heap.c_allocator;
const text = native.text;
const Rect = desktop.Rect;
const Window = desktop.Window;

var placement_memory: memory.Memory = .{};
var placement_memory_loaded = false;
var placement_claims: usize = 0;

fn placementEntry(window: Window, frame: Rect, expires: f64) ?memory.Entry {
    if (window.observation.bundle[0] == 0) return null;
    var entry: memory.Entry = .{ .bundle = window.observation.bundle, .floating = window.floating, .floating_frame = window.floating_frame, .frame = frame, .expires = expires };
    const name = text(&desktop.config().workspaces[window.workspace].name);
    @memcpy(entry.workspace[0..name.len], name);
    return entry;
}

fn writePlacements(entries: []const memory.Entry) void {
    const hash = session.storageKey(memory.stem, std.mem.span(native.platform_filter()));
    const encoded = memory.encode(allocator, entries) catch return native.platform_error("Placement memory: out of memory");
    defer allocator.free(encoded);
    if (!session.huen_session_write(memory.stem, &hash, encoded.ptr, encoded.len, true)) native.platform_error("Placement memory: file write failed");
}

// After restoration each window is where a restarted manager will discover it.
pub fn persist() void {
    if (!desktop.config().placement_memory) return;
    const now = native.platform_monotonic();
    var persisted = placement_memory;
    persisted.prune(now);
    // An entry whose application still runs is for a closed window, so the next manager must not hand it out.
    persisted.settle(now, recovery.processExited);
    persisted.dropPending();
    for (desktop.windows()) |window| {
        var frame: Rect = undefined;
        if (window.vanished == null and native.platform_read_frame(window.identity, &frame)) persisted.remember(placementEntry(window, frame, now) orelse continue);
    }
    writePlacements(persisted.entries[0..persisted.count]);
}

pub fn load() void {
    if (!placement_memory_loaded and desktop.config().placement_memory) read: {
        const hash = session.storageKey(memory.stem, std.mem.span(native.platform_filter()));
        const bytes = allocator.alloc(u8, memory.max_bytes) catch {
            native.platform_error("Placement memory: out of memory");
            break :read;
        };
        defer allocator.free(bytes);
        var used: usize = 0;
        switch (session.huen_session_read(memory.stem, &hash, bytes.ptr, bytes.len, &used)) {
            0 => memory.decode(allocator, bytes[0..used], native.platform_monotonic() + 60, &placement_memory) catch native.platform_error("Placement memory: file rejected"),
            1 => break :read,
            else => {
                native.platform_error("Placement memory: file unreadable");
                break :read;
            },
        }
        writePlacements(&.{});
    }
    placement_memory_loaded = true;
    if (placement_memory.count > 0) placement_memory.settle(native.platform_monotonic(), recovery.processExited);
}

pub fn claim(window: *Window, decision: rules.Decision, display: u32) void {
    if (desktop.config().placement_memory and decision.workspace == null) claim: {
        const entry = placement_memory.claim(text(&window.observation.bundle), window.observation.frame, window.discovered) orelse break :claim;
        const workspace = desktop.config().workspaceIndex(text(&entry.workspace)) orelse break :claim;
        placement_claims += 1;
        window.workspace = workspace;
        if (decision.floating == null) window.floating = entry.floating;
        if (!window.floating or decision.geometry != null or decision.centered) break :claim;
        const destination = routing.resolve()[workspace] orelse display;
        window.floating_frame = desktop.boundedFloating(entry.floating_frame, desktop.displayArea(destination));
        window.floating_restore = true;
    }
}

// An application can take seconds to exit after its windows close, so the entry waits for `settle` to see the exit.
pub fn rememberClosed(gone: Window, now: f64) void {
    if (desktop.config().placement_memory and gone.observation.process_token != 0) if (placementEntry(gone, gone.observation.frame, now + 30)) |entry| {
        var owned = entry;
        owned.owner = .{ .process = .{ .pid = gone.observation.pid, .token = gone.observation.process_token }, .since = now };
        placement_memory.remember(owned);
    };
}

// Expired entries are pruned first, so the count is what a claim could still use.
pub fn status() struct { entries: usize, claimed: usize } {
    return .{ .entries = if (placement_memory.count == 0) 0 else unexpired: {
        placement_memory.prune(native.platform_monotonic());
        break :unexpired placement_memory.count;
    }, .claimed = placement_claims };
}
