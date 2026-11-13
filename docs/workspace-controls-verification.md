# Workspace controls verification

The five requested feature areas passed combined native fixture acceptance on one built-in display.
They cover focus memory, container editing and groups, mouse tiling, session continuity, and richer rules.
Scratchpad workspaces are outside this iteration.

## Artifact and checks

- Runtime source is `5a1c08d340b401cee4cc002788c6e6d93685ff4a`.
- Signed ReleaseSafe executable SHA256 is `a80c834caa55e0558bb3058e27eb16e276a6a8abafce51947c68a596f3a2398e`.
- Debug build, ReleaseSafe bundle, fixture build, repository checks, and strict signature verification passed.
- No candidate rebuild followed native acceptance.
- Independent Sol reviews covered the implementation units, integration corrections, and session cleanup fix.
  No distinct-model-family review ran.

The accepted runs recorded 210 passing observation checks and 28 separate cleanup checks.
Counts include startup and helper-readiness observations, not independent product requirements.
Every accepted run has zero cleanup errors.

| Run | Observation checks | Cleanup checks |
| --- | ---: | ---: |
| Session-enabled lifecycle | 7 | 1 |
| Focus and container commands | 18 | 3 |
| Header and native mouse interaction | 31 | 3 |
| Assignment, group, ratio, and floating restart | 30 | 3 |
| Duplicate identifiers | 12 | 3 |
| Missing identifiers | 13 | 3 |
| Existing native scenes | 20 | 2 |
| Literal and glob rules | 12 | 2 |
| Geometry clamping | 10 | 2 |
| Rule precedence and rejected reload | 10 | 2 |
| Cancellation checkpoint comparisons | 30 | 1 |
| Four direct group members and restart | 17 | 3 |

The unchanged baseline driver passed all 22 required checks, including its two cleanup checks.
It can be rerun against a signed bundle with:

```sh
python3 scripts/native-smoke.py --scenes --app "/absolute/path/Huen WM.app" --output "/new/evidence/directory"
```

## Observed behavior

### Focus and containers

An empty-workspace roundtrip returned native focus to a nondefault window.
Parent and child commands selected distinct logical containers.
Tilemove changed native geometry.
Joining grew a group from two to four members.
Next and previous changed the actual key window.
Stacked conversion, workspace return, and four-member splitting produced the expected visible geometry without overlap or placement errors.

A separate checkpoint contained exactly one stacked group with four direct leaf children.
After an actual manager restart with the same fixture process, all four windows matched.
The selected key window returned, public AX exposed four header labels, and splitting restored four contained, nonoverlapping frames.

### Headers and mouse controls

Public AX exposed header labels and selection values.
AXPress selected a hidden member while the fixture remained the active application.
Header-only screenshots show the tabbed and stacked presentations.

![Tabbed group with Alpha selected](images/tabbed-group.png)

![Stacked group with Gamma selected](images/stacked-group.png)

Synthetic events traversed the native input path only while the fixture was frontmost.
Fixture counters confirmed ordinary left-button delivery.
Modified left reorder and right-boundary resize changed native geometry only after release.
The fixture did not receive those captured button streams.
Master layout passed modified left input through without changing geometry.

Escape and modifier loss consumed the owned release without changing geometry.
Canonical clean-checkpoint comparisons also preserved topology, ratios, selected children, focus, assignments, floating intent, and active workspace.
These comparisons began with a leaf editing selection.
Each gesture restored the cursor, released both buttons, and preserved the relevant modifier state.

### Session continuity and rules

Clean quit restored original frames and wrote a clean mode-0600 checkpoint.
Restart with the same fixture process matched four windows with zero session errors.
Assignments, floating intent and native frame, active workspace, focus, group child selection, and runtime ratio returned.
Visible native geometry matched its pre-quit state.

Four duplicate AXIdentifiers yielded zero matches and four ambiguous saved records.
Fresh rules applied instead of saved assignments or floating state.
Missing identifiers and document URLs yielded no zero-window checkpoint.
Save reported skipped with unavailable metadata and zero errors.

Native rule runs covered literal title geometry, glob workspace routing, default tiling, clamping, workspace return, later floating overrides, and malformed-rule reload rejection.
Rejected reloads preserved native frames.

## Corrections and qualifications

The earlier candidate crashed after restoring frames during session save.
Its deferred cleanup cleared the optional checkpoint owner before releasing the arena.
The cleanup-order fix alone removed the ReleaseSafe crash.
Independent review confirmed success, error, and skip cleanup paths.
Native fault injection of save errors remains unverified.

All failed or interrupted acceptance attempts remain in the local evidence.
Driver corrections addressed modifier syntax, fixture field names, native truth values, unavailable AX nodes, inherited constants, and unrelated CG flags.
An infeasible split correctly rejected application minimum sizes and restored the original frames.
Other assertions were corrected to respect bounded floating restoration and deferred metadata collection.
Those attempts are excluded from the accepted counts.

Group selected-child continuity is proven.
An internal parent editing selection is not promised across restart activation.
Verified native focus resets the editing selection to its leaf.
The observed parent-to-leaf change did not alter group selection or tree structure.

Unverified cases include multiple displays, negative secondary-display coordinates, physical input hardware, global hotkey delivery, permission revocation, tap failure, forced shutdown draining, rollback failure injection, document-URL identity fallback, and arbitrary user applications.
Unmodified right-button and master-right passthrough were not separately exercised.
Header screenshots do not establish workspace-animation appearance.

## Evidence and cleanup

Raw reports, per-command snapshots, native fixture frames, checkpoint copies, and reusable external drivers are in `../huen-workspace-acceptance/`.
The crash reproduction and narrow correction are in `../huen-session-crash/`.
These local directories are not part of a fresh clone.

Every accepted run restored original fixture frames and stopped its owned processes.
AeroSpace returned to its original enabled state, PID, and main mode.
Only uniquely scoped fixture checkpoints were removed.
The normal unfiltered checkpoint was not touched.

The installed app remained unchanged throughout acceptance.
The initial personal-config hash was not captured, so acceptance has no before-and-after config-hash proof.
The verifier made no personal-config edits.
