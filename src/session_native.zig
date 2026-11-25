//! Native session identity and private file storage under ~/Library/Application Support/HuenWM.
//! Built as its own object for the manager executable; `native/session.h` declares its exports for Objective-C callers.

const std = @import("std");
const macos = @import("macos.zig");
const NativeAttributes = @import("session.zig").NativeAttributes;

const libc = std.c;
const mode_mask: libc.mode_t = 0o777;

fn copyString(value: ?macos.CFTypeRef, output: []u8) bool {
    const string = value orelse return false;
    if (output.len == 0 or macos.CFGetTypeID(string) != macos.CFStringGetTypeID()) return false;
    const length = macos.CFStringGetLength(string);
    var used: macos.CFIndex = 0;
    const converted = macos.CFStringGetBytes(string, .{ .location = 0, .length = length }, macos.string_encoding_utf8, 0, false, output.ptr, @intCast(output.len - 1), &used);
    if (converted != length or used <= 0) return false;
    const bytes = output[0..@intCast(used)];
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return false;
    output[bytes.len] = 0;
    return true;
}

/// Returns 1 when copied, 0 when the attribute is unsupported or has no value, and -1 on failure.
fn attribute(element: macos.AXUIElementRef, name: [*:0]const u8, output: []u8) i32 {
    var value: ?macos.CFTypeRef = null;
    const result = macos.AXUIElementCopyAttributeValue(element, macos.__CFStringMakeConstantString(name), &value);
    if (result == macos.ax_attribute_unsupported or result == macos.ax_no_value) return 0;
    if (result != macos.ax_success) return -1;
    const copied = value orelse return -1;
    defer macos.CFRelease(copied);
    return if (copyString(copied, output)) 1 else -1;
}

export fn huen_session_identify(element: ?macos.AXUIElementRef, pid: i32, output: *NativeAttributes) bool {
    const window = element orelse return false;
    if (pid <= 0) return false;
    output.* = std.mem.zeroes(NativeAttributes);
    var actual_pid: i32 = 0;
    if (macos.AXUIElementGetPid(window, &actual_pid) != macos.ax_success or actual_pid != pid) return false;
    const pool = macos.objc_autoreleasePoolPush();
    defer macos.objc_autoreleasePoolPop(pool);
    const application_class = macos.objc_getClass("NSRunningApplication") orelse return false;
    const application = macos.message(fn (macos.Object, macos.Selector, i32) callconv(.c) ?macos.Object)(application_class, macos.selector("runningApplicationWithProcessIdentifier:"), pid) orelse return false;
    const launch_date = macos.send(application, "launchDate") orelse return false;
    const bundle = macos.send(application, "bundleIdentifier") orelse return false;
    output.pid = pid;
    output.launch = macos.message(fn (macos.Object, macos.Selector) callconv(.c) f64)(launch_date, macos.selector("timeIntervalSince1970"));
    if (!std.math.isFinite(output.launch) or output.launch <= 0 or
        !copyString(bundle, &output.bundle) or
        attribute(window, "AXRole", &output.role) != 1 or
        attribute(window, "AXSubrole", &output.subrole) < 0) return false;
    const identifier = attribute(window, "AXIdentifier", &output.value);
    if (identifier < 0) return false;
    output.kind = if (identifier != 0) 1 else 2;
    if (identifier != 0) return true;
    if (attribute(window, "AXDocument", &output.value) != 1) return false;
    const string_class = macos.objc_getClass("NSString") orelse return false;
    const url_class = macos.objc_getClass("NSURL") orelse return false;
    const text = macos.message(fn (macos.Object, macos.Selector, [*:0]const u8) callconv(.c) ?macos.Object)(string_class, macos.selector("stringWithUTF8String:"), @ptrCast(&output.value)) orelse return false;
    const document = macos.message(fn (macos.Object, macos.Selector, macos.Object) callconv(.c) ?macos.Object)(url_class, macos.selector("URLWithString:"), text) orelse return false;
    const scheme = macos.send(document, "scheme") orelse return false;
    return macos.count(scheme, "length") > 0;
}

