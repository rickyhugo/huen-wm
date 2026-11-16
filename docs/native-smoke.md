# Run the native smoke check

This check moves only disposable HuenFixture windows. Do not interact with the fixture during the run.
Grant Accessibility to the installed Huen WM app first. For `--scenes`, also grant Screen Recording.

Build the fixture without launching it.

```sh
sh scripts/build-native-fixture.sh
```

Run against the installed app. Choose an output directory that does not exist.

```sh
python3 scripts/native-smoke.py \
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
python3 scripts/native-smoke.py \
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
