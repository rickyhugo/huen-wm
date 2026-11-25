#import "scene.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <math.h>

@interface HuenScenePanel : NSPanel
@end

@implementation HuenScenePanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

typedef NS_ENUM(NSUInteger, HuenSceneState) {
    HuenSceneCapturing,
    HuenSceneCovered,
    HuenSceneFading,
    HuenSceneRetired,
};

@interface HuenSceneTransition : NSObject
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint32_t displayID;
@property(nonatomic) double duration;
@property(nonatomic) HuenSceneState state;
@property(nonatomic) HuenSceneReady callback;
@property(nonatomic) void *context;
@property(nonatomic, strong) HuenScenePanel *panel;
@end

static HuenSceneTransition *currentTransition;

@implementation HuenSceneTransition
- (void)announceCover {
    if (currentTransition != self || self.state != HuenSceneCapturing) return;
    self.state = HuenSceneCovered;
    [self settle:true];
}

- (void)settle:(bool)covered {
    HuenSceneReady callback = self.callback;
    void *context = self.context;
    self.callback = NULL;
    self.context = NULL;
    if (callback) callback(context, covered);
}
@end

static void retire_and_settle_callback(HuenSceneTransition *transition) {
    if (currentTransition == transition) currentTransition = nil;
    transition.state = HuenSceneRetired;
    [transition.panel orderOut:nil];
    [transition.panel.contentView.layer removeAllAnimations];
    transition.panel.contentView.layer.contents = nil;
    [transition.panel close];
    transition.panel = nil;
    [transition settle:false];
}

static NSScreen *screen_for_display(uint32_t displayID) {
    for (NSScreen *screen in NSScreen.screens) {
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) return screen;
    }
    return nil;
}

bool huen_scene_capture_allowed(void) {
    NSCAssert(NSThread.isMainThread, @"Scene calls require the main thread");
    return CGPreflightScreenCaptureAccess();
}

