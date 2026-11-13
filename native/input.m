#define HUEN_INTERACTION_INTERNAL
#import "interaction.h"

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { HuenQueueCapacity = 64, HuenQueueAdmissionLimit = 60 };
typedef enum { HuenDragIdle, HuenDragActive, HuenDragDraining } HuenDragPhase;

static struct {
    bool enabled;
    bool stopping;
    bool ready;
    bool transitioning;
    uint32_t modifiers;
    uint64_t generation;
    uint64_t next_gesture;
    HuenInputAvailability availability;
    CFMachPortRef tap;
    CFRunLoopSourceRef source;
    HuenHitRegion *hits;
    size_t hit_count;
    HuenInteractionEvent queue[HuenQueueCapacity];
    size_t queue_head;
    size_t queue_count;
    struct {
        HuenDragPhase phase;
        CGEventType drag_type;
        CGEventType up_type;
        HuenInteractionEvent sample;
    } drag;
} input;

static void require_main_thread(void) {
    NSCAssert(NSThread.isMainThread, @"Interaction calls require the main thread");
}

static uint64_t monotonic_ns(void) {
    struct timespec instant;
    clock_gettime(CLOCK_MONOTONIC_RAW, &instant);
    return (uint64_t)instant.tv_sec * UINT64_C(1000000000) + (uint64_t)instant.tv_nsec;
}

static bool permissions_allowed(void) {
    return CGPreflightListenEventAccess() && AXIsProcessTrusted();
}

static void enqueue(HuenInteractionEvent event) {
    NSCAssert(input.queue_count < HuenQueueCapacity, @"Reserved interaction queue exhausted");
    size_t tail = (input.queue_head + input.queue_count) % HuenQueueCapacity;
    input.queue[tail] = event;
    input.queue_count++;
}

static void cancel_drag(HuenCancelReason reason) {
    if (input.drag.phase != HuenDragActive) return;
    input.drag.sample.kind = HuenInteractionCancel;
    input.drag.sample.reason = reason;
    input.drag.sample.monotonic_ns = monotonic_ns();
    enqueue(input.drag.sample);
    input.drag.phase = HuenDragDraining;
}

static uint32_t carbon_modifiers(CGEventFlags flags) {
    uint32_t modifiers = 0;
    if (flags & kCGEventFlagMaskCommand) modifiers |= cmdKey;
    if (flags & kCGEventFlagMaskShift) modifiers |= shiftKey;
    if (flags & kCGEventFlagMaskAlternate) modifiers |= optionKey;
    if (flags & kCGEventFlagMaskControl) modifiers |= controlKey;
    return modifiers;
}

static bool valid_rect(HuenInteractionRect rect) {
    return isfinite(rect.left) && isfinite(rect.top) && isfinite(rect.width) &&
           isfinite(rect.height) && rect.width > 0 && rect.height > 0 &&
           isfinite(rect.left + rect.width) && isfinite(rect.top + rect.height);
}

static bool contains(HuenInteractionRect rect, CGPoint point) {
    return point.x >= rect.left && point.x < rect.left + rect.width &&
           point.y >= rect.top && point.y < rect.top + rect.height;
}

static bool same_ref(HuenNodeRef first, HuenNodeRef second) {
    return first.slot == second.slot && first.generation == second.generation;
}

static bool same_hit(HuenHitRegion first, HuenHitRegion second) {
    return first.kind == second.kind &&
        first.rect.left == second.rect.left && first.rect.top == second.rect.top &&
        first.rect.width == second.rect.width && first.rect.height == second.rect.height &&
        same_ref(first.node, second.node) && same_ref(first.group, second.group) &&
        same_ref(first.boundary, second.boundary) &&
        first.window_identity == second.window_identity && first.window_id == second.window_id;
}

static const HuenHitRegion *hit_for_down(CGEventType type, CGPoint point) {
    HuenHitKind desired = type == kCGEventRightMouseDown ? HuenHitBoundary : HuenHitTile;
    if (type == kCGEventLeftMouseDown) {
        for (size_t index = 0; index < input.hit_count; index++) {
            if (input.hits[index].kind == HuenHitHeader && contains(input.hits[index].rect, point)) return NULL;
        }
    }
    for (size_t index = input.hit_count; index > 0; index--) {
        const HuenHitRegion *hit = &input.hits[index - 1];
        if (hit->kind == desired && contains(hit->rect, point)) return hit;
    }
    return NULL;
}

static void update_sample(CGEventRef event) {
    CGPoint point = CGEventGetLocation(event);
    input.drag.sample.point = (HuenInteractionPoint){point.x, point.y};
    input.drag.sample.monotonic_ns = monotonic_ns();
    double horizontal = point.x - input.drag.sample.origin.left;
    double vertical = point.y - input.drag.sample.origin.top;
    if (hypot(horizontal, vertical) >= 4) input.drag.sample.crossed_threshold = true;
}

