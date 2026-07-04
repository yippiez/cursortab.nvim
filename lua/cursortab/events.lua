-- Event handling and autocommands for cursortab.nvim
--
-- This module owns the editor-side glue: keymaps for accepting/rejecting a
-- completion and the autocommands that keep the visuals in sync with what the
-- user is doing (clearing ghost text on movement, updating it while typing).
--
-- It is deliberately backend-agnostic. The Go server that used to drive
-- completions has been removed; a replacement backend plugs in by overriding
-- the handlers in `events.handlers` and calling `ui.show_completion` /
-- `ui.show_cursor_prediction` to render, plus `ui.close_all` to clear.

local config = require("cursortab.config")
local ui = require("cursortab.ui")

---@class EventsModule
local events = {}

-- Handlers the backend overrides to react to editor activity. All default to
-- no-ops so the visual layer works standalone.
---@class CursortabHandlers
---@field accept fun():boolean|nil        Tab pressed while a completion/prediction is visible. Return true if handled.
---@field partial_accept fun():boolean|nil Partial-accept key pressed while a completion is visible.
---@field trigger fun()                   Manual trigger key pressed.
---@field reject fun()                    Visuals were dismissed (esc, movement, mode change).
---@field event fun(name: string)         Editor event fired (text_changed, cursor_moved, insert_enter, insert_leave, file_saved).
events.handlers = {
	accept = function() end,
	partial_accept = function() end,
	trigger = function() end,
	reject = function() end,
	event = function(_) end,
}

-- Track if autocommands have been set up to prevent duplicate registrations
local autocommands_setup_done = false

-- Track currently bound keys so we can clean them up on re-setup
---@type {accept: string|nil, partial_accept: string|nil, trigger: string|nil}
local current_keymaps = { accept = nil, partial_accept = nil, trigger = nil }

local esc_handler_ns = nil

-- Skip exactly one TextChanged after accepting a completion
---@type boolean
local skip_next_text_changed = false

-- State for cursor movement suppression during completion application
---@type boolean
local skip_next_cursor_moved = false

-- Track if text changed in current event loop tick (to dedupe with CursorMovedI)
---@type boolean
local text_changed_this_tick = false

-- True while cursortab is applying a completion; native completion plugins should stay closed
---@type boolean
local completing = false

-- Whether blink-cmp is installed (detected once)
local has_blink = pcall(require, "blink.cmp")

-- Suppress blink-cmp via its buffer-local variable (safe in expr mappings)
local function suppress_blink()
	if has_blink then
		vim.b.completion = false
	end
end

-- Re-enable blink-cmp
local function release_blink()
	if has_blink and vim.b.completion == false then
		vim.b.completion = nil
	end
end

-- Close any visible native completion menus. Must run via vim.schedule (not safe in expr mappings).
local function dismiss_native_completion()
	if vim.fn.pumvisible() == 1 then
		local keys = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
		vim.api.nvim_feedkeys(keys, "n", false)
	end
	local ok_cmp, cmp = pcall(require, "cmp")
	if ok_cmp and type(cmp.visible) == "function" and cmp.visible() then
		cmp.abort()
	end
	local ok_blink, blink = pcall(require, "blink.cmp")
	if ok_blink and blink.is_visible and blink.is_visible() then
		blink.cancel()
	end
end

-- Accept key handler
---@return string
local function on_accept()
	if ui.has_cursor_prediction() or ui.has_completion() then
		-- Suppress the immediate text change and cursor movement caused by applying the completion
		skip_next_text_changed = true
		skip_next_cursor_moved = true
		completing = true
		suppress_blink()
		vim.schedule(dismiss_native_completion)
		events.handlers.accept()
		return ""
	else
		return "\t"
	end
end

-- Escape key handler
local function on_escape()
	ui.close_all()
	events.handlers.reject()
end

-- Partial accept handler (Shift-Tab by default)
---@return string
local function on_partial_accept()
	if ui.has_completion() then
		-- Suppress the immediate text change and cursor movement caused by partial accept
		skip_next_text_changed = true
		skip_next_cursor_moved = true
		completing = true
		suppress_blink()
		vim.schedule(dismiss_native_completion)
		events.handlers.partial_accept()
		return ""
	else
		-- Pass through configured key
		local cfg = config.get()
		return vim.api.nvim_replace_termcodes(cfg.keymaps.partial_accept, true, true, true)
	end
end

-- Manual trigger handler
local function on_trigger()
	events.handlers.trigger()
end

-- Update a single keymap slot: clear old binding if changed, set new one
local function update_keymap(name, new_key, handler, opts)
	if current_keymaps[name] and current_keymaps[name] ~= new_key then
		pcall(vim.keymap.del, "i", current_keymaps[name])
		pcall(vim.keymap.del, "n", current_keymaps[name])
		current_keymaps[name] = nil
	end
	if new_key then
		vim.keymap.set("i", new_key, handler, opts)
		vim.keymap.set("n", new_key, handler, opts)
		current_keymaps[name] = new_key
	end
