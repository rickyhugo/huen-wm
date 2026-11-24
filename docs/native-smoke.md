# Run the native smoke check

This check moves only disposable HuenFixture windows. Do not interact with the fixture during the run.
Grant Accessibility to the installed Huen WM app first. For `--scenes`, also grant Screen Recording.

Build the fixture without launching it.

```sh
sh scripts/build-native-fixture.sh
```

Run against the installed app. Choose an output directory that does not exist.
The driver is `tools/native_smoke.zig`. `mise run native-smoke` builds it and passes the options through. Run it from the repository root, because the default `--fixture` is `zig-out/fixtures/HuenFixture.app` relative to the current directory.

```sh
mise run native-smoke \
    --app "$HOME/Applications/Huen WM.app" \
    --output "$PWD/native-smoke-result"
```

Add `--scenes` to require captured covers for both workspace switches, then check native frame convergence. This does not prove appearance, animation quality, or snapshot coverage.

The driver refuses an existing huen-wm or HuenFixture process. It checks permissions through LaunchServices before it pauses AeroSpace.
It restores AeroSpace only if this run disabled it. If the owned manager does not stop, the driver leaves AeroSpace disabled and records the failure.
It never hard-kills the manager or installs an app.

`result.json` contains checks, command output, native fixture snapshots, failures, and cleanup errors.
Separate log files contain LaunchServices stdout and stderr. Exit code zero requires all checks and cleanup to succeed.

The fixture puts Alpha and Beta on the primary display and Gamma on a second display when available.
The driver checks native tiling, focus, a 40-point move, floating return, layout with resize, workspace parking and return, automatic reload, and restoration before stop.
Parking checks preserve size, require a one-point vertical strip with two-point readback tolerance, and reject overlap with another display's full bounds.
On two displays, it also checks that workspace changes leave the other display's fixture frames unchanged.
`multi_display_covered` records whether that check included windows on another display.

Without `--workflow`, the driver does not check swap, send-to-workspace, hotkeys, borders, minimize or fullscreen behavior, display disconnection, crash recovery, or visual scene output.
It checks layout and resize together because two windows can have identical geometry in both layouts.
It does not independently observe unrelated applications' geometry.
The fixture also records its activation state and the frontmost application's identity to diagnose focus loss during desktop interaction.

## Check keyboard workflow commands

Add `--workflow` to replace the default checks with keyboard workflow checks on one display.
It uses the same preflight, AeroSpace pause, cleanup, and restoration as the default run. It excludes `--scenes`.

```sh
mise run native-smoke \
    --app "$HOME/Applications/Huen WM.app" \
    --output "$PWD/native-workflow-result" \
    --workflow
```

The fixture starts three windows without `--spread`, so all windows open on the primary display.
The generated configuration has three workspaces named One, Two, and Three, a 12-point gap, instant switches, and `workspace_back_and_forth = true`.
Each step checks the fixture report and the `windows` and `workspaces` JSON, not only the command reply.
A shown window must be unparked and inside the gapped visible frame. A hidden window must be parked to a strip of at most three points.

The run checks these behaviors in order:

- `workspace previous` before a switch returns `NoPreviousWorkspace`. `occupied+1` with one occupied workspace replies `changed: false`.
- `-1` and `+1` wrap. `previous` returns to workspace 1. `workspace 2` on workspace 2 returns to workspace 1.
- `name:Two` and `name:One` resolve. An unknown name returns `UnknownWorkspaceName`.
- `empty` selects workspace 2. `next-empty` from workspace 2 selects workspace 3.
- `focus last` toggles between two windows on one workspace.
- `move-to-workspace 3` shows workspace 3 with the moved window focused and parks the source windows.
- `focus last` switches to workspace 1 and back to workspace 3.
- `cycle next` with one window keeps it focused. `occupied+1` wraps and skips the empty workspace 2.
- With every workspace occupied, `empty` and `next-empty` return `NoEmptyWorkspace`.
- With three dwindle tiles, three `cycle next` and three `cycle previous` steps follow reading order and wrap.
  The driver derives the order from fixture frames, top then left. `result.json` records it as `workflow_reading_order`.
