#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include "platform.h"
#include "scene.h"

@interface WindowRecord : NSObject
@property AXUIElementRef element;
@property WMWindow observation;
@property WMRect original;
@property WMRect target;
@property WMRect animationStart;
@property double animationTime;
@property double animationDuration;
@property double placementVisibilityDeadline;
@property BOOL changed;
@property WMMotionState motion;
@end
@implementation WindowRecord
- (void)dealloc { if (_element) CFRelease(_element); }
@end

static NSMutableArray<WindowRecord *> *records;
static NSMutableDictionary<NSNumber *, NSValue *> *observers;
static NSMutableDictionary<NSNumber *, NSRunningApplication *> *applications;
static uint64_t nextIdentity = 1;
static BOOL dirty = YES;
static BOOL stopping;
static NSString *configPath;
static NSString *bundleFilter;
static NSPanel *borderPanel;
static int serverSocket = -1;
static NSString *socketPath;
static EventHotKeyRef hotkeyRefs[256];
static WMBinding currentBindings[256];
static volatile sig_atomic_t interrupted;
void platform_error(const char *message) { fprintf(stderr, "%s\n", message ?: "unknown error"); }
static void copyUTF8(char *destination, size_t capacity, NSString *source) {
    NSUInteger used = 0;
    [source getBytes:destination maxLength:capacity - 1 usedLength:&used encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, source.length) remainingRange:NULL];
    destination[used] = 0;
}

static void luaBudget(lua_State *state, lua_Debug *debug) { (void)debug; luaL_error(state, "configuration instruction budget exceeded"); }
static size_t luaMemory;
static void *luaAllocate(void *context, void *pointer, size_t oldSize, size_t newSize) {
    (void)context;
    if (!pointer) oldSize = 0;
    if (!newSize) { free(pointer); luaMemory -= oldSize; return NULL; }
    if (newSize > 16 * 1024 * 1024 || luaMemory - oldSize > 16 * 1024 * 1024 - newSize) return NULL;
    void *result = realloc(pointer, newSize);
    if (result) luaMemory = luaMemory - oldSize + newSize;
    return result;
}
lua_State *platform_lua_open(void) {
    luaMemory = 0;
    lua_State *state = lua_newstate(luaAllocate, NULL, 0);
    if (!state) return NULL;
    luaL_requiref(state, "_G", luaopen_base, 1); lua_pop(state, 1);
    luaL_requiref(state, "table", luaopen_table, 1); lua_pop(state, 1);
    luaL_requiref(state, "string", luaopen_string, 1); lua_pop(state, 1);
    luaL_requiref(state, "math", luaopen_math, 1); lua_pop(state, 1);
    for (const char **name = (const char *[]){"dofile", "loadfile", "load", "collectgarbage", NULL}; *name; name++) { lua_pushnil(state); lua_setglobal(state, *name); }
    lua_sethook(state, luaBudget, LUA_MASKCOUNT, 1000000);
    return state;
}

static id attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef result = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &result) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(result);
}

static BOOL readFrame(AXUIElementRef element, WMRect *frame) {
    id position = attribute(element, kAXPositionAttribute);
    id size = attribute(element, kAXSizeAttribute);
    CGPoint origin; CGSize extent;
    if (!position || !size || CFGetTypeID((__bridge CFTypeRef)position) != AXValueGetTypeID() || CFGetTypeID((__bridge CFTypeRef)size) != AXValueGetTypeID()) return NO;
    if (!AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &origin) || !AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &extent)) return NO;
    *frame = (WMRect){origin.x, origin.y, extent.width, extent.height};
    return YES;
}

static BOOL canMove(WindowRecord *record) {
    id minimized = attribute(record.element, kAXMinimizedAttribute);
    id fullscreen = attribute(record.element, CFSTR("AXFullScreen"));
    return minimized && fullscreen && ![minimized boolValue] && ![fullscreen boolValue];
}

static BOOL writeFrame(WindowRecord *record, WMRect frame) {
    if (!canMove(record)) return NO;
    WMRect current = {0};
    BOOL priorReadable = readFrame(record.element, &current);
    BOOL resizeNeeded = !priorReadable || current.width != frame.width || current.height != frame.height;
    CGPoint origin = CGPointMake(frame.left, frame.top);
    CGSize extent = CGSizeMake(frame.width, frame.height);
    AXValueRef position = AXValueCreate(kAXValueCGPointType, &origin);
    AXValueRef size = AXValueCreate(kAXValueCGSizeType, &extent);
    // Move before resizing to avoid clamping at the old origin, then restore the origin after resizing.
    AXError initialPositionResult = AXUIElementSetAttributeValue(record.element, kAXPositionAttribute, position);
    // Even an unchanged size can be clamped after moving down or offscreen.
    AXError sizeResult = resizeNeeded ? AXUIElementSetAttributeValue(record.element, kAXSizeAttribute, size) : kAXErrorSuccess;
    AXError positionResult = AXUIElementSetAttributeValue(record.element, kAXPositionAttribute, position);
    BOOL applied = initialPositionResult == kAXErrorSuccess && sizeResult == kAXErrorSuccess && positionResult == kAXErrorSuccess;
    if (applied) record.placementVisibilityDeadline = CACurrentMediaTime() + 0.25;
    CFRelease(position); CFRelease(size);
    return applied;
}

