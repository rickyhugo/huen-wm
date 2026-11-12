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

Add `--scenes` to check convergence with short workspace scenes. This does not prove appearance, animation quality, or snapshot coverage.

The driver refuses an existing huen-wm or HuenFixture process. It checks permissions through LaunchServices before it pauses AeroSpace.
It restores AeroSpace only if this run disabled it. If the owned manager does not stop, the driver leaves AeroSpace disabled and records the failure.
It never hard-kills the manager or installs an app.

`result.json` contains checks, command output, native fixture snapshots, failures, and cleanup errors.
Separate log files contain LaunchServices stdout and stderr. Exit code zero requires all checks and cleanup to succeed.

The fixture puts Alpha and Beta on the primary display and Gamma on a second display when available.
The driver checks native tiling, focus, a 40-point move, floating return, layout with resize, workspace parking and return, reload, and restoration before stop.
On two displays, it also checks that workspace changes leave the other display's fixture frames unchanged.
`multi_display_covered` records whether that check included windows on another display.

The driver does not check swap, send-to-workspace, hotkeys, borders, minimize or fullscreen behavior, display disconnection, crash recovery, or visual scene output.
It checks layout and resize together because two windows can have identical geometry in both layouts.
It does not independently observe unrelated applications' geometry.
