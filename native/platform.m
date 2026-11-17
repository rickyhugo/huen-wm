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
@property double cornerRadius;
@property double assumedVisibleDeadline;
@property BOOL changed;
@property WMMotionState motion;
@end
@implementation WindowRecord
- (void)dealloc { if (_element) CFRelease(_element); }
@end

static NSMutableArray<WindowRecord *> *records;
static NSArray<NSDictionary *> *inputWindowOrdering;
static NSMutableDictionary<NSNumber *, NSValue *> *observers;
static NSMutableDictionary<NSNumber *, NSRunningApplication *> *applications;
// An application that does not answer AX stalls every scan for the messaging timeout, and every command scans.
// After two consecutive timeouts, scans of every application skip it for a doubling delay, up to 30 seconds.
// A scan of that one application, an AX notification from it, or its activation retries it at once.
// A scan that a command waits for skips it after one timeout, so only timer scans pay for retries.
static NSMutableDictionary<NSNumber *, NSNumber *> *timeoutCounts;
static NSMutableDictionary<NSNumber *, NSNumber *> *timeoutRetryTimes;
static void forgetTimeouts(pid_t process) { [timeoutCounts removeObjectForKey:@(process)]; [timeoutRetryTimes removeObjectForKey:@(process)]; }
static uint64_t nextIdentity = 1;
// The first scan of every application also finds windows on other native Spaces. Later scans find only windows created since.
static BOOL initialScanComplete = NO;
static BOOL dirty = YES;
// Commands scan before they act only when this is set: since the last scan of every application, a window appeared,
// went away, or changed geometry or state. Focus changes and the echoes of our own frame writes leave it clear, because
// commands read focus directly and use layout intent, not observed frames. Most hotkeys therefore act without a scan.
static BOOL commandScanNeeded = YES;
static BOOL scanningForCommand = NO;
static void markChanged(void) { dirty = YES; commandScanNeeded = YES; }
// A created window can be unready for the first scan (no subrole, frame, or settable position) and posts no later notification.
// Until this deadline, scans repeat quickly so the window tiles once it is ready instead of at the next periodic scan.
// One settling application is scanned alone on every tick, which costs far less than a scan of every application.
// Zero means every application: a launch, or several applications settling at once.
static double settleScanDeadline = 0;
static pid_t settleProcess = 0;
static void requestSettleScans(pid_t process) {
    double now = CACurrentMediaTime();
    settleProcess = now < settleScanDeadline && settleProcess != process ? 0 : process;
    settleScanDeadline = now + 1.0;
    markChanged();
}
// An application launched hidden is shown after its first window is placed, so the window never appears at the frame
// the application chose. Some applications create no window while hidden, so the deadline shows them anyway.
static NSRunningApplication *revealApplication;
static double revealDeadline = 0;
static double revealPlacementTime = 0;
static double lastScan = 0;
static double lastProcessScan = 0;
// A scan of one application that timed out waits this long before the next, so a busy application cannot stall every tick.
static double processScanRetryTime = 0;
static BOOL serviceActive = NO;
static void scanAndTick(pid_t process);
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
static bool copyUTF8(char *destination, size_t capacity, NSString *source) {
    NSUInteger used = 0;
    NSRange remaining = NSMakeRange(0, source.length);
    [source getBytes:destination maxLength:capacity - 1 usedLength:&used encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, source.length) remainingRange:&remaining];
    destination[used] = 0;
    return remaining.length == 0 && memchr(destination, 0, used) == NULL;
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

// Set when an AX read times out. A scan stops reading that application, or each further read would wait for the timeout again.
static BOOL readTimedOut = NO;
static id attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef result = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, name, &result);
    if (error == kAXErrorCannotComplete) readTimedOut = YES;
    if (error != kAXErrorSuccess) return nil;
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

static NSUInteger largestScreen(WMRect frame) {
    double primaryHeight = CGDisplayBounds(CGMainDisplayID()).size.height;
    NSArray<NSScreen *> *screens = NSScreen.screens;
    NSUInteger largest = NSNotFound;
    double largestArea = 0;
    for (NSUInteger index = 0; index < screens.count; index++) {
        NSRect full = screens[index].frame;
        CGRect overlap = CGRectIntersection(CGRectMake(full.origin.x, primaryHeight - NSMaxY(full), full.size.width, full.size.height), CGRectMake(frame.left, frame.top, frame.width, frame.height));
        double area = CGRectIsNull(overlap) ? 0 : overlap.size.width * overlap.size.height;
        if (area > largestArea) { largestArea = area; largest = index; }
    }
    return largest;
}

