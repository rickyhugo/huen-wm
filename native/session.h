#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    int32_t pid;
    uint32_t kind;
    double launch;
    char bundle[256];
    char value[2048];
    char role[128];
    char subrole[128];
} HuenSessionAttributes;

bool huen_session_identify(AXUIElementRef element, pid_t pid, HuenSessionAttributes *output);
bool huen_session_display_uuid(CGDirectDisplayID display, char *output, size_t capacity);
bool huen_session_boot_identity(char *output, size_t capacity);
/* Hash is exactly 64 lowercase hexadecimal characters. Load returns 0, missing 1, failure -1. */
int huen_session_read(const char *hash, void *output, size_t capacity, size_t *used);
bool huen_session_write(const char *hash, const void *bytes, size_t length);
