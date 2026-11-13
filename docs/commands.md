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

Focus-dependent actions read the frontmost application's focused AX window immediately.
They do not reuse the periodic observation's focused flag.
An unknown or unmanaged focus returns `NoFocusedWindow`.
Focus replies report an accepted native request separately from immediate verification.
`verified = false` means that activation has not been observed on the target.
The next command reads actual focus again.

## Existing command grammar

Existing verbs keep their grammar and reject extra arguments.

| Commands | Arguments |
| --- | --- |
| `status`, `windows`, `monitors`, `workspaces` | None. |
| `reload`, `quit`, `stop`, `restore`, `recover` | None. |
| `swap`, `move` | One direction. |
| `resize` | One finite ratio delta with absolute value at most `0.5`, or `width`/`height` and a finite point delta with absolute value at most `10000`. |
| `split` | `horizontal`, `vertical`, or `toggle`. |
| `fullscreen` | None. Toggles managed fullscreen without creating a macOS Space. |
| `toggle-floating` | None. |
| `layout` | `dwindle` or `master`. |
| `workspace`, `send-to-workspace` | One workspace index, starting at `1`. |
| `mode` | One configured mode name. |

Flags precede their positional argument.
Repeated flags and unknown options are invalid.
Runtime command text is bounded by the existing 511-byte transport limit.