void huen_scene_begin(uint32_t display_id, uint64_t generation,
                      double duration_seconds, HuenSceneReady callback, void *context) {
    NSCAssert(NSThread.isMainThread, @"Scene calls require the main thread");
    HuenSceneTransition *transition = [[HuenSceneTransition alloc] init];
    transition.generation = generation;
    transition.displayID = display_id;
    transition.duration = isfinite(duration_seconds) ? fmin(0.5, fmax(0, duration_seconds)) : 0;
    transition.callback = callback;
    transition.context = context;
    transition.state = HuenSceneCapturing;
    HuenSceneTransition *previousTransition = currentTransition;
    currentTransition = transition;
    retire_and_settle_callback(previousTransition);
    if (currentTransition != transition) return;
    if (!huen_scene_capture_allowed() || !screen_for_display(display_id)) {
        retire_and_settle_callback(transition);
        return;
    }

    __weak HuenSceneTransition *weakTransition = transition;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (currentTransition == weakTransition) retire_and_settle_callback(currentTransition);
    });
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
        completionHandler:^(SCShareableContent *content, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (currentTransition != transition || transition.state != HuenSceneCapturing) return;
                SCDisplay *selectedDisplay = nil;
                for (SCDisplay *display in content.displays) {
                    if (display.displayID == transition.displayID) {
                        selectedDisplay = display;
                        break;
                    }
                }
                NSMutableArray<SCRunningApplication *> *excludedApplications = [NSMutableArray array];
                pid_t processID = NSProcessInfo.processInfo.processIdentifier;
                for (SCRunningApplication *application in content.applications) {
                    if (application.processID == processID) [excludedApplications addObject:application];
                }
                if (error || !content || !selectedDisplay || excludedApplications.count == 0) {
                    retire_and_settle_callback(transition);
                    return;
                }
                SCContentFilter *filter = [[SCContentFilter alloc]
                    initWithDisplay:selectedDisplay excludingApplications:excludedApplications exceptingWindows:@[]];
                CGFloat scale = filter.pointPixelScale;
                double pixelWidth = ceil(CGRectGetWidth(filter.contentRect) * scale);
                double pixelHeight = ceil(CGRectGetHeight(filter.contentRect) * scale);
                if (!isfinite(scale) || scale <= 0 || !isfinite(pixelWidth) || !isfinite(pixelHeight) ||
                    pixelWidth < 1 || pixelHeight < 1 || pixelWidth > UINT32_MAX || pixelHeight > UINT32_MAX) {
                    retire_and_settle_callback(transition);
                    return;
                }
                SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
                configuration.width = (size_t)pixelWidth;
                configuration.height = (size_t)pixelHeight;
                configuration.showsCursor = NO;
                [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                    completionHandler:^(CGImageRef image, NSError *captureError) {
                        id ownedImage = image ? CFBridgingRelease(CGImageRetain(image)) : nil;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (currentTransition != transition || transition.state != HuenSceneCapturing) return;
                            NSScreen *screen = screen_for_display(transition.displayID);
                            if (captureError || !ownedImage || !screen) {
                                retire_and_settle_callback(transition);
                                return;
                            }
                            HuenScenePanel *panel = [[HuenScenePanel alloc]
                                initWithContentRect:screen.frame
                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                backing:NSBackingStoreBuffered defer:NO];
                            panel.releasedWhenClosed = NO;
                            panel.opaque = YES;
                            panel.backgroundColor = NSColor.blackColor;
                            panel.hasShadow = NO;
                            panel.hidesOnDeactivate = NO;
                            panel.becomesKeyOnlyIfNeeded = YES;
                            panel.ignoresMouseEvents = NO;
                            panel.level = NSScreenSaverWindowLevel;
                            panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                                       NSWindowCollectionBehaviorFullScreenAuxiliary |
                                                       NSWindowCollectionBehaviorStationary |
                                                       NSWindowCollectionBehaviorIgnoresCycle;
                            panel.animationBehavior = NSWindowAnimationBehaviorNone;
                            NSView *imageView = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, screen.frame.size}];
                            CALayer *layer = [CALayer layer];
                            layer.frame = imageView.bounds;
                            imageView.layer = layer;
                            imageView.wantsLayer = YES;
                            panel.contentView = imageView;
                            [CATransaction begin];
                            [CATransaction setDisableActions:YES];
                            layer.contentsScale = scale;
                            layer.contentsGravity = kCAGravityResize;
                            layer.opaque = YES;
                            layer.contents = ownedImage;
                            [CATransaction commit];
                            transition.panel = panel;
                            [panel orderFrontRegardless];
                            [panel displayIfNeeded];
                            [CATransaction flush];
                            [transition performSelector:@selector(announceCover) withObject:nil afterDelay:0
                                               inModes:@[NSRunLoopCommonModes]];
                        });
                    }];
            });
        }];
}

void huen_scene_finish(uint64_t generation) {
    NSCAssert(NSThread.isMainThread, @"Scene calls require the main thread");
    HuenSceneTransition *transition = currentTransition;
    if (!transition || transition.generation != generation || transition.state == HuenSceneFading) return;
    if (transition.state != HuenSceneCovered || transition.duration == 0) {
        retire_and_settle_callback(transition);
        return;
    }
    transition.state = HuenSceneFading;
    transition.panel.opaque = NO;
    transition.panel.backgroundColor = NSColor.clearColor;
    CALayer *layer = transition.panel.contentView.layer;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.duration = transition.duration;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (currentTransition == transition) retire_and_settle_callback(transition);
        });
    }];
    layer.opaque = NO;
    layer.opacity = 0;
    [layer addAnimation:fade forKey:@"huen.scene.fade"];
    [CATransaction commit];
}

void huen_scene_cancel(void) {
    NSCAssert(NSThread.isMainThread, @"Scene calls require the main thread");
    retire_and_settle_callback(currentTransition);
}
