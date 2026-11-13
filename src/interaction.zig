pub const max_hits = 4096;
pub const max_header_items = 2046;
pub const max_header_panels = 1024;
pub const title_bytes = 256;

pub const Rect = extern struct { left: f64, top: f64, width: f64, height: f64 };
pub const Point = extern struct { left: f64, top: f64 };
pub const NodeRef = extern struct { slot: u32, generation: u64 };
pub const HitKind = enum(c_uint) { tile = 1, boundary = 2, header = 3 };
pub const HitRegion = extern struct {
    kind: HitKind,
    rect: Rect,
    node: NodeRef,
    group: NodeRef,
    boundary: NodeRef,
    window_identity: u64,
    window_id: u32,
};
pub const Snapshot = extern struct {
    generation: u64,
    hits: ?[*]const HitRegion,
    hit_count: usize,
    ready: bool,
    transitioning: bool,
};
pub const Availability = enum(c_uint) {
    disabled,
    available,
    permission_denied,
    tap_unavailable,
    stopping,
};
pub const EventKind = enum(c_uint) { start = 1, update, end, cancel, group_select };
pub const Gesture = enum(c_uint) { none, reorder, resize };
pub const CancelReason = enum(c_uint) {
    none,
    publication,
    modifiers,
    escape,
    tap_disabled,
    permission,
    configuration,
    shutdown,
};
pub const Event = extern struct {
    kind: EventKind,
    gesture: Gesture,
    reason: CancelReason,
    generation: u64,
    gesture_id: u64,
    monotonic_ns: u64,
    target: HitRegion,
    origin: Point,
    point: Point,
    crossed_threshold: bool,
};
pub const HeaderItem = extern struct {
    generation: u64,
    group: NodeRef,
    child: NodeRef,
    window_identity: u64,
    window_id: u32,
    rect: Rect,
    title: [title_bytes]u8,
    selected: bool,
    eligible: bool,
};
pub const HeaderPresentation = extern struct {
    generation: u64,
    items: ?[*]const HeaderItem,
    item_count: usize,
    border_color: u32,
    border_width: f64,
};
pub const PreviewKind = enum(c_uint) { insertion = 1, resize };
pub const Preview = extern struct {
    generation: u64,
    kind: PreviewKind,
    rect: Rect,
    border_color: u32,
    border_width: f64,
};

pub extern "c" fn huen_input_configure(enabled: bool, carbon_modifiers: u32) Availability;
pub extern "c" fn huen_input_status() Availability;
pub extern "c" fn huen_input_publish(snapshot: *const Snapshot) bool;
pub extern "c" fn huen_input_poll(event: *Event) bool;
pub extern "c" fn huen_input_stop() void;
pub extern "c" fn huen_input_stop_ready() bool;
pub extern "c" fn huen_input_finish_stop(force: bool) bool;
pub extern "c" fn huen_groups_publish(presentation: *const HeaderPresentation) bool;
pub extern "c" fn huen_groups_preview(preview: ?*const Preview) void;
pub extern "c" fn huen_groups_clear() void;
