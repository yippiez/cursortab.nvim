-- Label picker for on-screen arrows (<leader>tt).
--
-- Pressing the key does NOT trigger anything by itself. Instead it dims the
-- code grey and gives every actionable target a short label: every arrow in
-- the buffer (dwell / review / user / result), plus proposal and
-- bash-approval controls when those are live. You type the label to act on
-- that target (multi-char labels resolve incrementally: type the first char
-- to narrow, the second to select).
--
-- Label placement follows the arrow style: EOL arrows get their label
-- appended at the end of the arrow text; ghost arrows (result bodies) get it
-- below the ghost text. Non-arrow controls draw their own labelled line.
--
-- Esc (or any non-matching key) cancels and restores the screen.

local arrows = require("agentictab.agent.arrows")
local diffview = require("agentictab.agent.diffview")
local S = require("agentictab.agent.state")

local M = {}

local ns = vim.api.nvim_create_namespace("agentictab_picker")

-- Home-row-first label alphabet; single chars until we run out, then pairs.
local ALPHA = "asdfghjklqwertyuiopzxcvbnm"

---@param n integer
---@return string[]
local function make_labels(n)
	local labels = {}
	if n <= #ALPHA then
		for i = 1, n do
			labels[i] = ALPHA:sub(i, i)
		end
		return labels
	end
	local i = 1
	for a = 1, #ALPHA do
		for b = 1, #ALPHA do
			if i > n then
				return labels
			end
			labels[i] = ALPHA:sub(a, a) .. ALPHA:sub(b, b)
			i = i + 1
		end
	end
	return labels
end

---Collect the actionable targets in the current window.
---@param buf integer
---@return table[] targets each {lnum, kind, desc, action, arrow_id|nil}
local function gather(buf)
	local targets = {}
	local agent = require("agentictab.agent")

	local cur = vim.api.nvim_win_get_cursor(0)[1]

	-- Proposal controls when a hunk/jump is being walked.
	if S.proposal then
		local row = cur
		if S.display and S.display.hunk then
			row = math.max(1, math.min(diffview.hunk_buffer_line(S.display.hunk, 0), vim.api.nvim_buf_line_count(buf)))
		end
		targets[#targets + 1] = {
			lnum = row,
			kind = "proposal",
			desc = "accept current hunk",
			action = function()
				agent._do_accept()
			end,
		}
		targets[#targets + 1] = {
			lnum = row,
			kind = "proposal",
			desc = "skip current hunk",
			action = function()
				require("agentictab.agent.proposal").skip()
			end,
		}
		targets[#targets + 1] = {
			lnum = row,
			kind = "proposal",
			desc = "revise proposal",
			action = agent.request_key,
		}
	end

	-- Pending bash approval (also accepts with normal-mode Tab).
	local bash_cmd = agent.pending_bash()
	if bash_cmd then
		local short = bash_cmd:gsub("%s+", " ")
		if vim.fn.strchars(short) > 56 then
			short = vim.fn.strcharpart(short, 0, 55) .. "…"
		end
		targets[#targets + 1] = {
			lnum = cur,
			kind = "bash",
			desc = "run bash: " .. short,
			action = function()
				agent.approve_bash(true)
			end,
		}
		targets[#targets + 1] = {
			lnum = cur,
			kind = "bash",
			desc = "deny bash",
			action = function()
				agent.approve_bash(false)
			end,
		}
		targets[#targets + 1] = {
			lnum = cur,
			kind = "bash",
			desc = "deny and steer",
			action = agent.request_key,
		}
	end

	-- Every arrow in the buffer. Suggestion arrows dispatch their action;
	-- result arrows offer dismiss/expand; in-flight user arrows are not
	-- actionable. While a walk suppresses suggestion arrows, skip them.
	for _, a in ipairs(arrows.list(buf)) do
		local lnum = arrows.lnum(a)
		local hidden = arrows.suppressed() and a.source ~= "user" and a.source ~= "result"
		if lnum and not hidden then
			if a.source == "result" then
				targets[#targets + 1] = {
					lnum = lnum,
					kind = a.kind,
					desc = "dismiss result",
					arrow_id = a.id,
					action = function()
						arrows.remove(a.id)
					end,
				}
			elseif not a.status then
				targets[#targets + 1] = {
					lnum = lnum,
					kind = a.kind,
					desc = a.text,
					arrow_id = a.id,
					action = function()
						arrows.dispatch(a)
					end,
				}
			end
		end
	end

	return targets
