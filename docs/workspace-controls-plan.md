# Workspace controls and session continuity

## Goal

Implement the five requested areas without scratchpad workspaces.
Keep SIP enabled, Lua configuration, and the existing verified native placement and recovery contract.

## Playbook

- [x] Read the Principles section of the poteto-mode skill.
- [ ] Phase A: Frame.
- [ ] Phase B: Design the workflow.
- [ ] Phase C: Run the loop.
- [ ] Phase D: Keep the audit trail.
- [ ] Phase E: Verify and hand back.

### Architecture

- [ ] Ground.
- [ ] Sketch.
- [ ] Agree. Proceed after comparison without an approval pause.
- [ ] Implement.
- [ ] Scrap. Revisit the model if implementation repeatedly violates its boundaries.

### Design comparison

- [ ] Frame.
- [ ] Fan out.
- [ ] Cross-judge. No distinct-family judge is configured; same-model review remains available.
- [ ] Pick.
- [ ] Graft.
- [ ] Verify.

## Scope and acceptance

1. Workspace focus memory. Return to the last eligible focused window. Handle closure, minimization, send, swap, reload, and managed fullscreen.
2. Container editing. Move tiled windows between splits, select parent and child containers, and support tabbed and stacked groups. Preserve the existing floating move command.
3. Mouse tiling controls. Drag tiled windows to rearrange them and resize shared boundaries. Keep pointer handling outside layout policy.
4. Session persistence. Restore workspace assignments, tree topology, ratios, and useful focus state after a normal restart. Reject stale or ambiguous window matches. Do not claim durable AX identity or guaranteed crash recovery.
5. Richer rules. Support title matching and practical per-app placement policies with deterministic precedence and transactional validation.

Native acceptance must observe resulting geometry and focus independently.
Persistence must survive an actual manager restart and reject ambiguous matches.
Input behavior must be exercised through the native input path where permissions permit.
Unverified UI behavior must be reported explicitly.

## Throughput checkpoint

This is a multi-hour, cross-cutting iteration across five feature areas.
The highest-risk dependencies are container ownership, hidden group members, pointer event handling, and restart identity matching.
Two Sol design candidates will compare module boundaries before runtime implementation.
Score safety and recovery, interface simplicity, integration cost, native verification, and compatibility from one to five.

Runtime writers use separate worktrees and frozen base commits.
Integration is sequential. One owner controls GUI processes and restores AeroSpace after each native run.
Configuration and persistence serialization can proceed independently once their contracts are fixed.
Focus and container editing share layout state and require coordinated ownership.

Use existing broad smoke checks and targeted native acceptance. Do not add a unit-test suite.
Do not overwrite the installed build or personal configuration until combined acceptance passes.
Do not merge the next PR without explicit authorization.

## Starting point

Base is merged commit `de2a0b4062cadc8a3cc46e363b3ce9eb57f10cc0`.
Installed runtime and the prior acceptance evidence are recorded in `verification-feature-completion.md`.
The current tree is binary, focus restoration chooses a fullscreen winner or the first eligible window, and runtime layout state is process-local.
The decision trail remains `decisions.tsv`.
