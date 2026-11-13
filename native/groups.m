#define HUEN_INTERACTION_INTERNAL
#import "interaction.h"

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <string.h>

@interface HuenInteractionPanel : NSPanel
@end

@implementation HuenInteractionPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface HuenHeaderButton : NSButton {
    HuenHeaderItem _pressedItem;
    BOOL _tracking;
}
@property(nonatomic) HuenHeaderItem item;
@property(nonatomic) BOOL available;
- (void)selectHeader:(id)sender;
@end

@implementation HuenHeaderButton
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}
- (void)mouseDown:(NSEvent *)event {
    __attribute__((objc_precise_lifetime)) HuenHeaderButton *trackingButton = self;
    trackingButton->_pressedItem = self.item;
    trackingButton->_tracking = YES;
    [super mouseDown:event];
    trackingButton->_tracking = NO;
}
- (void)selectHeader:(id)sender {
    (void)sender;
    if (!self.available) return;
    HuenHeaderItem selectedItem = _tracking ? _pressedItem : self.item;
    huen_input_select_header(&selectedItem);
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return self.title; }
- (id)accessibilityValue { return @(self.item.selected); }
- (BOOL)accessibilityPerformPress {
    if (!self.available) return NO;
    HuenHeaderItem selectedItem = self.item;
    return huen_input_select_header(&selectedItem);
}
@end

@interface HuenHeaderRow : NSObject
@property(nonatomic) NSRect frame;
@property(nonatomic) double area;
@property(nonatomic, strong) NSMutableArray<NSValue *> *items;
@end

@implementation HuenHeaderRow
@end

static NSMutableArray<HuenInteractionPanel *> *headerPanels;
static HuenInteractionPanel *previewPanel;
static uint64_t headerGeneration;

static void require_main_thread(void) {
    NSCAssert(NSThread.isMainThread, @"Group calls require the main thread");
}

static bool valid_rect(HuenInteractionRect rect) {
    return isfinite(rect.left) && isfinite(rect.top) && isfinite(rect.width) &&
           isfinite(rect.height) && rect.width > 0 && rect.height > 0 &&
           isfinite(rect.left + rect.width) && isfinite(rect.top + rect.height);
}

static NSRect cocoa_rect(HuenInteractionRect rect) {
    double primaryTop = CGDisplayBounds(CGMainDisplayID()).size.height;
    return NSMakeRect(rect.left, primaryTop - rect.top - rect.height, rect.width, rect.height);
}

static NSColor *border_color(uint32_t color, CGFloat alpha) {
    return [NSColor colorWithRed:((color >> 16) & 255) / 255.0
        green:((color >> 8) & 255) / 255.0 blue:(color & 255) / 255.0 alpha:alpha];
}