- `swap next` exchanges the frames of the focused tile and its reading-order neighbor. `swap previous` restores them.
- On a floating window, `swap next` returns `WindowNotTiled`.
- `move-by 10000 10000` and `move-by -10000 -10000` stop at the gapped visible frame's corners. `center` centers the window.
- `resize-by -100 -60` and `resize-by 10000 10000` keep the top-left corner. The second stops at the gapped visible edge.
- On a tiled window, `center` and `move-by` return `WindowNotFloating`.
- `restore` returns the original fixture frames.

The workflow run does not check selectors on a second display, `workspace_monitors`, `send-to-workspace`, `cycle` kind filters, master layout, or tiled `resize-by`.

## Check two-display owner routing and monitor focus

`--owner`, `--monitors`, `--global`, and `--monitor-moves` replace the default checks. They need at least two displays, with at least one built-in and one external display.
With other hardware, the driver prints `SKIP`, records `skipped` in `result.json`, and exits with code zero before preflight.
Both use the fixture with `--spread`, a 12-point gap, instant switches, and workspaces One, Two, and Three. They exclude `--scenes`, `--workflow`, and each other.
The driver reads and warps the pointer through public CoreGraphics calls to set a known start position.

```sh
mise run native-smoke \
    --app "$HOME/Applications/Huen WM.app" \
    --output "$PWD/native-owner-result" \
    --owner
```

`--owner` (N1) starts with `workspace_monitors = { 'external', 'built-in' }` and `mouse_follows_monitor = false`. It checks these behaviors in order:

- Every window moves to the external owner. `status.workspace_owner` is the owner, and `workspaces` lists only the owner.
- `workspace 2` parks every window on the owner. `workspace 1` shows them and selects the owner without a pointer warp.
- `send-to-workspace 2` parks only the sent window. The active workspace, owner, and selected monitor stay the same.
- `workspace 2` shows and focuses the sent window. `send-to-workspace 1` returns it. `workspace 1` shows every window.
- A reload to `{ 'built-in', 'external' }` moves every window to the built-in display. Background routing keeps the selected monitor and the pointer. `workspace 1` selects the new owner without a pointer warp.
- A reload to `{ 'external', 'built-in' }` with mouse follow moves every window back. Background routing does not warp the pointer. `workspace 1` selects the owner and warps the pointer to its center.
- `restore` returns the original fixture frames.

`--monitors` (N3) needs `focus-monitor`. It starts in independent mode with `mouse_follows_monitor = true`:

- `monitors` reports a 36-character `uuid`, `workspace = 1`, and `selected` for each display.
- `focus-monitor` runs `built-in`, `name:` with the external display's name, `left`, `right`, `up`, `down`, `next`, `previous`, `external`, `built-in`, and `next`.
  Before each step, the driver puts the pointer at the selected display's center.
  The driver computes the expected display from `monitors` geometry. A direction without a display must return `NoMonitorInDirection` and keep the selection and pointer.
  Otherwise the reply names the expected display, `status.selected_monitor` changes, the pointer moves to the new display's center, and the key window is on that display.
- An unknown `name:` returns `UnknownMonitorName`.
- A reload to `{ 'external', 'built-in' }` moves every window to the external owner. `monitors` reports a null `workspace` on the built-in display.
  `focus-monitor` to the built-in display selects it and warps the pointer without a focus change.
  `workspace 2` from the built-in display activates workspace 2 on the owner and selects the owner.
- A reload without mouse follow repeats `built-in`, `external`, `previous`, and `next`. Selection changes, and the pointer stays.
- `restore` returns the original fixture frames.

`--global` (N2) checks per-workspace monitors. It starts with `workspace_monitors = { 'external', 'built-in' }`, `mouse_follows_monitor = false`, workspaces One and Two on `external`, and Three on `built-in`.

```sh
mise run native-smoke \
    --app "$HOME/Applications/Huen WM.app" \
    --output "$PWD/native-global-result" \
    --global
```

