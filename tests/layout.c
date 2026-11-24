#include <stddef.h>
#include "platform.h"
#include "interaction.h"

/* Read by the layout case in tests/cases/layout_check.zig, which compares them with the Zig mirrors in tests/fake/abi.zig. */
const size_t huen_test_window_layout[] = {
    sizeof(WMWindow), offsetof(WMWindow, identity), offsetof(WMWindow, pid), offsetof(WMWindow, frame),
    offsetof(WMWindow, motion), offsetof(WMWindow, minimized), offsetof(WMWindow, fullscreen), offsetof(WMWindow, focused),
    offsetof(WMWindow, stale), offsetof(WMWindow, onscreen), offsetof(WMWindow, title_complete), offsetof(WMWindow, hit_eligible),
    offsetof(WMWindow, public_window_id), offsetof(WMWindow, bundle), offsetof(WMWindow, title), offsetof(WMWindow, process_token),
    offsetof(WMWindow, stack_order),
};
const size_t huen_test_window_layout_count = sizeof(huen_test_window_layout) / sizeof(huen_test_window_layout[0]);
const size_t huen_test_struct_sizes[] = {
    sizeof(WMDisplay), sizeof(WMLaunchStatus), sizeof(HuenSessionAttributes), sizeof(HuenHitRegion), sizeof(HuenInputSnapshot),
};
