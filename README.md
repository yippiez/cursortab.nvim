# cursortab.nvim

The **visual layer** for edit completions and cursor predictions in Neovim:
ghost text, inline diff overlays (additions / deletions / modifications), and a
cursor-jump ("TAB") indicator.

> [!NOTE]
>
> The bundled Go completion server has been removed. This repository now ships
> only the rendering layer and the editor-side glue (keymaps + autocommands).
> Bring your own backend: compute a diff, call `show_completion`, and the plugin
> draws it. See [Wiring a backend](#wiring-a-backend).

<p align="center">
    <img src="assets/demo.gif" width="600">
</p>

## Requirements

- Neovim 0.8+

No build step and no external processes — it's pure Lua.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "cursortab/cursortab.nvim",
  event = "VeryLazy",
  opts = {},
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "cursortab/cursortab.nvim",
  config = function()
    require("cursortab").setup({})
  end,
})
```

## Configuration

`setup()` accepts the following options (defaults shown):

```lua
require("cursortab").setup({
  enabled = true, -- start with the visual layer active

  keymaps = {
    accept = "<Tab>",           -- accept the visible completion/prediction, or false to disable
    partial_accept = "<S-Tab>", -- partially accept, or false
    trigger = false,            -- manual trigger key, or false
  },

  ui = {
    completions = {
      addition_style = "dimmed", -- "dimmed" or "highlight"
      fg_opacity = 0.6,          -- overlay opacity when dimmed (0 = invisible, 1 = fully visible)
    },
    jump = {
      symbol = "",               -- glyph shown before the jump text
      text = " TAB ",            -- cursor-jump indicator label
      show_distance = true,      -- append "(N lines)" for off-screen jumps
    },
  },

  blink = {
    enabled = false,   -- expose append-char ghost text as a blink.cmp source
    ghost_text = true, -- render inline ghost text for appended characters
  },
})
```

Unknown keys are rejected at `setup()` time so typos surface immediately.

### Highlight Groups

All groups are defined with `default = true`, so a colorscheme can override them.

| Group                   | Purpose                                  |
| ----------------------- | ---------------------------------------- |
| `CursorTabDeletion`     | Lines / char ranges to be deleted        |
| `CursorTabAddition`     | Added lines and appended characters      |
| `CursorTabModification` | Modified lines (new content overlay)     |
| `CursorTabCompletion`   | Inline ghost text                        |
| `CursorTabJumpSymbol`   | The jump indicator symbol                |
| `CursorTabJumpText`     | The jump indicator label                 |

Override them before or after `setup()`:

```lua
vim.api.nvim_set_hl(0, "CursorTabCompletion", { fg = "#7aa2f7", italic = true })
```

### blink.cmp Integration

When `blink.enabled = true`, the current append-character ghost text is offered
as a [blink.cmp](https://github.com/Saghen/blink.cmp) source:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "cursortab" },
    providers = {
      cursortab = { name = "Cursortab", module = "cursortab.blink" },
    },
  },
})
```

## Rendering API

The plugin renders whatever diff you hand it. A completion is a `DiffResult`
made of `groups`; each group targets a buffer line and describes how to draw it.

```lua
local cursortab = require("cursortab")

-- Ghost text appended to the cursor line.
cursortab.show_completion({
  groups = {
    {
      type = "modification",
      start_line = 1,
      end_line = 1,
      buffer_line = 20,                 -- 1-indexed absolute buffer line
      lines = { "local x = compute()" },-- new content
      old_lines = { "local x = " },     -- existing content
      render_hint = "append_chars",     -- append_chars | replace_chars | delete_chars | stacked | nil
      col_start = 10,                   -- byte offset where new chars begin
      col_end = 10,
    },
  },
  startLine = 20,
  cursor_line = 1,
  cursor_col = 10,
})

-- The cursor-jump ("TAB") indicator on line 42.
cursortab.show_cursor_prediction(42)

-- Clear everything.
cursortab.clear()
```

Group `type` is `"modification"`, `"addition"`, or `"deletion"`. For single-line
character-level edits, set `render_hint` to `append_chars` (ghost text for the
appended suffix), `replace_chars` (overlay the line, highlight the changed span),
or `delete_chars` (highlight the span to remove). Multi-line modifications may
use the `stacked` hint to render new content on virtual lines below the old.

Run `:CursortabDemo` to render a sample completion on the current line and see
the ghost text without any backend.

## Wiring a backend

The plugin owns the keymaps and autocommands; your backend reacts by overriding
handlers and rendering. All handlers default to no-ops.

```lua
local cursortab = require("cursortab")

cursortab.handlers.event = function(name)
  -- name: "text_changed" | "cursor_moved" | "insert_enter" | "insert_leave" | "file_saved"
  -- Request a completion from your source, then render it:
  --   cursortab.show_completion(diff)
  --   cursortab.show_cursor_prediction(line)
end

cursortab.handlers.accept = function()
  -- Apply the currently displayed edit to the buffer.
end

cursortab.handlers.partial_accept = function() end
cursortab.handlers.trigger = function() end -- manual trigger key
cursortab.handlers.reject = function() end  -- visuals were dismissed
```

The visual layer clears itself when the cursor moves or the buffer changes in a
way that no longer matches the ghost text, so backends only need to render.

## Usage

### Commands

- `:CursortabToggle` — enable/disable the visual layer.
- `:CursortabDemo` — render a sample ghost-text completion on the current line.

### Public API

| Function                                | Description                                     |
| --------------------------------------- | ----------------------------------------------- |
| `show_completion(diff_result)`          | Render a completion diff.                       |
| `show_cursor_prediction(line_num)`      | Render the jump indicator at a 1-indexed line.  |
| `clear()`                               | Clear all visuals.                              |
| `accept()`                              | Accept the visible completion (returns bool).   |
| `is_completing()`                       | True while an accept is being applied.          |
| `toggle()`                              | Toggle the visual layer.                        |
| `handlers`                              | Table of overridable backend handlers.          |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
