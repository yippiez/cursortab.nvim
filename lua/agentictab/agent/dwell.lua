-- Dwell arrows: predicted actions where the cursor rests.
--
-- When the cursor rests somewhere — insert or normal mode — with no arrow
-- already on that line and the agent idle, a cheap tool-less pi session is
-- asked: "what one action does the user most likely want here?"
-- The answer becomes an EOL arrow (`⇥ implement retry logic`), coloured by
-- its action kind (do / bash / ask); <leader>tt or Tab dispatches it,
-- any movement or edit clears it. Only fires when the user has edited
-- recently, and caches per (buffer, line, changedtick) so dwelling on the
-- same spot never queries twice.

local arrows = require("agentictab.agent.arrows")
local config = require("agentictab.config")
local context = require("agentictab.agent.context")
local logview = require("agentictab.logview")
local rpc = require("agentictab.agent.rpc")
local status = require("agentictab.status")

---@class DwellModule
local dwell = {}

local SYSTEM_PROMPT = table.concat({
	"You predict the next action a programmer wants at their cursor position.",
	"You are given the file, cursor context, and their recent uncommitted changes.",
	"Reply with ONLY one line in one of these forms (max 15 words after the prefix):",
	"",
	"do: <edit instruction>       an edit they likely want performed at/near the cursor",
	"bash: <shell task>           a command they likely want run (tests, build, search)",
	"ask: <question>              a question about this code they likely want answered",
	"NONE                         nothing specific is likely",
	"",
	"Examples of good replies:",
	"do: implement the body of parseConfig",
	"do: add a nil guard for the fs_open result",
	"bash: run the tests for this file",
	"ask: what calls handle_payment besides the webhook",
	"NONE",
	"",
	"Never reply with anything else. No punctuation-only replies, no explanations, no code blocks.",
}, "\n")

local client = rpc.new()
---@type string|nil root the dwell process was started in
local client_root = nil

---@type uv.uv_timer_t|nil dwell timer
local dwell_timer = nil
---@type integer bumped on every movement/edit; stale replies are dropped
local generation = 0
---@type integer|nil ms timestamp of the last buffer edit anywhere
local last_edit_ms = nil
---@type table<string, boolean> cache of already-queried spots
local asked = {}
---@type string accumulated assistant text for the in-flight query
local reply_acc = ""
---@type boolean
local querying = false

---Predicate wired in by agent.setup.
---@type fun():boolean
local agent_busy = function()
	return true
end

function dwell.clear()
	arrows.clear("dwell")
end

local function ensure_client(root)
	if client:is_running() and client_root == root then
		return true
	end
	client:stop()
	local cfg = config.get()
	local provider = cfg.arrows.dwell.provider or cfg.pi.provider
	local model = cfg.arrows.dwell.model or cfg.pi.model
	local cmd = { cfg.pi.cmd, "--mode", "rpc", "--no-session", "--no-tools", "--no-extensions", "--no-skills" }
	if provider then
		vim.list_extend(cmd, { "--provider", provider })
	end
	if model then
		vim.list_extend(cmd, { "--model", model })
	end
	vim.list_extend(cmd, { "--thinking", "off", "--system-prompt", SYSTEM_PROMPT })

	local ok = client:start({
		cmd = cmd,
		cwd = root,
		on_event = vim.schedule_wrap(function(ev)
			dwell._on_event(ev)
		end),
		on_exit = function()
			client_root = nil
		end,
	})
	if ok then
		client_root = root
	end
	return ok
end

---Parse a model reply into an arrow spec. Unprefixed replies default to do:.
---@param text string
---@return {kind: string, text: string, prompt: string|nil}|nil
function dwell.parse(text)
	if text == "" or text:upper():find("^NONE") or #text > 120 then
		return nil
	end
	local kind, rest = text:match("^(%l+):%s*(.+)$")
	if kind == "do" or kind == "bash" or kind == "ask" then
		return { kind = kind, text = rest }
	end
	return { kind = "do", text = text }
end

---@type integer generation the in-flight query belongs to
local query_gen = 0

function dwell._on_event(ev)
	if ev.type == "message_end" then
		local msg = ev.message
		if msg and msg.role == "assistant" and type(msg.content) == "table" then
			for _, part in ipairs(msg.content) do
				if part.type == "text" and part.text then
					reply_acc = reply_acc .. part.text
				end
			end
		end
	elseif ev.type == "agent_end" then
		querying = false
		-- Drop the "predicting" spinner unless the main agent took over
		if not agent_busy() then
			status.hide()
		end
		local text = vim.trim(reply_acc)
		reply_acc = ""
		logview.append("dwell: → " .. (text ~= "" and text or "(empty)"))
		local spec = dwell.parse(text)
		if not spec then
			return
		end
		if query_gen ~= generation or agent_busy() then
			logview.append("dwell: (stale, dropped)")
			return
		end
		-- Still on the same spot?
		local buf = vim.api.nvim_get_current_buf()
		spec.lnum = vim.api.nvim_win_get_cursor(0)[1]
		arrows.set("dwell", buf, { spec })
	end
end

---@param force boolean|nil manual trigger: skip the enabled/recency/cache gates
local function fire(force)
	local cfg = config.get()
	if querying or agent_busy() then
		return
	end
	if not force and not cfg.arrows.dwell.enabled then
		return
	end
	local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
	if mode ~= "n" and mode ~= "i" then
		return
	end
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		return
	end
	-- Only predict when the user has been editing recently
	if not force and (not last_edit_ms or (vim.uv.now() - last_edit_ms) > 120000) then
		return
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	-- An existing arrow on this line (review/user) takes precedence
	local at = arrows.at_line(buf, lnum)
	if not force and at and at.source ~= "dwell" then
		return
	end
	local key = buf .. ":" .. lnum .. ":" .. vim.b[buf].changedtick
	if not force and asked[key] then
		return
	end
	asked[key] = true

	local ctx = context.gather()
	if not ensure_client(ctx.root) then
		return
	end
	querying = true
	query_gen = generation
	reply_acc = ""
	status.running()
	status.set_detail("predicting")
	logview.append(string.format("dwell: predicting for %s:%d%s", ctx.relpath, lnum, force and " (manual)" or ""))
	-- Fresh session per query (keeps context tiny); the prompt must only go
	-- out after the switch completes or the switch kills the pending run.
	client:send({ type = "new_session" }, function()
		client:send({ type = "prompt", message = ctx.block })
	end)
	-- Safety: never let a lost reply wedge the dwell
	vim.defer_fn(function()
		if querying then
			querying = false
			if not agent_busy() then
				status.hide()
			end
		end
	end, 30000)
end

---Force a prediction right now (debug command), bypassing the enabled,
---recent-edit, and cache gates.
function dwell.trigger()
	fire(true)
end

---Wire dwell detection.
---@param busy fun():boolean true while the agent runs/proposes (suppresses the dwell)
function dwell.setup(busy)
	agent_busy = busy
	local group = vim.api.nvim_create_augroup("AgenticTabDwell", { clear = true })

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufEnter" }, {
		group = group,
		callback = function()
			generation = generation + 1
			dwell.clear()
			if not config.get().arrows.dwell.enabled then
				return
			end
			if dwell_timer then
				dwell_timer:stop()
			else
				dwell_timer = vim.uv.new_timer()
			end
			dwell_timer:start(config.get().arrows.dwell.dwell_ms, 0, function()
				vim.schedule(fire)
			end)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		callback = function()
			last_edit_ms = vim.uv.now()
			generation = generation + 1
			dwell.clear()
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			client:stop()
		end,
	})
end

return dwell
