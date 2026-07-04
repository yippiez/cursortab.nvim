# Contributing

Contributions are welcome! Please open an issue or a pull request.

cursortab.nvim is now a pure-Lua plugin — the visual layer for edit
completions and cursor predictions. There is no build step and no external
server.

## Prerequisites

- Neovim 0.8+
- [luajit](https://luajit.org/) (optional, for syntax-checking outside Neovim)

## Layout

```
lua/cursortab/
  init.lua     Entry point: setup, public API, commands
  config.lua   Config schema, validation, highlight groups
  ui.lua       Rendering: ghost text, diff overlays, jump indicator
  events.lua   Keymaps and autocommands; backend handler hooks
  blink.lua    Optional blink.cmp source for append-char ghost text
```

## Checking your changes

Syntax-check every module with luajit:

```bash
for f in lua/cursortab/*.lua; do luajit -bl "$f" >/dev/null && echo "ok: $f"; done
```

Load and exercise the visuals inside Neovim:

```bash
nvim -u scripts/init.lua somefile.lua
# then, in Neovim:
:CursortabDemo   # render sample ghost text on the current line
```

`scripts/init.lua` loads the plugin from the repo root, and
`scripts/nvim-test.sh <version>` runs an isolated Neovim against it.

## Code Style

Match the surrounding Lua: tabs for indentation, `snake_case` for locals and
functions, and LuaCATS annotations (`---@param`, `---@return`) on public
functions.
