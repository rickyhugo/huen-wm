# Commands and binding modes

## Binding modes

Top-level `bindings` defines `main`. `modes` is an optional dense array of named modes.
Mode names contain ASCII letters, digits, hyphens, or underscores.
Names are unique and contain at most 63 bytes.
The name `main` is reserved for top-level bindings.

```lua
return {
	bindings = {
		{ key = "r", mods = "alt+shift", command = "mode resize" },
		{ key = "h", mods = "alt", command = "focus --wrap left" },
		{ key = "return", mods = "alt", command = "launch com.mitchellh.ghostty" },
	},
	modes = {
		{
			name = "resize",
			bindings = {
				{ key = "h", mods = "", command = "resize -0.05" },
				{ key = "l", mods = "", command = "resize 0.05" },
				{ key = "return", mods = "", command = "mode main" },
				{ key = "escape", mods = "", command = "mode main" },
			},
		},
	},
}
```

There are at most eight modes, including `main`, and 256 bindings in total.
Each mode has at most 128 bindings.
Every non-main mode requires unmodified Escape bound to `mode main`.
An unmodified Return binding is optional.
Only non-main modes accept `mods = ""`.
Main bindings require at least one modifier.
Duplicate key-and-modifier pairs are invalid within a mode.
Different modes can bind the same pair.

Mode tables accept only `name` and `bindings`.
Binding tables accept only `key`, `mods`, and `command`.
Mode arrays and binding arrays must be dense.
Unknown fields, metatables, NUL bytes, and unknown mode targets are invalid.
Mode references resolve after all names have been collected.
Configuration binding commands contain at most 127 UTF-8 bytes.

`mode NAME` replaces the active bindings without inheriting main bindings.
A hotkey registration failure leaves the old mode and bindings active.
A successful configuration reload activates the candidate's `main`.
A failed reload preserves the current mode and configuration.
`status.active_mode` reports the active name.
The menu bar shows a non-main mode name instead of its workspace label.
The tooltip includes the mode name.

## Application commands

| Command | Behavior |
| --- | --- |
| `launch BUNDLE` | Requests application activation or launch by bundle ID. |
| `launch --new-instance BUNDLE` | Requests a new application instance through NSWorkspace. |
| `exec-and-forget SHELLTEXT` | Starts `/bin/sh -c` with the remaining command text. |
| `close` | Presses the focused known window's AX close button. |
| `close --quit-if-last-window` | Requests close, then conditionally requests normal application termination. |

Bundle IDs contain at most 127 bytes of ASCII letters, digits, periods, or hyphens.
`launch` does not interpret shell syntax.
An unknown bundle ID returns `ApplicationNotFound`.
Launch replies contain `accepted` and a `request_id`.
Acceptance does not mean that an application has created a window.
`status.launch` reports the latest request.
Its numeric state is `0` before a request, `1` while pending, `2` after completion, or `3` after failure.
The completion message contains the native error when available.
A successful NSWorkspace completion does not guarantee a new window.

`exec-and-forget` explicitly interprets shell syntax.
Commands must fit on one line. Embedded carriage returns and newlines are invalid
in CLI operands and configured bindings. Shell commands can use semicolons or a
script path instead.
Lua configuration evaluation does not execute this command.
The shell starts only when the binding or runtime command runs.
Standard input, output, and error use the null device.
The command returns after process creation without waiting for shell completion.
The reply does not report the shell's exit status.
The native task copies shell text before the command buffer is released.

```sh
huen-wm launch com.google.Chrome
huen-wm launch --new-instance com.mitchellh.ghostty
huen-wm exec-and-forget 'open -a Flameshot --args gui'
huen-wm close --quit-if-last-window
```

Close requires an immediate AX focus match in the frontmost application.
Unknown, stale, minimized, and fullscreen windows are not closed.
Close never sends a keyboard shortcut or force-terminates an application.
The close reply acknowledges the AX request, not completed closure.

