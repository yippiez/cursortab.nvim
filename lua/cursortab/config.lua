-- Configuration management for cursortab.nvim

---@class CursortabUIJumpConfig
---@field symbol string
---@field text string
---@field show_distance boolean

---@class CursortabUICompletionsConfig
---@field addition_style string "dimmed" or "highlight"
---@field fg_opacity number opacity for completion overlays (0=invisible, 1=fully visible)

---@class CursortabUIConfig
---@field completions CursortabUICompletionsConfig
---@field jump CursortabUIJumpConfig

---@class CursortabKeymapsConfig
---@field accept string|false Accept keymap (e.g., "<Tab>"), or false to disable
---@field partial_accept string|false Partial accept keymap (e.g., "<S-Tab>"), or false to disable
---@field trigger string|false Trigger completion keymap (e.g., "<C-Space>"), or false to disable

---@class CursortabBlinkConfig
---@field enabled boolean
---@field ghost_text boolean

---@class CursortabConfig
---@field enabled boolean
---@field keymaps CursortabKeymapsConfig
---@field ui CursortabUIConfig
---@field blink CursortabBlinkConfig

-- Default configuration
---@type CursortabConfig
local default_config = {
	enabled = true,

	keymaps = {
		accept = "<Tab>", -- Keymap to accept completion, or false to disable
		partial_accept = "<S-Tab>", -- Keymap to partially accept completion, or false to disable
		trigger = false, -- Keymap to manually trigger completion, or false to disable
	},

	ui = {
		completions = {
			addition_style = "dimmed", -- "dimmed" or "highlight"
			fg_opacity = 0.6, -- opacity for completion overlays (0=invisible, 1=fully visible)
		},
		jump = {
			symbol = "",
			text = " TAB ",
			show_distance = true,
		},
	},

	blink = {
		enabled = false,
		ghost_text = true,
	},
}

-- Valid values for enum-like config options
local valid_addition_styles = { dimmed = true, highlight = true }

-- Validate that all keys in user config exist in default config
---@param user_cfg table User configuration
---@param default_cfg table Default configuration
---@param path string Current path for error messages
local function validate_config_keys(user_cfg, default_cfg, path)
	for key, value in pairs(user_cfg) do
		if default_cfg[key] == nil then
			error(string.format("[cursortab.nvim] Unknown config option: %s%s", path, key))
		end
		-- Recursively validate nested tables (skip lists with numeric keys)
		if type(value) == "table" and type(default_cfg[key]) == "table" and next(value) ~= nil and type(next(value)) ~= "number" then
			validate_config_keys(value, default_cfg[key], path .. key .. ".")
		end
	end
end

-- Validate configuration values
---@param cfg table
local function validate_config(cfg)
	-- First, validate that all keys are recognized
	validate_config_keys(cfg, default_config, "")

	-- Validate keymaps.accept (must be string or false)
	if cfg.keymaps and cfg.keymaps.accept ~= nil then
		local accept = cfg.keymaps.accept
		if accept ~= false and type(accept) ~= "string" then
			error("[cursortab.nvim] keymaps.accept must be a string (keymap) or false to disable")
		end
		if type(accept) == "string" and accept == "" then
			error("[cursortab.nvim] keymaps.accept cannot be an empty string (use false to disable)")
		end
	end

	-- Validate addition style
	if cfg.ui and cfg.ui.completions and cfg.ui.completions.addition_style then
		if not valid_addition_styles[cfg.ui.completions.addition_style] then
			error(string.format(
				"[cursortab.nvim] Invalid ui.completions.addition_style '%s'. Must be one of: dimmed, highlight",
				cfg.ui.completions.addition_style
			))
		end
	end

	-- Validate fg_opacity
	if cfg.ui and cfg.ui.completions and cfg.ui.completions.fg_opacity then
		local f = cfg.ui.completions.fg_opacity
		if type(f) ~= "number" or f < 0 or f > 1 then
			error("[cursortab.nvim] ui.completions.fg_opacity must be a number between 0 and 1")
		end
	end
end

---@class ConfigModule
local config = {}
---@type CursortabConfig
local current_config = vim.deepcopy(default_config)

-- Get current configuration
---@return CursortabConfig
function config.get()
	return current_config
end

-- Set up configuration with user overrides
---@param user_config table|nil User configuration overrides
---@return CursortabConfig
function config.setup(user_config)
	local user = user_config or {}
	validate_config(user)
	current_config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user)
	return current_config
end

-- Set up default values for highlight groups
function config.setup_highlights()
	vim.api.nvim_set_hl(0, "CursorTabDeletion", {
		default = true,
		ctermbg = "DarkRed",
		bg = "#4f2f2f",
		bold = false,
	})

	vim.api.nvim_set_hl(0, "CursorTabAddition", {
		default = true,
		ctermbg = "DarkGreen",
		bg = "#394f2f",
		bold = false,
	})

	vim.api.nvim_set_hl(0, "CursorTabModification", {
		default = true,
		ctermbg = "DarkGray",
		bg = "#282e38",
		bold = false,
	})

	vim.api.nvim_set_hl(0, "CursorTabCompletion", {
		default = true,
		ctermfg = "DarkBlue",
		fg = "#80899c",
		bold = false,
	})

	vim.api.nvim_set_hl(0, "CursorTabJumpSymbol", {
		default = true,
		ctermfg = "Cyan",
		fg = "#373b45",
		bold = false,
	})

	vim.api.nvim_set_hl(0, "CursorTabJumpText", {
		default = true,
		ctermbg = "Cyan",
		ctermfg = "Black",
		bg = "#373b45",
		fg = "#bac1d1",
		bold = false,
	})
end

return config
