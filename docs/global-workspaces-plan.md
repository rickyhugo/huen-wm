# Global workspaces plan

Status: implemented 2026-11-16 (units 0–9). Design A. Hyprland-style
multi-monitor behavior in huen's own command style. User documentation:
[monitor routing](monitors.md) and [commands](commands.md).

## Deviations from this plan

- `Placement` also has `shown` (was the workspace active on its display at the
  start of the tick, for a display that just vanished) and `shown_when_lost`
  (kept while a workspace waits on a fallback display, so a reconnected display
  shows the workspace it showed before).
- Config `monitor` lists reject `left|right|up|down|next|previous` with
  `RelativeMonitorSelector`.
- Session homes are not derived from root hints. Root hints cannot tell a
  runtime home from configuration placement, and an empty workspace can lack a
  root. The checkpoint gains an optional `homes` array (workspace name,
  occurrence, display UUID). Schema stays v1: old checkpoints load without
  homes. An older binary rejects a checkpoint with `homes` as a schema error.
  Homes restore even when no window matches.
- The menu-bar title shows `—` on an empty display with global routing.
- Display disconnection is verified only by a manual checklist
  (`docs/native-smoke.md`).

## Decisions

- Add a third mode, **global**. Each workspace is on exactly one display.
- Owner mode (`workspace_monitors` without per-workspace `monitor`) is global
  mode where every workspace resolves to one display. Its behavior must not
  change.
- Independent per-display mode stays the default when `workspace_monitors` is
  absent.
- `workspace N` when N is on another display: select that display (jump). Do
  not pull N.
- A display with no workspace placed on it stays empty.
- Reconnect: an explicit move or swap wins over config `monitor`. A reload
  resets homes of workspaces that have a `monitor` field.
- `+N`, `occupied±N`, `empty` resolve against the whole workspace set in global
  mode.

## Data shape (`src/main.zig`)

```zig
const Placement = struct { display: ?u32, home: [128]u8 }; // home = display UUID hint, "" = config-resolved
var placements: [10]Placement;
var global_previous: ?usize;
```

- Invariant: each workspace is on one display. `Display.workspace` is a
  workspace placed on that display, or null.
- `window.display` derives from `placements[window.workspace].display`. Roots
  keep the `(display, workspace)` key but are unique per workspace. The rekey
  and collision code in `commitRouting` handles moves.
- `Routing.owner: ?u32` becomes per-workspace destinations. In
  `commitRouting`, each window and root picks its destination from its
  workspace. Snapshot and rollback code does not change.
- `preferredOwner()` becomes `resolvePlacements()`. Per workspace:
  1. runtime home UUID, if present;
  2. else the workspace's `monitor` list;
  3. else `workspace_monitors`;
  4. else the current display;
  5. else the lowest display identity.
- New pure module `src/monitor.zig` (style of `src/selector.zig`): monitor
  selector resolution and the placement planner.

## Commands

Monitor selector: `left|right|up|down|next|previous|built-in|external|name:NAME`.

- Directions use centers of `full_bounds`.
- `next`/`previous` order displays left to right, then top to bottom, and wrap.
- `name:` matches `NSScreen.localizedName` exactly (`Display.name`). Duplicate
  names: lowest identity wins. `monitors` shows names and UUIDs.

| Command | Behavior |
|---|---|
| `focus-monitor SEL` | Select the display and focus its candidate. Empty display: select without focus change. Both modes. |
| `send-to-monitor SEL` | Send the window to the target display's active workspace. Selection stays. Both modes. |
| `move-to-monitor SEL` | Send, then focus the moved window. |
| `move-workspace-to-monitor SEL` | Global only. Move the selected display's active workspace; set its home to the target UUID. Source display falls back to its previous workspace, else another workspace placed there, else none. Selection follows. Else `RequiresGlobalWorkspaces`. |
| `swap-monitor-workspaces SEL` | Global only. Swap active workspaces and their homes. |

## Config

```lua
workspace_monitors = { 'external', 'built-in' },   -- default for workspaces without monitor
workspaces = {
  { name = '1', monitor = { 'name:DELL U2725QE', 'external' } },
  { name = '6', monitor = 'built-in' },
},
```

- `monitor` without `workspace_monitors` is a config error
  (`MonitorRequiresGlobalWorkspaces`).
- At most 4 entries, no duplicates, no empty list.
- No listed monitor present: fall back through steps 3–5 above.

## Hotplug and session

- Disconnect: the workspace moves to its fallback display and keeps its home.
- Reconnect: it returns home.
- Session: `Root.display_hint` and `active` exist; schema stays v1. Restore
  seeds `placements[i].home` from the saved `homes` array before
  `resolvePlacements()`. `continuity.restore(…, owner)` takes per-workspace
  destinations. Mode switches change the config hash, so old checkpoints are
  rejected cleanly.

## Interactions

- `previous`: one global value (`global_previous`), replaces
  `owner_previous_workspace`.
- Independent mode selectors do not change.
- `focus last`: `WindowOffOwnerDisplay` goes away; the target's display is
  switched and selected.
- `mouse_follows_monitor` applies through `selectDisplay`.
- `status`: `workspace_owner` stays (null when split) and gains `placements`.
  `monitors` gains `uuid` and `workspace`.

## Units

Each unit ends with `mise run build`, `mise run check`, and `mise run smoke`.
Only the coordinator runs `mise run native-smoke`.

0. `native-smoke --owner` (N1) and `--monitors` modes.
1. `src/monitor.zig`, selector parsing in `src/command.zig`, `focus-monitor`
   grammar.
2. `focus-monitor` runtime and `monitors` additions, both modes.
3. Config `monitor` field (`src/config.zig`): parsing, wire round trip,
   validation.
4. `placements` replace owner variables; per-workspace destinations in
   `commitRouting`. Owner behavior identical.
5. Global `workspace`, selectors, `focus last`, `global_previous`.
6. `send-to-monitor` / `move-to-monitor`.
7. `move-workspace-to-monitor` / `swap-monitor-workspaces` with runtime homes.
8. Hotplug return home, session restore homes (`src/continuity.zig`).
9. Docs (`docs/monitors.md`, `docs/commands.md`).

## Native scenarios (MacBook + DELL U2725QE, `--spread`)

- N1 owner mode: baseline before unit 4, regression after. Migration to the
  Dell, workspace switches, `send-to-workspace`, `status.workspace_owner`,
  pointer warp with `mouse_follows_monitor` on and off.
- N2 after unit 5: split config (1–5 external, 6–10 built-in). `workspace 7`
  selects built-in while the Dell keeps its workspace; `previous`,
  `occupied+1`, `focus last` across displays.
- N3 after unit 2: `focus-monitor left/right/next/built-in/name:DELL U2725QE`
  with pointer warp.
- N4 after unit 6: `send-to-monitor` / `move-to-monitor` with focus.
- N5 after unit 7: `move-workspace-to-monitor`, `swap-monitor-workspaces`.
- N6 after unit 8: restart continuity; workspaces return to hinted displays.
- Manual: unplug/replug the Dell.
- Regression: default independent-mode exercise.
