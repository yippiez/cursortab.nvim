-- Main entry point for agentictab.nvim
--
-- Agentic tab: an on-demand coding agent (pi in RPC mode) whose entire UI is
-- arrows. Alt+. opens a prompt bar in one of three modes — a ask: · b bash: ·
-- d do:. do: edits land as inline diff proposals walked with Tab; bash:
-- output comes back as a red result arrow; ask: answers as a yellow one.
-- Suggestion arrows appear on their own: dwell (cursor rested) and review
-- (periodic background reviewer); <leader>tt labels every arrow for dispatch,
-- Esc dismisses.
--
-- Everything heavier than config is loaded lazily: setup() only registers
-- commands/keymaps and schedules the wiring; the agent/arrow modules load on
-- the first idle tick (or first use), never during startup.

local config = require("agentictab.config")

---@class AgenticTabModule
local M = {}

local function ui()
	return require("agentictab.ui")
end

local function events()
	return require("agentictab.events")
end

local function agent()
	return require("agentictab.agent")
end

-- Rendering API (kept for programmatic/backend use) ---------------------------

---Render a completion diff (ghost text / overlays).
---@param diff_result DiffResult
function M.show_completion(diff_result)
	ui().show_completion(diff_result)
end

---Render the cursor-jump ("TAB") indicator at the given line.
---@param line_num integer Predicted line number (1-indexed)
function M.show_cursor_prediction(line_num)
	ui().show_cursor_prediction(line_num)
end

---Clear all visuals (ghost text, overlays, jump indicator).
function M.clear()
	ui().close_all()
end

---Accept the current hunk/prediction if one is visible.
---@return boolean accepted
function M.accept()
	return events().accept()
end

---Whether agentictab is mid-completion (for other plugins to suppress their menus).
---@return boolean
function M.is_completing()
	return events().is_completing()
end

---Agent state: "idle" | "running" | "proposing". Useful for statuslines.
---@return string
function M.state()
	return agent().state()
end

-- Public commands ------------------------------------------------------------

---Open the request/steer prompt bar (mode chooser: a ask · b bash · d do).
function M.request()
	agent().request_key()
end

---Cancel the current run or dismiss the current proposal.
function M.cancel()
	agent().cancel()
end

---Toggle the visual layer on/off.
function M.toggle()
	local enabled = not ui().is_enabled()
	ui().set_enabled(enabled)
	if enabled then
		vim.notify("AgenticTab enabled", vim.log.levels.INFO)
	else
		M.clear()
		vim.notify("AgenticTab disabled", vim.log.levels.INFO)
	end
end

---Render sample arrows so the visuals can be inspected without a backend:
---a gray suggestion arrow on the cursor line and a yellow ask: result below.
function M.demo()
	if not ui().is_enabled() then
		ui().set_enabled(true)
	end

	local arrows = require("agentictab.agent.arrows")
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	arrows.add({
		buf = vim.api.nvim_get_current_buf(),
		lnum = lnum,
		source = "review",
		kind = "do",
		text = "sample suggestion arrow (dispatch or :AgenticTab toggle to clear)",
	})
	arrows.result({
		kind = "ask",
		lnum = math.min(lnum + 1, vim.api.nvim_buf_line_count(0)),
		text = "sample ask result arrow\nsecond ghost line of the answer body",
	})
	vim.notify("AgenticTab demo: sample arrows shown (Esc dismisses the result)", vim.log.levels.INFO)
end

---Setup agentictab. Cheap by design: registers commands and keymaps, defers
---all module loading and autocmd wiring to the first idle tick.
---@param user_config table|nil User configuration overrides
function M.setup(user_config)
	config.setup(user_config)
	config.setup_highlights()

	pcall(vim.api.nvim_del_user_command, "AgenticTab")
	pcall(vim.api.nvim_del_user_command, "AgenticTabReview")
	vim.api.nvim_create_user_command("AgenticTab", function(cmd_opts)
		local sub = cmd_opts.args
		if sub == "log" then
			agent().show_log()
		elseif sub == "cancel" then
			agent().cancel()
		elseif sub == "dwell" then
			require("agentictab.agent.dwell").trigger()
		elseif sub == "review" then
			require("agentictab.agent.review").trigger()
		elseif sub == "reset" then
			agent().reset_session()
		elseif sub == "toggle" then
			M.toggle()
		elseif sub == "demo" then
			M.demo()
		else
			M.request()
		end
	end, {
		nargs = "?",
		complete = function()
			return { "log", "cancel", "dwell", "review", "reset", "toggle", "demo" }
		end,
		desc = "AgenticTab: request (default) | log | cancel | dwell | review | reset | toggle | demo",
	})
	vim.api.nvim_create_user_command("AgenticTabReview", function()
		require("agentictab.agent.review").trigger()
	end, { desc = "AgenticTab: force a review tick now" })

	-- Request keymap (prompt bar) in normal and insert mode
	local km = config.get().keymaps
	if km.request then
		vim.keymap.set({ "n", "i" }, km.request, function()
			agent().request_key()
		end, { silent = true, desc = "Request agent (a ask · b bash · d do)" })
	end

	-- Debug/utility keymaps (normal mode)
	if km.log then
		vim.keymap.set("n", km.log, function()
			require("agentictab.logview").toggle()
		end, { silent = true, desc = "Agent log" })
	end
	if km.stop then
		vim.keymap.set("n", km.stop, function()
			agent().cancel()
		end, { silent = true, desc = "Stop agent" })
	end
	if km.expand then
		vim.keymap.set({ "n", "i" }, km.expand, function()
			agent().expand()
		end, { silent = true, desc = "Expand detail" })
	end
	if km.model then
		vim.keymap.set("n", km.model, function()
			require("agentictab.models").pick()
		end, { silent = true, desc = "Pick model (session)" })
	end

	-- Everything else — the ui/events wiring, the agent backend, the arrow
	-- feeders' autocmds and timers — waits for the first idle tick so setup
	-- never contributes to startup time.
	vim.schedule(function()
		ui().set_enabled(config.get().enabled)
		events().setup()
		agent().setup()
		M._patch_completion_plugins()
	end)
end

-- Wrap a completion plugin's enabled function to return false while agentictab is completing
---@param original any
---@return function
local function wrap_enabled(original)
	return function()
		if events().is_completing() then
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

-- Patch nvim-cmp to suppress during completion application
function M._patch_completion_plugins()
	local ok_cmp, cmp = pcall(require, "cmp")
	if ok_cmp and cmp.get_config and vim.is_callable(cmp.setup) then
		local cmp_config = cmp.get_config()
		cmp.setup({ enabled = wrap_enabled(cmp_config.enabled) })
	end
end

return M
