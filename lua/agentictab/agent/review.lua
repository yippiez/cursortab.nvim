-- Review arrows: a background reviewer on its own clock.
--
-- Unlike dwell, review is NOT driven by user action: a repeating timer fires
-- every period_ms regardless of where the cursor is. Each tick, if you have
-- been editing recently and the agent is idle, a cheap tool-less pi session
-- reviews the editor context (including your uncommitted diff) and replies
-- with up to max_arrows suggestions, each pinned to a line. Every suggestion
-- becomes a review arrow coloured by its action kind — nothing runs on its
-- own; you dispatch an arrow with <leader>tt (or Tab on its line) or ignore
-- it. A cooldown keeps the reviewer from becoming a backseat driver.

local arrows = require("agentictab.agent.arrows")
local config = require("agentictab.config")
local context = require("agentictab.agent.context")
local logview = require("agentictab.logview")
local rpc = require("agentictab.agent.rpc")
local status = require("agentictab.status")

---@class ReviewModule
local review = {}

local SYSTEM_PROMPT = table.concat({
	"You are a senior colleague reviewing, in the background, the code a programmer is writing",
	"right now. You are given the file with line numbers, cursor context, and their recent",
	"uncommitted changes. Reply with up to %d lines, each anchoring one suggestion to a line:",
	"",
	"<line> do: <one-line imperative edit, max 15 words>",
	"<line> bash: <one-line shell task worth running, max 15 words>",
	"<line> ask: <one-line question the programmer should look into>",
	"",
	"Or exactly: NONE",
	"",
	"Examples of good replies:",
	"41 do: return the error from fs_open instead of swallowing it",
	"88 bash: run the auth tests, this changes token expiry",
	"",
	"12 do: this duplicates parse_headers below, extract a helper",
	"",
	"NONE",
	"",
	"Rules: only flag things clearly worth the interruption (bug, missing error handling,",
	"real duplication, a risky change untested). Prefer NONE over speculation. Never invent",
	"APIs. Line numbers must come from the numbered context you were shown.",
	"Never reply with anything outside these forms. No explanations, no greetings.",
}, "\n")

local client = rpc.new()
---@type string|nil root the review process was started in
local client_root = nil

---@type uv.uv_timer_t|nil the autonomous background cadence
local period_timer = nil
---@type integer|nil ms timestamp of the last buffer edit anywhere
local last_edit_ms = nil
---@type integer|nil ms timestamp of the last intervention (cooldown anchor)
local last_fired_ms = nil
---@type table<string, boolean> spots already reviewed (buf:changedtick)
local asked = {}
---@type string accumulated assistant text for the in-flight query
local reply_acc = ""
---@type boolean
local querying = false

