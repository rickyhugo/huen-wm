#import "observe.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

static CFMachPortRef tap;
static CFRunLoopSourceRef source;
static bool gestures;

static CGEventRef observe_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (tap && CGPreflightListenEventAccess()) CGEventTapEnable(tap, true);
        return event;
    }
    if (type == (CGEventType)NSEventTypeGesture) {
        if (!gestures) return event;
        @autoreleasepool {
            NSSet<NSTouch *> *touches = [[NSEvent eventWithCGEvent:event] touchesMatchingPhase:NSTouchPhaseTouching inView:nil];
            double horizontal = 0, vertical = 0;
            for (NSTouch *touch in touches) {
                horizontal += touch.normalizedPosition.x;
                vertical += touch.normalizedPosition.y;
            }
            NSUInteger count = touches.count;
            wm_swipe((uint32_t)count, count ? horizontal / count : 0, count ? vertical / count : 0);
        }
        return event;
    }
    if (type != kCGEventKeyDown || CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return event;
    CGEventFlags flags = CGEventGetFlags(event);
    uint32_t modifiers = 0;
    if (flags & kCGEventFlagMaskCommand) modifiers |= cmdKey;
    if (flags & kCGEventFlagMaskShift) modifiers |= shiftKey;
    if (flags & kCGEventFlagMaskAlternate) modifiers |= optionKey;
    if (flags & kCGEventFlagMaskControl) modifiers |= controlKey;
    platform_hotkey_pressed((uint32_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode), modifiers);
    return event;
}

bool huen_observe_start(void) {
    if (tap || !CGPreflightListenEventAccess()) return huen_observe_active();
    tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, CGEventMaskBit(kCGEventKeyDown) | (gestures ? CGEventMaskBit(NSEventTypeGesture) : 0), observe_callback, NULL);
    source = tap ? CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) : NULL;
    if (!source) {
        if (tap) CFRelease(tap);
        tap = NULL;
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    return true;
}

bool huen_observe_active(void) {
    return tap && CFMachPortIsValid(tap) && CGEventTapIsEnabled(tap);
}

void huen_observe_stop(void) {
    if (!tap) return;
    CGEventTapEnable(tap, false);
    CFMachPortInvalidate(tap);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFRelease(tap);
    tap = NULL;
    source = NULL;
}

void huen_observe_gestures(bool enabled) {
    if (gestures == enabled) return;
    gestures = enabled;
    huen_observe_stop();
    huen_observe_start();
}
