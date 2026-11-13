#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
typedef struct { double left, top, width, height; } WMRect;
typedef struct { uint64_t identity; int pid; WMRect frame; bool minimized, fullscreen, focused, stale, onscreen; char bundle[256], title[512]; } WMWindow;
typedef struct { uint32_t identity; WMRect frame; WMRect full_bounds; char name[128]; } WMDisplay;
typedef struct { uint32_t key, modifiers; char command[128]; } WMBinding;
int platform_main(int argc, char **argv);
lua_State *platform_lua_open(void);
size_t platform_windows(WMWindow *output, size_t capacity);
size_t platform_displays(WMDisplay *output, size_t capacity);
bool platform_frame(uint64_t identity, WMRect frame, double duration);
bool platform_read_frame(uint64_t identity, WMRect *frame);
void platform_focus(uint64_t identity);
bool platform_bindings(const WMBinding *bindings, size_t count);
void platform_border(uint64_t identity, double width, uint32_t color);
void platform_hud(const char *text);
void platform_quit(void);
size_t platform_restore(void);
const char *platform_config_path(void);
const char *platform_filter(void);
void platform_config_changed(void);
extern bool wm_initialize(const char *path);
extern bool wm_activate_config(void);
extern void wm_config_poll(void);
extern void wm_tick(void);
extern const char *wm_command(const char *command);
extern bool wm_shutdown(void);
