# Feature-completion verification

The final candidate implements the active AeroSpace workflow with the approximations in [the preset reference](aerospace.md).
Verification uses disposable native windows on one built-in display.
It does not establish complete AeroSpace parity or multi-display reliability.

## Artifact

- Runtime source is `1eb6eb8000b1d9255bf0c288b6c7af946c6e1067`.
- ReleaseSafe executable SHA256 is `c7b3853dc237bc9162e0ea0efe0631b372d16f06d9add889d9dc84976127005f`.
- Installed comparison baseline source is `9b447577e010cf94f47b59637afb7d8805141c08`.
- Baseline SHA256 is `692de11e4e5f524c846d8d38fc517fb1be7782ea2a440e78b881e70a6583ca35`.
- Both signed bundles passed strict signature verification. No candidate rebuild followed native acceptance.

## Correctness

`mise run check`, `mise run build`, and `sh scripts/smoke.sh` passed.
Headless fake-socket checks ran separately from native management.

| Final-artifact run | Passed checks | Observed behavior |
| --- | ---: | --- |
| Minimized recovery | 12 | Stable identity through omitted AX enumeration, then original-frame restoration. |
| Existing native scenes | 22 | Tiling, focus, movement, captured parking and return, reload, restoration. |
| Extended workflow | 40 | Wrapped focus, both split axes, 50-point resizing, tiled and floating fullscreen, routing, modes, launch, shell execution, close, restoration. |
| Conditional-close workflow | 42 | The same workflow, plus close without terminating an app with surviving windows and removal of the closed identity. |

Counts include setup and cleanup observations, not distinct feature counts.
All four runs have no failed checks or cleanup errors.
Geometry and key focus come from independent AppKit fixture reports.
Command acceptance alone is not completion evidence.
Each manager was filtered to `dev.huen-wm.fixture`.

The preceding timing build passed eight original-order startup runs and 200 eligibility checks.
Those checks include 16 fullscreen workspace returns and 24 floating fullscreen/retile cycles.
They were not repeated in full after the minimized-record-only change.

The existing scene flow is repeatable with:

```sh
python3 scripts/native-smoke.py --scenes --app "/absolute/path/Huen WM.app" --output "/new/evidence/directory"
```

## Corrections from failed runs

- Native motion state prevents intermediate animation frames from replacing floating intent.
- Running application bundle URLs resolve apps that LaunchServices cannot find by identifier.
- Fresh observations prevent mixed-time CG and AX geometry from incorrectly excluding a window at command and focus boundaries.
- Scoped retries prevent unrelated persistent invisibility from repeatedly blocking the main loop.
- Animation evaluation refreshes its timestamp after work that can create new animations.
- Retained minimized AX records preserve original geometry and window identity across enumeration omissions.

The startup trace directly records negative progress and application-clamped negative dimensions.
Its connection to an earlier terminal placement rejection remains inferred.
Eight corrected startup runs and the final scene run passed.

Earlier verification errors included assuming wrapped focus cycles through every window and using an outdated bundled executable.
Those runs remain in local evidence and are excluded from acceptance.
Independent same-model reviews covered integration, launch, eligibility, timing, and minimized recovery.
No distinct-model-family review ran.

## Matched performance

Completed zero-duration resize is faster than the baseline in this workload.
Five fresh alternating pairs ran A1, B1, A2, B2 through A5, B5.
Each used three fixture windows, master layout, gap 12, one display, and the same expected native geometry within two points.
Each batch warmed up with five status requests and five resize pairs.
Timed work comprised 40 status requests and 20 completed geometry changes per batch.
Each side completed 200 status requests and 100 geometry changes with zero errors.

| Metric | Baseline A | Final B |
| --- | ---: | ---: |
| Median of geometry batch medians | 160.980 ms | 33.692 ms |
| Range of geometry batch medians | 152.339 to 163.762 ms | 33.115 to 41.103 ms |
| Median of status batch medians | 16.661 ms | 16.659 ms |
| Largest observer sampling gap | 14.160 ms | 5.530 ms |

Geometry batch medians in milliseconds:

- A. `152.3393545, 160.979792, 161.600437, 163.762375, 153.0936045`.
- B. `33.692, 33.523521, 41.1030415, 33.1149995, 34.1175005`.

The geometry ratio is 4.778, a 79.071 percent reduction.
Status latency has no measurable change.
This result supersedes the earlier ninefold claim.
It does not measure animation duration, physical hotkeys, or menu responsiveness.

A separate final-binary profile identifies fresh observation scans, synchronous AX writes, and the 60 Hz command service as remaining limits.
The profile completed 180 geometry operations and is excluded from the matched batches.
Of 4,728 main-thread samples, 1,572 were under command observation refresh and 1,451 under command placement.
Those stack counts do not isolate per-command costs.
The 10-core machine had one-minute loads from 3.279 to 5.275 during timed batches.
Background compilers, security software, and desktop services remained active.
Alternation reduces drift bias but does not remove scheduling noise.

## Limits and retained evidence

Menu rendering and clicks, physical global hotkeys, final multi-display routing and hotplug, native Space changes, and broad application compatibility remain unverified.
So do global stacking order, save prompts, new-instance behavior, last-window termination, and conditional close concurrent with minimization.
A direct-launch minimized conditional-close probe returned `CloseRejected`; its cause remains unproven.
Hard-kill recovery remains unsupported. Synchronous AX calls can block the main loop.

All successful runs restored surviving original frames, stopped owned processes, and restored AeroSpace's prior enabled state and main mode.
The failed concurrent-minimization probe could not restore a still-minimized window before its disposable fixture exited.

Local raw reports and rerunnable drivers are under the session's sibling directories:

- `../huen-minimized-fix/` contains final correctness results, exact candidate, measurement scripts, `perf/A1` through `perf/B5`, `perf/summary.json`, and `profile/manager.sample.txt`.
- `../huen-startup-fix/` contains startup traces, eight corrected startup runs, and the preceding 200-check eligibility run.
- `../huen-eligibility-fix/` contains both eligibility reproductions and their treatment.
- `../huen-launch-focus-fix/` contains launch-resolution reproduction and independent public AppKit resolution data.

These local directories are not included in a fresh clone.
This report preserves the artifact identities, measured outcomes, method, failures, and remaining limits.

## Local installation

The exact verified bundle was copied to `~/Applications/Huen WM.app` without rebuilding.
Every installed file matches the candidate.
The personal `~/.config/huen-wm/config.lua` matches `config/aerospace.lua`.
Installed config validation passes. The installed doctor reports Zig 0.17.0, Accessibility, and Screen Recording available.
The installed app also started with a copy of the personal preset against disposable windows.
Main-to-resize-to-main activation passed with 37 main bindings and six resize bindings, without registration errors.
Independent fixture geometry confirmed gap 10. Runtime state confirmed ten workspaces and the built-in monitor owner.
Original frames and AeroSpace's prior state were restored afterward.
This checks registration and mode switching, not physical key delivery or menu rendering.
Raw installed-preset evidence is `../huen-install-verification/installed-config/result.json`.
The prior app ZIP and configuration remain under `~/.local/state/huen-wm/backups/2026-11-13-feature-completion/`.
Login startup was not enabled. AeroSpace remains the active manager outside controlled fixture checks.