static BOOL framesNear(WMRect first, WMRect second, double tolerance) {
    return fabs(first.left - second.left) <= tolerance && fabs(first.top - second.top) <= tolerance && fabs(first.width - second.width) <= tolerance && fabs(first.height - second.height) <= tolerance;
}

static void observationCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context) {
    (void)observer; (void)element; (void)notification; (void)context;
    dirty = YES;
}

static BOOL scanWindowSnapshot(void) {
    BOOL unmatched = NO;
    NSArray *visibleWindows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableSet<NSNumber *> *livePids = [NSMutableSet set];
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        if (application.processIdentifier == getpid() || application.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (bundleFilter.length && ![application.bundleIdentifier isEqualToString:bundleFilter]) continue;
        NSNumber *process = @(application.processIdentifier);
        NSRunningApplication *previous = applications[process];
        if (previous && (previous.terminated || (previous.launchDate && application.launchDate && ![previous.launchDate isEqualToDate:application.launchDate]))) {
            AXObserverRef observer = [observers[process] pointerValue];
            if (observer) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes); CFRelease(observer); [observers removeObjectForKey:process]; }
            NSIndexSet *expired = [records indexesOfObjectsPassingTest:^BOOL(WindowRecord *record, NSUInteger index, BOOL *stop) { (void)index; (void)stop; return record.observation.pid == application.processIdentifier; }];
            [records removeObjectsAtIndexes:expired];
        }
        applications[process] = application;
        [livePids addObject:process];
        AXUIElementRef appElement = AXUIElementCreateApplication(application.processIdentifier);
        AXUIElementSetMessagingTimeout(appElement, 0.08);
        if (!observers[process]) {
            AXObserverRef observer;
            if (AXObserverCreate(application.processIdentifier, observationCallback, &observer) == kAXErrorSuccess) {
                for (NSString *name in @[(__bridge NSString *)kAXWindowCreatedNotification, (__bridge NSString *)kAXFocusedWindowChangedNotification, (__bridge NSString *)kAXApplicationHiddenNotification, (__bridge NSString *)kAXApplicationShownNotification]) AXObserverAddNotification(observer, appElement, (__bridge CFStringRef)name, NULL);
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
                observers[process] = [NSValue valueWithPointer:observer];
            }
        }
        CFTypeRef windowValues = NULL;
        AXError scanResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowValues);
        if (scanResult != kAXErrorSuccess || !windowValues || CFGetTypeID(windowValues) != CFArrayGetTypeID()) {
            if (windowValues) CFRelease(windowValues);
            for (WindowRecord *record in records) if (record.observation.pid == application.processIdentifier) { WMWindow observation = record.observation; observation.stale = true; record.observation = observation; }
            CFRelease(appElement); continue;
        }
        NSArray *windows = CFBridgingRelease(windowValues);
        NSMutableDictionary<NSValue *, NSValue *> *frames = [NSMutableDictionary dictionary];
        for (id object in windows) {
            AXUIElementRef element = (__bridge AXUIElementRef)object;
            AXUIElementSetMessagingTimeout(element, 0.08);
            WMRect frame;
            if (readFrame(element, &frame)) frames[[NSValue valueWithPointer:element]] = [NSValue valueWithBytes:&frame objCType:@encode(WMRect)];
        }
        id focused = attribute(appElement, kAXFocusedWindowAttribute);
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        for (id object in windows) {
            AXUIElementRef element = (__bridge AXUIElementRef)object;
            AXUIElementSetMessagingTimeout(element, 0.08);
            WindowRecord *record = nil;
            for (WindowRecord *candidate in records) if (candidate.observation.pid == application.processIdentifier && CFEqual(candidate.element, element)) { record = candidate; break; }
            NSString *subrole = attribute(element, kAXSubroleAttribute);
            if (!subrole && record) { [seen addObject:@(record.observation.identity)]; WMWindow observation = record.observation; observation.stale = true; record.observation = observation; continue; }
            if (![subrole isEqualToString:(__bridge NSString *)kAXStandardWindowSubrole]) continue;
            WMRect frame;
            NSValue *cachedFrame = frames[[NSValue valueWithPointer:element]];
            if (!cachedFrame) {
                if (record) { [seen addObject:@(record.observation.identity)]; WMWindow observation = record.observation; observation.stale = true; record.observation = observation; }
                continue;
            }
            [cachedFrame getValue:&frame];
            if (!record) {
                if (records.count >= 1024) continue;
                Boolean positionSettable = false, sizeSettable = false;
                AXUIElementIsAttributeSettable(element, kAXPositionAttribute, &positionSettable);
                AXUIElementIsAttributeSettable(element, kAXSizeAttribute, &sizeSettable);
                if (!positionSettable || !sizeSettable) continue;
                record = [WindowRecord new]; record.element = (AXUIElementRef)CFRetain(element); record.original = frame;
                WMWindow initial = {0}; initial.identity = nextIdentity++; initial.pid = application.processIdentifier; record.observation = initial;
                [records addObject:record];
                AXUIElementSetMessagingTimeout(element, 0.08);
                AXObserverRef observer = [observers[process] pointerValue];
                if (observer) for (NSString *name in @[(__bridge NSString *)kAXUIElementDestroyedNotification, (__bridge NSString *)kAXMovedNotification, (__bridge NSString *)kAXResizedNotification, (__bridge NSString *)kAXWindowMiniaturizedNotification, (__bridge NSString *)kAXWindowDeminiaturizedNotification]) AXObserverAddNotification(observer, element, (__bridge CFStringRef)name, NULL);
            }
            WMWindow observation = record.observation;
            observation.frame = frame; observation.stale = false;
            observation.onscreen = false;
            NSUInteger matchingAX = 0, matchingCG = 0;
            for (NSValue *candidate in frames.allValues) {
                WMRect candidateFrame; [candidate getValue:&candidateFrame];
                if (framesNear(frame, candidateFrame, 4)) matchingAX++;
            }
            for (NSDictionary *visibleWindow in visibleWindows) {
                if ([visibleWindow[(__bridge NSString *)kCGWindowOwnerPID] intValue] != application.processIdentifier || [visibleWindow[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
                CGRect bounds;
                if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)visibleWindow[(__bridge NSString *)kCGWindowBounds], &bounds) && framesNear(frame, (WMRect){bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height}, 4)) matchingCG++;
            }
            observation.onscreen = frames.count == windows.count && matchingAX == 1 && matchingCG == 1;
            observation.minimized = [attribute(element, kAXMinimizedAttribute) boolValue];
            observation.fullscreen = [attribute(element, CFSTR("AXFullScreen")) boolValue];
            if (!observation.minimized && !observation.fullscreen && frames.count == windows.count && matchingAX == 1 && matchingCG == 0 && CACurrentMediaTime() < record.placementVisibilityDeadline) unmatched = YES;
            observation.focused = application.active && focused && CFEqual((__bridge CFTypeRef)focused, element);
            copyUTF8(observation.bundle, sizeof(observation.bundle), application.bundleIdentifier);
            NSString *title = attribute(element, kAXTitleAttribute);
            copyUTF8(observation.title, sizeof(observation.title), [title isKindOfClass:NSString.class] ? title : @"");
            record.observation = observation;
            [seen addObject:@(observation.identity)];
        }
        NSIndexSet *removed = [records indexesOfObjectsPassingTest:^BOOL(WindowRecord *record, NSUInteger index, BOOL *stop) { (void)index; (void)stop; return record.observation.pid == application.processIdentifier && ![seen containsObject:@(record.observation.identity)]; }];
        [records removeObjectsAtIndexes:removed];
        CFRelease(appElement);
    }
    NSIndexSet *dead = [records indexesOfObjectsPassingTest:^BOOL(WindowRecord *record, NSUInteger index, BOOL *stop) { (void)index; (void)stop; return ![livePids containsObject:@(record.observation.pid)]; }];
    [records removeObjectsAtIndexes:dead];
    for (NSNumber *process in observers.allKeys) if (![livePids containsObject:process]) { AXObserverRef observer = [observers[process] pointerValue]; CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes); CFRelease(observer); [observers removeObjectForKey:process]; }
    for (NSNumber *process in applications.allKeys) if (![livePids containsObject:process]) [applications removeObjectForKey:process];
    return !unmatched;
}