Each placement check reads `status`, `windows`, `workspaces`, and `monitors`. `status.workspace_owner` must be null, `routing_blocked` false, and `status.placements` must list One and Two on the external display and Three on the built-in display with an empty `home`. Every window must be on its workspace's display, shown windows inside the gapped frame, and hidden windows parked. The pointer stays at the built-in display's center until mouse follow is enabled. The checks run in this order:

- Every window starts in One on the external display. The built-in display shows Three.
- `workspace 1` selects the external display. `send-to-workspace 3` moves the key window to the built-in display and keeps the external display selected.
- `workspace 3` selects the built-in display and focuses the sent window, and the external display keeps One visible. `workspace previous` selects the external display again.
- `occupied+1` jumps to Three on the built-in display. `occupied+1` again wraps to One on the external display.
- `+1` shows Two on the external display. `previous` shows One again.
- From Three, `focus last` targets a window in One and selects the external display.
- With Two on the external display and Three selected, `focus last` shows One on the external display, selects it, and focuses the window.
- A reload with mouse follow keeps the placement. `workspace 3` and `workspace previous` warp the pointer to each display's center.
- A reload to the owner configuration (no `monitor` fields) routes every window to the external display, with the sent window parked in Three. A reload back to the split configuration returns Three to the built-in display. Neither reload leaves routing blocked.
- `restore` returns the original fixture frames.

`--monitor-moves` (N4, N5) checks window and workspace moves between displays. It starts in independent mode without mouse follow. The fixture's spread puts two windows on one display and one on the other.

```sh
mise run native-smoke \
    --app "$HOME/Applications/Huen WM.app" \
    --output "$PWD/native-monitor-moves-result" \
    --monitor-moves
```

Window checks compare each window's display, workspace, and parking with the fixture frames. The checks run in this order:

- Independent `send-to-monitor` moves the key window to the other display's workspace 1. The selection stays, and the source display's other window gets focus. `focus last` and `move-to-monitor` bring the window back, select its display, and focus it.
- With workspace 2 on the single-window display, `move-to-monitor` puts a window in workspace 2 there and focuses it. A second `move-to-monitor` and `workspace 1` restore the start layout.
- `move-workspace-to-monitor` and `swap-monitor-workspaces` return `RequiresGlobalWorkspaces`.
- A reload to the split configuration of `--global` routes every window to One on the external display. `send-to-monitor built-in` puts the key window in Three and keeps the external display selected. `move-to-monitor external` returns it to One and focuses it.
- `move-workspace-to-monitor built-in` shows One on the built-in display with its UUID as `home`. The external display falls back to Two, and the selection follows. `swap-monitor-workspaces external` shows One on the external display and Two on the built-in display and sets both homes.
- A reload of the split configuration clears both homes, because One and Two have `monitor` fields. The start placement returns.
- A reload to the owner configuration routes every workspace to the external display. `send-to-monitor built-in` and `swap-monitor-workspaces built-in` return `NoWorkspaceOnMonitor`. `move-workspace-to-monitor built-in` splits One onto the built-in display, and a reload keeps that home. Moving One back leaves the built-in display empty. From the empty display, `move-workspace-to-monitor` returns `NoWorkspaceOnMonitor`.
- A reload to independent mode clears every home. `restore` returns the original fixture frames.

`--global-restart` (N6) checks that a runtime home survives a clean restart. It uses the split configuration of `--global` with `session = { enabled = true }` and a random `border_color`. The color gives each run its own configuration hash, so a run never reads an earlier run's checkpoint. Each run leaves one small checkpoint file in `~/Library/Application Support/HuenWM`. The fixture starts with `--identifiers unique`, so session matching can identify its windows.

```sh
mise run native-smoke \
    --app "$HOME/Applications/Huen WM.app" \
    --output "$PWD/native-global-restart-result" \
    --global-restart
```

The checks run in this order:

- `status.session.load` is `none`. Every window starts in One on the external display.
- `focus-monitor external`, then `move-workspace-to-monitor built-in`, shows One on the built-in display with the built-in UUID as `home`. The external display shows Two.
- `stop` exits the manager cleanly and restores the original fixture frames.
- A new manager with the same configuration reports `session.load = restored`, matches all three windows, and has no session errors.
- One and its windows are on the built-in display, Two is on the external display, and `status.placements` shows One's home again.
- `restore` returns the original fixture frames.

