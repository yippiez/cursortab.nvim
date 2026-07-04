---
name: config
description: Guidelines for adding, removing, or updating configuration options in cursortab.nvim. Use when modifying config fields, enum values, or validation logic.
---

## Design Principle

cursortab.nvim is pure Lua. All config lives in `lua/cursortab/config.lua`:
the schema, defaults, validation, and highlight groups. There is no external
process and no config serialization — `config.get()` returns the merged table
that the rest of the plugin reads directly.

Config sections: `enabled`, `keymaps`, `ui`, `blink`. Unknown keys are
rejected at `setup()` time by `validate_config_keys()`, so typos surface
immediately.

## Files to Update

When modifying config options, update these locations:

### 1. Config module — `lua/cursortab/config.lua`

- Type annotation in the appropriate `---@class` block (e.g., `---@field new_option type`)
- Default value in the `default_config` table
- Validation in `validate_config()`:
  - For enum-like options, add a `valid_*` lookup table (e.g., `valid_addition_styles`) and raise a clear error listing the allowed values
  - For numeric ranges / typed values, add a direct check
- If adding or changing a highlight group default, update `config.setup_highlights()`

Unknown-key rejection is automatic via `validate_config_keys()` — no update
needed there unless you are changing the validation logic itself.

### 2. Consumers

Grep for the option and update the modules that read it:

- `ui.lua` — reads `ui.completions.*`, `ui.jump.*`, `blink.ghost_text`
- `events.lua` — reads `keymaps.*`
- `blink.lua` — reads `blink.*`

### 3. Documentation

- `README.md` — the configuration example and the options table
- `doc/cursortab.txt` — the vim help configuration example; keep it in sync with the README

## Checklist

For enum-like options (e.g., `ui.completions.addition_style`):

- [ ] Add a `valid_*` table in config.lua
- [ ] Add the check + error message (listing valid values) in `validate_config()`
- [ ] Add the `---@field` annotation and a default in `default_config`
- [ ] Update the consumer(s) in ui.lua / events.lua / blink.lua
- [ ] Update README.md and doc/cursortab.txt

For simple options:

- [ ] Add the `---@field` type annotation in the appropriate `---@class` block
- [ ] Add the default value in `default_config`
- [ ] Add validation in `validate_config()` if needed (numeric ranges, types)
- [ ] If `ui.jump.*` or a new highlight, update `config.setup_highlights()`
- [ ] Update the consumer(s)
- [ ] Update README.md and doc/cursortab.txt

For removing or renaming options:

- [ ] Remove the field from `default_config` and the `---@class` blocks
- [ ] Remove any validation and `valid_*` entries for it
- [ ] Remove or update the consumer(s)
- [ ] Update README.md and doc/cursortab.txt

## Example: Adding an enum value

Adding "underline" to `ui.completions.addition_style`:

```lua
-- config.lua
local valid_addition_styles = { dimmed = true, highlight = true, underline = true }

-- In validate_config():
-- error: "Must be one of: dimmed, highlight, underline"
```

```markdown
<!-- README.md and doc/cursortab.txt -->
addition_style = "dimmed", -- "dimmed", "highlight", or "underline"
```
