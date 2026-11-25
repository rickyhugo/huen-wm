# Window rules

Rules run in array order when a window is discovered. Later matching rules
replace only the actions they specify. A workspace-only rule does not undo an
earlier floating action. Without a floating decision, a window starts tiled.
The first observed title is used, even if it is empty. Later title changes do
not reapply rules, except for the `focus_on_activate` and border actions.

```lua
rules = {
    { bundle = "com.tinyspeck.slackmacgap", workspace = 4 },
    {
        bundle = "com.apple.TextEdit",
        title = { glob = "Notes ?*" },
        geometry = { left = 40, top = 60, width = 800, height = 600 },
    },
    { bundle = { regex = "^com\\.google\\." }, title = { regex = "(?i)devtools" }, floating = true },
    { bundle = "com.apple.systempreferences", centered = true },
    { bundle = "com.mitchellh.ghostty", border = false },
    { bundle = "com.apple.Safari", title = { regex = "(?i)private" }, border_color = "#ff6b6b", border_width = 4 },
}
```

`bundle` is required. A string matches the exact application bundle identifier.
A pattern table matches it with exactly one of `{ literal = "..." }`,
`{ glob = "..." }`, or `{ regex = "..." }`. An optional `title` further restricts
the match and takes the same pattern table. Patterns must contain 1 to 255 UTF-8
bytes. Matching is case-sensitive.

Literal and glob patterns cover the whole text. In a glob, `*` matches any
sequence, including an empty sequence. `?` matches one Unicode scalar, not one
byte or grapheme. Globs have no escape syntax.

A regular expression uses the ICU syntax of `NSRegularExpression`. It matches
anywhere in the text, so anchor it with `^` and `$` to cover the whole text.
Start it with `(?i)` to ignore case. A Lua string needs two backslashes for one
in the expression, as in `"^com\\.google\\."`. An expression that does not
compile rejects the configuration with `InvalidRegex`. Matching has no time
limit, so avoid expressions with nested repetition.

Lua callbacks are not supported. Invalid UTF-8 titles do not satisfy a title
predicate.

Native discovery copies at most 511 UTF-8 bytes and reports whether the entire
title fits. Truncated, unencodable, or NUL-containing titles never satisfy a title predicate.
Bundle-only rules still match.

Actions are optional `floating`, `workspace`, `geometry`, `centered`,
`focus_on_activate`, `border`, `border_width`, and `border_color`. Workspace numbers are one-based in Lua. Geometry requires all four finite point values.
`left` and `top` range from -10000 to 10000. `width` and `height` range from
80 to 10000. Geometry implies `floating = true`; combining it with explicit
`floating = false` in the same rule is invalid.

Geometry uses points relative to the destination display's visible frame after
the configured gap inset. Monitor preferences select that destination before
geometry is calculated. Without a preference, the nearest display is used.
The inset is capped at half the shorter frame dimension minus half a point,
so the remaining area is at least one point on each axis.
Width and height are capped at the remaining area's dimensions.
The configured minimum is 80 points, but an area smaller than 80 takes priority.
Position is clamped so the entire window fits inside that area.

`centered = true` centers the window in the same area and implies
`floating = true`. Without geometry, the window keeps its own size, which suits
applications with a fixed window size. With geometry, the geometry supplies the
size and `centered` replaces its position. Combining it with explicit
`floating = false` in the same rule is invalid.

`focus_on_activate` accepts a boolean and replaces the global
`focus_on_activate` setting for the window. It applies when an application
takes focus for the window on a hidden workspace, not on discovery, and uses
the title at that time. See
[activation requests](commands.md#activation-requests).

`border`, `border_width`, and `border_color` style the focused-window border
for matching windows. `border = false` hides it, and `border = true` shows it
even when `border_single_window = false` would hide it. `border_width` ranges
from 0 to 12, and `border_color` is a `"#rrggbb"` string, as in the global
settings. A rule without them keeps the global values. Like
`focus_on_activate`, these actions use the window's current title each time
the border is drawn, so a title change or a configuration reload applies at
once.

Each matching rule replaces only its supplied actions. Geometry also supplies
`floating = true`. A later explicit `floating = false` overrides that decision
without removing the stored geometry. Geometry is applied only if the final
floating decision is true.

Initial geometry remains pending until native placement is eligible and verified.
Minimized, native fullscreen, stale, and off-Space windows are not placed.
A native fullscreen window also blocks placement on its display.
Native recovery retains the original frame. If an application rejects the
requested geometry, the existing floating fallback retains its accepted frame.

Unknown fields, metatables, invalid types, and invalid ranges reject the entire
configuration. The worker response remains bounded to 128 KiB. A configuration
whose combined bindings and rules exceed that encoded limit is rejected rather
than partially applied.
