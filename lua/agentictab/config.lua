-- Configuration management for agentictab.nvim

---@class AgenticTabUIJumpConfig
---@field symbol string
---@field text string
---@field show_distance boolean

---@class AgenticTabUICompletionsConfig
---@field addition_style string "dimmed" or "highlight"
---@field fg_opacity number opacity for completion overlays (0=invisible, 1=fully visible)

---@class AgenticTabUIConfig
---@field completions AgenticTabUICompletionsConfig
---@field jump AgenticTabUIJumpConfig

---@class AgenticTabKeymapsConfig
---@field accept string|false Accept the on-screen suggestion / proposal hunk (e.g., "<Tab>"), or false
---@field agent string|false Open the arrow action picker (e.g., "<leader>tt"), or false
---@field request string|false Open the ask/bash/do prompt bar (e.g., "<M-.>"), or false to disable

---@class AgenticTabPiConfig
---@field cmd string Executable used to launch the agent
---@field provider string|nil Provider passed as --provider
---@field model string|nil Model passed as --model
---@field thinking string|nil Thinking level passed as --thinking
---@field extra_args string[] Additional CLI args appended to the pi invocation

---@class AgenticTabContextConfig
---@field diagnostics_radius integer Lines around the cursor to collect diagnostics from
---@field recent_diff_max_lines integer Cap on the git-diff trajectory included in prompts

---@class AgenticTabConfig
---@field enabled boolean
---@field keymaps AgenticTabKeymapsConfig
---@field ui AgenticTabUIConfig
---@field pi AgenticTabPiConfig
---@field context AgenticTabContextConfig
---@field arrows table

-- Default configuration
---@type AgenticTabConfig
local default_config = {
	enabled = true,

	keymaps = {
		accept = "<Tab>", -- Accept a proposal hunk / dispatch the arrow on the cursor line, or false
		agent = "<leader>tt", -- Open the arrow action picker, or false
		request = "<M-.>", -- Open the prompt bar (a ask · b bash · d do), or false to disable
		log = "<leader>tl", -- Toggle the live agent log window, or false to disable
		stop = "<leader>ts", -- Stop the current agent run, or false to disable
		expand = "<M-e>", -- Expand truncated detail (bash command, result arrow), or false to disable
		model = "<leader>tm", -- Pick the pi model for this session (in-memory only), or false to disable
	},

	ui = {
		completions = {
			addition_style = "highlight", -- "highlight" (green block) or "dimmed" (faded syntax colors)
			fg_opacity = 0.6, -- opacity for completion overlays (0=invisible, 1=fully visible)
		},
		jump = {
			symbol = "",
			text = " TAB ",
			show_distance = true,
		},
	},

	pi = {
		cmd = "pi",
		provider = nil,
		model = nil,
		thinking = nil,
		extra_args = {},
	},

	context = {
		diagnostics_radius = 40,
		recent_diff_max_lines = 200,
	},

	arrows = {
		-- Dwell arrows: resting the cursor (insert or normal mode) asks a cheap
		-- model what action you most likely want there.
		dwell = {
			enabled = true,
			provider = nil, -- defaults to pi.provider
			model = nil, -- defaults to pi.model; use something cheap/fast
			dwell_ms = 2500, -- idle time before asking for a prediction
		},

		-- Review arrows: a background reviewer runs periodically (NOT
		-- user-triggered) and drops suggestion arrows on the lines it reviewed.
		review = {
			enabled = true,
			provider = nil, -- defaults to pi.provider
			model = nil, -- defaults to pi.model; use something cheap/fast
			period_ms = 120000, -- autonomous cadence: a review tick fires every this often
			cooldown_ms = 240000, -- minimum time between review interventions
			max_arrows = 3, -- most arrows one review tick may place
		},
	},

	bash = {
		-- "unsafe": auto-approve read-only commands, ask for the rest
		-- "always": ask for every bash command
		-- "off": never ask (trust the agent)
		approval = "unsafe",
		allow = {}, -- extra command names to auto-approve (e.g. {"make", "pytest"})
	},
}

-- Valid values for enum-like config options
local valid_addition_styles = { dimmed = true, highlight = true }

