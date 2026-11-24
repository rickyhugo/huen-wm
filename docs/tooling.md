# Development tools

Run these commands from the repository root.

```sh
mise trust
mise install
mise run check
mise run build
mise run test
```

Lua 5.5.1 is compiled from checked-in, checksum-recorded upstream source in `native/vendor`.
The mise Lua pin is for tooling, not a runtime dependency.

Install the repository's pre-commit and commit-msg hooks.
Linked worktrees share this Git hook configuration.

```sh
mise exec -- hk install --mise
```

`mise run test` builds `manager-tests` and runs each case in its own process.
The manager keeps its state in globals, so one process is one manager lifetime.
`mise exec -- zig build test --summary all` lists every case with its result.

`mise run smoke` runs `tools/smoke.zig` against the built binary: CLI arguments, config validation, and the socket client's handling of bad replies.
It never starts the manager. The socket part runs only when no manager is running, because it binds the manager's socket path.
`mise run native-smoke` runs `tools/native_smoke.zig` on real fixture windows. See [native smoke](native-smoke.md).
The repository has no Python. Helpers are Zig programs under `tools/`, built by `zig build`.

`mise run check` checks Zig formatting, Lua syntax, and source names without a build.
`mise run fmt` formats Zig files and runs the other checks.
Pre-commit applies the same checks to staged files and stages Zig formatting fixes.
hk preserves unstaged work with its default pre-commit stash behavior.

Use a Conventional Commit title for each new commit.
The format is `type(scope)!: subject`. The scope and `!` are optional.
For example, use `fix: handle empty input` or `feat(layout)!: change tile order`.
Accepted types are `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
`refactor`, `revert`, `style`, and `test`.
Types are case-insensitive. Use lowercase for consistency.
The subject must start with a non-whitespace character.
The commit-msg hook checks the title, not the body or footers.
Merge, revert, and fixup commits also need a Conventional Commit title.
Existing commits do not need changes.

The Lua checker rejects whitespace-only subjects and repeated `!` markers
that hk 2.9.0's built-in checker accepts.

To check a message file without creating a commit, run:

```sh
mise exec -- hk run commit-msg "/path/to/commit message.txt"
```

The name checker rejects single-letter ASCII identifiers in Zig, Objective-C,
Objective-C++, C headers, and Lua. This includes bare references and function
names, not only variable and parameter declarations. `_` remains valid.
Names after `.` are allowed, including framework members such as `point.origin.x`
and Zig enum literals such as `callconv(.c)`. C pointer members after `->` and Lua
methods after `:` are also allowed. Whitespace and comments do not break member access.
Member declarations still require descriptive names.
The checker skips comments, string literals, character literals, Lua long strings,
Zig multiline strings, and angle-bracket headers in `#include`, `#include_next`,
and `#import` directives. Zig quoted single-letter identifiers follow the same rules.
It is a lexical policy check, not a language parser or compiler.

Vendor directories named `vendor`, `vendored`, `third_party`, or `third-party`
and Zig output directories are excluded. Keep external source in those directories.

Tool versions and task definitions live in `mise.toml`.
Hook commands and file selection live in `hk.pkl`.

References are the [mise configuration](https://mise.jdx.dev/configuration.html),
[hk configuration](https://hk.jdx.dev/configuration.html), and
[Conventional Commits specification](https://www.conventionalcommits.org/en/v1.0.0/).

## Manager-seam tests

The suite tests one seam, the exported `wm_*` functions.
Each case acts as a user, an application, or a command-line caller, and asserts on what they observe.
That is the JSON reply of `windows`, `status`, or another command, or the frame where the fake screen shows a window.
The suite has no tests of pure modules or of the command line.

`tests/fake/adapter.zig` replaces `native/` and is the only mock.
It models Accessibility, Carbon, the clock, and the private files, as `native/platform.m` behaves where a case depends on it.
For example, a window is on screen only when it touches a display and no other window of its application has a frame within 4 points.
The fake writes every frame at once, so the suite does not cover animation.
`tests/layout.c` checks the Zig mirrors in `tests/fake/abi.zig` against the C headers, because the linker matches the adapter by name only.

To add a case:

1. Write `pub fn @"what the user can rely on"(manager: *Manager) !void` in a file under `tests/cases/`.
2. Add the same name to `tests/cases.zig`. The build fails when the two lists differ.
3. Take expected values from the display size and the gap, or from a relation such as "inside the display". Do not repeat the manager's arithmetic.

A case marked `restart` runs twice. The first process saves the fake world to a state file in the build cache, and the second process loads it.
`manager.world.restarted` tells the case which process it is in.
