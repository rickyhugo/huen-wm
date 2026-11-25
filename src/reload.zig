const std = @import("std");
const native = @import("native.zig");
const configuration = @import("config.zig");
const reply = @import("reply.zig");
const world = @import("world.zig");

pub const State = enum { idle, pending, ready, failed };
pub const Status = struct { request_id: u64, state: State, err_message: ?[]const u8 };
var request: configuration.Request = .{};
var generation: u64 = 0;
var state: State = .idle;
var last_error: ?[]const u8 = null;

pub fn evaluate(path: [*:0]const u8) ?world.Config {
    return configuration.evaluate(path, null, null) catch |err| {
        native.platform_error(@errorName(err));
        return null;
    };
}

pub fn markReady() void {
    state = .ready;
}

pub fn start() reply.Reply {
    if (world.isSuspended()) return reply.failure("RuntimeSuspendedRestartToResume");
    const request_id = generation + 1;
    request.start(native.platform_config_path(), request_id) catch |err| return reply.failure(@errorName(err));
    generation = request_id;
    state = .pending;
    last_error = null;
    return reply.json(.{ .ok = true, .accepted = true, .request_id = request_id });
}

pub fn waiting() bool {
    return state == .pending;
}

// The finished load of the current request, or null when none finished, a newer request superseded it, or it failed.
pub fn take() ?world.Config {
    const completion = request.take() orelse return null;
    if (completion.generation != generation or state != .pending) return null;
    const candidate = switch (completion.result) {
        .ready => |candidate| candidate,
        .failed => |err| {
            reject(@errorName(err));
            return null;
        },
    };
    if (world.isSuspended()) {
        reject("RuntimeSuspendedRestartToResume");
        return null;
    }
    return candidate;
}

pub fn reject(message: [:0]const u8) void {
    state = .failed;
    last_error = message;
    native.platform_error(message.ptr);
}

pub fn settle() void {
    state = .ready;
    last_error = null;
}

pub fn cancel() void {
    if (state != .pending) return;
    request.cancel();
    state = .failed;
    last_error = "ConfigLoadCancelled";
}

pub fn inFlight() bool {
    return request.inFlight();
}

pub fn status() Status {
    return .{ .request_id = generation, .state = state, .err_message = last_error };
}