// Shared by every cross-display settle in one run-loop tick or command, so moving many windows cannot stall it.
static double settleBudgetDeadline = 0;
void platform_settle_budget_begin(void) { settleBudgetDeadline = CACurrentMediaTime() + 0.1; }

static BOOL writeFrame(WindowRecord *record, WMRect frame, BOOL settle) {
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
    if (applied && settle && resizeNeeded && priorReadable && largestScreen(current) != largestScreen(frame)) {
        // AppKit sizes against the previous screen until the app handles the move, so rewrite once it settles.
        // Stop when the size is near the target, a rewrite does not change it (cell snapping, minimum size),
        // or the tick's settle budget is spent.
        WMRect settled, previous = {0};
        BOOL rewritten = NO;
        for (NSUInteger attempt = 0; attempt < 10 && CACurrentMediaTime() < settleBudgetDeadline && readFrame(record.element, &settled); attempt++) {
            if (fabs(settled.width - frame.width) <= 1 && fabs(settled.height - frame.height) <= 1) break;
            if (rewritten && fabs(settled.width - previous.width) <= 0.5 && fabs(settled.height - previous.height) <= 0.5) break;
            previous = settled;
            usleep(10000);
            AXUIElementSetAttributeValue(record.element, kAXSizeAttribute, size);
            AXUIElementSetAttributeValue(record.element, kAXPositionAttribute, position);
            rewritten = YES;
        }
    }
    if (applied) record.placementVisibilityDeadline = CACurrentMediaTime() + 0.25;
    CFRelease(position); CFRelease(size);
    return applied;
}

static BOOL framesNear(WMRect first, WMRect second, double tolerance) {
    return fabs(first.left - second.left) <= tolerance && fabs(first.top - second.top) <= tolerance && fabs(first.width - second.width) <= tolerance && fabs(first.height - second.height) <= tolerance;
}

static void observationCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context) {
    (void)observer; (void)context;
    if (CFEqual(notification, kAXWindowCreatedNotification) || CFEqual(notification, kAXApplicationShownNotification)) {
        pid_t process = 0;
        AXUIElementGetPid(element, &process);
        forgetTimeouts(process);
        requestSettleScans(process);
        // Place a new window now instead of at the next timer tick. The scan runs outside this AX callback.
        dispatch_async(dispatch_get_main_queue(), ^{
            pid_t target = settleProcess;
            if (serviceActive && CACurrentMediaTime() - (target ? lastProcessScan : lastScan) > 0.005) scanAndTick(target);
        });
        return;
    }
    dirty = YES;
    if (CFEqual(notification, kAXFocusedWindowChangedNotification)) return;
    if (CFEqual(notification, kAXMovedNotification) || CFEqual(notification, kAXResizedNotification)) {
        // An application reports our own frame write back. That is not a change a command has to scan for.
        for (WindowRecord *record in records) if (CFEqual(record.element, element)) {
            if (CACurrentMediaTime() < record.placementVisibilityDeadline) return;
            break;
        }
    }
    commandScanNeeded = YES;
}