static void scanWindows(void) {
    // AX can reflect our placement before WindowServer publishes the matching CG bounds.
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        if (attempt) usleep(10000);
        if (scanWindowSnapshot()) break;
    }
}

size_t platform_windows(WMWindow *output, size_t capacity) {
    size_t count = MIN(capacity, records.count);
    for (size_t index = 0; index < count; index++) {
        WindowRecord *record = records[index];
        output[index] = record.observation;
        output[index].motion = record.motion;
    }
    return count;
}

size_t platform_refresh_windows(WMWindow *output, size_t capacity) {
    scanWindows();
    return platform_windows(output, capacity);
}

size_t platform_displays(WMDisplay *output, size_t capacity) {
    double primaryHeight = CGDisplayBounds(CGMainDisplayID()).size.height;
    size_t count = 0;
    for (NSScreen *screen in NSScreen.screens) {
        if (count >= capacity) break;
        NSRect visible = screen.visibleFrame;
        WMDisplay display = {0}; display.identity = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        display.built_in = CGDisplayIsBuiltin(display.identity);
        display.frame = (WMRect){visible.origin.x, primaryHeight - NSMaxY(visible), visible.size.width, visible.size.height};
        NSRect full = screen.frame;
        display.full_bounds = (WMRect){full.origin.x, primaryHeight - NSMaxY(full), full.size.width, full.size.height};
        copyUTF8(display.name, sizeof(display.name), screen.localizedName);
        output[count++] = display;
    }
    return count;
}

bool platform_pointer(WMPoint *point) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return false;
    CGPoint location = CGEventGetLocation(event);
    CFRelease(event);
    *point = (WMPoint){location.x, location.y};
    return true;
}