-- Options whose default is nil (so they can't be discovered from default_config)
local nullable_keys = {
	["pi.provider"] = true,
	["pi.model"] = true,
	["pi.thinking"] = true,
	["arrows.dwell.provider"] = true,
	["arrows.dwell.model"] = true,
	["arrows.review.provider"] = true,
	["arrows.review.model"] = true,
}

-- Validate that all keys in user config exist in default config
---@param user_cfg table User configuration
---@param default_cfg table Default configuration
---@param path string Current path for error messages
local function validate_config_keys(user_cfg, default_cfg, path)
	for key, value in pairs(user_cfg) do
		if default_cfg[key] == nil and not nullable_keys[path .. key] then
			error(string.format("[agentictab.nvim] Unknown config option: %s%s", path, key))
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

	-- Validate keymaps (must be string or false)
	if cfg.keymaps then
		for _, name in ipairs({ "accept", "agent", "request", "log", "stop", "expand", "model" }) do
			local key = cfg.keymaps[name]
			if key ~= nil and key ~= false and type(key) ~= "string" then
				error(string.format("[agentictab.nvim] keymaps.%s must be a string (keymap) or false to disable", name))
			end
			if type(key) == "string" and key == "" then
				error(string.format("[agentictab.nvim] keymaps.%s cannot be an empty string (use false to disable)", name))
			end
		end
	end

	-- Validate addition style
	if cfg.ui and cfg.ui.completions and cfg.ui.completions.addition_style then
		if not valid_addition_styles[cfg.ui.completions.addition_style] then
			error(string.format(
				"[agentictab.nvim] Invalid ui.completions.addition_style '%s'. Must be one of: dimmed, highlight",
				cfg.ui.completions.addition_style
			))
		end
	end

	-- Validate fg_opacity
	if cfg.ui and cfg.ui.completions and cfg.ui.completions.fg_opacity then
		local f = cfg.ui.completions.fg_opacity
		if type(f) ~= "number" or f < 0 or f > 1 then
			error("[agentictab.nvim] ui.completions.fg_opacity must be a number between 0 and 1")
		end
	end

	-- Validate arrow timings
	if cfg.arrows then
		for section, names in pairs({ dwell = { "dwell_ms" }, review = { "period_ms", "cooldown_ms", "max_arrows" } }) do
			local sec = cfg.arrows[section]
			if sec then
				for _, name in ipairs(names) do
					local v = sec[name]
					if v ~= nil and (type(v) ~= "number" or v <= 0) then
						error(string.format("[agentictab.nvim] arrows.%s.%s must be a positive number", section, name))
					end
				end
			end
		end
	end
end

---@class ConfigModule
local config = {}
---@type AgenticTabConfig
local current_config = vim.deepcopy(default_config)

-- Get current configuration
---@return AgenticTabConfig
function config.get()
	return current_config
end

-- Set up configuration with user overrides
---@param user_config table|nil User configuration overrides
---@return AgenticTabConfig
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

	vim.api.nvim_set_hl(0, "AgenticTabStatus", {
		default = true,
		link = "Comment",
	})

	-- Small hints riding along arrows (key help, "· queued", placeholders)
	vim.api.nvim_set_hl(0, "AgenticTabHint", {
		default = true,
		fg = "#6b7089",
		italic = true,
	})

	-- Input bar text: muted gray like the hint ghost, but upright
	vim.api.nvim_set_hl(0, "AgenticTabPrompt", {
		default = true,
		fg = "#6b7089",
	})

	-- do: arrows (the default action kind): muted gray.
	vim.api.nvim_set_hl(0, "AgenticTabArrow", {
		default = true,
		fg = "#6b7089",
	})
	vim.api.nvim_set_hl(0, "AgenticTabArrowActive", {
		default = true,
		fg = "#ffffff", -- white: this target's label is being typed
		bold = true,
	})

	-- Arrows are grouped by colour, not by textual prefix: gray = do (above),
	-- yellow = ask, red = bash. Results reuse the same groups.
	vim.api.nvim_set_hl(0, "AgenticTabArrowAsk", {
		default = true,
		fg = "#d8b45a",
		italic = true,
	})
	vim.api.nvim_set_hl(0, "AgenticTabArrowBash", {
		default = true,
		fg = "#cf6a6a",
		italic = true,
	})

	-- Action picker (<leader>tt). While the picker is open the code dims; the
	-- only highlighted thing is the label (the letters that trigger a target),
	-- and a target whose label you're typing turns its text gray -> white.
	vim.api.nvim_set_hl(0, "AgenticTabDim", {
		default = true,
		fg = "#4b5263", -- greyed-out code while the picker is open
	})
	vim.api.nvim_set_hl(0, "AgenticTabPickerLabel", {
		default = true,
		fg = "#1a1b26",
		bg = "#7dcfff", -- the trigger letters — the one highlighted element
		bold = true,
	})
	vim.api.nvim_set_hl(0, "AgenticTabPickerHit", {
		default = true,
		fg = "#1a1b26",
		bg = "#ffffff", -- the part of the label you've already typed
		bold = true,
	})

	-- Log window
	vim.api.nvim_set_hl(0, "AgenticTabLogUser", { default = true, link = "Function" })
	vim.api.nvim_set_hl(0, "AgenticTabLogTool", { default = true, link = "Identifier" })
	vim.api.nvim_set_hl(0, "AgenticTabLogMeta", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "AgenticTabLogDwell", { default = true, link = "AgenticTabHint" })
	vim.api.nvim_set_hl(0, "AgenticTabLogError", { default = true, link = "DiagnosticError" })
	vim.api.nvim_set_hl(0, "AgenticTabLogOk", { default = true, link = "DiagnosticOk" })
end

return config
