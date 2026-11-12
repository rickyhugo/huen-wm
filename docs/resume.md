# Paused at the user's request

The goal is a polished SIP-enabled macOS tiling manager with Zig 0.17.0 and Lua configuration.
The user requested a pause before leaving work on November 12, 2026.
Do not resume native desktop activity without a new request.

## Safe state

- Branch `feat/huen-wm` has local commits only. Nothing pushed and no PR opened.
- Huen WM and HuenFixture are stopped. AeroSpace is running.
- The last native driver restored AeroSpace successfully and reported no cleanup errors.
- All delegated workers returned. No background work remains.
- An integration cherry-pick conflict was aborted. No merge operation remains active.
- The installed app is `~/Applications/Huen WM.app`, built from `28e106f`.

## Verified progress

The exact Zig build, headless configuration and CLI smoke, and hk checks passed before the last native run.
Lua now executes in bounded self-exec workers. Independent review found a dropped reload during transitions, fixed in `29e22d8`.
Window recovery ownership, restore failure reporting, visibility ambiguity handling, physical key codes, and first floating movement were corrected.
Development signing has an explicit stable designated requirement. Accessibility and Screen Recording grants survived subsequent rebuilds.

Native run 4 passed fixture-only discovery, tiling on two displays, focus changes, a 40-point move, return to tiling, and layout and ratio changes.
Workspace switching failed with rejected parking placement. Rollback ran, then cleanup restored and stopped the manager and fixture.
Full restoration assertions later in the driver were not reached.
Native reload checks, workspace return, scenes, hotkeys, and border appearance remain unverified.
Hard-kill recovery is unsupported. Synchronous AX work can still block the application loop.

## First action on resume

Integrate only the incremental pure-move change from worker commit `e2ccd1124e53c501d0d3882a5da5ffcdfe08b151`.
That amended commit replaces worker commit `eeb05e6d6d45b5a98cb66faf341b79bf2f6e14e1`, whose first version is already integrated as `28e106f`.
Compare the two worker commits rather than cherry-picking the amended commit wholesale.
The change reads current dimensions and skips the AXSize write when dimensions already match.
It may fix parking clamping but has not been verified on the desktop.

The first placement defect was reproduced on all three fixture windows.
Writing SIZE before POSITION clamped height at the old origin.
POSITION, SIZE, POSITION fixed tiling and movement in native run 4.
Parking still failed. If skipping unchanged SIZE does not fix it, record requested and observed frames at the failed placement before changing policy.
Keep verified rollback and recovery ownership. Do not weaken assertions to claim success.

After integrating, rebuild with `sh scripts/bundle.sh --install` and rerun the native driver when the user permits desktop work.
Use a fresh output directory. The driver temporarily pauses AeroSpace and restores it in cleanup.
It launches through LaunchServices because direct shell invocation sees a different Accessibility permission context.

## Files and evidence

- `scripts/native-smoke.py` drives one broad native check and uses fixture-reported geometry.
- `scripts/native-fixture.m` owns the disposable windows and independent observations.
- `native/platform.m` owns AX writes and native recovery.
- `src/main.zig` owns placement transactions, workspace intent, and reload publication.
- `src/config.zig` and `native/config_worker.c` own isolated evaluation.
- `docs/implementation.md` has the original plan. Its progress section needs an update after native verification.
- `decisions.tsv` records architecture and verification decisions.
- Native output is under `/private/var/folders/zj/d5cklrtd0cb5nl3s7hrd558r0000gp/T/opencode/huen-native-run4/`.
- The placement worker checkout is `/private/var/folders/zj/d5cklrtd0cb5nl3s7hrd558r0000gp/T/opencode/huen-wm-placement`.
- Integration checkout is `/private/var/folders/zj/d5cklrtd0cb5nl3s7hrd558r0000gp/T/opencode/huen-wm-main`.

Keep implementation delegated to `openai/gpt-6.1-sol` as requested.
No single-letter variables or parameters. No unit tests. Use only the existing broad checks unless the user requests more.
Finish independent review and native verification before claiming a usable build. No distinct-family reviewer is configured.