// A nonzero process limits AX reads to that application. Other applications keep their last observations.
static BOOL scanWindowSnapshot(pid_t onlyProcess) {
    BOOL unmatched = NO;
    NSArray *visibleWindows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    inputWindowOrdering = visibleWindows;
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
        if (onlyProcess && application.processIdentifier != onlyProcess) continue;
        if (!onlyProcess && (scanningForCommand ? timeoutCounts[process] != nil : timeoutRetryTimes[process] && CACurrentMediaTime() < timeoutRetryTimes[process].doubleValue)) continue;
        AXUIElementRef appElement = AXUIElementCreateApplication(application.processIdentifier);
        AXUIElementSetMessagingTimeout(appElement, 0.08);
        if (!observers[process]) {
            AXObserverRef observer;
            if (AXObserverCreate(application.processIdentifier, observationCallback, &observer) == kAXErrorSuccess) {
                BOOL registered = YES;
                for (NSString *name in @[(__bridge NSString *)kAXWindowCreatedNotification, (__bridge NSString *)kAXFocusedWindowChangedNotification, (__bridge NSString *)kAXApplicationHiddenNotification, (__bridge NSString *)kAXApplicationShownNotification]) {
                    AXError added = AXObserverAddNotification(observer, appElement, (__bridge CFStringRef)name, NULL);
                    if (added != kAXErrorSuccess && added != kAXErrorNotificationAlreadyRegistered) registered = NO;
                }
                if (registered) {
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
                    observers[process] = [NSValue valueWithPointer:observer];
                } else {
                    // A launching application can reject registration. Retry soon, or its new windows would wait for periodic scans.
                    // Applications that keep rejecting it are retried only by periodic scans.
                    CFRelease(observer);
                    if (application.launchDate && -application.launchDate.timeIntervalSinceNow < 5) requestSettleScans(application.processIdentifier);
                }
            }
        }
        CFTypeRef windowValues = NULL;
        readTimedOut = NO;
        AXError scanResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowValues);
        if (scanResult != kAXErrorSuccess || !windowValues || CFGetTypeID(windowValues) != CFArrayGetTypeID()) {
            if (windowValues) CFRelease(windowValues);
            for (WindowRecord *record in records) if (record.observation.pid == application.processIdentifier) { WMWindow observation = record.observation; observation.stale = true; record.observation = observation; }
            if (scanResult == kAXErrorCannotComplete) {
                NSUInteger count = timeoutCounts[process].unsignedIntegerValue + 1;
                timeoutCounts[process] = @(count);
                if (count >= 2) timeoutRetryTimes[process] = @(CACurrentMediaTime() + MIN(30.0, 0.5 * (double)(1u << MIN(count - 2, (NSUInteger)6))));
            }
            CFRelease(appElement); continue;
        }
        forgetTimeouts(application.processIdentifier);
        NSArray *windows = CFBridgingRelease(windowValues);
        NSMutableDictionary<NSValue *, NSValue *> *frames = [NSMutableDictionary dictionary];
        for (id object in windows) {
            AXUIElementRef element = (__bridge AXUIElementRef)object;
            AXUIElementSetMessagingTimeout(element, 0.08);
            WMRect frame;
            if (readFrame(element, &frame)) frames[[NSValue valueWithPointer:element]] = [NSValue valueWithBytes:&frame objCType:@encode(WMRect)];
            if (readTimedOut) break;
        }
        id focused = readTimedOut ? nil : attribute(appElement, kAXFocusedWindowAttribute);
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        for (id object in windows) {
            if (readTimedOut) break;
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
                // WindowServer can publish a new window tens of milliseconds after AX does. A window created after the first scan
                // in an application that is not hidden opens on the current Space, so place it at once and let WindowServer
                // confirm it within the deadline. Without that confirmation it stops being eligible, as before.
                // Other new windows only make the scan retry instead of waiting unplaced for the next scan.
                BOOL revealing = revealApplication && revealApplication.processIdentifier == application.processIdentifier;
                // WindowServer does not list a hidden application's window, so that window stays assumed until it is shown.
                if (initialScanComplete && (!application.hidden || revealing)) record.assumedVisibleDeadline = (revealing ? revealDeadline : CACurrentMediaTime()) + 0.5;
                else record.placementVisibilityDeadline = CACurrentMediaTime() + 0.25;
                WMWindow initial = {0}; initial.identity = nextIdentity++; initial.pid = application.processIdentifier; record.observation = initial;
                [records addObject:record];
                AXUIElementSetMessagingTimeout(element, 0.08);
                AXObserverRef observer = [observers[process] pointerValue];
                if (observer) for (NSString *name in @[(__bridge NSString *)kAXUIElementDestroyedNotification, (__bridge NSString *)kAXMovedNotification, (__bridge NSString *)kAXResizedNotification, (__bridge NSString *)kAXWindowMiniaturizedNotification, (__bridge NSString *)kAXWindowDeminiaturizedNotification]) AXObserverAddNotification(observer, element, (__bridge CFStringRef)name, NULL);
            }
            WMWindow observation = record.observation;
            observation.frame = frame; observation.stale = false;
            observation.onscreen = false;
            observation.public_window_id = 0;
            observation.hit_eligible = false;
            NSUInteger matchingAX = 0, matchingCG = 0;
            NSUInteger matchedOrder = NSNotFound;
            for (NSValue *candidate in frames.allValues) {
                WMRect candidateFrame; [candidate getValue:&candidateFrame];
                if (framesNear(frame, candidateFrame, 4)) matchingAX++;
            }
            for (NSDictionary *visibleWindow in visibleWindows) {
                if ([visibleWindow[(__bridge NSString *)kCGWindowOwnerPID] intValue] != application.processIdentifier || [visibleWindow[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
                CGRect bounds;
                if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)visibleWindow[(__bridge NSString *)kCGWindowBounds], &bounds) && framesNear(frame, (WMRect){bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height}, 4)) {
                    matchingCG++;
                    matchedOrder = [visibleWindows indexOfObjectIdenticalTo:visibleWindow];
                    observation.public_window_id = [visibleWindow[(__bridge NSString *)kCGWindowNumber] unsignedIntValue];
                }
            }
            BOOL assumedVisible = frames.count == windows.count && matchingAX == 1 && matchingCG == 0 && CACurrentMediaTime() < record.assumedVisibleDeadline;
            observation.onscreen = frames.count == windows.count && matchingAX == 1 && (matchingCG == 1 || assumedVisible);
            if (!observation.onscreen) observation.public_window_id = 0;
            observation.hit_eligible = observation.public_window_id != 0;
            for (NSUInteger frontIndex = 0; observation.hit_eligible && frontIndex < matchedOrder; frontIndex++) {
                NSDictionary *front = visibleWindows[frontIndex];
                if ([front[(__bridge NSString *)kCGWindowOwnerPID] intValue] == getpid() || [front[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= 0) continue;
                CGRect bounds;
                if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)front[(__bridge NSString *)kCGWindowBounds], &bounds)) { observation.hit_eligible = false; break; }
                CGRect tile = CGRectMake(frame.left, frame.top, frame.width, frame.height);
                if (CGRectIntersectsRect(tile, bounds)) observation.hit_eligible = false;
            }
            observation.minimized = [attribute(element, kAXMinimizedAttribute) boolValue];
            observation.fullscreen = [attribute(element, CFSTR("AXFullScreen")) boolValue];
            if (!observation.minimized && !observation.fullscreen && frames.count == windows.count && matchingAX == 1 && matchingCG == 0 && !assumedVisible && CACurrentMediaTime() < record.placementVisibilityDeadline) unmatched = YES;
            observation.focused = application.active && focused && CFEqual((__bridge CFTypeRef)focused, element);
            copyUTF8(observation.bundle, sizeof(observation.bundle), application.bundleIdentifier);
            NSString *title = attribute(element, kAXTitleAttribute);
            observation.title_complete = copyUTF8(observation.title, sizeof(observation.title), [title isKindOfClass:NSString.class] ? title : @"");
            record.observation = observation;
            [seen addObject:@(observation.identity)];
        }
        if (readTimedOut) {
            // The application stopped answering partway, usually while it launches or is busy. Keep its records as they
            // are: the windows not reached are unknown, not gone.
            NSUInteger count = timeoutCounts[process].unsignedIntegerValue + 1;
            timeoutCounts[process] = @(count);
            if (count >= 2) timeoutRetryTimes[process] = @(CACurrentMediaTime() + MIN(30.0, 0.5 * (double)(1u << MIN(count - 2, (NSUInteger)6))));
            if (onlyProcess) processScanRetryTime = CACurrentMediaTime() + 0.05;
            CFRelease(appElement); continue;
        }
        NSIndexSet *removed = [records indexesOfObjectsPassingTest:^BOOL(WindowRecord *record, NSUInteger index, BOOL *stop) {
            (void)index; (void)stop;
            if (record.observation.pid != application.processIdentifier || [seen containsObject:@(record.observation.identity)]) return NO;
            CFTypeRef role = NULL, minimized = NULL;
            AXError roleResult = AXUIElementCopyAttributeValue(record.element, kAXRoleAttribute, &role);
            AXError minimizedResult = AXUIElementCopyAttributeValue(record.element, kAXMinimizedAttribute, &minimized);
            BOOL destroyed = roleResult == kAXErrorInvalidUIElement || minimizedResult == kAXErrorInvalidUIElement;
            if (roleResult == kAXErrorSuccess && role && !CFEqual(role, kAXWindowRole)) destroyed = YES;
            WMWindow observation = record.observation;
            observation.stale = true; observation.onscreen = false; observation.focused = false;
            if (minimizedResult == kAXErrorSuccess && minimized && CFGetTypeID(minimized) == CFBooleanGetTypeID()) observation.minimized = CFBooleanGetValue(minimized);
            record.observation = observation;
            record.animationDuration = 0; record.motion = WMMotionIdle;
            if (role) CFRelease(role);
            if (minimized) CFRelease(minimized);
            return destroyed;
        }];
        [records removeObjectsAtIndexes:removed];
        CFRelease(appElement);
    }
    NSIndexSet *dead = [records indexesOfObjectsPassingTest:^BOOL(WindowRecord *record, NSUInteger index, BOOL *stop) { (void)index; (void)stop; return ![livePids containsObject:@(record.observation.pid)]; }];
    [records removeObjectsAtIndexes:dead];
    for (NSNumber *process in observers.allKeys) if (![livePids containsObject:process]) { AXObserverRef observer = [observers[process] pointerValue]; CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes); CFRelease(observer); [observers removeObjectForKey:process]; }
    for (NSNumber *process in applications.allKeys) if (![livePids containsObject:process]) { [applications removeObjectForKey:process]; forgetTimeouts(process.intValue); }
    if (!onlyProcess) initialScanComplete = YES;
    return !unmatched;
}

