//! One listen-only session tap. It needs Input Monitoring, never prompts for it, and never delays an event.
//! Built as its own object for the manager executable; `native/observe.h` declares its exports for Objective-C callers.

const macos = @import("macos.zig");

/// Provided by the platform: key is a virtual key code and modifiers a Carbon modifier mask.
extern "c" fn platform_hotkey_pressed(key: u32, modifiers: u32) void;
/// Fingers is the count of touching fingers, 0 after the last lifts. Positions are their mean normalized position.
extern "c" fn wm_swipe(fingers: u32, horizontal: f64, vertical: f64) void;

/// NSTouchPhaseBegan, NSTouchPhaseMoved, and NSTouchPhaseStationary.
const touch_phase_touching: usize = 7;

var tap: ?macos.CFMachPortRef = null;
var source: ?macos.CFRunLoopSourceRef = null;
var gestures = false;

fn reportTouches(event: macos.CGEventRef) void {
    const pool = macos.objc_autoreleasePoolPush();
    defer macos.objc_autoreleasePoolPop(pool);
    const event_class = macos.objc_getClass("NSEvent") orelse return;
    const wrapped = macos.message(fn (macos.Object, macos.Selector, macos.CGEventRef) callconv(.c) ?macos.Object)(event_class, macos.selector("eventWithCGEvent:"), event) orelse return;
    const touches = macos.message(fn (macos.Object, macos.Selector, usize, ?macos.Object) callconv(.c) ?macos.Object)(wrapped, macos.selector("touchesMatchingPhase:inView:"), touch_phase_touching, null) orelse return;
    const ordered = macos.send(touches, "allObjects") orelse return;
    const touch_count = macos.count(ordered, "count");
    var horizontal: f64 = 0;
    var vertical: f64 = 0;
    for (0..touch_count) |index| {
        const touch = macos.message(fn (macos.Object, macos.Selector, usize) callconv(.c) macos.Object)(ordered, macos.selector("objectAtIndex:"), index);
        const position = macos.message(fn (macos.Object, macos.Selector) callconv(.c) macos.CGPoint)(touch, macos.selector("normalizedPosition"));
        horizontal += position.horizontal;
        vertical += position.vertical;
    }
    const divisor: f64 = @floatFromInt(touch_count);
    wm_swipe(@intCast(touch_count), if (touch_count != 0) horizontal / divisor else 0, if (touch_count != 0) vertical / divisor else 0);
}

fn observeCallback(proxy: macos.CGEventTapProxy, event_type: u32, event: macos.CGEventRef, context: ?*anyopaque) callconv(.c) ?macos.CGEventRef {
    _ = proxy;
    _ = context;
    if (event_type == macos.EventType.tap_disabled_by_timeout or event_type == macos.EventType.tap_disabled_by_user_input) {
        if (tap) |port| if (macos.CGPreflightListenEventAccess()) macos.CGEventTapEnable(port, true);
        return event;
    }
    if (event_type == macos.EventType.gesture) {
        if (gestures) reportTouches(event);
        return event;
    }
    if (event_type != macos.EventType.key_down or macos.CGEventGetIntegerValueField(event, macos.field_keyboard_autorepeat) != 0) return event;
    const key: u32 = @truncate(@as(u64, @bitCast(macos.CGEventGetIntegerValueField(event, macos.field_keyboard_keycode))));
    platform_hotkey_pressed(key, macos.carbonModifiers(macos.CGEventGetFlags(event)));
    return event;
}

export fn huen_observe_start() bool {
    if (tap != null or !macos.CGPreflightListenEventAccess()) return huen_observe_active();
    var mask = macos.eventMaskBit(macos.EventType.key_down);
    if (gestures) mask |= macos.eventMaskBit(macos.EventType.gesture);
    const port = macos.CGEventTapCreate(macos.session_event_tap, macos.head_insert_event_tap, macos.tap_option_listen_only, mask, observeCallback, null) orelse return false;
    const loop_source = macos.CFMachPortCreateRunLoopSource(null, port, 0) orelse {
        macos.CFRelease(port);
        return false;
    };
    tap = port;
    source = loop_source;
    macos.CFRunLoopAddSource(macos.CFRunLoopGetMain(), loop_source, macos.kCFRunLoopCommonModes);
    macos.CGEventTapEnable(port, true);
    return true;
}

export fn huen_observe_active() bool {
    const port = tap orelse return false;
    return macos.CFMachPortIsValid(port) and macos.CGEventTapIsEnabled(port);
}

export fn huen_observe_stop() void {
    const port = tap orelse return;
    macos.CGEventTapEnable(port, false);
    macos.CFMachPortInvalidate(port);
    macos.CFRunLoopRemoveSource(macos.CFRunLoopGetMain(), source.?, macos.kCFRunLoopCommonModes);
    macos.CFRelease(source.?);
    macos.CFRelease(port);
    tap = null;
    source = null;
}

/// Trackpad gesture events wake the main thread for every touch frame, so the tap listens for them only when enabled.
export fn huen_observe_gestures(enabled: bool) void {
    if (gestures == enabled) return;
    gestures = enabled;
    huen_observe_stop();
    _ = huen_observe_start();
}