bool platform_warp_pointer(WMPoint point) {
    return CGWarpMouseCursorPosition(CGPointMake(point.left, point.top)) == kCGErrorSuccess;
}

bool platform_frame(uint64_t identity, WMRect frame, double duration, WMFrameIntent intent) {
    for (WindowRecord *record in records) if (record.observation.identity == identity) {
        if (record.observation.stale || record.observation.minimized || record.observation.fullscreen) return false;
        WMRect priorTarget = record.target;
        if (duration > 0 && record.motion == WMMotionRejected && framesNear(priorTarget, frame, 2)) return false;
        if (duration > 0 && memcmp(&priorTarget, &frame, sizeof(frame)) == 0 && record.motion == WMMotionAnimating) return true;
        WMRect current;
        if (!readFrame(record.element, &current)) return false;
        if (framesNear(current, frame, intent == WMFrameIntentVerifiedPlacement ? 0 : 2)) {
            record.animationDuration = 0;
            record.motion = WMMotionIdle;
            record.target = frame;
            return true;
        }
        record.motion = WMMotionIdle;
        record.target = frame; record.changed = YES;
        if (duration <= 0) { record.animationDuration = 0; return writeFrame(record, frame); }
        record.animationStart = current; record.animationTime = CACurrentMediaTime(); record.animationDuration = duration; record.motion = WMMotionAnimating;
        return true;
    }
    return false;
}

bool platform_read_frame(uint64_t identity, WMRect *frame) {
    for (WindowRecord *record in records) if (record.observation.identity == identity) return readFrame(record.element, frame);
    return false;
}

bool platform_focus(uint64_t identity) {
    for (WindowRecord *record in records) if (record.observation.identity == identity && !record.observation.minimized && !record.observation.fullscreen && !record.observation.stale) {
        NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:record.observation.pid];
        BOOL activated = [application activateWithOptions:0];
        AXError raised = AXUIElementPerformAction(record.element, kAXRaiseAction);
        AXUIElementSetAttributeValue(record.element, kAXMainAttribute, kCFBooleanTrue);
        dirty = YES;
        return activated && raised == kAXErrorSuccess;
    }
    return false;
}

uint64_t platform_focused_window(void) {
    NSRunningApplication *application = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!application) return 0;
    AXUIElementRef appElement = AXUIElementCreateApplication(application.processIdentifier);
    AXUIElementSetMessagingTimeout(appElement, 0.08);
    id focusedWindow = attribute(appElement, kAXFocusedWindowAttribute);
    CFRelease(appElement);
    if (!focusedWindow || CFGetTypeID((__bridge CFTypeRef)focusedWindow) != AXUIElementGetTypeID()) return 0;
    for (WindowRecord *record in records) if (record.observation.pid == application.processIdentifier && !record.observation.stale && CFEqual(record.element, (__bridge CFTypeRef)focusedWindow)) return record.observation.identity;
    return 0;
}

static WMLaunchStatus launchStatus;
uint64_t platform_launch(const char *bundle, bool new_instance) {
    NSString *identifier = [NSString stringWithUTF8String:bundle];
    NSURL *url = nil;
    for (NSRunningApplication *application in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
        if (!application.terminated && application.bundleURL && [NSFileManager.defaultManager fileExistsAtPath:application.bundleURL.path]) {
            url = application.bundleURL;
            break;
        }
    }
    if (!url) url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier];
    if (!url) return 0;
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = new_instance;
    configuration.activates = YES;
    uint64_t requestID = launchStatus.request_id + 1;
    launchStatus = (WMLaunchStatus){ .request_id = requestID, .state = 1 };
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration completionHandler:^(NSRunningApplication *application, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (launchStatus.request_id != requestID) return;
            launchStatus.state = error || !application ? 3 : 2;
            copyUTF8(launchStatus.message, sizeof(launchStatus.message), error.localizedDescription ?: @"");
        });
    }];
    return requestID;
}
WMLaunchStatus platform_launch_status(void) { return launchStatus; }

bool platform_exec(const char *shell) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", [NSString stringWithUTF8String:shell]];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    return [task launchAndReturnError:&error];
}

static WindowRecord *closingRecord;
static double closingProcessToken;
double platform_monotonic(void) { return CACurrentMediaTime(); }
void platform_close_cancel(void) { closingRecord = nil; closingProcessToken = 0; }

bool platform_close(uint64_t identity, bool track, double *process_token) {
    if (platform_focused_window() != identity) return false;
    for (WindowRecord *record in records) if (record.observation.identity == identity && !record.observation.stale && !record.observation.minimized && !record.observation.fullscreen) {
        NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:record.observation.pid];
        double token = application.launchDate.timeIntervalSinceReferenceDate;
        if (track && (!application.launchDate || token == 0)) return false;
        id button = attribute(record.element, kAXCloseButtonAttribute);
        if (!button || CFGetTypeID((__bridge CFTypeRef)button) != AXUIElementGetTypeID()) return false;
        if (AXUIElementPerformAction((__bridge AXUIElementRef)button, kAXPressAction) != kAXErrorSuccess) return false;
        if (track) { closingRecord = record; closingProcessToken = token; *process_token = token; }
        dirty = YES;
        return true;
    }
    return false;
}

