# Workspace controls and session continuity

## Goal

Implement the five requested areas without scratchpad workspaces.
Keep SIP enabled, Lua configuration, and the existing verified native placement and recovery contract.

## Playbook

- [x] Read the Principles section of the poteto-mode skill.
- [x] Phase A: Frame.
- [x] Phase B: Design the workflow.
- [ ] Phase C: Run the loop.
- [ ] Phase D: Keep the audit trail.
- [ ] Phase E: Verify and hand back.

### Architecture

- [x] Ground.
- [x] Sketch.
- [x] Agree. Proceed after comparison without an approval pause.
- [ ] Implement.
- [ ] Scrap. Revisit the model if implementation repeatedly violates its boundaries.

### Design comparison

- [x] Frame.
- [x] Fan out.
- [x] Cross-judge. Skipped because no distinct-family judge is configured. Both candidates used Sol.
- [x] Pick.
- [x] Graft.
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

## Selected design

Candidate A preserves binary splits and adds explicit ordered tabbed/stacked groups in the same bounded node pool.
Candidate B replaces all containers with arbitrary-child groups.
Both keep parentage in one owner and reject a separate group-membership registry.

| Criterion, higher is better | A | B |
| --- | ---: | ---: |
| Safety and recovery | 4 | 4 |
| Interface simplicity | 4 | 4 |
| Integration cost | 4 | 2 |
| Native verification effort | 4 | 3 |
| Existing command compatibility | 5 | 3 |

Choose A because binary resize and projection already have native evidence.
Use B's typed visibility reasons and generation-tagged presentation events.
Reject heuristic title/geometry persistence fallback. Match unique public identifiers or document URLs within the same application process lifetime.
Unknown or ambiguous windows receive current rules and fresh layout membership.
Persistence therefore supports a normal manager restart while applications remain open, with explicit unmatched reporting.
It does not promise restoring arbitrary windows after application relaunch or reboot.

### Contracts

- `layout.zig` owns topology, container selection, focus memory, projection, group visibility, and shared resize boundaries. Preserve existing binary and master APIs while adding the new commands.
- Commands are `select parent|child`, `tilemove DIRECTION`, `group join DIRECTION`, and `group tabbed|stacked|split|next|previous`. Existing `move` keeps floating-and-nudge behavior.
- Native group headers use copied typed presentations. Clicks carry a generation and target reference, not borrowed runtime pointers.
- Mouse controls are opt-in through `mouse = { enabled = true, mods = "ctrl+alt" }`. Modified left drag reorders; modified right drag resizes. Preview is local until release commits through verified placement.
- Session continuity is opt-in through `session = { enabled = true }`. Persist versioned bounded logical state with atomic private-file writes. Never persist native recovery authority.
- Rules gain optional `title = { literal = "..." }` or `title = { glob = "..." }` and display-local floating geometry. Matching predicates are AND. Later matching rules override only explicitly supplied actions.
- Group hiding uses verified corner parking, with inactive-group membership distinct from inactive-workspace membership. Failed group edits restore topology and geometry while retaining actual native recovery obligations.
- Stateful native placement remains owned by one integration writer. Leaf workers do not edit the installed app, personal config, or live desktop.

### Implementation units

- [ ] Extend pure layout and command grammar.
- [ ] Extend isolated configuration and rule decisions.
- [ ] Add native group headers and bounded pointer capture.
- [ ] Define persistence checkpoints and native stable attributes.
- [ ] Integrate focus memory, container/group transactions, rules, and native controls.
- [ ] Integrate clean restart save/restore.
- [ ] Independently review and exercise native acceptance.
- [ ] Publish the feature PR with verified outcomes and explicit limits.
