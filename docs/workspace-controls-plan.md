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

- [x] Extend pure layout and command grammar.
- [x] Extend isolated configuration and rule decisions.
- [x] Add native group headers and bounded pointer capture.
- [x] Define persistence checkpoints and native stable attributes.
- [x] Integrate focus memory, container/group transactions, rules, and native controls.
- [x] Integrate clean restart save/restore.
- [ ] Independently review and exercise native acceptance.
- [ ] Publish the feature PR with verified outcomes and explicit limits.

## Unit evidence

Rules are integrated at `6497590`. Three native lifecycles passed 38 observations covering literal/glob matching, floating geometry and clamping, workspace assignment, precedence, invalid reload retention, and original-frame recovery.
Raw evidence is in `../huen-rule-verification/`. The installed app and personal configuration remained unchanged.

The layout unit adds group topology, selection, focus memory, hidden-group projection, edits, and pointer previews.
Independent review found three defects before native use.
Corrections `1d32ed0`, `666b1f7`, and `da733b0` prevent four-child ungroup corruption, repair identity-following ancestor memory, and derive previews from the actual proposed projection.
A fresh independent review confirmed all three fixes. Native container behavior remains pending integration.

The native interaction unit is `d7a94c2`. Strict Objective-C compilation and C/Zig ABI checks passed, followed by independent static review.
The session unit is `5bd4a83`. Bounded conversion and matching checks passed, followed by independent static review.
Neither result establishes actual pointer delivery, header appearance, or restart restoration.

Runtime integration is fast-forwarded through `cd0edf4`.
`96f2878` adds group transactions and verified focus memory.
`c34aea4` adds header publication, pointer previews, and verified gesture commits.
`d97c939` and `da15c07` add clean restart conversion and populated-root preservation.
Debug and ReleaseSafe builds, repository checks, and existing headless smoke pass.

Integration review identified five defects.
Commits `cd8c607`, `2756e7b`, `0080f04`, and `8ac817a` fix affected-display transaction scope, stale-window rejection, runtime ratio import, master-layout pointer capture, and floating-coordinate origins.
A fresh independent Sol review confirmed all five fixes with no remaining P1 or P2 findings in that diff.
See [runtime review fixes](workspace-runtime-review-fixes.md) for source deductions and verification limits.

Independent comment review checked four added blocks.
It identified a false import precondition and a commented-out rule example already covered by `docs/window-rules.md`.
Both blocks were removed, six lines total.
The first review attempt lacked Git access and reviewed nothing. A fresh Sol reviewer completed the frozen-diff review.
Two public API contracts remain. No constraint encodings or application refactors were needed.

## Native acceptance checkpoint

The signed `da15c07` candidate passed all 22 existing native scene checks.
Its executable SHA256 is `8ad4bc5386799229a03cbbe507a89e10d2b8e3f0e6a0b399e017a9878bdaed05`.
These checks establish baseline behavior, not acceptance of the new workflows.

A four-window startup independently confirmed native tiling and four unique public AXIdentifiers.
The subsequent valid `restore` command restored every original frame, then crashed during session save.
The observed panic is integer overflow at `session_status.errors += 1` in `src/main.zig`.
The root cause remains under investigation in isolated branch `fix/session-save-crash`.
The full reproduction, harness corrections, native logs, and cleanup evidence are in `../huen-workspace-native/report.md`.

Combined acceptance resumes after the crash fix and independent review.
Use one exact signed candidate and one desktop owner.
The remaining sequence is:

1. Verify session-enabled restore and clean quit without a crash.
2. Verify remembered native focus, parent and child selection, tilemove, four-child groups, cycling, workspace roundtrips, and splitting.
3. Verify native header activation and modified drag and resize through the input path.
   Check unmodified delivery, master-layout passthrough, and cancellation without unintended edits.
4. Restart the manager with the same live fixture.
   Observe restored assignments, topology, ratios, active workspace, focus, and floating geometry.
   Confirm private checkpoint permissions and rejection of duplicate or unavailable identities.
5. Run the required combined baseline and rule regression checks.
   Record unsupported multi-display and native failure-injection cases separately.

The installed application and personal configuration have not changed during this iteration.
No feature PR has been opened.