static void scanWindows(pid_t onlyProcess) {
    // AX can reflect our placement before WindowServer publishes the matching CG bounds.
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        if (attempt) usleep(10000);
        if (scanWindowSnapshot(onlyProcess)) break;
    }
}

bool platform_session_attributes(uint64_t identity, HuenSessionAttributes *output) {
    for (WindowRecord *record in records) if (record.observation.identity == identity && !record.observation.stale && !record.observation.minimized && !record.observation.fullscreen) {
        return huen_session_identify(record.element, record.observation.pid, output);
    }
    return false;
}

bool platform_input_rect_unobscured(uint32_t window_id, WMRect frame) {
    if (!window_id || !inputWindowOrdering) return false;
    CGRect target = CGRectMake(frame.left, frame.top, frame.width, frame.height);
    for (NSDictionary *front in inputWindowOrdering) {
        if ([front[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == window_id) return true;
        if ([front[(__bridge NSString *)kCGWindowOwnerPID] intValue] == getpid() || [front[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= 0) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)front[(__bridge NSString *)kCGWindowBounds], &bounds)) return false;
        if (CGRectIntersectsRect(target, bounds)) return false;
    }
    return false;
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
    if (commandScanNeeded || CACurrentMediaTime() - lastScan > 2) {
        dirty = NO; commandScanNeeded = NO;
        lastScan = CACurrentMediaTime();
        scanningForCommand = YES;
        scanWindows(0);
        scanningForCommand = NO;
    }
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

// A command does not scan again after its own writes, so a window it has just placed keeps its last observation.
// Windows of one application parked on the same corner are observed as not on screen, because their frames are equal.
// Mark a placed window as on screen, or it would be ineligible for focus and layout until the next scan.
static void assumeOnscreen(WindowRecord *record) { WMWindow observation = record.observation; observation.onscreen = true; record.observation = observation; }

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
            if (intent == WMFrameIntentVerifiedPlacement) assumeOnscreen(record);
            return true;
        }
        record.motion = WMMotionIdle;
        record.target = frame; record.changed = YES;
        if (duration <= 0) {
            record.animationDuration = 0;
            BOOL applied = writeFrame(record, frame, YES);
            if (applied && intent == WMFrameIntentVerifiedPlacement) assumeOnscreen(record);
            return applied;
        }
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

static void revealLaunchedApplication(void) {
    NSRunningApplication *application = revealApplication;
    if (!application) return;
    revealApplication = nil;
    if (application.terminated) return;
    // NSRunningApplication can refuse to activate another application from the background, so also ask through AX.
    AXUIElementRef appElement = AXUIElementCreateApplication(application.processIdentifier);
    AXUIElementSetMessagingTimeout(appElement, 0.08);
    AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute, kCFBooleanFalse);
    [application unhide];
    [application activateWithOptions:0];
    AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute, kCFBooleanTrue);
    CFRelease(appElement);
    for (WindowRecord *record in records) if (record.observation.pid == application.processIdentifier) {
        AXUIElementPerformAction(record.element, kAXRaiseAction);
        AXUIElementSetAttributeValue(record.element, kAXMainAttribute, kCFBooleanTrue);
        break;
    }
    requestSettleScans(application.processIdentifier);
}
static void revealWhenPlaced(void) {
    if (!revealApplication) return;
    if (revealApplication.terminated || CACurrentMediaTime() > revealDeadline) { revealLaunchedApplication(); return; }
    for (WindowRecord *record in records) if (record.observation.pid == revealApplication.processIdentifier && record.target.width > 0) {
        // Show the application when its window is at the frame we asked for. A launching application can still override
        // or adjust that frame, so stop waiting 150 ms after the first placement.
        double now = CACurrentMediaTime();
        if (!revealPlacementTime) revealPlacementTime = now;
        WMRect actual;
        if ((readFrame(record.element, &actual) && framesNear(actual, record.target, 2)) || now - revealPlacementTime > 0.15) { revealLaunchedApplication(); return; }
    }
}