export fn huen_session_display_uuid(display: u32, output: [*]u8, capacity: usize) bool {
    const uuid = macos.CGDisplayCreateUUIDFromDisplayID(display) orelse return false;
    defer macos.CFRelease(uuid);
    const string = macos.CFUUIDCreateString(null, uuid);
    defer if (string) |created| macos.CFRelease(created);
    return copyString(string, output[0..capacity]);
}

export fn huen_session_boot_identity(output: [*]u8, capacity: usize) bool {
    var boot = std.mem.zeroes(libc.timeval);
    var length: usize = @sizeOf(libc.timeval);
    if (libc.sysctlbyname("kern.boottime", &boot, &length, null, 0) != 0 or length != @sizeOf(libc.timeval)) return false;
    _ = std.fmt.bufPrintSentinel(output[0..capacity], "{d}.{d:0>6}", .{ boot.sec, boot.usec }, 0) catch return false;
    return true;
}

fn privateFile(descriptor: libc.fd_t, kind: libc.mode_t, permissions: libc.mode_t) bool {
    var status: libc.Stat = undefined;
    return libc.fstat(descriptor, &status) == 0 and status.mode & libc.S.IFMT == kind and
        status.uid == libc.geteuid() and status.mode & mode_mask == permissions;
}

extern "c" fn arc4random() u32;

fn failedWith(code: libc.E) bool {
    return libc._errno().* == @backingInt(code);
}

extern "c" fn NSHomeDirectory() ?macos.Object;

fn sessionDirectory() libc.fd_t {
    const pool = macos.objc_autoreleasePoolPush();
    defer macos.objc_autoreleasePoolPop(pool);
    const home = NSHomeDirectory() orelse return -1;
    if (macos.count(home, "length") == 0) return -1;
    const home_path = macos.message(fn (macos.Object, macos.Selector) callconv(.c) [*:0]const u8)(home, macos.selector("fileSystemRepresentation"));
    const components = [_][*:0]const u8{ home_path, "Library", "Application Support", "HuenWM" };
    var descriptor: libc.fd_t = libc.AT.FDCWD;
    for (components, 0..) |component, index| {
        const final = index == components.len - 1;
        if (final and libc.mkdirat(descriptor, component, 0o700) != 0 and !failedWith(.EXIST)) {
            _ = libc.close(descriptor);
            return -1;
        }
        const next = libc.openat(descriptor, component, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (descriptor != libc.AT.FDCWD) _ = libc.close(descriptor);
        if (next < 0) return -1;
        var status: libc.Stat = undefined;
        if (libc.fstat(next, &status) != 0 or status.uid != libc.geteuid() or
            status.mode & 0o022 != 0 or (final and (status.mode & libc.S.IFMT != libc.S.IFDIR or status.mode & mode_mask != 0o700)))
        {
            _ = libc.close(next);
            return -1;
        }
        descriptor = next;
    }
    return descriptor;
}

/// Stem is 1 to 16 lowercase letters.
fn fileName(buffer: *[96]u8, stem: [*:0]const u8, hash: [*:0]const u8) ?[:0]u8 {
    var length: usize = 0;
    while (length < 17 and stem[length] != 0) : (length += 1) {}
    if (length == 0 or length > 16) return null;
    for (stem[0..length]) |character| if (character < 'a' or character > 'z') return null;
    return std.fmt.bufPrintSentinel(buffer, "{s}-{s}.json", .{ stem[0..length], std.mem.span(hash) }, 0) catch null;
}

fn writeAll(descriptor: libc.fd_t, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = libc.write(descriptor, bytes.ptr + offset, bytes.len - offset);
        if (written < 0 and failedWith(.INTR)) continue;
        if (written <= 0) return false;
        offset += @intCast(written);
    }
    return true;
}