end

---Dim every visible line, label the arrows in place, and draw a labelled
---line for every non-arrow target.
---@param buf integer
---@param targets table[]
---@param labels string[]
---@param typed string prefix already typed (its chars render highlighted)
local function render(buf, targets, labels, typed)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	-- Dim the whole visible viewport (labels/arrows draw on top at higher prio).
	local w0 = math.max(1, vim.fn.line("w0"))
	local wend = vim.fn.line("w$")
	for l = w0, wend do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, l - 1, 0, {
			end_row = l,
			hl_group = "AgenticTabDim",
			hl_eol = true,
			-- must sit above tree-sitter (100) and LSP semantic tokens (~125),
			-- or only the lower-priority captures (strings, etc.) get dimmed
			priority = 5000,
		})
	end

	-- Arrow targets: re-render the arrows with their labels attached (at the
	-- end of EOL arrows, below the ghost text of ghost arrows).
	local arrow_labels = {}
	for i, t in ipairs(targets) do
		if t.arrow_id then
			arrow_labels[t.arrow_id] = { label = labels[i], typed = typed }
		end
	end
	arrows.render(buf, { labels = arrow_labels })

	-- Non-arrow targets (proposal/bash controls): draw a labelled line.
	for i, t in ipairs(targets) do
		if not t.arrow_id then
			local label = labels[i]
			local matched = typed ~= "" and label:sub(1, #typed) == typed
			local arrow_hl = matched and "AgenticTabArrowActive" or "AgenticTabArrow"
			local chunks = { { "⇥ ", arrow_hl } }
			if matched then
				if #typed > 0 then
					chunks[#chunks + 1] = { typed, "AgenticTabPickerHit" }
				end
				chunks[#chunks + 1] = { label:sub(#typed + 1), "AgenticTabPickerLabel" }
			else
				chunks[#chunks + 1] = { label, "AgenticTabPickerLabel" }
			end
			local desc = (t.desc or t.kind):gsub("%s+", " ")
			if vim.fn.strchars(desc) > 48 then
				desc = vim.fn.strcharpart(desc, 0, 47) .. "…"
			end
			chunks[#chunks + 1] = { " " .. desc, arrow_hl }
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, t.lnum - 1, 0, {
				virt_text = chunks,
				virt_text_pos = "eol",
				priority = 5001,
			})
		end
	end
	vim.cmd("redraw")
end

---Open the picker. Blocking (reads keys) until a target is chosen or cancelled.
function M.open()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		return
	end
	local targets = gather(buf)
	if #targets == 0 then
		local ok, status = pcall(require, "agentictab.status")
		if ok then
			status.flash("nothing to act on — no arrows")
		end
		return
	end
	local labels = make_labels(#targets)

	local typed = ""
	local chosen = nil
	render(buf, targets, labels, typed)
	while true do
		local ok, ch = pcall(vim.fn.getcharstr)
		if not ok or ch == "" or ch == vim.keycode("<Esc>") then
			break
		end
		-- getcharstr returns raw bytes; ignore anything that isn't a label char
		typed = typed .. ch
		local exact, n_prefix = nil, 0
		for i, label in ipairs(labels) do
			if label == typed then
				exact = targets[i]
			end
			if label:sub(1, #typed) == typed then
				n_prefix = n_prefix + 1
			end
		end
		if exact then
			chosen = exact
			break
		end
		if n_prefix == 0 then
			break -- no label matches; cancel
		end
		render(buf, targets, labels, typed)
	end

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	arrows.render(buf) -- drop the labels
	vim.cmd("redraw")
	if chosen then
		local ok, err = pcall(chosen.action)
		if not ok then
			vim.notify("[agentictab] picker action failed: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

-- Test hooks (the interactive open() loop can't run headlessly).
M._make_labels = make_labels
M._gather = gather
M._render = render

return M