No mode checks display disconnection. Use the manual checklist.

## Manual hotplug checklist

Use the MacBook and the external display. Start the manager with the split configuration of `--global` (or your own config with `workspace_monitors` and a `monitor` field), and open a few windows in each workspace.

1. Record `huen-wm status` (`placements`) and `huen-wm monitors`.
2. With a workspace from the external display shown, unplug the external display. Within a few seconds:
   - `placements` lists every external workspace on the built-in display. `home` values do not change.
   - The built-in display keeps its active workspace. Windows of the moved workspaces are parked, not lost. `routing_blocked` is false.
   - `selected_monitor` is the built-in display. The menu-bar title is a workspace, not `—`.
3. Run `huen-wm workspace N` for a moved workspace. It shows on the built-in display.
4. Replug the external display. Within a few seconds:
   - The moved workspaces and their windows return to the external display.
   - The external display shows the workspace it showed before step 2, or the one you showed in step 3.
   - The built-in display shows one of its own workspaces. `routing_blocked` is false, and no window has a `placement_error`.
5. Run `huen-wm move-workspace-to-monitor built-in` from the external display, then repeat steps 2 to 4. The moved workspace stays on the built-in display throughout, and its `home` stays the built-in UUID.
6. With a workspace homed on the external display (`swap-monitor-workspaces`), repeat steps 2 to 4. It falls back while unplugged and returns to the external display.
7. Select the empty display in owner mode and confirm the menu-bar title is `—`.

## Prepare broader native checks

The default run uses only `--spread`. For a separate controlled native run, pass these arguments directly to the fixture executable.
The defaults retain the three Alpha, Beta, and Gamma windows, their frames, and their titles.

- `--windows N` creates 1 through 8 windows. The default is 3. Additional names are Delta, Epsilon, Zeta, Eta, and Theta.
- `--identifiers none` is the default and sets every public `NSWindow.accessibilityIdentifier` to nil.
- `--identifiers unique` sets identifiers such as `dev.huen-wm.fixture.alpha`, using each lowercase window name.
- `--identifiers duplicate` sets every identifier to `dev.huen-wm.fixture.duplicate`.
- `--report <absolute-path>` enables the independent JSON report.
- `--spread` retains the existing display placement behavior.

`--windows`, `--identifiers`, and `--report` each accept one occurrence. Missing values, invalid values, and duplicates exit with code 2 and a stderr message.
Repeated `--spread` and unknown arguments retain their previous behavior. Unknown arguments are ignored.

The report retains its existing keys and adds the configured `window_count` and `identifier_mode`.
Each window adds a nullable `identifier` and the public `NSWindow.windowNumber` as `window_number`.
The window number helps diagnose pointer occlusion within a run. Do not use it as a persistent identity.
The identifier field reports the Cocoa property, not an independent AX readback.
Probe the native AXIdentifier before claiming identifier exposure or restart identity.

With `--report`, a public NSEvent local monitor counts events delivered to the fixture.
`mouse_events` contains `left_down`, `left_up`, `left_drag`, `right_down`, `right_up`, and `right_drag`, initially zero.
`last_mouse_event` is initially null. It then contains `type`, `position`, `modifiers`, and `time` for one event.
`position.left` and `position.top` use global top-left coordinates relative to the primary screen, like the frame report.
`modifiers` is the native modifier-flags bitmask. `time` is the NSEvent timestamp in seconds since system startup.
The monitor returns the original event unchanged. It does not monitor mouse movement or write on a timer.
Report writes do not post input events.

For physical input checks, compare counters before and after an ordinary click, then before and after a modifier drag.
An ordinary click must reach the fixture. A drag consumed by the manager must not add delivered drag events.
Record down and up counts separately because the manager may consume only part of the gesture.
Counters show application delivery, not whether a particular control acted on the event.
Repeat with four or more windows and each identifier mode as needed.
Actual AX exposure, restart identity, and physical input behavior require native verification. Compilation alone does not verify them.
