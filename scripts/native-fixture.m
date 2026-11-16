#import <Cocoa/Cocoa.h>

static NSDictionary *AXFrame(NSRect frame, CGFloat referenceHeight) {
    return @{
        @"left": @(NSMinX(frame)),
        @"top": @(referenceHeight - NSMaxY(frame)),
        @"width": @(NSWidth(frame)),
        @"height": @(NSHeight(frame))
    };
}

@interface HuenFixtureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, copy) NSArray<NSWindow *> *windows;
@property(nonatomic, copy) NSString *reportPath;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL spread;
@property(nonatomic) NSUInteger windowCount;
@property(nonatomic, copy) NSString *identifierMode;
@property(nonatomic, strong) id mouseMonitor;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *mouseEventCounts;
@property(nonatomic, copy) NSDictionary *lastMouseEvent;
@end

@implementation HuenFixtureDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *applicationItem = [[NSMenuItem alloc] init];
    NSMenu *applicationMenu = [[NSMenu alloc] init];
    [applicationMenu addItemWithTitle:@"Quit HuenFixture"
                              action:@selector(terminate:)
                       keyEquivalent:@"q"];
    applicationItem.submenu = applicationMenu;
    [mainMenu addItem:applicationItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    [mainMenu addItem:fileItem];
    NSApp.mainMenu = mainMenu;

    NSArray<NSString *> *names = @[@"Alpha", @"Beta", @"Gamma", @"Delta",
                                   @"Epsilon", @"Zeta", @"Eta", @"Theta"];
    NSMutableArray<NSWindow *> *windows = [[NSMutableArray alloc] initWithCapacity:self.windowCount];
    for (NSUInteger windowIndex = 0; windowIndex < self.windowCount; windowIndex += 1) {
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(100 + windowIndex * 90, 180 + windowIndex * 60, 520, 340)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = [@"Huen Fixture " stringByAppendingString:names[windowIndex]];
        window.accessibilityIdentifier = [self.identifierMode isEqualToString:@"unique"]
            ? [@"dev.huen-wm.fixture." stringByAppendingString:names[windowIndex].lowercaseString]
            : ([self.identifierMode isEqualToString:@"duplicate"] ? @"dev.huen-wm.fixture.duplicate" : nil);
        window.releasedWhenClosed = NO;
        window.contentMinSize = NSMakeSize(240, 160);
        if (self.spread) {
            NSArray<NSScreen *> *screens = [NSScreen screens];
            NSScreen *screen = screens[(windowIndex == 2 && screens.count > 1) ? 1 : 0];
            NSRect visibleFrame = screen.visibleFrame;
            NSUInteger offsetIndex = screens.count > 1 ? windowIndex % 2 : windowIndex;
            [window setFrameOrigin:NSMakePoint(NSMinX(visibleFrame) + 80 + offsetIndex * 100,
                                               NSMinY(visibleFrame) + 100 + offsetIndex * 60)];
        }
        [windows addObject:window];
        [window makeKeyAndOrderFront:nil];
    }
    self.windows = windows;
    if (self.reportPath) {
        NSDictionary<NSNumber *, NSString *> *eventNames = @{
            @(NSEventTypeLeftMouseDown): @"left_down", @(NSEventTypeLeftMouseUp): @"left_up",
            @(NSEventTypeLeftMouseDragged): @"left_drag", @(NSEventTypeRightMouseDown): @"right_down",
            @(NSEventTypeRightMouseUp): @"right_up", @(NSEventTypeRightMouseDragged): @"right_drag"
        };
        self.mouseEventCounts = [[NSMutableDictionary alloc] init];
        for (NSString *eventName in eventNames.allValues) {
            self.mouseEventCounts[eventName] = @0;
        }
        __weak HuenFixtureDelegate *weakDelegate = self;
        self.mouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
            NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged |
            NSEventMaskRightMouseDown | NSEventMaskRightMouseUp | NSEventMaskRightMouseDragged
            handler:^NSEvent *(NSEvent *event) {
                HuenFixtureDelegate *delegate = weakDelegate;
                if (delegate) {
                    NSString *eventName = eventNames[@(event.type)];
                    delegate.mouseEventCounts[eventName] =
                        @(delegate.mouseEventCounts[eventName].unsignedLongLongValue + 1);
                    NSPoint location = event.window
                        ? [event.window convertPointToScreen:event.locationInWindow] : event.locationInWindow;
                    delegate.lastMouseEvent = @{
                        @"type": eventName,
                        @"position": @{@"left": @(location.x),
                                       @"top": @(NSHeight([NSScreen screens].firstObject.frame) - location.y)},
                        @"modifiers": @(event.modifierFlags),
                        @"time": @(event.timestamp)
                    };
                    [delegate writeReport:nil];
                }
                return event;
            }];
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        NSArray<NSNotificationName> *windowNotifications = @[
            NSWindowDidMoveNotification,
            NSWindowDidResizeNotification,
            NSWindowDidBecomeKeyNotification,
            NSWindowDidResignKeyNotification,
            NSWindowDidMiniaturizeNotification,
            NSWindowDidDeminiaturizeNotification,
            NSWindowWillCloseNotification
        ];
        for (NSNotificationName notificationName in windowNotifications) {
            [notificationCenter addObserver:self selector:@selector(windowChanged:)
                                       name:notificationName object:nil];
        }
        [notificationCenter addObserver:self selector:@selector(writeReport:)
                                   name:NSApplicationDidChangeScreenParametersNotification object:nil];
        [notificationCenter addObserver:self selector:@selector(writeReport:)
                                   name:NSApplicationDidBecomeActiveNotification object:NSApp];
        [notificationCenter addObserver:self selector:@selector(writeReport:)
                                   name:NSApplicationDidResignActiveNotification object:NSApp];
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver:self selector:@selector(writeReport:)
                   name:NSWorkspaceDidActivateApplicationNotification object:nil];
    }
    [NSApp activateIgnoringOtherApps:YES];
    if (self.spread) {
        [self.windows.firstObject makeKeyAndOrderFront:nil];
    }
    self.ready = YES;
    [self writeReport:nil];
}

