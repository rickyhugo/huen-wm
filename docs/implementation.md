# Build the first usable huen-wm

## Goal

Build a macOS tiling window manager with Hyprland-inspired interaction and Lua configuration.
Keep SIP enabled. Use Zig 0.17.0, mise, and hk.

The first build targets keyboard-driven tiling, virtual workspaces, multiple monitors, Lua reload, and visual feedback.
It is not a replacement for the macOS compositor.

## Acceptance gates

1. Build the native executable with the pinned compiler through mise.
2. Load a real Lua configuration and reject invalid configuration without losing the previous configuration.
3. Manage disposable native windows through macOS Accessibility APIs.
4. Exercise tiling, focus, movement, workspace switching, and restoration on shutdown.
5. Check the pre-commit configuration and reject single-letter variables and parameters in authored source.

Compilation alone does not satisfy the native-window gates.
Unavailable permissions leave those gates unverified.
Use a broad integration smoke check where needed. Do not add unit tests.

## Work sequence

- [x] Inspect the repository, compiler availability, and requested agent model.
- [x] Confirm the user's feature priorities and SIP requirement.
- [x] Compare two independent architecture proposals against the macOS API constraints.
- [x] Establish pinned development tools and quick hooks.
- [x] Implement the native window manager against the selected model.
- [ ] Exercise the executable and inspect the resulting window state.
- [ ] Independently review the implementation and resolve demonstrated defects.
- [ ] Commit the verified work and document remaining platform limits.

## Throughput checkpoint

- Blocking first steps. Confirm the macOS integration boundary and select the shared state model before runtime implementation.
- Independent workstreams. Tooling owns mise, hk, and naming checks. Runtime work owns the executable, Lua integration, and AX adapter. Separate workers own the disposable window fixture and the scene-capture bridge.
- Shared mutable state. Writers use separate git worktrees. One implementation owner controls the runtime interfaces.
- Smallest safe decomposition. One runtime owner avoids competing definitions of window identity, workspace state, and native lifetimes.

## Review scope

Two GPT-6.1 Sol agents independently propose designs.
GPT-6.1 Sol implements the code at the user's request.
No distinct-family judge is configured. Independent same-model review does not constitute cross-family review.

Decisions and verification outcomes are recorded in `decisions.tsv`.

## Architecture selection

Both candidates came from independent GPT-6.1 Sol agents.
Scores below are design judgments on a five-point scale, not runtime measurements.

| Criterion | Event-driven split tree | Snapshot reconciliation |
| --- | --- | --- |
| SIP-compatible API boundary | 5 | 5 |
| State ownership | 4 | 5 |
| Recovery from missing observations | 4 | 5 |
| Small maintainable interface | 3 | 4 |
| Hyprland-like layout flexibility | 5 | 3 |

Snapshot reconciliation is the base.
The window manager records user intent separately from observed macOS state and derives target frames.
Periodic discovery repairs missed notifications without replaying an event history.
Stable window order supports both master and derived dwindle layouts.
The split-tree proposal contributed explicit ownership and cancellation of stale geometry work.

Both proposals chose Dock minimization for inactive workspaces.
The user challenged that product choice.
The selected presentation uses ScreenCaptureKit and a native overlay to conceal intermediate window placement.
The overlay captures the outgoing display without huen-wm's own windows, then fades after placement completes.
Screen Recording permission is optional. Without permission, workspace placement remains immediate.
Corner parking stores inactive windows while the snapshot supplies the transition.
Native readback disproved fully off-screen parking. macOS clamped a requested x-coordinate of 5608 to 1472 on a 1512-point display.
The revised placement targets a one-point strip at an available bottom corner and rejects overlap with another display.
Rejected placements must be reported and restored. A snapshot cannot make failed placement correct.

This bridge has a small frozen C interface for capture, reveal, and cancellation.
Zig retains workspace policy. Objective-C owns only the native presentation resources.
Scene smoothness, capture timing, and parking remain unverified until native execution.

## Principles and concrete choices

- Model the Domain separates observed windows, workspace intent, and target frames.
- Foundational Thinking puts compiler pins, native discovery, and shared types before workspace effects.
- Separate Before Serializing Shared State gives each writer a worktree and assigns runtime interfaces to one owner.
- Laziness Protocol selects reconciliation over a larger event journal and effect framework.
- Experience First separates workspace presentation from window storage instead of exposing Dock minimization as the interaction.
- Boundary Discipline keeps capture resources and permission checks inside the native bridge, with workspace policy in Zig.
- Build the Lever produces a reusable native fixture and source checks.
- Sequence Work into Verifiable Units checks tooling and the fixture before native integration.
- Prove It Works requires actual Accessibility readback before claiming native behavior works.

## Verification so far

- `mise exec -- zig version` reports `0.17.0`.
- `mise exec -- hk validate` accepts `hk.pkl`.
- `mise run check` passes on the integrated tooling and fixture source.
- `scripts/build-native-fixture.sh` builds the disposable Cocoa application.
- `codesign --verify --strict --verbose=2 zig-out/fixtures/HuenFixture.app` passes.
- `plutil -lint zig-out/fixtures/HuenFixture.app/Contents/Info.plist` passes.
- LaunchServices permission checks now report Accessibility and Screen Recording access. Direct shell invocations have a different permission context.
- `xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -mmacosx-version-min=14.0 -fsyntax-only native/scene.m` passes.
- Independent scene review found no concrete lifetime or cancellation defects. Native presentation remains unverified.
- Comment review removed two redundant comments and made synchronous callback settlement explicit in internal names. Public lifetime contracts remain.
- `mise exec -- hk install --mise` installed the repository-local pre-commit hook through Git configuration.
- Headless smoke covers isolated Lua evaluation, malformed configuration, and invalid or truncated IPC replies.
- Native fixture checks passed tiling, focus, 40-point movement, floating return, and layout changes on both one-display and two-display setups.
- Native readback confirmed that far-offscreen parking is clamped even when AX setters return success. Corner parking is under implementation.
- Full restoration, native reload, and scene assertions remain blocked behind workspace verification.
- Native cleanup stopped the owned manager and fixture and restored AeroSpace without reported errors.
