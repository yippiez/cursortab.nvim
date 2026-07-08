-- Bash approval: the pi extension blocks each agent bash command until we
-- answer. Read-only commands auto-approve; everything else renders the FULL
-- command as a ghost at the cursor (never the status line, never truncated)
-- and blocks on a single picker-style key: Tab/a = run, d / Esc = deny, s = deny
-- and drop into the prompt bar to steer.

local config = require("agentictab.config")
local expand = require("agentictab.agent.expand")
local status = require("agentictab.status")
local S = require("agentictab.agent.state")

local bash = {}

-- Commands auto-approved in "unsafe" mode: read-only, no shell metacharacters.
local SAFE_BASH = {
	ls = true, cat = true, head = true, tail = true, grep = true, rg = true,
	find = true, fd = true, wc = true, pwd = true, which = true, file = true,
	stat = true, tree = true, du = true,
}
local SAFE_GIT_SUB = {
	status = true, log = true, diff = true, show = true, blame = true,
	grep = true, ["ls-files"] = true, branch = true, ["rev-parse"] = true,
}

---@param cmd string
---@return boolean
function bash.is_safe(cmd)
	local cfg = config.get().bash
	if cfg.approval == "always" then
		return false
	end
	-- Chaining/redirection/substitution: can't classify, ask.
	if cmd:find("[;&|><`$\n]") then
		return false
	end
	local first, second = cmd:match("^%s*(%S+)%s*(%S*)")
	if not first then
		return false
	end
	first = first:match("[^/]+$") or first
	if SAFE_BASH[first] then
		return true
	end
	for _, name in ipairs(cfg.allow or {}) do
		if first == name then
			return true
		end
	end
	if first == "git" and SAFE_GIT_SUB[second] then
		return true
	end
	return false
end

-- Approval ghost ----------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("agentictab_bash")
---@type {buf: integer, extmark: integer}|nil
local ghost = nil

function bash.ghost_clear()
	if ghost and vim.api.nvim_buf_is_valid(ghost.buf) then
		pcall(vim.api.nvim_buf_del_extmark, ghost.buf, ns, ghost.extmark)
	end
	ghost = nil
end

---@param cmd string
function bash.ghost_show(cmd)
	bash.ghost_clear()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		return
	end
	local row = vim.api.nvim_win_get_cursor(0)[1]
	-- wrap the whole command, untruncated, to the window width
	local width = math.max(30, vim.api.nvim_win_get_width(0) - 12)
	local vlines = {}
	for _, line in ipairs(vim.split(cmd, "\n")) do
		repeat
			vlines[#vlines + 1] = { { "    " .. vim.fn.strcharpart(line, 0, width), "AgenticTabArrowBash" } }
			line = vim.fn.strcharpart(line, width)
		until line == ""
	end
	vlines[#vlines + 1] = {
		{ "    · ", "AgenticTabHint" },
		{ "Tab", "AgenticTabPickerLabel" },
		{ "/", "AgenticTabHint" },
		{ "a", "AgenticTabPickerLabel" },
		{ " run  ", "AgenticTabHint" },
		{ "d", "AgenticTabPickerLabel" },
		{ " deny  ", "AgenticTabHint" },
		{ "s", "AgenticTabPickerLabel" },
		{ " steer (declines)", "AgenticTabHint" },
	}
	ghost = {
		buf = buf,
		extmark = vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
			virt_text = { { " ⇥ run this command?", "AgenticTabArrowBash" } },
			virt_text_pos = "eol",
			virt_lines = vlines,
		}),
	}
end

---Answer the pending approval (unblocks the agent).
---@param approved boolean
function bash.answer(approved)
	if not S.pending_bash then
		return
	end
	local p = S.pending_bash
	S.pending_bash = nil
	expand.close()
	bash.ghost_clear()
	S.client:send({ type = "extension_ui_response", id = p.id, confirmed = approved })
	S.log((approved and "  ✓ bash approved: " or "  ✗ bash denied: ") .. p.cmd)
	if S.run_active then
		status.running()
		status.set_detail(approved and "running bash" or "bash denied")
	end
end

-- Auto-opened approval for a pending bash command — no <leader>tt needed. This
-- blocks on a single picker-style key (like the picker's label read): Tab/a = run,
-- d / Esc = deny, s (or the steer key) = decline AND drop into the prompt bar
-- to steer. Because it blocks, the user always resolves it (no wedge, no timer).
function bash.flash()
	if not S.pending_bash then
		return
	end
	local esc = vim.keycode("<Esc>")
	local tab = vim.keycode("<Tab>")
	local req = config.get().keymaps.request
	local req_tc = req and vim.api.nvim_replace_termcodes(req, true, true, true) or nil
	while S.pending_bash do
		local ok, ch = pcall(vim.fn.getcharstr)
		if not ok then
			bash.answer(false)
			return
		end
		if ch == "a" or ch == tab or ch == "\t" then
			bash.answer(true)
			return
		elseif ch == "d" or ch == esc then
			bash.answer(false)
			return
		elseif ch == "s" or (req_tc and ch == req_tc) then
			-- steering during an approval auto-declines it, then opens the bar
			bash.answer(false)
			require("agentictab.agent").request_key()
			return
		end
	end
end

---An extension asked whether a bash command may run.
function bash.on_request(ev)
	local cmd = ev.message or ""
	if bash.is_safe(cmd) then
		S.client:send({ type = "extension_ui_response", id = ev.id, confirmed = true })
		S.log("  ✓ bash auto: " .. cmd)
		return
	end
	S.pending_bash = { id = ev.id, cmd = cmd }
	bash.ghost_show(cmd)
	-- auto-open the accept/deny prompt right away (no <leader>tt)
	vim.schedule(bash.flash)
end

return bash
