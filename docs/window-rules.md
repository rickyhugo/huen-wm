# Window rules

Rules run in array order when a window is discovered. Later matching rules
replace only the actions they specify. A workspace-only rule does not undo an
earlier floating action. Without a floating decision, a window starts tiled.
The first observed title is used, even if it is empty. Later title changes do
not reapply rules.

```lua
rules = {
    { bundle = "com.tinyspeck.slackmacgap", workspace = 4 },
    {
        bundle = "com.apple.TextEdit",
        title = { glob = "Notes ?*" },
        geometry = { left = 40, top = 60, width = 800, height = 600 },
    },
}
```

`bundle` is required and matches the exact application bundle identifier.
It must contain 1 to 255 UTF-8 bytes. An optional `title` further restricts the
match. Supply exactly one of `{ literal = "..." }` or `{ glob = "..." }`.
Patterns must contain 1 to 255 UTF-8 bytes. Matching is case-sensitive and covers
the whole provided title. `*` matches any sequence, including an empty sequence.
`?` matches one Unicode scalar, not one byte or grapheme. No escape syntax,
regular expressions, or Lua callbacks are supported. Invalid UTF-8 titles do
not satisfy a title predicate.

Native discovery copies at most 511 UTF-8 bytes and reports whether the entire
title fits. Truncated, unencodable, or NUL-containing titles never satisfy a title predicate.
Bundle-only rules still match.

Actions are optional `floating`, `workspace`, and `geometry`. Workspace numbers
are one-based in Lua. Geometry requires all four finite point values.
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
