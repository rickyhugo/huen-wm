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

    NSArray<NSString *> *titles = @[@"Huen Fixture Alpha", @"Huen Fixture Beta", @"Huen Fixture Gamma"];
    NSMutableArray<NSWindow *> *windows = [[NSMutableArray alloc] initWithCapacity:titles.count];
    NSUInteger windowIndex = 0;
    for (NSString *title in titles) {
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(100 + windowIndex * 90, 180 + windowIndex * 60, 520, 340)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = title;
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
        windowIndex += 1;
    }
    self.windows = windows;
    if (self.reportPath) {
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
            @"frame": AXFrame(window.frame, referenceHeight),
            @"minimized": @(window.miniaturized),
            @"key": @(window.keyWindow),
            @"visible": @(window.visible)
        }];
    }
    NSMutableArray<NSDictionary *> *screenReports = [[NSMutableArray alloc] init];
    for (NSScreen *screen in screens) {
        [screenReports addObject:@{@"visible_frame": AXFrame(screen.visibleFrame, referenceHeight)}];
    }
    NSDictionary *report = @{
        @"ready": @(self.ready),
        @"process_id": @([NSProcessInfo processInfo].processIdentifier),
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
        BOOL spread = NO;
        NSArray<NSString *> *arguments = [NSProcessInfo processInfo].arguments;
        for (NSUInteger argumentIndex = 1; argumentIndex < arguments.count; argumentIndex += 1) {
            if ([arguments[argumentIndex] isEqualToString:@"--spread"]) {
                spread = YES;
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
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