static void enqueue_motion(void) {
    input.drag.sample.kind = HuenInteractionUpdate;
    if (input.queue_count) {
        size_t tail = (input.queue_head + input.queue_count - 1) % HuenQueueCapacity;
        HuenInteractionEvent *previous = &input.queue[tail];
        if (previous->kind == HuenInteractionUpdate &&
            previous->gesture_id == input.drag.sample.gesture_id) {
            *previous = input.drag.sample;
            return;
        }
    }
    if (input.queue_count < HuenQueueCapacity - 1) enqueue(input.drag.sample);
}

static CGEventRef input_callback(CGEventTapProxy proxy, CGEventType type,
                                 CGEventRef event, void *context) {
    (void)proxy;
    (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        cancel_drag(HuenCancelTapDisabled);
        if ((input.enabled || input.drag.phase != HuenDragIdle) && permissions_allowed() && input.tap) {
            CGEventTapEnable(input.tap, true);
            input.availability = input.stopping ? HuenInputStopping : HuenInputAvailable;
        } else {
            input.availability = !input.enabled && input.drag.phase == HuenDragIdle ?
                (input.stopping ? HuenInputStopping : HuenInputDisabled) : HuenInputPermissionDenied;
        }
        return event;
    }
    if (input.drag.phase != HuenDragIdle) {
        if (type == input.drag.up_type) {
            if (input.drag.phase == HuenDragActive) {
                update_sample(event);
                if (carbon_modifiers(CGEventGetFlags(event)) != input.modifiers) {
                    cancel_drag(HuenCancelModifiers);
                } else {
                    input.drag.sample.kind = HuenInteractionEnd;
                    enqueue(input.drag.sample);
                }
            }
            input.drag.phase = HuenDragIdle;
            return NULL;
        }
        if (type == input.drag.drag_type) {
            if (input.drag.phase == HuenDragActive) {
                if (carbon_modifiers(CGEventGetFlags(event)) != input.modifiers) {
                    cancel_drag(HuenCancelModifiers);
                } else {
                    update_sample(event);
                    enqueue_motion();
                }
            }
            return NULL;
        }
        if (type == kCGEventFlagsChanged &&
            carbon_modifiers(CGEventGetFlags(event)) != input.modifiers) {
            cancel_drag(HuenCancelModifiers);
        }
        if (type == kCGEventKeyDown && CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == kVK_Escape &&
            input.drag.phase == HuenDragActive) {
            cancel_drag(HuenCancelEscape);
            return NULL;
        }
        return event;
    }
    if (type != kCGEventLeftMouseDown && type != kCGEventRightMouseDown) return event;
    if (!input.enabled || input.stopping || !input.ready || input.transitioning ||
        input.availability != HuenInputAvailable || input.queue_count > HuenQueueAdmissionLimit ||
        carbon_modifiers(CGEventGetFlags(event)) != input.modifiers) return event;
    CGPoint point = CGEventGetLocation(event);
    const HuenHitRegion *hit = hit_for_down(type, point);
    if (!hit) return event;
    input.drag.phase = HuenDragActive;
    input.drag.drag_type = type == kCGEventLeftMouseDown ? kCGEventLeftMouseDragged : kCGEventRightMouseDragged;
    input.drag.up_type = type == kCGEventLeftMouseDown ? kCGEventLeftMouseUp : kCGEventRightMouseUp;
    input.next_gesture++;
    if (input.next_gesture == 0) input.next_gesture++;
    input.drag.sample = (HuenInteractionEvent){
        .kind = HuenInteractionStart,
        .gesture = type == kCGEventLeftMouseDown ? HuenGestureReorder : HuenGestureResize,
        .generation = input.generation,
        .gesture_id = input.next_gesture,
        .monotonic_ns = monotonic_ns(),
        .target = *hit,
        .origin = {point.x, point.y},
        .point = {point.x, point.y},
    };
    enqueue(input.drag.sample);
    return NULL;
}

static bool install_tap(void) {
    if (input.tap && CFMachPortIsValid(input.tap)) return true;
    if (input.source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), input.source, kCFRunLoopCommonModes);
        CFRelease(input.source);
        input.source = NULL;
    }
    if (input.tap) {
        CFRelease(input.tap);
        input.tap = NULL;
    }
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown);
    input.tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, input_callback, NULL);
    if (!input.tap) return false;
    input.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, input.tap, 0);
    if (!input.source) {
        CFRelease(input.tap);
        input.tap = NULL;
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), input.source, kCFRunLoopCommonModes);
    CGEventTapEnable(input.tap, true);
    return true;
}

HuenInputAvailability huen_input_configure(bool enabled, uint32_t modifiers) {
    require_main_thread();
    if (input.stopping) return HuenInputStopping;
    const uint32_t allowed = cmdKey | shiftKey | optionKey | controlKey;
    if (modifiers == 0 || (modifiers & ~allowed)) enabled = false;
    if (input.enabled != enabled || input.modifiers != modifiers) cancel_drag(HuenCancelConfiguration);
    input.enabled = enabled;
    input.modifiers = modifiers;
    return huen_input_status();
}

