#!/bin/bash

ARBITER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# arbiter CLI: install lua-cjson for both interpreters (nvim's LuaJIT 5.1
# and standalone Lua 5.4 used by the CLI), and busted for running the spec
# suite. Then symlink cli.lua onto $PATH so `arbiter list/show/...` works
# from any cwd inside any git repo.
luarocks install lua-cjson || true
luarocks --lua-version=5.1 install lua-cjson || true
luarocks install busted || true
mkdir -p "$HOME/.local/bin"
chmod +x "$ARBITER_DIR/cli.lua"
ln -sf "$ARBITER_DIR/cli.lua" "$HOME/.local/bin/arbiter"
