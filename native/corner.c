#include "corner.h"
#include <math.h>
#include <stdbool.h>

// A continuous corner of radius R cuts 1.0540 times the area of a circular one, R^2 * (1 - pi / 4).
// A translucent window is not opaque inside the corner either, so transparency is relative to the median alpha along the interior edges.
double huen_corner_radius(const uint8_t *alpha, size_t width, size_t height, double side) {
    if (!alpha || width < 2 || height < 2 || !isfinite(side) || !(side > 0.0)) return -1.0;
    size_t histogram[256] = {0};
    for (size_t column = 0; column < width; column++) histogram[alpha[(height - 1) * width + column]]++;
    for (size_t row = 0; row + 1 < height; row++) histogram[alpha[row * width + width - 1]]++;
    size_t samples = width + height - 1;
    size_t lowTarget = (samples - 1) / 2;
    size_t highTarget = samples / 2;
    size_t seen = 0;
    double lowMedian = 0.0;
    double highMedian = 0.0;
    bool foundLow = false;
    for (size_t value = 0; value < 256; value++) {
        seen += histogram[value];
        if (!foundLow && seen > lowTarget) { lowMedian = (double)value; foundLow = true; }
        if (seen > highTarget) { highMedian = (double)value; break; }
    }
    double inside = (lowMedian + highMedian) / 2.0;
    if (inside < 32.0) return -1.0;
    double cut = 0.0;
    size_t count = width * height;
    for (size_t index = 0; index < count; index++) {
        double missing = 1.0 - (double)alpha[index] / inside;
        if (missing > 0.0) cut += missing;
    }
    return sqrt(cut / ((1.0 - M_PI / 4.0) * 1.0540)) * side / (double)width;
}
