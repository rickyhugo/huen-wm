# macOS integration limits

huen-wm targets normal SIP-enabled macOS installations.
Its core window operations use public Accessibility APIs.

## Window control

Accessibility lets a process enumerate application windows and request changes to their position, size, and focus.
Applications can reject these requests or enforce minimum sizes.
A successful request does not prove that the resulting frame matches the requested frame.

Window identity must not depend on the private `_AXUIElementGetWindow` function.
The native adapter retains Accessibility objects and assigns internal window identities.

## Workspaces

huen-wm workspaces are separate from native macOS Spaces.
Inactive windows need a reversible visibility strategy.
Application hiding is unsuitable because it hides every window in an application.

[AeroSpace documents offscreen workspace emulation](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces).
That approach has display-layout and Mission Control limitations.
Recovery and restoration must be part of the workspace implementation.

## Appearance

Hyprland controls composition on Wayland.
huen-wm requests window changes from other applications on macOS.
Repeated Accessibility writes do not provide compositor-level animation guarantees.

Public AppKit panels can draw borders.
Their stacking, fullscreen behavior, and synchronization need native verification.
Arbitrary application blur, opacity, and corner clipping are outside this implementation's public API contract.

## Coordinates

Use points for layout.
Convert AppKit coordinates to Accessibility coordinates in the native adapter.
Use the menu-bar display as the coordinate reference, including displays with negative origins.

[NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe) excludes occupied Dock and menu-bar areas.
Refresh that frame when the display environment changes.

## Sources

- [Hyprland README](https://raw.githubusercontent.com/hyprwm/Hyprland/main/README.md).
- [AeroSpace README](https://raw.githubusercontent.com/nikitabobko/AeroSpace/main/README.md).
- Installed macOS SDK headers for `AXUIElement`, `AXAttributeConstants`, `AXNotificationConstants`, `CarbonEvents`, `NSScreen`, and `NSWindow`.