static WMLaunchStatus launchStatus;
uint64_t platform_launch(const char *bundle, bool new_instance, bool hidden) {
    NSString *identifier = [NSString stringWithUTF8String:bundle];
    NSURL *url = nil;
    for (NSRunningApplication *application in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
        if (!application.terminated && application.bundleURL && [NSFileManager.defaultManager fileExistsAtPath:application.bundleURL.path]) {
            url = application.bundleURL;
            break;
        }
    }
    // Hiding applies to a new process only. It must not hide an application that already shows windows.
    BOOL hide = hidden && (new_instance || !url);
    if (!url) url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier];
    if (!url) return 0;
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = new_instance;
    configuration.activates = YES;
    configuration.hides = hide;
    uint64_t requestID = launchStatus.request_id + 1;
    launchStatus = (WMLaunchStatus){ .request_id = requestID, .state = 1 };
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration completionHandler:^(NSRunningApplication *application, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (launchStatus.request_id != requestID) return;
            launchStatus.state = error || !application ? 3 : 2;
            copyUTF8(launchStatus.message, sizeof(launchStatus.message), error.localizedDescription ?: @"");
            if (hide && application && !error) {
                revealLaunchedApplication();
                revealApplication = application;
                revealPlacementTime = 0;
                revealDeadline = CACurrentMediaTime() + 1.0;
                requestSettleScans(application.processIdentifier);
            }
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
        markChanged();
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

static void scanAndTick(pid_t process) {
    lastProcessScan = CACurrentMediaTime();
    if (!process) { dirty = NO; commandScanNeeded = NO; lastScan = lastProcessScan; }
    platform_settle_budget_begin();
    scanWindows(process);
    wm_tick();
    revealWhenPlaced();
}

static NSRect cocoaRect(WMRect frame) { return NSMakeRect(frame.left, CGDisplayBounds(CGMainDisplayID()).size.height - frame.top - frame.height, frame.width, frame.height); }
// macOS 26 centers the close button on the window corner's arc, so its offset from the top-left is the corner radius:
// 16 for a title bar, 20 for a compact toolbar, 26 for a unified toolbar. Earlier releases use one fixed radius.
static double windowCornerRadius(WindowRecord *record, WMRect frame) {
    if (record.cornerRadius > 0) return record.cornerRadius;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26) return record.cornerRadius = 10;
    id button = attribute(record.element, kAXCloseButtonAttribute);
    WMRect bounds;
    if (!button || CFGetTypeID((__bridge CFTypeRef)button) != AXUIElementGetTypeID() || !readFrame((__bridge AXUIElementRef)button, &bounds)) return 16;
    double offset = MIN(bounds.top + bounds.height / 2 - frame.top, bounds.left + bounds.width / 2 - frame.left);
    return record.cornerRadius = MIN(MAX(offset, 10), 26);
}

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
    // The layer draws its border inside its bounds, so the outer radius grows by the width to keep the inner edge on the window's arc.
    borderPanel.contentView.layer.cornerRadius = windowCornerRadius(focused, frame) + width;
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
    platform_settle_budget_begin();
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
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(identity), NULL, &identity) == noErr && identity.id < 256 && hotkeyRefs[identity.id]) { platform_settle_budget_begin(); wm_command(currentBindings[identity.id].command); }
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
            writeFrame(record, record.original, YES);
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
void platform_config_changed(void) { markChanged(); }
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
        if ([verb isEqualToString:@"--help"] || [verb isEqualToString:@"help"]) { puts("huen-wm start [--config PATH] [--app BUNDLE_ID]\nhuen-wm doctor | validate [--config PATH]\nhuen-wm status | windows | monitors | workspaces\nhuen-wm focus [--wrap] left|right|up|down | focus last\nhuen-wm focus-monitor|send-to-monitor|move-to-monitor MONITOR\nhuen-wm move-workspace-to-monitor|swap-monitor-workspaces MONITOR\nMONITOR: left | right | up | down | next | previous | built-in | external | name:NAME\nhuen-wm cycle next|previous [tiled|floating]\nhuen-wm swap left|right|up|down|next|previous\nhuen-wm move left|right|up|down | resize DELTA\nhuen-wm resize width|height DELTA\nhuen-wm center | move-by DX DY | resize-by DX DY\nhuen-wm split horizontal|vertical|toggle | fullscreen\nhuen-wm toggle-floating | layout dwindle|master\nhuen-wm workspace|send-to-workspace|move-to-workspace SELECTOR\nSELECTOR: INDEX | name:NAME | previous | +N | -N | occupied+N | occupied-N | empty | next-empty\nhuen-wm mode NAME | launch [--new-instance] BUNDLE\nhuen-wm exec-and-forget SHELLTEXT\nhuen-wm close [--quit-if-last-window]\nhuen-wm reload | restore | recover | stop | quit\nWorkspace parking is reversible during a live session. Hard-kill recovery is not guaranteed."); return 0; }
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
        records = [NSMutableArray array]; observers = [NSMutableDictionary dictionary]; applications = [NSMutableDictionary dictionary]; timeoutCounts = [NSMutableDictionary dictionary]; timeoutRetryTimes = [NSMutableDictionary dictionary];
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
        __block double lastConfigCheck = 0; __block struct timespec lastModified = {0};
        // AX observers exist only for applications seen by an earlier scan, so launches need their own signal.
        NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
        for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification, NSWorkspaceDidUnhideApplicationNotification]) {
            [workspaceCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                NSRunningApplication *subject = notification.userInfo[NSWorkspaceApplicationKey];
                requestSettleScans(subject ? subject.processIdentifier : 0);
            }];
        }
        [workspaceCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            NSRunningApplication *activated = notification.userInfo[NSWorkspaceApplicationKey];
            if (activated) forgetTimeouts(activated.processIdentifier);
            dirty = YES;
        }];
        // Neither event reaches an AX observer: a terminated application's windows go away, and a native Space change
        // changes which windows WindowServer lists.
        [workspaceCenter addObserverForName:NSWorkspaceDidTerminateApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { (void)notification; markChanged(); }];
        [workspaceCenter addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { (void)notification; markChanged(); }];
        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timerValue) {
            (void)timerValue;
            platform_settle_budget_begin();
            wm_config_poll();
            if (interrupted) platform_quit();
            wm_input_poll();
            double now = CACurrentMediaTime();
            revealWhenPlaced();
            BOOL settling = now < settleScanDeadline;
            // Slightly under three 60 Hz ticks, so settle scans of every application run every 50 ms instead of every fourth tick.
            if ((dirty && now - lastScan > 0.15) || (settling && !settleProcess && now - lastScan > 0.045) || now - lastScan > 2) scanAndTick(0);
            else if (settling && settleProcess && now - lastProcessScan > 0.012 && now > processScanRetryTime) scanAndTick(settleProcess);
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
                BOOL applied = writeFrame(record, (WMRect){start.left + (target.left - start.left) * eased, start.top + (target.top - start.top) * eased, start.width + (target.width - start.width) * eased, start.height + (target.height - start.height) * eased}, progress >= 1);
                if (!applied || progress >= 1) {
                    WMRect actual;
                    record.motion = !applied || !readFrame(record.element, &actual) || !framesNear(actual, target, 2) ? WMMotionRejected : WMMotionIdle;
                    record.animationDuration = 0;
                    markChanged();
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
                    platform_settle_budget_begin();
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
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes]; serviceActive = YES; [NSApp run]; serviceActive = NO; [timer invalidate];
        close(serverSocket); unlink(socketPath.fileSystemRepresentation); close(lockDescriptor); return 0;
    }
}