/// Hash is exactly 64 lowercase hexadecimal characters. Returns 0 when loaded, 1 when missing, and -1 on failure.
export fn huen_session_read(stem: [*:0]const u8, hash: [*:0]const u8, output: [*]u8, capacity: usize, used: *usize) c_int {
    used.* = 0;
    var name_buffer: [96]u8 = undefined;
    const name = fileName(&name_buffer, stem, hash) orelse return -1;
    const directory = sessionDirectory();
    if (directory < 0) return -1;
    defer _ = libc.close(directory);
    const descriptor = libc.openat(directory, name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
    if (descriptor < 0) return if (failedWith(.NOENT)) 1 else -1;
    defer _ = libc.close(descriptor);
    var status: libc.Stat = undefined;
    if (libc.fstat(descriptor, &status) != 0 or status.mode & libc.S.IFMT != libc.S.IFREG or status.uid != libc.geteuid() or
        status.mode & mode_mask != 0o600 or status.size <= 0 or @as(u64, @intCast(status.size)) > capacity) return -1;
    var offset: usize = 0;
    while (offset < capacity) {
        const count = libc.read(descriptor, output + offset, capacity - offset);
        if (count < 0 and failedWith(.INTR)) continue;
        if (count < 0) return -1;
        if (count == 0) break;
        offset += @intCast(count);
    }
    var extra: [1]u8 = undefined;
    var trailing = libc.read(descriptor, &extra, 1);
    while (trailing < 0 and failedWith(.INTR)) trailing = libc.read(descriptor, &extra, 1);
    if (trailing != 0 or offset == 0) return -1;
    used.* = offset;
    return 0;
}

/// A write that is not durable skips the fsyncs and survives the death of this process, not of the machine.
export fn huen_session_write(stem: [*:0]const u8, hash: [*:0]const u8, bytes: [*]const u8, length: usize, durable: bool) bool {
    var name_buffer: [96]u8 = undefined;
    const name = fileName(&name_buffer, stem, hash) orelse return false;
    var temporary_buffer: [128]u8 = undefined;
    const temporary = std.fmt.bufPrintSentinel(&temporary_buffer, ".{s}-{s}-{x:0>8}.tmp", .{ std.mem.span(stem), std.mem.span(hash), arc4random() }, 0) catch return false;
    const directory = sessionDirectory();
    if (directory < 0) return false;
    defer _ = libc.close(directory);
    var existing: libc.Stat = undefined;
    if (libc.fstatat(directory, name, &existing, libc.AT.SYMLINK_NOFOLLOW) == 0) {
        if (existing.mode & libc.S.IFMT != libc.S.IFREG or existing.uid != libc.geteuid() or existing.mode & mode_mask != 0o600) return false;
    } else if (!failedWith(.NOENT)) return false;
    const descriptor = libc.openat(directory, temporary, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(libc.mode_t, 0o600));
    if (descriptor < 0) return false;
    var success = privateFile(descriptor, libc.S.IFREG, 0o600) and writeAll(descriptor, bytes[0..length]);
    if (success and durable) success = libc.fsync(descriptor) == 0;
    if (libc.close(descriptor) != 0) success = false;
    if (success) success = libc.renameat(directory, temporary, directory, name) == 0;
    if (success and durable) success = libc.fsync(directory) == 0;
    if (!success) _ = libc.unlinkat(directory, temporary, 0);
    return success;
}

/// Appends to journal.jsonl beside the session files, renaming it to journal.1.jsonl first past 1 MiB.
export fn huen_journal_append(line: [*]const u8, length: usize) bool {
    const directory = sessionDirectory();
    if (directory < 0) return false;
    defer _ = libc.close(directory);
    var existing: libc.Stat = undefined;
    if (libc.fstatat(directory, "journal.jsonl", &existing, libc.AT.SYMLINK_NOFOLLOW) == 0) {
        if (existing.mode & libc.S.IFMT != libc.S.IFREG or existing.uid != libc.geteuid() or existing.mode & mode_mask != 0o600 or
            (@as(u64, @intCast(existing.size)) + length > 1024 * 1024 and libc.renameat(directory, "journal.jsonl", directory, "journal.1.jsonl") != 0)) return false;
    } else if (!failedWith(.NOENT)) return false;
    const descriptor = libc.openat(directory, "journal.jsonl", .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(libc.mode_t, 0o600));
    if (descriptor < 0) return false;
    var success = privateFile(descriptor, libc.S.IFREG, 0o600) and writeAll(descriptor, line[0..length]);
    if (libc.close(descriptor) != 0) success = false;
    return success;
}
