# Development tools

Run these commands from the repository root.

```sh
mise trust
mise install
mise run check
mise run build
```

Install the repository's pre-commit and commit-msg hooks.
Linked worktrees share this Git hook configuration.

```sh
mise exec -- hk install --mise
```

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
