#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "session.h"
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
typedef struct { double left, top, width, height; } WMRect;
typedef enum { WMFrameIntentVisibleGoal = 0, WMFrameIntentVerifiedPlacement = 1 } WMFrameIntent;
typedef enum { WMMotionIdle, WMMotionAnimating, WMMotionRejected } WMMotionState;
typedef struct { uint64_t identity; int pid; WMRect frame; WMMotionState motion; bool minimized, fullscreen, focused, stale, onscreen, title_complete, hit_eligible; uint32_t public_window_id; char bundle[256], title[512]; } WMWindow;
typedef struct { uint32_t identity; WMRect frame; WMRect full_bounds; char name[128]; bool built_in; } WMDisplay;
typedef struct { double left; double top; } WMPoint;
bool platform_pointer(WMPoint *point);
bool platform_warp_pointer(WMPoint point);
typedef struct { uint32_t key, modifiers; char command[128]; } WMBinding;
typedef struct { char title[80], command[128]; bool checked, enabled; } WMStatusRow;
typedef struct { char title[160], tooltip[256]; size_t row_count; WMStatusRow rows[12]; } WMStatusPresentation;
/* Synchronous main-thread copy. NULL disables. Strings are terminated UTF-8; row_count <= 12. */
void platform_status_present(const WMStatusPresentation *presentation);
int platform_main(int argc, char **argv);
lua_State *platform_lua_open(void);
size_t platform_windows(WMWindow *output, size_t capacity);
size_t platform_refresh_windows(WMWindow *output, size_t capacity);
bool platform_session_attributes(uint64_t identity, HuenSessionAttributes *output);
bool platform_input_rect_unobscured(uint32_t window_id, WMRect frame);
size_t platform_displays(WMDisplay *output, size_t capacity);
bool platform_frame(uint64_t identity, WMRect frame, double duration, WMFrameIntent intent);
bool platform_read_frame(uint64_t identity, WMRect *frame);
bool platform_focus(uint64_t identity);
uint64_t platform_focused_window(void);
uint64_t platform_launch(const char *bundle, bool new_instance);
typedef struct { uint64_t request_id; int state; char message[256]; } WMLaunchStatus;
WMLaunchStatus platform_launch_status(void);
bool platform_exec(const char *shell);
bool platform_close(uint64_t identity, bool track, double *process_token);
int platform_close_state(uint64_t identity, int pid, double process_token);
void platform_close_cancel(void);
double platform_monotonic(void);
bool platform_terminate_if_empty(uint64_t identity, int pid, double process_token);
bool platform_bindings(const WMBinding *bindings, size_t count);
void platform_border(uint64_t identity, double width, uint32_t color);
void platform_quit(void);
size_t platform_restore(void);
const char *platform_config_path(void);
const char *platform_filter(void);
void platform_config_changed(void);
extern bool wm_initialize(const char *path);
extern bool wm_activate_config(void);
extern void wm_config_poll(void);
extern void wm_tick(void);
extern void wm_input_poll(void);
extern const char *wm_command(const char *command);
extern bool wm_shutdown(void);