int platform_close_state(uint64_t identity, int pid, double process_token) {
    if (!closingRecord || closingRecord.observation.identity != identity || closingRecord.observation.pid != pid || closingProcessToken != process_token) return -1;
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!application || application.terminated || !application.launchDate || application.launchDate.timeIntervalSinceReferenceDate != process_token) return -1;
    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(appElement, 0.08);
    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &value);
    CFRelease(appElement);
    if (result != kAXErrorSuccess || !value || CFGetTypeID(value) != CFArrayGetTypeID()) { if (value) CFRelease(value); return -1; }
    NSArray *allWindows = CFBridgingRelease(value);
    for (id window in allWindows) {
        if (CFGetTypeID((__bridge CFTypeRef)window) != AXUIElementGetTypeID()) return -1;
        if (CFEqual(closingRecord.element, (__bridge CFTypeRef)window)) return 0;
    }
    return allWindows.count == 0 ? 2 : 1;
}

bool platform_terminate_if_empty(uint64_t identity, int pid, double process_token) {
    if (platform_close_state(identity, pid, process_token) != 2) return false;
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!application.launchDate || application.launchDate.timeIntervalSinceReferenceDate != process_token) return false;
    return [application terminate];
}

static NSRect cocoaRect(WMRect frame) { return NSMakeRect(frame.left, CGDisplayBounds(CGMainDisplayID()).size.height - frame.top - frame.height, frame.width, frame.height); }
void platform_border(uint64_t identity, double width, uint32_t color) {
    WindowRecord *focused = nil;
    for (WindowRecord *record in records) if (record.observation.identity == identity && !record.observation.minimized && !record.observation.fullscreen && !record.observation.stale) focused = record;
    if (!focused || width <= 0) { [borderPanel orderOut:nil]; return; }
    if (!borderPanel) {
        borderPanel = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        borderPanel.opaque = NO; borderPanel.backgroundColor = NSColor.clearColor; borderPanel.ignoresMouseEvents = YES; borderPanel.level = NSFloatingWindowLevel;
        borderPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
        borderPanel.contentView.wantsLayer = YES;
    }
    WMRect frame = focused.observation.frame; readFrame(focused.element, &frame);
    [borderPanel setFrame:NSInsetRect(cocoaRect(frame), -width, -width) display:YES];
    borderPanel.contentView.layer.borderWidth = width;
    borderPanel.contentView.layer.cornerRadius = 11;
    borderPanel.contentView.layer.borderColor = [NSColor colorWithRed:((color >> 16) & 255) / 255.0 green:((color >> 8) & 255) / 255.0 blue:(color & 255) / 255.0 alpha:0.95].CGColor;
    [borderPanel orderFrontRegardless];
}

@interface StatusItemOwner : NSObject
@property(nonatomic, strong) NSStatusItem *item;
- (void)dispatchCommand:(NSMenuItem *)sender;
@end

@implementation StatusItemOwner
- (void)dispatchCommand:(NSMenuItem *)sender {
    if (stopping || !self.item.menu || sender.target != self || !sender.enabled || sender.menu != self.item.menu ||
        [self.item.menu indexOfItem:sender] < 0) return;
    NSString *command = [sender.representedObject copy];
    const char *reply = wm_command(command.UTF8String);
    NSData *data = [NSData dataWithBytes:reply length:strlen(reply)];
    NSError *parseError = nil;
    id response = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (parseError || ![response isKindOfClass:NSDictionary.class]) {
        platform_error("Status menu command returned invalid JSON");
    } else if (response[@"error"]) {
        NSString *message = response[@"err_message"];
        platform_error([message isKindOfClass:NSString.class] ? message.UTF8String : "Status menu command failed");
    }
}
@end

static StatusItemOwner *statusOwner;

void platform_status_present(const WMStatusPresentation *presentation) {
    if (!presentation || stopping) {
        if (!statusOwner) return;
        [statusOwner.item.menu cancelTracking];
        for (NSMenuItem *entry in statusOwner.item.menu.itemArray) entry.target = nil;
        statusOwner.item.menu = nil;
        [NSStatusBar.systemStatusBar removeStatusItem:statusOwner.item];
        statusOwner = nil;
        return;
    }
    if (presentation->row_count > 12) { platform_error("Status menu exceeds row limit"); return; }
    if (!statusOwner) {
        statusOwner = [StatusItemOwner new];
        statusOwner.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    }
    [statusOwner.item.menu cancelTracking];
    for (NSMenuItem *entry in statusOwner.item.menu.itemArray) entry.target = nil;
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    for (size_t index = 0; index < presentation->row_count; index++) {
        const WMStatusRow *row = &presentation->rows[index];
        NSMenuItem *entry = [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:row->title] action:@selector(dispatchCommand:) keyEquivalent:@""];
        entry.target = statusOwner;
        entry.representedObject = [NSString stringWithUTF8String:row->command];
        entry.enabled = row->enabled;
        entry.state = row->checked ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:entry];
    }
    statusOwner.item.button.title = [NSString stringWithUTF8String:presentation->title];
    statusOwner.item.button.toolTip = [NSString stringWithUTF8String:presentation->tooltip];
    statusOwner.item.menu = menu;
}

