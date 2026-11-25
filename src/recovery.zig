const std = @import("std");
const native = @import("native.zig");
const parking = @import("parking.zig");
const memory = @import("memory.zig");
const world = @import("world.zig");
const allocator = std.heap.c_allocator;
const text = native.text;
const Rect = world.Rect;
const Window = world.Window;

var parking_journal: parking.Writer = .{};
var parking_journal_failed = false;

// A parked window the manager lost track of while its application still runs. Its record stays in the journal and is
// matched against new windows for up to a minute, because most orphans are windows their application closed while parked.
const orphan_lifetime = 60.0;
const Orphan = struct { bundle: [256]u8, pid: c_int, token: f64, original: Rect, corners: [2]Rect, since: f64 };
var orphan_buffer: [256]Orphan = undefined;
var orphans: std.ArrayList(Orphan) = .initBuffer(&orphan_buffer);
const ParkingRecovery = struct { records: usize = 0, recovered: usize = 0, failed: usize = 0 };

// Null until the first tick that has displays has matched the journal of the previous process.
var parking_recovery: ?ParkingRecovery = null;

fn reportParkingJournal(message: []const u8, err: anyerror) void {
    var buffer: [256:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ message, @errorName(err) }) catch return;
    native.platform_error(&buffer);
}

fn writeParkingJournal(records: []const parking.Record) void {
    parking_journal.save(allocator, std.mem.span(native.platform_filter()), records) catch |err| {
        if (!parking_journal_failed) reportParkingJournal("Parking journal save failed", err);
        parking_journal_failed = true;
        return;
    };
    parking_journal_failed = false;
}

// A corner that touches another display is never used, so a window there is not a parked one.
fn parkingRecord(window: *const Window) ?parking.Record {
    const display = world.displays()[world.displayIndex(window.display) orelse return null];
    var corners = parking.corners(window.parking_frame, display.frame);
    const blocked = [2]bool{ world.overlapsOtherDisplays(corners[0], window.display), world.overlapsOtherDisplays(corners[1], window.display) };
    if (blocked[0] and blocked[1]) return null;
    if (blocked[0]) corners[0] = corners[1];
    if (blocked[1]) corners[1] = corners[0];
    const record: parking.Record = .{ .bundle = text(&window.observation.bundle), .pid = window.observation.pid, .token = window.observation.process_token, .original = window.parking_frame, .corners = corners };
    return if (parking.valid(record)) record else null;
}

fn orphanRecord(lost: *const Orphan) parking.Record {
    return .{ .bundle = text(&lost.bundle), .pid = lost.pid, .token = lost.token, .original = lost.original, .corners = lost.corners };
}

fn orphanOf(record: parking.Record, since: f64) Orphan {
    var result: Orphan = .{ .bundle = @splat(0), .pid = record.pid, .token = record.token, .original = record.original, .corners = record.corners, .since = since };
    @memcpy(result.bundle[0..record.bundle.len], record.bundle);
    return result;
}

// `prior` is the window state a rollback is about to return to. A window that the transaction showed goes back to its corner.
pub fn save(prior: []const Window) void {
    var records: [parking.max_records]parking.Record = undefined;
    var count: usize = 0;
    for (world.windows()) |*window| if ((window.parked or window.vanished_parked) and count < records.len) if (parkingRecord(window)) |record| {
        records[count] = record;
        count += 1;
    };
    for (prior) |*window| {
        if (!window.parked or count == records.len) continue;
        if (world.windowIndex(window.identity)) |index| if (world.windows()[index].parked) continue;
        records[count] = parkingRecord(window) orelse continue;
        count += 1;
    }
    for (orphans.items) |*lost| if (count < records.len) {
        records[count] = orphanRecord(lost);
        count += 1;
    };
    writeParkingJournal(records[0..count]);
}

// After a verified restore only the orphans can still sit at a corner.
pub fn settle() void {
    var records: [256]parking.Record = undefined;
    for (orphans.items, records[0..orphans.items.len]) |*lost, *record| record.* = orphanRecord(lost);
    writeParkingJournal(records[0..orphans.items.len]);
}

