# arbiter CLI

Standalone command-line interface for the [arbiter](../lua/custom/plugins/arbiter.lua) review-notes plugin. Lets you read and update notes from outside Neovim — shell scripts, CI hooks, or just a terminal.

Notes live in `<git_dir>/arbiter.jsonl`, one JSON record per line. The plugin (the human side) creates them; this CLI (the AI/automation side) consumes and updates them.

## Layout

- `cli.lua` — the entry point. Symlinked to `~/.local/bin/arbiter` by `setup.sh`.
- `setup.sh` — installs `lua-cjson` (for both LuaJIT 5.1 and Lua 5.4), `busted`, and the `arbiter` symlink. Called by the top-level `~/.config/nvim/setup.sh`.
- `spec/` — busted tests for `core.lua` and `cli.lua`. Run with `busted spec/` from this directory.

The pure-Lua data layer (record schema, JSONL IO, filters, hashing) lives in [`../lua/custom/local-plugins/arbiter/core.lua`](../lua/custom/local-plugins/arbiter/core.lua) and is shared with the Neovim plugin.

## Usage

```
arbiter list [filter flags...] [--json]
arbiter show <id> [--json]
arbiter set-status <id> <pending|in-progress|needs-rereview|resolved>
arbiter resolve <id>
arbiter add <file> <line-or-range> [--commit <sha> | --commit-null] < note-body
arbiter reply <id> [--author <name>] < reply-body
```

`arbiter --help` has the full filter list and exit-code taxonomy. The CLI must run from inside a git repo; `arbiter list` defaults to actionable notes (`pending` + `needs-rereview`) on the current branch.

## Tests

```
cd ~/.config/nvim/arbiter && busted spec/
```