end

-- Set up keymaps (can be called multiple times when config changes)
local function setup_keymaps()
	local cfg = config.get()
	local expr_opts = { noremap = true, silent = true, expr = true }
	local plain_opts = { noremap = true, silent = true }

	update_keymap("accept", cfg.keymaps.accept, on_accept, expr_opts)
	update_keymap("partial_accept", cfg.keymaps.partial_accept, on_partial_accept, expr_opts)
	update_keymap("trigger", cfg.keymaps.trigger, on_trigger, plain_opts)

	if esc_handler_ns then
		-- Clear previous handler
		vim.on_key(nil, esc_handler_ns)
	end

	local ESC = vim.keycode("<Esc>")
	esc_handler_ns = vim.on_key(function(_, typed)
		if typed == ESC then
			on_escape()
		end
	end)
end

-- Set up autocommands (only once)
local function setup_autocommands()
	if autocommands_setup_done then
		return
	end
	autocommands_setup_done = true

	-- Text change events
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		callback = function()
			-- Skip exactly one text change immediately following a completion accept
			if skip_next_text_changed then
				skip_next_text_changed = false
				vim.schedule(function()
					completing = false
					release_blink()
				end)
				return
			end

			-- Mark that text changed this tick (to dedupe with CursorMovedI)
			text_changed_this_tick = true
			vim.schedule(function()
				text_changed_this_tick = false
			end)

			-- Handle cursor prediction (always clear - no partial match logic)
			if ui.has_cursor_prediction() then
				ui.close_all()
			elseif ui.has_completion() then
				-- For completions, check if typing matches the prediction.
				-- If it matches, update ghost text locally to avoid visual glitch.
				-- If it doesn't match, clear immediately to avoid stale ghost text.
				local current_line = vim.api.nvim_get_current_line()
				local cursor_line = vim.fn.line(".")
				if ui.typing_matches_completion(cursor_line, current_line) then
					ui.update_ghost_text_for_typing(cursor_line, current_line)
				else
					ui.close_all()
				end
			end

			events.handlers.event("text_changed")
		end,
	})

	-- Shared cursor movement handler (UI only)
	---@return boolean suppressed true if the event was suppressed (skip dispatching)
	local function handle_cursor_moved(is_insert)
		if is_insert and text_changed_this_tick then
			return true
		end
		if skip_next_cursor_moved then
			skip_next_cursor_moved = false
			return true
		end
		if ui.has_cursor_prediction() or ui.has_completion() then
			ui.close_all()
		end
		return false
	end

	-- Cursor movement events (normal mode)
	vim.api.nvim_create_autocmd({ "CursorMoved" }, {
		callback = function()
			local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
			if mode ~= "n" then
				return
			end
			if handle_cursor_moved(false) then
				return
			end
			events.handlers.event("cursor_moved")
		end,
	})

	-- Cursor movement events (insert mode - e.g., arrow keys)
	vim.api.nvim_create_autocmd({ "CursorMovedI" }, {
		callback = function()
			if handle_cursor_moved(true) then
				return
			end
			events.handlers.event("cursor_moved")
		end,
	})

	-- Insert mode events
	vim.api.nvim_create_autocmd({ "InsertEnter" }, {
		callback = function()
			events.handlers.event("insert_enter")
		end,
	})

	vim.api.nvim_create_autocmd({ "InsertLeave" }, {
		callback = function()
			if ui.has_cursor_prediction() or ui.has_completion() then
				ui.close_all()
			end
			events.handlers.event("insert_leave")
		end,
	})

	-- File save
	vim.api.nvim_create_autocmd({ "BufWritePost" }, {
		callback = function()
			events.handlers.event("file_saved")
		end,
	})

	-- Close completions/predictions on mode/window transitions
	vim.api.nvim_create_autocmd({ "ModeChanged", "CmdlineEnter", "CmdwinEnter", "BufEnter" }, {
		callback = function(args)
			-- Don't close when transitioning from normal to insert mode
			if args.event == "ModeChanged" and args.match and args.match:match("^n:i") then
				return
			end

			if ui.has_cursor_prediction() or ui.has_completion() then
				ui.close_all()
			end

			events.handlers.reject()
		end,
	})
end

-- Set up all autocommands and keymaps
function events.setup()
	setup_autocommands()
	setup_keymaps()
end

-- Clear all completions (exposed for manual use)
function events.clear_all_completions()
	ui.close_all()
	events.handlers.reject()
end

---Accept current completion/prediction if available.
---@return boolean accepted
function events.accept()
	return on_accept() == ""
end

---Check if cursortab is mid-completion (for other plugins to suppress their menus).
---@return boolean
function events.is_completing()
	return completing
end

return events
