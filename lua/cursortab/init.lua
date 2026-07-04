-- Main entry point for cursortab.nvim
--
-- The Go completion server has been removed. What remains is the visual layer:
-- ghost text, diff overlays, and the cursor-jump ("TAB") indicator. A backend
-- drives it by rendering with `show_completion` / `show_cursor_prediction` and
-- reacting to editor activity through `require("cursortab.events").handlers`.

local config = require("cursortab.config")
local events = require("cursortab.events")
local ui = require("cursortab.ui")

---@class CursortabModule
local M = {}

-- Handlers the backend overrides to react to editor activity (accept, reject,
-- trigger, and raw editor events). See `events.CursortabHandlers`.
M.handlers = events.handlers

-- Rendering API --------------------------------------------------------------

---Render a completion diff (ghost text / overlays).
---@param diff_result DiffResult
function M.show_completion(diff_result)
	ui.show_completion(diff_result)
end

---Render the cursor-jump ("TAB") indicator at the given line.
---@param line_num integer Predicted line number (1-indexed)
function M.show_cursor_prediction(line_num)
	ui.show_cursor_prediction(line_num)
end

---Clear all visuals (ghost text, overlays, jump indicator).
function M.clear()
	ui.close_all()
end

---Accept the current completion/prediction if one is visible.
---@return boolean accepted
function M.accept()
	return events.accept()
end

---Whether cursortab is mid-completion (for other plugins to suppress their menus).
---@return boolean
function M.is_completing()
	return events.is_completing()
end

-- Public commands ------------------------------------------------------------

---Toggle the visual layer on/off.
function M.toggle()
	local enabled = not ui.is_enabled()
	ui.set_enabled(enabled)
	if enabled then
		vim.notify("Cursortab enabled", vim.log.levels.INFO)
	else
		M.clear()
		vim.notify("Cursortab disabled", vim.log.levels.INFO)
	end
end

---Render a sample completion so the visuals can be inspected without a backend.
function M.demo()
	if not ui.is_enabled() then
		ui.set_enabled(true)
	end

	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
	local current = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or ""

	local suffix = "  -- ghost text from cursortab"
	M.show_completion({
		groups = {
			{
				type = "modification",
				start_line = 1,
				end_line = 1,
				buffer_line = cursor_line,
				lines = { current .. suffix },
				old_lines = { current },
				render_hint = "append_chars",
				col_start = #current,
				col_end = #current,
			},
		},
		startLine = cursor_line,
		cursor_line = 1,
		cursor_col = #current,
	})

	vim.notify("Cursortab demo: sample ghost text shown (move the cursor to clear)", vim.log.levels.INFO)
end

---Setup cursortab.
---@param user_config table|nil User configuration overrides
function M.setup(user_config)
	config.setup(user_config)
	ui.set_enabled(config.get().enabled)

	vim.api.nvim_create_user_command("CursortabToggle", function()
		M.toggle()
	end, { desc = "Toggle Cursortab visuals" })

	vim.api.nvim_create_user_command("CursortabDemo", function()
		M.demo()
	end, { desc = "Render a sample completion to preview the visuals" })

	-- Setup highlight groups
	config.setup_highlights()

	-- Setup events and keymaps
	events.setup()

	-- Patch completion plugins after all plugins have loaded
	vim.schedule(function()
		M._patch_completion_plugins()
	end)
end

-- Wrap a completion plugin's enabled function to return false while cursortab is completing
---@param original any
---@return function
local function wrap_enabled(original)
	return function()
		if events.is_completing() then
			return false
		end
		if type(original) == "function" then
			return original()
		end
		if original == nil then
			return true
		end
		return original
	end
end

-- Patch nvim-cmp to suppress during cursortab completion
function M._patch_completion_plugins()
	local ok_cmp, cmp = pcall(require, "cmp")
	if ok_cmp and cmp.get_config and vim.is_callable(cmp.setup) then
		local cmp_config = cmp.get_config()
		cmp.setup({ enabled = wrap_enabled(cmp_config.enabled) })
	end
end

return M