For conditional termination, Zig tracks the window identity, process ID, process launch date, and a five-second deadline.
The native adapter retains the original AX element.
After a complete AX window enumeration no longer contains that element, Zig decides whether to request termination.
The enumeration includes minimized, fullscreen, and unmanaged windows.
Any remaining window prevents termination.
An unknown enumeration result never permits termination.
The adapter rechecks the full enumeration and the process launch date before normal termination.
Save prompts can delay or cancel close and termination.
An expired close request does not terminate the application.
Only one conditional close request can be pending.
`status.close_state` reports its state.
`termination_requested` does not mean that the application has exited.
Restore and shutdown cancel a pending request.

## Focus commands

`focus DIRECTION` keeps the existing directional search, including cross-display candidates.
`focus --wrap DIRECTION` restricts candidates to the source display and workspace.
Directions are `left`, `right`, `up`, and `down`.
The search prefers windows ahead of the source.
At an edge, the wrapped search selects the opposite edge.
Wrapped-focus geometry ties use window identity.
With one eligible window, wrapped focus keeps that window.

`focus last` focuses the most recently focused window other than the current one.
A 16-entry history records verified and observed focus changes.
Closed windows leave the history.
Minimized, native fullscreen, stale, and display-less windows are skipped.
A target on a hidden workspace first switches its display to that workspace.
That switch reveals and focuses the target instead of the workspace's own candidate.
Without a candidate, `focus last` returns `NoPreviousWindow`.
With `workspace_monitors`, a target stranded off the owner display returns `WindowOffOwnerDisplay`.

`cycle next` and `cycle previous` focus through the active display's visible windows.
`cycle next tiled` and `cycle next floating` restrict the candidates to one kind.
Tiled windows come before floating windows.
Each kind is ordered top to bottom, then left to right, then by identity.
The order wraps.
Minimized, stale, native fullscreen, group-hidden, and parked windows are skipped.
Without a candidate, `cycle` returns `NoWindowToCycle`.
With one candidate, `cycle` focuses it again.

`swap next` and `swap previous` swap the focused tile with its neighbor in the same tiled order.
They use the directional swap's placement and focus verification.
A floating or managed fullscreen window returns `WindowNotTiled`.
A single tile replies `changed: false`.

Focus-dependent actions read the frontmost application's focused AX window immediately.
They do not reuse the periodic observation's focused flag.
An unknown or unmanaged focus returns `NoFocusedWindow`.
Focus replies report an accepted native request separately from immediate verification.
`verified = false` means that activation has not been observed on the target.
The next command reads actual focus again.

## Workspace selectors

`workspace`, `send-to-workspace`, and `move-to-workspace` take one selector.

| Selector | Target |
| --- | --- |
| `N` | Workspace `N`, starting at `1`. |
| `name:NAME` | The workspace named `NAME`. The name runs to the end of the command and can contain spaces. |
| `previous` | The workspace shown before the current one. |
| `+N`, `-N` | The workspace `N` positions after or before the current one. The position wraps within the configured set. |
| `occupied+N`, `occupied-N` | The same step, counting only the current workspace and workspaces with eligible windows. |
| `empty` | The first workspace without eligible windows. |
| `next-empty` | The first workspace without eligible windows after the current one, with wrap. |

Offsets require a sign. Their absolute value is from 1 to 10.
Eligible windows are not minimized, native fullscreen, or stale.
Configuration rejects a `name:` selector without a matching workspace with `UnknownWorkspaceName`.
After a reload removes that name, the runtime command returns the same error.

With `workspace_monitors`, selectors resolve against the owner display.
Otherwise they resolve against the active display and never select another monitor.
Each display has its own previous workspace.
With `workspace_monitors`, one previous workspace follows the owner across migration.
The previous workspace changes only after a switch commits.
A reload maps it to the workspace with the same name, or drops it.

`previous` without a recorded workspace returns `NoPreviousWorkspace`.
`empty` and `next-empty` without a match return `NoEmptyWorkspace`.
`occupied+N` without another occupied workspace selects the current workspace.
Selecting the current workspace replies `changed: false` and focuses its candidate.

