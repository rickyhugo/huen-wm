#ifndef HUEN_SCENE_H
#define HUEN_SCENE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*HuenSceneReady)(void *context, bool covered);

// All calls and callbacks use the main thread. Permission is never requested.
bool huen_scene_capture_allowed(void);

// A nonnull callback runs exactly once, possibly before begin returns. Keep context
// alive until callback returns. Replacement, cancel, early finish, and timeout
// settle pending callbacks with false. Cancel invokes that callback before returning;
// stale capture completions never call it again or access context.
// A true result follows an AppKit display, CA flush, and run-loop timer, not proof of scanout.
void huen_scene_begin(uint32_t display_id, uint64_t generation,
                      double duration_seconds, HuenSceneReady callback, void *context);

// Only the matching generation fades. Duration is clamped to 0..0.5 seconds.
void huen_scene_finish(uint64_t generation);
void huen_scene_cancel(void);

#ifdef __cplusplus
}
#endif

#endif
