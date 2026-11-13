#ifndef HUEN_INTERACTION_H
#define HUEN_INTERACTION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HUEN_INPUT_MAX_HITS 4096
#define HUEN_GROUPS_MAX_ITEMS 2046
#define HUEN_GROUPS_MAX_PANELS 1024
#define HUEN_GROUP_TITLE_BYTES 256

typedef struct { double left, top, width, height; } HuenInteractionRect;
typedef struct { double left, top; } HuenInteractionPoint;
typedef struct { uint32_t slot; uint64_t generation; } HuenNodeRef;

typedef enum {
    HuenHitTile = 1,
    HuenHitBoundary = 2,
    HuenHitHeader = 3,
} HuenHitKind;

typedef struct {
    HuenHitKind kind;
    HuenInteractionRect rect;
    HuenNodeRef node;
    HuenNodeRef group;
    HuenNodeRef boundary;
    uint64_t window_identity;
    uint32_t window_id;
} HuenHitRegion;

typedef struct {
    uint64_t generation;
    const HuenHitRegion *hits;
    size_t hit_count;
    bool ready;
    bool transitioning;
} HuenInputSnapshot;

typedef enum {
    HuenInputDisabled,
    HuenInputAvailable,
    HuenInputPermissionDenied,
    HuenInputTapUnavailable,
    HuenInputStopping,
} HuenInputAvailability;

typedef enum {
    HuenInteractionStart = 1,
    HuenInteractionUpdate,
    HuenInteractionEnd,
    HuenInteractionCancel,
    HuenInteractionGroupSelect,
} HuenInteractionEventKind;

typedef enum {
    HuenGestureNone,
    HuenGestureReorder,
    HuenGestureResize,
} HuenGestureKind;

typedef enum {
    HuenCancelNone,
    HuenCancelPublication,
    HuenCancelModifiers,
    HuenCancelEscape,
    HuenCancelTapDisabled,
    HuenCancelPermission,
    HuenCancelConfiguration,
    HuenCancelShutdown,
} HuenCancelReason;

typedef struct {
    HuenInteractionEventKind kind;
    HuenGestureKind gesture;
    HuenCancelReason reason;
    uint64_t generation;
    uint64_t gesture_id;
    uint64_t monotonic_ns;
    HuenHitRegion target;
    HuenInteractionPoint origin;
    HuenInteractionPoint point;
    bool crossed_threshold;
} HuenInteractionEvent;

typedef struct {
    uint64_t generation;
    HuenNodeRef group;
    HuenNodeRef child;
    uint64_t window_identity;
    uint32_t window_id;
    HuenInteractionRect rect;
    char title[HUEN_GROUP_TITLE_BYTES];
    bool selected;
    bool eligible;
} HuenHeaderItem;

typedef struct {
    uint64_t generation;
    const HuenHeaderItem *items;
    size_t item_count;
    uint32_t border_color;
    double border_width;
} HuenHeaderPresentation;

typedef enum {
    HuenPreviewInsertion = 1,
    HuenPreviewResize,
} HuenPreviewKind;

typedef struct {
    uint64_t generation;
    HuenPreviewKind kind;
    HuenInteractionRect rect;
    uint32_t border_color;
    double border_width;
} HuenInteractionPreview;

HuenInputAvailability huen_input_configure(bool enabled, uint32_t carbon_modifiers);
HuenInputAvailability huen_input_status(void);
bool huen_input_publish(const HuenInputSnapshot *snapshot);
bool huen_input_poll(HuenInteractionEvent *event);
void huen_input_stop(void);
bool huen_input_stop_ready(void);
bool huen_input_finish_stop(bool force);
bool huen_groups_publish(const HuenHeaderPresentation *presentation);
void huen_groups_preview(const HuenInteractionPreview *preview);
void huen_groups_clear(void);

#ifdef HUEN_INTERACTION_INTERNAL
bool huen_input_generation_ready(uint64_t generation);
bool huen_input_select_header(const HuenHeaderItem *item);
void huen_groups_invalidate(uint64_t generation);
#endif

#endif