HuenInputAvailability huen_input_status(void) {
    require_main_thread();
    if (input.tap && !CFMachPortIsValid(input.tap)) cancel_drag(HuenCancelTapDisabled);
    if (!input.enabled && input.drag.phase == HuenDragIdle) {
        if (input.tap) CGEventTapEnable(input.tap, false);
        input.availability = input.stopping ? HuenInputStopping : HuenInputDisabled;
    } else if (!permissions_allowed()) {
        cancel_drag(HuenCancelPermission);
        input.availability = HuenInputPermissionDenied;
    } else if (!install_tap()) {
        cancel_drag(HuenCancelTapDisabled);
        input.availability = HuenInputTapUnavailable;
    } else {
        if (!CGEventTapIsEnabled(input.tap)) {
            cancel_drag(HuenCancelTapDisabled);
            CGEventTapEnable(input.tap, true);
        }
        input.availability = input.stopping ? HuenInputStopping :
            (input.enabled ? HuenInputAvailable : HuenInputDisabled);
    }
    return input.availability;
}

bool huen_input_publish(const HuenInputSnapshot *snapshot) {
    require_main_thread();
    if (!snapshot || input.stopping || snapshot->generation == 0 ||
        snapshot->hit_count > HUEN_INPUT_MAX_HITS || (snapshot->hit_count && !snapshot->hits)) return false;
    for (size_t index = 0; index < snapshot->hit_count; index++) {
        const HuenHitRegion *hit = &snapshot->hits[index];
        if (!valid_rect(hit->rect) || hit->kind < HuenHitTile || hit->kind > HuenHitHeader ||
            (hit->kind == HuenHitTile &&
             (hit->window_identity == 0 || hit->window_id == 0 || hit->node.generation == 0)) ||
            (hit->kind == HuenHitBoundary && hit->boundary.generation == 0) ||
            (hit->kind == HuenHitHeader && (hit->node.generation == 0 || hit->group.generation == 0))) return false;
    }
    if (snapshot->generation < input.generation ||
        (snapshot->generation == input.generation &&
         snapshot->hit_count != input.hit_count)) return false;
    if (snapshot->generation == input.generation) {
        for (size_t index = 0; index < snapshot->hit_count; index++) {
            if (!same_hit(snapshot->hits[index], input.hits[index])) return false;
        }
    }
    HuenHitRegion *copied = NULL;
    if (snapshot->hit_count) {
        copied = malloc(snapshot->hit_count * sizeof(*copied));
        if (!copied) return false;
        memcpy(copied, snapshot->hits, snapshot->hit_count * sizeof(*copied));
    }
    if (snapshot->generation != input.generation || !snapshot->ready || snapshot->transitioning) {
        cancel_drag(HuenCancelPublication);
        huen_groups_preview(NULL);
    }
    free(input.hits);
    input.hits = copied;
    input.hit_count = snapshot->hit_count;
    input.generation = snapshot->generation;
    input.ready = snapshot->ready;
    input.transitioning = snapshot->transitioning;
    huen_groups_invalidate(input.ready && !input.transitioning ? input.generation : 0);
    return true;
}

bool huen_input_poll(HuenInteractionEvent *event) {
    require_main_thread();
    if (!event) return false;
    huen_input_status();
    if (!input.queue_count) return false;
    *event = input.queue[input.queue_head];
    input.queue_head = (input.queue_head + 1) % HuenQueueCapacity;
    input.queue_count--;
    if (event->kind == HuenInteractionEnd || event->kind == HuenInteractionCancel) huen_groups_preview(NULL);
    return true;
}

bool huen_input_generation_ready(uint64_t generation) {
    require_main_thread();
    return !input.stopping && input.ready && !input.transitioning &&
           generation != 0 && generation == input.generation;
}

bool huen_input_select_header(const HuenHeaderItem *item) {
    require_main_thread();
    if (!item || !huen_input_generation_ready(item->generation) ||
        input.drag.phase != HuenDragIdle || input.queue_count > HuenQueueAdmissionLimit) return false;
    HuenInteractionEvent event = {
        .kind = HuenInteractionGroupSelect,
        .generation = item->generation,
        .monotonic_ns = monotonic_ns(),
        .target = {
            .kind = HuenHitHeader,
            .rect = item->rect,
            .node = item->child,
            .group = item->group,
            .window_identity = item->window_identity,
            .window_id = item->window_id,
        },
    };
    enqueue(event);
    return true;
}

void huen_input_stop(void) {
    require_main_thread();
    input.stopping = true;
    input.ready = false;
    cancel_drag(HuenCancelShutdown);
    huen_groups_clear();
}

bool huen_input_stop_ready(void) {
    require_main_thread();
    return input.stopping && input.drag.phase == HuenDragIdle;
}

bool huen_input_finish_stop(bool force) {
    require_main_thread();
    if (!input.stopping || (!force && !huen_input_stop_ready())) return false;
    if (input.tap) {
        CGEventTapEnable(input.tap, false);
        CFMachPortInvalidate(input.tap);
    }
    if (input.source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), input.source, kCFRunLoopCommonModes);
        CFRelease(input.source);
    }
    if (input.tap) CFRelease(input.tap);
    free(input.hits);
    memset(&input, 0, sizeof(input));
    return true;
}
