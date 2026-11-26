#pragma once
#include <stddef.h>
#include <stdint.h>

// Returns the continuous-corner radius in points from a row-major alpha buffer, or -1 if unmeasurable.
double huen_corner_radius(const uint8_t *alpha, size_t width, size_t height, double side);
