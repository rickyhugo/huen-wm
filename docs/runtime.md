# Runtime ownership

`src/main.zig` owns window intent, monitor selection, workspace selection, typed commands, configuration, and derived layout goals. Window order is stable until an explicit swap. Layout calculation does not call Accessibility.

`native/platform.m` observes Cocoa and Accessibility, retains AX objects, applies geometry, registers Carbon hotkeys, and draws nonactivating panels. Stable identities come from retained `CFEqual` AX objects scoped to each live PID. Titles are display text only. No private window-ID or Space API is used.

All mutations run on the main thread. AX notifications set a dirty flag. A coalesced snapshot runs at most once per 150 ms, with a repair scan every two seconds. Failed per-application scans preserve observations as stale. A successful scan removes missing windows. AX calls have an 80 ms messaging timeout. Many stalled applications can still delay the main loop because the timeout applies per call.

Frames use global top-left points in Zig. The Cocoa adapter converts using the primary display height. Visible monitor frames exclude the menu bar and Dock. CG on-screen bounds match PID, layer, and geometry only to avoid moving windows on another native Space. A match requires exactly one AX candidate and one CG candidate. Ambiguous windows remain unmanaged unless the runtime already owns their parking recovery. The match never assigns identity or proves native Space membership. This safety heuristic can omit unusual windows. Native fullscreen blocks its display conservatively, including when its Space is not current.

Binding names refer to physical keys, not characters produced by the active input layout. Letter, digit, and punctuation names use the ANSI positions from the macOS SDK `Events.h` virtual-key constants. `section` names the ISO key at code `0x0a`. For example, `j`, `k`, and `l` use codes `0x26`, `0x28`, and `0x25`. Numbered workspaces use the physical number row, not the keypad.

## Transactions

Reload parses into a candidate configuration. Carbon registrations reuse stable slots and stage new keys before releasing old ones. A collision rolls back only new registrations. After successful registration, the candidate becomes active. Existing window assignments survive reload, clamped when workspace count shrinks. New-window rules apply at discovery.

`native/scene.m` owns display snapshots and Core Animation covers. It does not move windows. A workspace command records a generation and asks for capture. Its callback performs a bounded AX placement transaction, reads back geometry, rolls back on rejection, commits focus, and fades the matching generation. Missing capture permission takes the same placement path without a cover. Commands that mutate layout wait until the current transition ends. Status remains available. Restore and shutdown cancel capture before restoring geometry.

Visibility changes share a synchronous placement transaction, including reconciliation after rules, reload, workspace-count reduction, and display migration. The transaction reads the prior frame, writes the target, and verifies all four coordinates within two points. Rejection triggers a verified rollback. Failed rollback retains parking recovery ownership so an offscreen window remains eligible for repair. Floating intent and pre-parking geometry are separate fields.

Placement rejection is observable through `status.transition_error`, `windows[].placement_error`, and stderr with a window identity. A failed workspace command attempts rollback without claiming that rollback succeeded. A queued scene command returns `accepted` and a generation, not a claim that placement has completed. The scene has a three-second watchdog, but it cannot execute while synchronous AX work blocks the main thread.

Derived tiles stay inside the display's usable area. Tiles smaller than 80 points in either dimension degrade to floating windows. This threshold is a crowding limit, not an application minimum-size estimate. Normal animation completion verifies geometry. A rejected or app-clamped goal degrades to floating geometry instead of restarting the same animation indefinitely. A rejected tiled unpark falls back to bounded pre-parking geometry on retry. Application constraints can still reject floating recovery geometry. Such windows retain recovery ownership and an error until placement succeeds.

## Safety and recovery

The process uses a per-user lock and mode-0600 Unix socket. Clients reject sockets owned by another user. The filter `--app dev.huen-wm.fixture` limits discovery before any AX window is retained or changed. Permission checks never prompt.

Original geometry is retained before the first placement. Restore cancels animations for every retained window before any restoration. It reads current minimized and fullscreen attributes rather than trusting the last snapshot. Missing state attributes prevent a write. Only a verified return to original geometry clears restoration eligibility. Explicit restore suspends policy so reconciliation does not tile windows again. Its error response includes an `outstanding` count when restoration remains incomplete. Later restore commands and shutdown retry outstanding windows. Shutdown logs failures but cannot provide recovery after process exit. Recovery never unhides an application or deminimizes a user window. Hard-kill recovery is unsupported. Persisting titles or guessing a new AX identity would risk moving the wrong window.

The current build has not passed permission-granted native validation. Remaining checks include geometry acceptance under real app constraints, hotkey collisions, native Space changes, monitor removal, scene latency, border appearance, and restoration after external minimization. Full-display capture can be denied independently of Accessibility. Neither permission is necessary for headless config validation.