---@param msg table|nil
---@return string
local function message_text(msg)
	if not msg or msg.role ~= "assistant" then
		return ""
	end
	if type(msg.content) == "string" then
		return msg.content
	end
	if type(msg.content) ~= "table" then
		return ""
	end
	local out = {}
	for _, part in ipairs(msg.content) do
		if part.type == "text" and part.text then
			out[#out + 1] = part.text
		end
	end
	return table.concat(out, "")
end

---Predicate wired in by agent.setup.
---@type fun():boolean
local agent_busy = function()
	return true
end

function review.clear()
	arrows.clear("review")
end

local function ensure_client(root)
	if client:is_running() and client_root == root then
		return true
	end
	client:stop()
	local cfg = config.get()
	local provider = cfg.arrows.review.provider or cfg.pi.provider
	local model = cfg.arrows.review.model or cfg.pi.model
	local cmd = { cfg.pi.cmd, "--mode", "rpc", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-context-files" }
	if provider then
		vim.list_extend(cmd, { "--provider", provider })
	end
	if model then
		vim.list_extend(cmd, { "--model", model })
	end
	vim.list_extend(cmd, { "--thinking", "off", "--system-prompt", string.format(SYSTEM_PROMPT, cfg.arrows.review.max_arrows) })

	local ok = client:start({
		cmd = cmd,
		cwd = root,
		on_event = vim.schedule_wrap(function(ev)
			review._on_event(ev)
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

---Parse the reviewer's reply into arrow specs.
---@param text string
---@param max integer
---@return table[] specs
function review.parse(text, max)
	local specs = {}
	for _, line in ipairs(vim.split(text, "\n")) do
		line = vim.trim(line)
		local lnum, kind, rest = line:match("^(%d+)%s+(%l+):%s*(.+)$")
		if lnum and rest and rest ~= "" then
			if kind == "do" or kind == "bash" or kind == "ask" then
				specs[#specs + 1] = { lnum = tonumber(lnum), kind = kind, text = rest }
			end
		end
		if #specs >= max then
			break
		end
	end
	return specs
end

function review._on_event(ev)
	if ev.type == "message_update" then
		local ame = ev.assistantMessageEvent or {}
		if ame.type == "text_delta" and ame.delta then
			reply_acc = reply_acc .. ame.delta
		end
	elseif ev.type == "message_end" then
		local text = message_text(ev.message)
		if text ~= "" then
			reply_acc = text
		end
	elseif ev.type == "agent_end" then
		if reply_acc == "" and type(ev.messages) == "table" then
			for i = #ev.messages, 1, -1 do
				local text = message_text(ev.messages[i])
				if text ~= "" then
					reply_acc = text
					break
				end
			end
		end
		querying = false
		if not agent_busy() then
			status.hide()
		end
		local text = vim.trim(reply_acc)
		reply_acc = ""
		if text == "" or text:upper():find("^NONE") or #text > 800 then
			return
		end
		-- The review is of your recent work, not a cursor position, so movement
		-- doesn't stale it — but never interrupt a run that started meanwhile.
		if agent_busy() then
			logview.append("review: (agent busy, dropped)")
			return
		end
		local specs = review.parse(text, config.get().arrows.review.max_arrows)
		if #specs == 0 then
			return
		end
		last_fired_ms = vim.uv.now()
		for _, s in ipairs(specs) do
			logview.append(string.format("review: %d %s: %s", s.lnum, s.kind, s.text))
		end
		arrows.set("review", vim.api.nvim_get_current_buf(), specs)
	end
end

---One background tick. Not tied to any user action: the period timer calls
---this on its own cadence and the gates decide whether a review is worthwhile.
---@param force boolean|nil manual trigger: skip the enabled/recency/cooldown gates
local function fire(force)
	local cfg = config.get()
	if querying or agent_busy() then
		return
	end
	if not force and not cfg.arrows.review.enabled then
		return
	end
	-- Never query mid-insert; the timer repeats, the next tick catches up.
	if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then
		return
	end
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		return
	end
	-- Only review when the user has been editing recently, and not too often
	if not force and (not last_edit_ms or (vim.uv.now() - last_edit_ms) > 600000) then
		return
	end
	if not force and last_fired_ms and (vim.uv.now() - last_fired_ms) < cfg.arrows.review.cooldown_ms then
		return
	end
	-- Skip if nothing changed since the last review of this buffer
	local key = buf .. ":" .. vim.b[buf].changedtick
	if not force and asked[key] then
		return
	end
	asked[key] = true

	local ctx = context.gather()
	if not ensure_client(ctx.root) then
		return
	end

	querying = true
	reply_acc = ""
	status.running()
	status.set_detail("reviewing")
	logview.append(string.format("review: reviewing %s%s", ctx.relpath, force and " (manual)" or ""))
	client:send({ type = "new_session" }, function()
		client:send({ type = "prompt", message = ctx.block })
	end)
	-- Safety: never let a lost reply wedge the reviewer
	vim.defer_fn(function()
		if querying then
			querying = false
			if not agent_busy() then
				status.hide()
			end
		end
	end, 45000)
end

---Force a review right now, bypassing the enabled/recency/cooldown gates.
function review.trigger()
	fire(true)
end

---Start the autonomous cadence. No user action triggers a review — the timer
---does; user activity only feeds the gates (recent-edit, changedtick).
---@param busy fun():boolean true while the agent runs/proposes (suppresses the reviewer)
function review.setup(busy)
	agent_busy = busy
	local group = vim.api.nvim_create_augroup("AgenticTabReview", { clear = true })

	if period_timer then
		period_timer:stop()
		period_timer:close()
		period_timer = nil
	end
	local period = config.get().arrows.review.period_ms
	if config.get().arrows.review.enabled and period > 0 then
		period_timer = vim.uv.new_timer()
		period_timer:start(period, period, function()
			vim.schedule(fire)
		end)
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		callback = function()
			last_edit_ms = vim.uv.now()
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if period_timer then
				period_timer:stop()
			end
			client:stop()
		end,
	})
end

return review