static OSStatus hotkeyCallback(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next; (void)context;
    EventHotKeyID identity;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(identity), NULL, &identity) == noErr && identity.id < 256 && hotkeyRefs[identity.id]) wm_command(currentBindings[identity.id].command);
    return noErr;
}

bool platform_bindings(const WMBinding *bindings, size_t count) {
    if (count > 128) return false;
    EventHotKeyRef staged[256] = {0}; WMBinding stagedBindings[256] = {0}; BOOL newlyRegistered[256] = {0};
    for (size_t index = 0; index < count; index++) {
        size_t slot = 256;
        for (size_t oldIndex = 0; oldIndex < 256; oldIndex++) if (hotkeyRefs[oldIndex] && currentBindings[oldIndex].key == bindings[index].key && currentBindings[oldIndex].modifiers == bindings[index].modifiers) { slot = oldIndex; break; }
        if (slot < 256) { staged[slot] = hotkeyRefs[slot]; stagedBindings[slot] = bindings[index]; continue; }
        for (size_t candidate = 0; candidate < 256; candidate++) if (!hotkeyRefs[candidate] && !staged[candidate]) { slot = candidate; break; }
        EventHotKeyID identity = {'HUEN', (UInt32)slot};
        if (slot == 256 || RegisterEventHotKey(bindings[index].key, bindings[index].modifiers, identity, GetApplicationEventTarget(), 0, &staged[slot]) != noErr) {
            for (size_t rollback = 0; rollback < 256; rollback++) if (newlyRegistered[rollback]) UnregisterEventHotKey(staged[rollback]);
            fprintf(stderr, "hotkey collision at binding %zu; previous bindings retained\n", index + 1); return false;
        }
        newlyRegistered[slot] = YES; stagedBindings[slot] = bindings[index];
    }
    for (size_t oldIndex = 0; oldIndex < 256; oldIndex++) if (hotkeyRefs[oldIndex] && !staged[oldIndex]) UnregisterEventHotKey(hotkeyRefs[oldIndex]);
    memcpy(hotkeyRefs, staged, sizeof(staged)); memcpy(currentBindings, stagedBindings, sizeof(stagedBindings));
    return true;
}

size_t platform_restore(void) {
    size_t outstanding = 0;
    for (WindowRecord *record in records) { record.animationDuration = 0; record.motion = WMMotionIdle; }
    for (WindowRecord *record in records) if (record.changed) {
        WMRect actual;
        BOOL restored = NO;
        if (canMove(record)) {
            writeFrame(record, record.original);
            restored = readFrame(record.element, &actual) && framesNear(actual, record.original, 2);
        }
        if (restored) record.changed = NO;
        else {
            outstanding++;
            fprintf(stderr, "restore incomplete for window %llu\n", (unsigned long long)record.observation.identity);
        }
    }
    return outstanding;
}
void platform_quit(void) { stopping = YES; platform_status_present(NULL); }
const char *platform_config_path(void) { return configPath.fileSystemRepresentation; }
const char *platform_filter(void) { return bundleFilter.UTF8String ?: ""; }
void platform_config_changed(void) { dirty = YES; }
static void signalHandler(int signalNumber) { (void)signalNumber; interrupted = 1; }

static int connectSocket(void) {
    struct stat metadata;
    if (lstat(socketPath.fileSystemRepresentation, &metadata) != 0 || metadata.st_uid != getuid() || !S_ISSOCK(metadata.st_mode)) return -1;
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
    struct timeval timeout = {2, 0}; setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)); setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) { close(descriptor); return -1; }
    return descriptor;
}

