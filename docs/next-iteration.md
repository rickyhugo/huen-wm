# AeroSpace parity, menu-bar status, and responsiveness

## Definition of done

The active shortcuts and routing preferences in the user's AeroSpace configuration have supported Huen WM equivalents, documented where semantics differ.
Workspace changes produce no centered popup.
A Lua-configured native menu-bar item can be enabled, disabled, and customized through reload.
New commits pass a local hk Conventional Commits gate.
Completed agent branches are removed only after their commits are preserved and their worktrees are audited.
Responsiveness changes have before-and-after evidence from the same completed workload, including failures.
Native checks and independent review must pass before the updated app replaces the user's running manager.

## Playbook

- [x] Read the Poteto mode principles.
- [x] Phase A. Frame the scope and acceptance gates.
- [ ] Phase B. Ground the runtime and compare two interface designs.
- [ ] Phase C. Implement and verify each bounded unit.
- [ ] Phase D. Record decisions and verification in `decisions.tsv` throughout the work.
- [ ] Phase E. Verify the whole, commit, push, and update the PR.

## Throughput checkpoint

- Blocking first steps. Audit the live manager, current configuration, and repository state. Define the configuration and command shapes before runtime changes.
- Independent workstreams. Tooling owns the commit hook. Read-only investigators own runtime grounding, performance diagnosis, and branch cleanup evidence.
- Shared mutable state. Runtime writers use separate worktrees but integrate sequentially. One owner controls configuration, commands, layout intent, and native interfaces in each implementation phase.
- Smallest safe decomposition. Land the commit hook independently, then status presentation, then compatible command groups, then measured responsiveness changes.

## Implementation units

- [x] Conventional Commits commit-msg hook with positive and negative command checks.
- [x] Archive and remove completed agent branches and clean worktrees. Preserve the active feature branch and user work.
- [ ] Optional configurable menu-bar item. Remove workspace HUD announcements.
- [ ] App launch, close, managed fullscreen, focus wrapping, and split-orientation commands.
- [ ] Binding modes and directional pixel resize behavior.
- [ ] External-display preference with built-in fallback, mouse-follow preference, and opt-in login startup.
- [ ] Update the personal Lua config to express the supported AeroSpace behavior.
- [ ] Profile the actual latency limiter and compare release builds on an unchanged workload.
- [ ] Independent correctness and comment review, native verification, and pushed Conventional Commits.

## Operating constraints

The latest process check found Huen WM stopped and AeroSpace running.
One fixture owner controls native verification and restores the prior AeroSpace state afterward.
No unit tests. Keep the existing broad smoke checks and targeted executable probes.
Keep SIP enabled. Hard-kill recovery and macOS compositor replacement are separate architectural limits, not claims of this iteration.

## Grounding

Zig owns validated configuration, command policy, window intent, workspace membership, and derived layout goals.
The native bridge owns AX handles, original geometry, hotkeys, IPC, AppKit panels, and the event loop.
Configuration crosses a bounded worker JSON boundary and stages hotkeys before publication.
Runtime layout commands currently mutate configuration ratios, so richer layout state needs an explicit reload policy.
There is no persistent split tree or native status item.

Workspace announcements have a dedicated HUD path. Error reporting is independent, so the HUD can be deleted without removing diagnostics or captured transitions.
The 60 Hz timer processes synchronous AX scans and animation writes before one IPC request. These are performance hypotheses until profiling identifies the limiter.

## Status-item design comparison

Compare a typed Zig-to-native presentation projection with native pull queries through existing runtime JSON.
Both must keep workspace decisions in Zig and preserve the configuration transaction.
Score each from one to five on native lifecycle correctness, configuration compatibility, interface depth, idle work, and verification cost.
Use two independent Sol designs. No distinct-family judge is configured.

## Completed maintenance

The commit-msg hook rejects malformed Conventional Commit titles. An isolated repository passed 41 real Git commit probes through installed hk hooks.
Both hooks are installed in this repository. `mise run check` passes after integration.
Nineteen completed agent branches and worktrees were clean and integrated before removal.
Their original tips are preserved in `.git/huen-wm-agent-branches-2026-11-13.bundle` in the main repository. Bundle verification matched all nineteen refs and full commit IDs.
