#pragma once
#include <stdbool.h>
#include <stdint.h>

/* One listen-only session tap. It needs Input Monitoring, never prompts for it, and never delays an event. */
bool huen_observe_start(void);
bool huen_observe_active(void);
void huen_observe_stop(void);
/* Provided by the platform: key is a virtual key code and modifiers a Carbon modifier mask. */
extern void platform_hotkey_pressed(uint32_t key, uint32_t modifiers);
