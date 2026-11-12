#pragma once
#include <stdbool.h>
#include <stddef.h>

typedef bool (*ConfigCancelled)(void *context);
int config_worker_run(const char *path, char *output, size_t capacity, size_t *used,
                      char *diagnostic, size_t diagnostic_capacity,
                      ConfigCancelled cancelled, void *context);