// The display layout may have changed since the crash, so the frame is bounded to the display it overlaps most.
pub fn restingFrame(frame: Rect) Rect {
    var largest: f64 = 0;
    var area = world.displays()[0].frame;
    for (world.displays()) |display| {
        const bounds = display.full_bounds;
        const width = world.overlap(frame, bounds, .horizontal);
        const height = world.overlap(frame, bounds, .vertical);
        if (width > 0 and height > 0 and width * height > largest) {
            largest = width * height;
            area = display.frame;
        }
    }
    return world.boundedFloating(frame, area);
}

pub fn processExited(process: memory.Process) bool {
    return native.platform_process_token(process.pid) != process.token;
}

pub const Recovered = struct { matches: []parking.Recovery, first_scan: bool };

// Patches the observations with the readback so discovery assigns each window to the display it is on now.
// The first scan matches the journal of the previous process. Later scans match the orphans against windows not seen before.
pub fn recover(observed: []native.WMWindow, recovered: *[1024]parking.Recovery) Recovered {
    const first_scan = parking_recovery == null;
    const matches = if (!first_scan and orphans.items.len == 0) recovered[0..0] else recover: {
        var outcome: ParkingRecovery = parking_recovery orelse .{};
        defer parking_recovery = outcome;
        var records: [parking.max_records]parking.Record = undefined;
        var since: [parking.max_records]f64 = undefined;
        const now = native.platform_monotonic();
        var record_count: usize = 0;
        var loaded: ?std.json.Parsed(parking.Journal) = null;
        defer if (loaded) |*parsed| parsed.deinit();
        if (first_scan) {
            loaded = parking.load(allocator, std.mem.span(native.platform_filter())) catch |err| {
                reportParkingJournal("Parking journal rejected", err);
                break :recover recovered[0..0];
            };
            if (loaded) |parsed| {
                record_count = parsed.value.records.len;
                @memcpy(records[0..record_count], parsed.value.records);
                @memset(since[0..record_count], now);
                outcome.records = record_count;
            }
        } else for (orphans.items) |*lost| {
            records[record_count] = orphanRecord(lost);
            since[record_count] = lost.since;
            record_count += 1;
        }
        if (record_count == 0) break :recover recovered[0..0];
        var eligible: [1024]bool = undefined;
        for (observed, eligible[0..observed.len]) |observation, *open| open.* = world.windowIndex(observation.identity) == null;
        var claimed: [parking.max_records]bool = @splat(false);
        const matches = parking.match(records[0..record_count], observed, eligible[0..observed.len], claimed[0..record_count], recovered);
        // An unmatched record stays for up to a minute while its application runs, because a scan can miss an application that does not answer.
        var kept: [256]Orphan = undefined;
        var kept_count: usize = 0;
        for (records[0..record_count], claimed[0..record_count], since[0..record_count]) |record, used, lost_at| {
            if (used or kept_count == kept.len or now - lost_at > orphan_lifetime or processExited(.{ .pid = record.pid, .token = record.token })) continue;
            kept[kept_count] = orphanOf(record, lost_at);
            kept_count += 1;
        }
        orphans.clearRetainingCapacity();
        orphans.appendSliceAssumeCapacity(kept[0..kept_count]);
        for (matches) |*recovery| {
            const window = &observed[recovery.index];
            recovery.original = restingFrame(recovery.original);
            var actual = window.frame;
            if (native.platform_adopt_original(window.identity, recovery.original, &actual)) outcome.recovered += 1 else outcome.failed += 1;
            window.frame = actual;
        }
        if (matches.len > 0) native.platform_config_changed();
        break :recover matches;
    };
    return .{ .matches = matches, .first_scan = first_scan };
}

// The window can still sit at its corner, as when its application stops being a regular application.
pub fn orphan(window: *const Window, since: f64) void {
    if (parkingRecord(window)) |record| {
        if (orphans.items.len == orphans.capacity) _ = orphans.orderedRemove(0);
        orphans.appendAssumeCapacity(orphanOf(record, since));
    }
}

pub fn status() ?ParkingRecovery {
    return parking_recovery;
}
