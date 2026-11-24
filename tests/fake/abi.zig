// Mirrors of the C structs in native/platform.h, native/session.h and native/interaction.h.
// The linker matches symbols by name only, so the layout case checks these against clang.
pub const Rect = extern struct { left: f64, top: f64, width: f64, height: f64 };
pub const Point = extern struct { left: f64, top: f64 };
pub const FrameIntent = enum(c_uint) { visible_goal = 0, verified_placement = 1 };
pub const Motion = enum(c_uint) { idle, animating, rejected };
pub const Window = extern struct {
    identity: u64,
    pid: c_int,
    frame: Rect,
    motion: Motion,
    minimized: bool,
    fullscreen: bool,
    focused: bool,
    stale: bool,
    onscreen: bool,
    title_complete: bool,
    hit_eligible: bool,
    public_window_id: u32,
    bundle: [256]u8,
    title: [512]u8,
    process_token: f64,
    stack_order: u32,
};
pub const Display = extern struct { identity: u32, frame: Rect, full_bounds: Rect, name: [128]u8, built_in: bool };
pub const Binding = extern struct { key: u32, modifiers: u32, command: [128]u8 };
pub const LaunchStatus = extern struct { request_id: u64, state: c_int, message: [256]u8 };
pub const SessionAttributes = extern struct { pid: i32, kind: u32, launch: f64, bundle: [256]u8, value: [2048]u8, role: [128]u8, subrole: [128]u8 };
pub const InputAvailability = enum(c_uint) { disabled, available, permission_denied, tap_unavailable, stopping };
pub const NodeRef = extern struct { slot: u32, generation: u64 };
pub const HitKind = enum(c_uint) { tile = 1, boundary = 2, header = 3, floating = 4, _ };
pub const HitRegion = extern struct { kind: HitKind, rect: Rect, node: NodeRef, group: NodeRef, boundary: NodeRef, window_identity: u64, window_id: u32 };
pub const InputSnapshot = extern struct { generation: u64, hits: ?[*]const HitRegion, hit_count: usize, ready: bool, transitioning: bool };
pub const SceneReady = *const fn (?*anyopaque, bool) callconv(.c) void;
pub const ConfigCancelled = ?*const fn (?*anyopaque) callconv(.c) bool;
