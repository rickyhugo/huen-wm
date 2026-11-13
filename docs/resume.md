# Work checkpoint

Paused November 13, 2026 at the user's request for a meeting.
Do not resume implementation, verification, or installation until explicitly asked.

## Current state

PR #1 is open at https://github.com/rickyhugo/huen-wm/pull/1.
The latest pushed commit is `940945e`. Current implementation commits are local.
The feature branch contains a configurable menu-bar item, removal of the centered workspace HUD, a Conventional Commits hook, and an opt-in login helper.
Local integration through `054f60e` also includes persistent layout trees, split orientation, point resizing, managed fullscreen, binding modes, application commands, and optional monitor routing.
There is no active cherry-pick or unresolved merge conflict.
The status build passed all 22 native scene checks on one display, plus headless smoke and repository checks.
Menu rendering and clicking remain unverified because desktop tools are unavailable and the AX observer lacks permission.
Nineteen completed agent branches were archived in a verified Git bundle and removed.

The installed app is `~/Applications/Huen WM.app`, built from `9b44757`.
The personal config remains `~/.config/huen-wm/config.lua` with the earlier 30 bindings.
No new app was installed, no personal configuration changed, and login startup was not enabled.
Development Accessibility and Screen Recording grants survived rebuilds after the old hash-based entries were replaced.
Launch through macOS `open`. Direct shell invocation has a different permission context.
All workers stopped. No manager, fixture, or measurement helper remains.
AeroSpace PID 35197 is running and enabled, matching the recorded pre-verification state.

## Placement correction

Five alternating A/B pairs measured completed zero-duration fixture resize at 155.55 ms baseline versus 16.62 ms candidate.
Each side completed 100 geometry operations and 200 status requests without timed errors.
Status latency remained approximately 16.65 ms.
The candidate then failed the animated scene smoke twice, so that version must not ship.

Tracing confirmed that Zig adopted top 46 while native animation targeted top 86.
Resubmitting the intermediate floating frame canceled movement.
The corrective checkpoint is `26fd89960714b8e56be498cfb8c08544b8de67f9` on `perf/event-response` in `../huen-wm-response`.
It projects native `idle`, `animating`, and `rejected` placement state and adopts floating observations only while idle.
Temporary tracing was removed and that worktree is clean.

The corrected worker build passed all 22 native scene checks, an exact-frame animated floating roundtrip, and animation reversal.
A subsequent five-batch candidate run completed 100 geometry operations and 200 status requests without errors.
Its batch-median median was 22.659 ms, with a 15.796–26.527 ms range.
This was not a fresh alternating comparison.
Parent integration, independent review, explicit repository checks, and combined native verification remain pending.

## Evidence

- `docs/verification-2026-11-13.json` records the final outcomes and representative measured geometry.
- `docs/native-smoke.md` gives the repeatable native command.
- `decisions.tsv` records architecture choices and corrections from native evidence.
- Full local logs are under `/private/var/folders/zj/d5cklrtd0cb5nl3s7hrd558r0000gp/T/opencode/huen-native-scenes3/`.
- `docs/next-iteration.md` contains the active implementation plan and completed gates.
- `../huen-status-verification/REPORT.md` records the newer status build's native verification and UI limitations.
- `../huen-perf-2026-11-13/` contains the baseline measurement and replayable driver.
- `../huen-response-measure/ab-20261113/` contains alternating results and the initial scene failures.
- `../huen-response-measure/floating-trace-before`, `floating-scenes-after`, `floating-roundtrip-after`, and `floating-perf-after` contain the correction evidence.
- `../huen-iteration-review-findings.md` records accepted findings.

## Remaining work

1. Review and integrate the worker's animated-placement checkpoint.
2. Review the combined monitor integration and its layout snapshots, root migration, and same-owner captured transitions.
3. Verify that directional focus confirms its target before changing monitor selection or warping the pointer.
4. Fix send-triggered owner changes to preserve the old owner's active workspace instead of the destination monitor's default.
5. Confirm the accepted failed-send rollback finding is resolved by the complete routing snapshot.
6. Run repository checks, headless smoke, and broad native verification against the combined build.
7. Update the personal configuration and install only after verification.
8. Commit and push final evidence, update PR #1, and archive completed helper branches.

`de236f2` rejects multiline commands and excludes parked focus targets.
`054f60e` preserves capture for same-owner workspace switches.
Review these fixes against the accepted findings rather than assuming integration proves behavior.

Verify final parking and corner fallback on multiple displays when available.
Physical global hotkeys, border and scene appearance, native Space changes, external minimization, and broader app compatibility remain unverified.
Hard-kill recovery is unsupported. Synchronous AX calls can still block the main loop.

Keep implementation delegated to `openai/gpt-6.1-sol` as requested.
No single-letter variables or parameters. No unit tests. Use the existing broad checks unless the user requests more.
