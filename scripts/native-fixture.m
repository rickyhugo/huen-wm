#import <Cocoa/Cocoa.h>

@interface HuenFixtureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSArray<NSWindow *> *windows;
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
        [windows addObject:window];
        [window makeKeyAndOrderFront:nil];
        windowIndex += 1;
    }
    self.windows = windows;
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return YES;
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        HuenFixtureDelegate *delegate = [[HuenFixtureDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
