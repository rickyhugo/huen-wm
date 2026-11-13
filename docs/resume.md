# Work checkpoint

Updated November 13, 2026 after the requested continuation.

## Current state

The SIP-enabled Zig 0.17.0 and Lua manager has passed the full native fixture flow on one display.
The final scene run verified both captured covers, workspace return, valid and invalid automatic reloads, and original-frame restoration.
All 22 checks passed. Headless smoke and repository checks passed too.
The manager and fixture stopped, and the driver restored AeroSpace without errors.

The installed app is `~/Applications/Huen WM.app`, built from `9b44757`.
Development Accessibility and Screen Recording grants survived rebuilds after the old hash-based entries were replaced.
Launch through macOS `open`. Direct shell invocation has a different permission context.

## Evidence

- `docs/verification-2026-11-13.json` records the final outcomes and representative measured geometry.
- `docs/native-smoke.md` gives the repeatable native command.
- `decisions.tsv` records architecture choices and corrections from native evidence.
- Full local logs are under `/private/var/folders/zj/d5cklrtd0cb5nl3s7hrd558r0000gp/T/opencode/huen-native-scenes3/`.

## Remaining work

Verify final parking and corner fallback on multiple displays when available.
Physical global hotkeys, border and scene appearance, native Space changes, external minimization, and broader app compatibility remain unverified.
Hard-kill recovery is unsupported. Synchronous AX calls can still block the main loop.

Keep implementation delegated to `openai/gpt-6.1-sol` as requested.
No single-letter variables or parameters. No unit tests. Use the existing broad checks unless the user requests more.
