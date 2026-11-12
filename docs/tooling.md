# Development tools

Run these commands from the repository root.

```sh
mise trust
mise install
mise run check
mise run build
```

Install the pre-commit hook from the main checkout, not a linked worktree.
This changes the repository's shared Git hook configuration.

```sh
mise exec -- hk install
```

`mise run check` checks Zig formatting, Lua syntax, and source names without a build.
`mise run fmt` formats Zig files and runs the other checks.
Pre-commit applies the same checks to staged files and stages Zig formatting fixes.
hk preserves unstaged work with its default pre-commit stash behavior.

The name checker rejects single-letter ASCII identifiers in Zig, Objective-C,
Objective-C++, C headers, and Lua. This includes references, members, and function
names, not only variable and parameter declarations. `_` remains valid.
The checker skips comments, string literals, character literals, Lua long strings,
and Zig multiline strings. Zig quoted single-letter identifiers still fail.
It is a lexical policy check, not a language parser or compiler.

Vendor directories named `vendor`, `vendored`, `third_party`, or `third-party`
and Zig output directories are excluded. Keep external source in those directories.

Tool versions and task definitions live in `mise.toml`.
Hook commands and file selection live in `hk.pkl`.

References are the [mise configuration](https://mise.jdx.dev/configuration.html)
and [hk configuration](https://hk.jdx.dev/configuration.html) documentation.