int platform_main(int argc, char **argv) {
    @autoreleasepool {
        configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".config/huen-wm/config.lua"];
        if (![NSFileManager.defaultManager fileExistsAtPath:configPath]) {
            NSString *bundled = [NSBundle.mainBundle pathForResource:@"config" ofType:@"lua"];
            if (bundled) configPath = bundled;
        }
        socketPath = [NSString stringWithFormat:@"/tmp/huen-wm-%u.sock", getuid()];
        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        for (int index = 1; index < argc; index++) {
            NSString *first = arguments.firstObject;
            if (first && ![@[@"start", @"doctor", @"validate", @"help", @"--help"] containsObject:first]) {
                [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
                continue;
            }
            if (!strcmp(argv[index], "--config") || !strcmp(argv[index], "--app")) {
                if (index + 1 >= argc) { fprintf(stderr, "missing value for %s\n", argv[index]); return 1; }
                BOOL isConfig = !strcmp(argv[index], "--config"); NSString *value = [NSString stringWithUTF8String:argv[++index]];
                if (!value.length) { fputs("option value cannot be empty\n", stderr); return 1; }
                if (isConfig) configPath = value.stringByExpandingTildeInPath; else bundleFilter = value;
            } else if (!strncmp(argv[index], "--", 2) && strcmp(argv[index], "--help")) { fprintf(stderr, "unknown option: %s\n", argv[index]); return 1; }
            else [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
        }
        NSString *verb = arguments.firstObject ?: @"--help";
        if (([verb isEqualToString:@"start"] || [verb isEqualToString:@"doctor"] || [verb isEqualToString:@"validate"]) && arguments.count != 1) { fputs("unexpected positional argument\n", stderr); return 1; }
        if ([verb isEqualToString:@"--help"] || [verb isEqualToString:@"help"]) { puts("huen-wm start [--config PATH] [--app BUNDLE_ID]\nhuen-wm doctor | validate [--config PATH]\nhuen-wm status | windows | monitors | workspaces\nhuen-wm focus [--wrap] left|right|up|down\nhuen-wm swap|move left|right|up|down | resize DELTA\nhuen-wm resize width|height DELTA\nhuen-wm split horizontal|vertical|toggle | fullscreen\nhuen-wm toggle-floating | layout dwindle|master\nhuen-wm workspace INDEX | send-to-workspace INDEX\nhuen-wm mode NAME | launch [--new-instance] BUNDLE\nhuen-wm exec-and-forget SHELLTEXT\nhuen-wm close [--quit-if-last-window]\nhuen-wm reload | restore | recover | stop | quit\nWorkspace parking is reversible during a live session. Hard-kill recovery is not guaranteed."); return 0; }
        if ([verb isEqualToString:@"doctor"]) {
            NSDictionary *report = @{ @"accessibility": AXIsProcessTrusted() ? @YES : @NO, @"screen_capture": @(huen_scene_capture_allowed()), @"screen_capture_required_for_tiling": @NO, @"zig": @"0.17.0", @"socket": socketPath, @"config": configPath, @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: @"unbundled", @"workspace_backend": @"reversible-corner-parking", @"recovery": @"live-session-only", @"permission_prompted": @NO };
            NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil]; fwrite(data.bytes, 1, data.length, stdout); puts(""); return 0;
        }
        if ([verb isEqualToString:@"validate"]) { BOOL valid = wm_initialize(configPath.fileSystemRepresentation); if (valid) puts("{\"ok\":true}"); return valid ? 0 : 1; }
        if (![verb isEqualToString:@"start"]) {
            NSString *operands = [arguments componentsJoinedByString:@" "];
            if ([operands rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location != NSNotFound) { fputs("command must be one line\n", stderr); return 1; }
            NSString *command = [operands stringByAppendingString:@"\n"];
            if ([command lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 511) { fputs("command too long\n", stderr); return 1; }
            int descriptor = connectSocket(); if (descriptor < 0) { fprintf(stderr, "huen-wm is not running for this user\n"); return 1; }
            int noSignal = 1;
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
            const char *commandBytes = command.UTF8String;
            size_t commandRemaining = strlen(commandBytes);
            while (commandRemaining) {
                ssize_t amount = write(descriptor, commandBytes, commandRemaining);
                if (amount < 0 && errno == EINTR) continue;
                if (amount <= 0) { perror("command write"); close(descriptor); return 1; }
                commandBytes += amount;
                commandRemaining -= (size_t)amount;
            }
            NSMutableData *reply = [NSMutableData data]; char buffer[8192]; ssize_t received;
            for (;;) {
                received = read(descriptor, buffer, sizeof(buffer));
                if (received < 0 && errno == EINTR) continue;
                if (received < 0) { perror("reply read"); close(descriptor); return 1; }
                if (!received) break;
                if (reply.length + (NSUInteger)received > 4 * 1024 * 1024) { fputs("runtime reply too large\n", stderr); close(descriptor); return 1; }
                [reply appendBytes:buffer length:(NSUInteger)received];
            }
            close(descriptor); if (!reply.length) { fputs("runtime did not respond\n", stderr); return 1; }
            NSError *parseError = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:reply options:0 error:&parseError];
            if (!parsed || parseError || (![parsed isKindOfClass:NSDictionary.class] && ![parsed isKindOfClass:NSArray.class])) { fputs("runtime returned invalid JSON\n", stderr); return 1; }
            if (fwrite(reply.bytes, 1, reply.length, stdout) != reply.length || fflush(stdout) != 0) { perror("reply output"); return 1; }
            return [parsed isKindOfClass:NSDictionary.class] && parsed[@"error"] ? 1 : 0;
        }
        NSString *lockPath = [socketPath stringByAppendingString:@".lock"];
        int lockDescriptor = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
        if (lockDescriptor < 0 || flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0) { fputs("huen-wm already running or lock unavailable\n", stderr); return 1; }
        if (!AXIsProcessTrusted()) { fputs("Accessibility permission required. Grant it to the signed Huen WM app in System Settings, then start explicitly. No permission was requested.\n", stderr); close(lockDescriptor); return 1; }
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        records = [NSMutableArray array]; observers = [NSMutableDictionary dictionary]; applications = [NSMutableDictionary dictionary];
        if (!wm_initialize(configPath.fileSystemRepresentation)) { close(lockDescriptor); return 1; }
        EventTypeSpec hotkeyEvent = {kEventClassKeyboard, kEventHotKeyPressed}; InstallApplicationEventHandler(hotkeyCallback, 1, &hotkeyEvent, NULL, NULL);
        if (!wm_activate_config()) { close(lockDescriptor); return 1; }
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0);
        if (serverSocket < 0) { platform_status_present(NULL); perror("IPC socket"); close(lockDescriptor); return 1; }
        struct sockaddr_un address = {0}; address.sun_family = AF_UNIX; strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
        unlink(socketPath.fileSystemRepresentation);
        mode_t oldMask = umask(0077); int bindResult = bind(serverSocket, (struct sockaddr *)&address, sizeof(address)); umask(oldMask);
        if (bindResult || listen(serverSocket, 8)) { platform_status_present(NULL); perror("IPC socket"); close(lockDescriptor); return 1; }
        fcntl(serverSocket, F_SETFL, O_NONBLOCK);
        signal(SIGINT, signalHandler); signal(SIGTERM, signalHandler); signal(SIGPIPE, SIG_IGN);
        __block double lastScan = 0; __block double lastConfigCheck = 0; __block struct timespec lastModified = {0};
        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timerValue) {
            (void)timerValue;
            wm_config_poll();
            if (interrupted) platform_quit();
            double now = CACurrentMediaTime();
            if ((dirty && now - lastScan > 0.15) || now - lastScan > 2) { dirty = NO; scanWindows(); wm_tick(); lastScan = now; }
            if (now - lastConfigCheck > 0.25) {
                struct stat metadata;
                if (stat(configPath.fileSystemRepresentation, &metadata) == 0 && (metadata.st_mtimespec.tv_sec != lastModified.tv_sec || metadata.st_mtimespec.tv_nsec != lastModified.tv_nsec)) {
                    BOOL deferred = NO;
                    if (lastModified.tv_sec) {
                        const char *result = wm_command("reload");
                        deferred = strstr(result, "WorkspaceTransitionPending") != NULL || strstr(result, "ConfigLoadPending") != NULL;
                        if (!deferred && strstr(result, "\"error\"")) fprintf(stderr, "automatic reload rejected: %s", result);
                    }
                    if (!deferred) lastModified = metadata.st_mtimespec;
                }
                lastConfigCheck = now;
            }
            now = CACurrentMediaTime();
            for (WindowRecord *record in records) if (record.motion == WMMotionAnimating) {
                if (record.observation.stale || !record.observation.onscreen || record.observation.minimized || record.observation.fullscreen) { record.animationDuration = 0; record.motion = WMMotionIdle; continue; }
                double progress = MIN(1, (now - record.animationTime) / record.animationDuration); double eased = 1 - pow(1 - progress, 3);
                WMRect start = record.animationStart, target = record.target;
                BOOL applied = writeFrame(record, (WMRect){start.left + (target.left - start.left) * eased, start.top + (target.top - start.top) * eased, start.width + (target.width - start.width) * eased, start.height + (target.height - start.height) * eased});
                if (!applied || progress >= 1) {
                    WMRect actual;
                    record.motion = !applied || !readFrame(record.element, &actual) || !framesNear(actual, target, 2) ? WMMotionRejected : WMMotionIdle;
                    record.animationDuration = 0;
                    dirty = YES;
                }
            }
            int client = accept(serverSocket, NULL, NULL);
            if (client >= 0) {
                double deadline = CACurrentMediaTime() + 0.1;
                int clientFlags = fcntl(client, F_GETFL);
                // macOS inherits O_NONBLOCK from the listening socket.
                if (clientFlags >= 0 && fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) == 0) {
                    char command[512]; size_t used = 0; BOOL complete = NO;
                    while (used < sizeof(command) - 1) {
                        double remainingTime = deadline - CACurrentMediaTime();
                        if (remainingTime <= 0) break;
                        struct timeval timeout = {0, MAX(1, (int)(remainingTime * 1000000))};
                        if (setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) break;
                        ssize_t amount = read(client, command + used, sizeof(command) - 1 - used);
                        if (amount < 0 && errno == EINTR) continue;
                        if (amount <= 0) break;
                        used += amount;
                        if (memchr(command, '\n', used)) { complete = YES; break; }
                    }
                    command[used] = 0; char *newline = strchr(command, '\n'); if (newline) *newline = 0;
                    double commandStarted = CACurrentMediaTime();
                    const char *reply = complete ? wm_command(command) : "{\"error\":\"incomplete or oversized command\"}\n";
                    deadline += CACurrentMediaTime() - commandStarted;
                    size_t remaining = strlen(reply);
                    while (remaining) {
                        double remainingTime = deadline - CACurrentMediaTime();
                        if (remainingTime <= 0) break;
                        struct timeval timeout = {0, MAX(1, (int)(remainingTime * 1000000))};
                        if (setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) break;
                        ssize_t amount = write(client, reply, remaining);
                        if (amount < 0 && errno == EINTR) continue;
                        if (amount <= 0) break;
                        reply += amount; remaining -= amount;
                    }
                }
                close(client);
            }
            if (stopping && wm_shutdown()) { [NSApp stop:nil]; NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0]; [NSApp postEvent:wake atStart:NO]; }
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes]; [NSApp run]; [timer invalidate];
        close(serverSocket); unlink(socketPath.fileSystemRepresentation); close(lockDescriptor); return 0;
    }
}