Set `workspace_back_and_forth = true` to make an index or name selector that matches the current workspace select the previous workspace.
This applies to all three commands.
Without a previous workspace, the selection stays on the current workspace.
The option defaults to `false`.

`move-to-workspace SELECTOR` sends the focused window and shows the target workspace in one placement commit.
It then focuses the moved window and reports `verified` and `target`.
It does not use the snapshot transition.
Selecting the window's own workspace replies `changed: false`.

## Floating geometry commands

`center` centers the focused floating window in its display's gapped area.
`move-by DX DY` moves the focused floating window by logical points.
Both keep the window inside the gapped area.
A tiled window returns `WindowNotFloating`.
`move DIRECTION` keeps its existing behavior and makes a tiled window floating.

`resize-by DX DY` keeps a floating window's top-left corner.
Its width and height stay between 80 points and the gapped area's right and bottom edges.
For a tiled window, `resize-by` applies `resize width DX` and `resize height DY` for each non-zero value.
Master layout rejects a non-zero `DY` with `MasterHeightResizeUnsupported` before it changes the layout.
The tiled reply reports `applied.width` and `applied.height`.
A managed fullscreen window returns `ManagedFullscreenActive` for all three commands.

## Command grammar

Verbs reject extra arguments.

| Commands | Arguments |
| --- | --- |
| `status`, `windows`, `monitors`, `workspaces` | None. |
| `reload`, `quit`, `stop`, `restore`, `recover` | None. |
| `swap` | One direction, `next`, or `previous`. |
| `move` | One direction. |
| `focus` | `last`, or an optional `--wrap` and one direction. |
| `cycle` | `next` or `previous`, then optionally `tiled` or `floating`. |
| `center` | None. |
| `move-by`, `resize-by` | Two finite point deltas, each with absolute value at most `10000`. |
| `tilemove` | One direction. Detaches and reparents the selected tiled subtree. |
| `select` | `parent` or `child`. Changes logical selection without native focus. |
| `group join` | One direction. Joins the selected subtree to a neighboring group or leaf. |
| `group` | `tabbed`, `stacked`, `split`, `next`, or `previous`. |
| `resize` | One finite ratio delta with absolute value at most `0.5`, or `width`/`height` and a finite point delta with absolute value at most `10000`. |
| `split` | `horizontal`, `vertical`, or `toggle`. |
| `fullscreen` | None. Toggles managed fullscreen without creating a macOS Space. |
| `toggle-floating` | None. |
| `layout` | `dwindle` or `master`. |
| `workspace`, `send-to-workspace`, `move-to-workspace` | One workspace selector. |
| `mode` | One configured mode name. |

Flags precede their positional argument.
Repeated flags and unknown options are invalid.
Runtime command text is bounded by the existing 511-byte transport limit.

## Container commands

The parser and pure layout APIs support these commands.
Runtime dispatch and verified native placement require integration in `main.zig`.
The existing runtime dispatch does not yet handle the new variants.

`select parent` selects the actual parent container.
`select child` selects its remembered eligible child, or its first eligible child.
Neither command requests application activation.

`tilemove DIRECTION` changes topology instead of swapping window identities.
The direction determines the split axis and the insertion order.
`group join DIRECTION` appends the selection to the neighboring explicit group.
Without a target group, it creates a tabbed group with the target first.
Directional edits do not wrap.
No eligible target returns `NoTileTarget`.

`group tabbed` and `group stacked` convert a selected binary split or change a selected group's mode.
A selected leaf returns `NoContainer`.
`group split` converts a selected group to an ordered binary split chain.
`group next` and `group previous` cycle the nearest selected ancestor group's eligible direct children.
The pure API returns a focus candidate, not evidence of successful native focus.

Container commands require dwindle and return `ContainerRequiresDwindle` in master.
The existing floating `move`, identity `swap`, and `focus --wrap` grammar is unchanged.