- (void)windowChanged:(NSNotification *)notification {
    if (![self.windows containsObject:notification.object]) {
        return;
    }
    if ([notification.name isEqualToString:NSWindowWillCloseNotification]) {
        NSMutableArray<NSWindow *> *remainingWindows = [self.windows mutableCopy];
        [remainingWindows removeObject:notification.object];
        self.windows = remainingWindows;
    }
    [self writeReport:nil];
}

- (void)writeReport:(NSNotification *)notification {
    (void)notification;
    if (!self.reportPath) {
        return;
    }
    NSArray<NSScreen *> *screens = [NSScreen screens];
    CGFloat referenceHeight = NSHeight(screens.firstObject.frame);
    NSMutableArray<NSDictionary *> *windowReports = [[NSMutableArray alloc] init];
    for (NSWindow *window in self.windows) {
        [windowReports addObject:@{
            @"title": window.title,
            @"identifier": window.accessibilityIdentifier ?: [NSNull null],
            @"window_number": @(window.windowNumber),
            @"frame": AXFrame(window.frame, referenceHeight),
            @"minimized": @(window.miniaturized),
            @"key": @(window.keyWindow),
            @"visible": @(window.visible)
        }];
    }
    NSMutableArray<NSDictionary *> *screenReports = [[NSMutableArray alloc] init];
    for (NSScreen *screen in screens) {
        [screenReports addObject:@{@"visible_frame": AXFrame(screen.visibleFrame, referenceHeight),
                                  @"full_bounds": AXFrame(screen.frame, referenceHeight)}];
    }
    NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
    NSDictionary *report = @{
        @"ready": @(self.ready),
        @"process_id": @([NSProcessInfo processInfo].processIdentifier),
        @"application_active": @(NSApp.active),
        @"frontmost_bundle": frontmostApplication.bundleIdentifier ?: [NSNull null],
        @"frontmost_pid": frontmostApplication ? @(frontmostApplication.processIdentifier) : [NSNull null],
        @"window_count": @(self.windowCount),
        @"identifier_mode": self.identifierMode,
        @"mouse_events": self.mouseEventCounts,
        @"last_mouse_event": self.lastMouseEvent ?: [NSNull null],
        @"windows": windowReports,
        @"screens": screenReports
    };
    NSError *error = nil;
    NSData *reportData = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
    if (!reportData || ![reportData writeToFile:self.reportPath options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "HuenFixture: cannot write report to %s: %s\n",
                self.reportPath.fileSystemRepresentation, error.localizedDescription.UTF8String);
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return YES;
}

@end

int main(void) {
    @autoreleasepool {
        NSString *reportPath = nil;
        NSUInteger windowCount = 0;
        NSString *identifierMode = nil;
        BOOL spread = NO;
        NSArray<NSString *> *arguments = [NSProcessInfo processInfo].arguments;
        for (NSUInteger argumentIndex = 1; argumentIndex < arguments.count; argumentIndex += 1) {
            if ([arguments[argumentIndex] isEqualToString:@"--spread"]) {
                spread = YES;
                continue;
            }
            if ([arguments[argumentIndex] isEqualToString:@"--windows"]) {
                argumentIndex += 1;
                NSInteger parsedCount = 0;
                NSScanner *scanner = argumentIndex < arguments.count
                    ? [NSScanner scannerWithString:arguments[argumentIndex]] : nil;
                scanner.charactersToBeSkipped = nil;
                if (windowCount || ![scanner scanInteger:&parsedCount] || !scanner.atEnd ||
                    parsedCount < 1 || parsedCount > 8) {
                    fprintf(stderr, "HuenFixture: expected --windows <1..8> once\n");
                    return 2;
                }
                windowCount = (NSUInteger)parsedCount;
                continue;
            }
            if ([arguments[argumentIndex] isEqualToString:@"--identifiers"]) {
                argumentIndex += 1;
                if (identifierMode || argumentIndex == arguments.count ||
                    ![@[@"unique", @"duplicate", @"none"] containsObject:arguments[argumentIndex]]) {
                    fprintf(stderr, "HuenFixture: expected --identifiers <unique|duplicate|none> once\n");
                    return 2;
                }
                identifierMode = arguments[argumentIndex];
                continue;
            }
            if (![arguments[argumentIndex] isEqualToString:@"--report"]) {
                continue;
            }
            argumentIndex += 1;
            if (reportPath || argumentIndex == arguments.count || !arguments[argumentIndex].absolutePath) {
                fprintf(stderr, "HuenFixture: expected --report <absolute-path> once\n");
                return 2;
            }
            reportPath = arguments[argumentIndex];
        }
        NSApplication *application = [NSApplication sharedApplication];
        HuenFixtureDelegate *delegate = [[HuenFixtureDelegate alloc] init];
        delegate.reportPath = reportPath;
        delegate.spread = spread;
        delegate.windowCount = windowCount ?: 3;
        delegate.identifierMode = identifierMode ?: @"none";
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
