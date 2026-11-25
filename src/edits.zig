const std = @import("std");
const native = @import("native.zig");
const commands = @import("command.zig");
const reply = @import("reply.zig");
const world = @import("world.zig");

pub const CloseState = enum { idle, pending, closed, termination_requested, termination_rejected, expired, cancelled };
const PendingClose = struct { identity: u64, pid: c_int, process_token: f64, deadline: f64 };
var pending_close: ?PendingClose = null;
var close_state: CloseState = .idle;

pub fn pollClose() void {
    const pending = pending_close orelse return;
    const observed = if (native.platform_monotonic() < pending.deadline) native.platform_close_state(pending.identity, pending.pid, pending.process_token) else -1;
    close_state = if (native.platform_monotonic() >= pending.deadline) .expired else if (observed == 2) (if (native.platform_terminate_if_empty(pending.identity, pending.pid, pending.process_token)) .termination_requested else .termination_rejected) else if (observed == 1) .closed else return;
    pending_close = null;
    native.platform_close_cancel();
}

// `cancelled` reports a pending close as cancelled, as `restore` does.
pub fn cancelClose(cancelled: bool) void {
    if (cancelled and pending_close != null) close_state = .cancelled;
    pending_close = null;
    native.platform_close_cancel();
}

pub fn closeState() CloseState {
    return close_state;
}

pub fn close(source: *const world.Window, quit_if_last: bool) reply.Reply {
    if (pending_close != null) return reply.failure("ClosePending");
    var process_token: f64 = 0;
    if (!native.platform_close(source.identity, quit_if_last, &process_token)) return reply.failure("CloseRejected");
    if (quit_if_last) {
        pending_close = .{ .identity = source.identity, .pid = source.observation.pid, .process_token = process_token, .deadline = native.platform_monotonic() + 5 };
        close_state = .pending;
    }
    return reply.json(.{ .ok = true, .accepted = true });
}

pub fn launch(request: commands.Launch) reply.Reply {
    if (world.isSuspended()) return reply.failure("RuntimeSuspendedRestartToResume");
    const request_id = native.platform_launch(request.bundle.text(), request.new_instance, request.hidden);
    if (request_id == 0) return reply.failure("ApplicationNotFound");
    return reply.json(.{ .ok = true, .accepted = true, .request_id = request_id });
}

pub fn exec(shell: []const u8) reply.Reply {
    if (world.isSuspended()) return reply.failure("RuntimeSuspendedRestartToResume");
    var terminated: [512:0]u8 = @splat(0);
    @memcpy(terminated[0..shell.len], shell);
    if (!native.platform_exec(&terminated)) return reply.failure("ProcessLaunchFailed");
    return reply.json(.{ .ok = true, .accepted = true });
}