static HuenInteractionPanel *new_panel(bool mouseEnabled) {
    HuenInteractionPanel *panel = [[HuenInteractionPanel alloc]
        initWithContentRect:NSZeroRect
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed = NO;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = NO;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.ignoresMouseEvents = !mouseEnabled;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.accessibilityElement = mouseEnabled;
    return panel;
}

static HuenHeaderButton *new_header_button(void) {
    HuenHeaderButton *button = [[HuenHeaderButton alloc] initWithFrame:NSZeroRect];
    button.bordered = NO;
    button.buttonType = NSButtonTypeMomentaryChange;
    button.alignment = NSTextAlignmentLeft;
    button.lineBreakMode = NSLineBreakByTruncatingTail;
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    button.focusRingType = NSFocusRingTypeNone;
    button.target = button;
    button.action = @selector(selectHeader:);
    button.wantsLayer = YES;
    return button;
}

static void disable_panel_buttons(HuenInteractionPanel *panel) {
    for (HuenHeaderButton *button in panel.contentView.subviews) button.available = NO;
}

bool huen_groups_publish(const HuenHeaderPresentation *presentation) {
    require_main_thread();
    if (!presentation || !huen_input_generation_ready(presentation->generation) ||
        presentation->item_count > HUEN_GROUPS_MAX_ITEMS ||
        (presentation->item_count && !presentation->items) ||
        !isfinite(presentation->border_width) || presentation->border_width < 0 ||
        presentation->border_width > 32) return false;
    NSMutableArray<HuenHeaderRow *> *rows = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, HuenHeaderRow *> *rowsByGroup = [NSMutableDictionary dictionary];
    for (size_t index = 0; index < presentation->item_count; index++) {
        const HuenHeaderItem *item = &presentation->items[index];
        if (item->generation != presentation->generation || !valid_rect(item->rect) ||
            item->group.generation == 0 || item->child.generation == 0 ||
            !memchr(item->title, '\0', sizeof(item->title))) return false;
        NSNumber *key = @(((uint64_t)item->group.slot << 32) | item->group.generation);
        HuenHeaderRow *row = rowsByGroup[key];
        NSRect itemFrame = cocoa_rect(item->rect);
        if (!row) {
            if (rows.count == HUEN_GROUPS_MAX_PANELS) return false;
            row = [[HuenHeaderRow alloc] init];
            row.frame = itemFrame;
            row.items = [NSMutableArray array];
            rowsByGroup[key] = row;
            [rows addObject:row];
        }
        for (NSValue *previous in row.items) {
            HuenHeaderItem previousItem;
            [previous getValue:&previousItem size:sizeof(previousItem)];
            if (NSIntersectsRect(itemFrame, cocoa_rect(previousItem.rect))) return false;
        }
        row.frame = NSUnionRect(row.frame, itemFrame);
        row.area += item->rect.width * item->rect.height;
        if (!isfinite(row.area)) return false;
        [row.items addObject:[NSValue valueWithBytes:item objCType:@encode(HuenHeaderItem)]];
    }
    for (HuenHeaderRow *row in rows) {
        double boundingArea = row.frame.size.width * row.frame.size.height;
        if (!isfinite(boundingArea) || fabs(boundingArea - row.area) > fmax(1, boundingArea) * 1e-9) return false;
    }
    if (!headerPanels) headerPanels = [NSMutableArray array];
    while (headerPanels.count > rows.count) {
        HuenInteractionPanel *panel = headerPanels.lastObject;
        disable_panel_buttons(panel);
        [panel orderOut:nil];
        [panel close];
        [headerPanels removeLastObject];
    }
    headerGeneration = presentation->generation;
    for (size_t index = 0; index < headerPanels.count; index++) {
        NSView *content = headerPanels[index].contentView;
        while (content.subviews.count > rows[index].items.count) {
            HuenHeaderButton *button = (HuenHeaderButton *)content.subviews.lastObject;
            button.available = NO;
            [button removeFromSuperview];
        }
    }
    for (size_t index = 0; index < rows.count; index++) {
        if (index == headerPanels.count) [headerPanels addObject:new_panel(true)];
        HuenHeaderRow *row = rows[index];
        HuenInteractionPanel *panel = headerPanels[index];
        NSView *content = panel.contentView;
        [panel setFrame:row.frame display:YES];
        for (size_t itemIndex = 0; itemIndex < row.items.count; itemIndex++) {
            if (itemIndex == content.subviews.count) [content addSubview:new_header_button()];
            HuenHeaderItem item;
            [row.items[itemIndex] getValue:&item size:sizeof(item)];
            HuenHeaderButton *button = (HuenHeaderButton *)content.subviews[itemIndex];
            button.item = item;
            button.available = YES;
            button.title = [[NSString alloc] initWithBytes:item.title length:strlen(item.title)
                encoding:NSUTF8StringEncoding] ?: @"Untitled";
            button.contentTintColor = item.selected ? NSColor.whiteColor :
                [NSColor colorWithWhite:0.78 alpha:1];
            button.layer.backgroundColor = item.selected ?
                border_color(presentation->border_color, 0.95).CGColor :
                [NSColor colorWithWhite:0.12 alpha:0.96].CGColor;
            button.layer.borderColor = border_color(presentation->border_color, 0.95).CGColor;
            button.layer.borderWidth = presentation->border_width;
            button.layer.cornerRadius = 3;
            button.layer.masksToBounds = YES;
            NSRect buttonFrame = cocoa_rect(item.rect);
            buttonFrame.origin.x -= row.frame.origin.x;
            buttonFrame.origin.y -= row.frame.origin.y;
            button.frame = buttonFrame;
        }
        [panel orderFrontRegardless];
    }
    return true;
}

void huen_groups_preview(const HuenInteractionPreview *preview) {
    require_main_thread();
    if (!preview || !huen_input_generation_ready(preview->generation) ||
        !valid_rect(preview->rect) || !isfinite(preview->border_width) ||
        preview->border_width <= 0 || preview->border_width > 32 ||
        (preview->kind != HuenPreviewInsertion && preview->kind != HuenPreviewResize)) {
        [previewPanel orderOut:nil];
        return;
    }
    if (!previewPanel) {
        previewPanel = new_panel(false);
        previewPanel.contentView.wantsLayer = YES;
    }
    previewPanel.contentView.layer.borderColor = border_color(preview->border_color, 0.95).CGColor;
    previewPanel.contentView.layer.borderWidth = preview->border_width;
    previewPanel.contentView.layer.cornerRadius = preview->kind == HuenPreviewInsertion ? 6 : 0;
    previewPanel.contentView.layer.backgroundColor = border_color(preview->border_color, 0.12).CGColor;
    [previewPanel setFrame:cocoa_rect(preview->rect) display:YES];
    [previewPanel orderFrontRegardless];
}

void huen_groups_invalidate(uint64_t generation) {
    require_main_thread();
    if (headerGeneration == generation && generation != 0) return;
    for (HuenInteractionPanel *panel in headerPanels) {
        disable_panel_buttons(panel);
        [panel orderOut:nil];
    }
    headerGeneration = 0;
    [previewPanel orderOut:nil];
}

void huen_groups_clear(void) {
    require_main_thread();
    for (HuenInteractionPanel *panel in headerPanels) {
        disable_panel_buttons(panel);
        [panel orderOut:nil];
        [panel close];
    }
    headerPanels = nil;
    [previewPanel orderOut:nil];
    [previewPanel close];
    previewPanel = nil;
    headerGeneration = 0;
}
