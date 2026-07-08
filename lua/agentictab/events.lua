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

local config = require("agentictab.config")
local ui = require("agentictab.ui")

---@class EventsModule
local events = {}

-- Handlers the backend overrides to react to editor activity. All default to
-- no-ops so the visual layer works standalone.
---@class CursortabHandlers
---@field accept fun():boolean|nil        Agent suggestion accepted (via the agent key / <leader>tt).
---@field partial_accept fun():boolean|nil Skip-hunk handler. Dormant: the S-Tab skip keymap was removed; kept for a future picker.
---@field trigger fun()                   Manual trigger key pressed.
---@field reject fun(reason: string|nil)  Visuals were dismissed ("esc" for a real Esc press; nil/"auto" for movement, mode change).
---@field event fun(name: string)         Editor event fired (text_changed, cursor_moved, insert_enter, insert_leave, file_saved, scrolled).
---@field tab_fallback fun():boolean      Tab pressed in normal mode with nothing visible. Return true if handled.
events.handlers = {
	accept = function() end,
	partial_accept = function() end,
	trigger = function() end,
	reject = function() end,
	event = function(_) end,
	tab_fallback = function()
		return false
	end,
}

-- Track if autocommands have been set up to prevent duplicate registrations
local autocommands_setup_done = false

-- Track currently bound keys so we can clean them up on re-setup
---@type {accept: string|nil, agent: string|nil}
local current_keymaps = { accept = nil, agent = nil }

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

-- Accept an on-screen agent suggestion (a rendered proposal hunk or a
-- cursor-jump prediction). Returns true if something was accepted.
local function accept_agent_suggestion()
	if not (ui.has_cursor_prediction() or ui.has_completion()) then
		return false
	end
	-- Suppress the immediate text change and cursor movement caused by applying the completion
	skip_next_text_changed = true
	skip_next_cursor_moved = true
	completing = true
	suppress_blink()
	vim.schedule(dismiss_native_completion)
	events.handlers.accept()
	return true
end

-- Tab handler. In normal mode, Tab is the "agentic tab": accept an on-screen
-- proposal/jump, approve a pending bash suggestion, or dispatch/jump to the
-- arrow on (or nearest to) the cursor line. In insert mode, Tab only accepts
-- visible agent visuals.
---@return string
local function on_accept()
	if accept_agent_suggestion() then
		return ""
	end
	if vim.api.nvim_get_mode().mode:sub(1, 1) == "n" and events.handlers.tab_fallback() then
		return ""
	end
	return "\t"
end

-- Escape key handler. Runs from vim.on_key where text/window changes are
-- forbidden (textlock), so defer the actual teardown.
local function on_escape()
	vim.schedule(function()
		ui.close_all()
		events.handlers.reject("esc")
	end)
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

	update_keymap("accept", cfg.keymaps.accept, on_accept, expr_opts)

	-- Agent key (<leader>tt): normal-mode only, not an expr passthrough — it
	-- either accepts the on-screen suggestion or triggers the anchor/dwell jump.
	if current_keymaps.agent and current_keymaps.agent ~= cfg.keymaps.agent then
		pcall(vim.keymap.del, "n", current_keymaps.agent)
		current_keymaps.agent = nil
	end
	if cfg.keymaps.agent then
		vim.keymap.set("n", cfg.keymaps.agent, function()
			require("agentictab.agent.picker").open()
		end, { noremap = true, silent = true, desc = "Open the agentictab action picker" })
		current_keymaps.agent = cfg.keymaps.agent
	end

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

	-- Shared cursor movement handler. Visuals are location-anchored and stay
	-- put during movement; the backend re-renders only when needed.
	---@return boolean suppressed true if the event was suppressed (skip dispatching)
	local function handle_cursor_moved(is_insert)
		if is_insert and text_changed_this_tick then
			return true
		end
		if skip_next_cursor_moved then
			skip_next_cursor_moved = false
			return true
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
			events.handlers.event("insert_leave")
		end,
	})

	-- File save
	vim.api.nvim_create_autocmd({ "BufWritePost" }, {
		callback = function()
			events.handlers.event("file_saved")
		end,
	})

	-- Viewport scroll without cursor movement (C-e/C-y, mouse wheel): overlay
	-- floats are screen-anchored, so clear and let the backend re-render.
	-- Only react to normal windows — opening/closing our own overlay floats
	-- also fires WinScrolled, which would otherwise re-render in a loop.
	vim.api.nvim_create_autocmd({ "WinScrolled" }, {
		callback = function()
			local scrolled_normal_win = false
			for key in pairs(vim.v.event or {}) do
				if key ~= "all" then
					local winid = tonumber(key)
					if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_config(winid).relative == "" then
						scrolled_normal_win = true
						break
					end
				end
			end
			if scrolled_normal_win and (ui.has_cursor_prediction() or ui.has_completion()) then
				ui.close_all()
				events.handlers.event("scrolled")
			end
		end,
	})

	-- Close completions/predictions on mode/window transitions
	vim.api.nvim_create_autocmd({ "ModeChanged", "CmdlineEnter", "CmdwinEnter", "BufEnter" }, {
		callback = function(args)
			-- Don't close when transitioning from normal to insert mode
			if args.event == "ModeChanged" and args.match and args.match:match("^n:i") then
				return
			end

			-- Cmdline round-trips (:w, :AgenticTab log, ...) must not discard
			-- an expensive proposal: clear visuals, let the backend re-present.
			local is_cmdline = args.event == "CmdlineEnter"
				or args.event == "CmdwinEnter"
				or (args.event == "ModeChanged" and args.match and (args.match:match(":c") or args.match:match("^c:")))
			if is_cmdline then
				if ui.has_cursor_prediction() or ui.has_completion() then
					ui.close_all()
				end
				events.handlers.event("cmdline")
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

---Accept current completion/prediction if available. Programmatic API:
---accepts an on-screen agent suggestion if present, else falls through to
---the same fallbacks as the Tab key.
---@return boolean accepted
function events.accept()
	if accept_agent_suggestion() then
		return true
	end
	return on_accept() == ""
end

---Check if agentictab is mid-completion (for other plugins to suppress their menus).
---@return boolean
function events.is_completing()
	return completing
end

---Clear the mid-completion latch when an accept did not change any text
---(e.g. a jump-only accept or a hunk skip), since no TextChanged will fire
---to reset it.
function events.reset_completing()
	completing = false
	release_blink()
end

return events
