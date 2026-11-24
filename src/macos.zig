//! Core Foundation, Core Graphics, Accessibility, and Objective-C runtime declarations for the native units written in Zig.
//! Constant values come from the macOS 14 SDK headers.

pub const CFTypeRef = *const anyopaque;
pub const CFStringRef = *const anyopaque;
pub const CFUUIDRef = *const anyopaque;
pub const CFMachPortRef = *anyopaque;
pub const CFRunLoopRef = *anyopaque;
pub const CFRunLoopSourceRef = *anyopaque;
pub const CFIndex = isize;
pub const CFRange = extern struct { location: CFIndex, length: CFIndex };
pub const string_encoding_utf8: u32 = 0x08000100;

pub extern "c" fn CFRelease(object: CFTypeRef) void;
pub extern "c" fn CFGetTypeID(object: CFTypeRef) usize;
pub extern "c" fn CFStringGetTypeID() usize;
pub extern "c" fn CFStringGetLength(string: CFStringRef) CFIndex;
pub extern "c" fn CFStringGetBytes(string: CFStringRef, range: CFRange, encoding: u32, loss_byte: u8, external_representation: bool, buffer: ?[*]u8, capacity: CFIndex, used: ?*CFIndex) CFIndex;
/// What CFSTR expands to. The returned string is never freed.
pub extern "c" fn __CFStringMakeConstantString(text: [*:0]const u8) CFStringRef;
pub extern "c" fn CFUUIDCreateString(allocator: ?*const anyopaque, uuid: CFUUIDRef) ?CFStringRef;
pub extern "c" fn CFRunLoopGetMain() CFRunLoopRef;
pub extern "c" fn CFRunLoopAddSource(loop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
pub extern "c" fn CFRunLoopRemoveSource(loop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
pub extern const kCFRunLoopCommonModes: CFStringRef;
pub extern "c" fn CFMachPortCreateRunLoopSource(allocator: ?*const anyopaque, port: CFMachPortRef, order: CFIndex) ?CFRunLoopSourceRef;
pub extern "c" fn CFMachPortIsValid(port: CFMachPortRef) bool;
pub extern "c" fn CFMachPortInvalidate(port: CFMachPortRef) void;

pub const CGEventRef = *anyopaque;
pub const CGEventTapProxy = ?*anyopaque;
pub const CGPoint = extern struct { horizontal: f64, vertical: f64 };
pub const EventType = struct {
    pub const left_mouse_down: u32 = 1;
    pub const left_mouse_up: u32 = 2;
    pub const right_mouse_down: u32 = 3;
    pub const right_mouse_up: u32 = 4;
    pub const left_mouse_dragged: u32 = 6;
    pub const right_mouse_dragged: u32 = 7;
    pub const key_down: u32 = 10;
    /// NSEventTypeGesture. A session tap delivers trackpad touch frames under this AppKit type.
    pub const gesture: u32 = 29;
    pub const tap_disabled_by_timeout: u32 = 0xFFFFFFFE;
    pub const tap_disabled_by_user_input: u32 = 0xFFFFFFFF;
};
pub const field_keyboard_autorepeat: u32 = 8;
pub const field_keyboard_keycode: u32 = 9;
pub const session_event_tap: u32 = 1;
pub const head_insert_event_tap: u32 = 0;
pub const tap_option_default: u32 = 0;
pub const tap_option_listen_only: u32 = 1;
pub const combined_session_state: i32 = 0;
pub const mouse_button_left: u32 = 0;
pub const mouse_button_right: u32 = 1;
pub const virtual_key_escape: i64 = 0x35;
pub const TapCallback = *const fn (CGEventTapProxy, u32, CGEventRef, ?*anyopaque) callconv(.c) ?CGEventRef;

pub fn eventMaskBit(event_type: u32) u64 {
    return @as(u64, 1) << @intCast(event_type);
}

pub extern "c" fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: u64, callback: TapCallback, context: ?*anyopaque) ?CFMachPortRef;
pub extern "c" fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;
pub extern "c" fn CGEventTapIsEnabled(tap: CFMachPortRef) bool;
pub extern "c" fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) i64;
pub extern "c" fn CGEventGetFlags(event: CGEventRef) u64;
pub extern "c" fn CGEventGetLocation(event: CGEventRef) CGPoint;
pub extern "c" fn CGEventSourceButtonState(state: i32, button: u32) bool;
pub extern "c" fn CGPreflightListenEventAccess() bool;
pub extern "c" fn CGDisplayCreateUUIDFromDisplayID(display: u32) ?CFUUIDRef;

pub const AXUIElementRef = *const anyopaque;
pub const ax_success: i32 = 0;
pub const ax_attribute_unsupported: i32 = -25205;
pub const ax_no_value: i32 = -25212;
pub extern "c" fn AXIsProcessTrusted() bool;
pub extern "c" fn AXUIElementGetPid(element: AXUIElementRef, pid: *i32) i32;
pub extern "c" fn AXUIElementCopyAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: *?CFTypeRef) i32;

/// Converts Core Graphics modifier flags to the Carbon mask that hotkey bindings and the pointer modifier use.
pub fn carbonModifiers(flags: u64) u32 {
    var modifiers: u32 = 0;
    if (flags & 0x100000 != 0) modifiers |= carbon_command;
    if (flags & 0x20000 != 0) modifiers |= carbon_shift;
    if (flags & 0x80000 != 0) modifiers |= carbon_option;
    if (flags & 0x40000 != 0) modifiers |= carbon_control;
    return modifiers;
}
pub const carbon_command: u32 = 0x100;
pub const carbon_shift: u32 = 0x200;
pub const carbon_option: u32 = 0x800;
pub const carbon_control: u32 = 0x1000;

pub extern "c" fn pthread_main_np() c_int;

pub const Object = *anyopaque;
pub const Selector = *anyopaque;
pub extern "c" fn objc_getClass(name: [*:0]const u8) ?Object;
pub extern "c" fn sel_registerName(name: [*:0]const u8) Selector;
pub extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
pub extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "c" fn objc_msgSend() void;

/// Casts objc_msgSend to one method signature. Every return type used here comes back in registers on arm64 and x86_64.
pub fn message(comptime Signature: type) *const Signature {
    return @ptrCast(&objc_msgSend);
}

pub fn selector(name: [*:0]const u8) Selector {
    return sel_registerName(name);
}

pub fn send(receiver: ?Object, name: [*:0]const u8) ?Object {
    const receiver_object = receiver orelse return null;
    return message(fn (Object, Selector) callconv(.c) ?Object)(receiver_object, selector(name));
}

pub fn count(receiver: Object, name: [*:0]const u8) usize {
    return message(fn (Object, Selector) callconv(.c) usize)(receiver, selector(name));
}
