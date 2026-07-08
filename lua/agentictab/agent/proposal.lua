-- Proposal engine: recomputed diffs presented as Tab-acceptable hunks.
--
-- For each touched file, the pending hunks are always diff(user buffer, agent
-- content). Accepting a hunk applies it to the buffer and the next recompute
-- naturally drops it; skipping remembers the hunk by content hash. There is
-- no line-delta bookkeeping.

local arrows = require("agentictab.agent.arrows")
local config = require("agentictab.config")
local diffview = require("agentictab.agent.diffview")
local events = require("agentictab.events")
local prompt = require("agentictab.agent.prompt")
local status = require("agentictab.status")
local ui = require("agentictab.ui")
local S = require("agentictab.agent.state")

local proposal = {}

local function dequeue()
	require("agentictab.agent")._dequeue()
end

---A finished (or dismissed) walk is a decision: the user saw the agent's
---content and chose what to keep in the buffer. Mark buffer and disk as
---agreed on the agent's version so the next :w plainly writes the buffer —
---skipped or dismissed hunks are overwritten on disk, not re-merged back.
local function settle_bases()
	if not S.proposal then
		return
	end
	local sync = require("agentictab.agent.sync")
	for _, path in ipairs(S.proposal.order) do
		local file = S.proposal.files[path]
		local bufnr = vim.fn.bufnr(path)
		if file and bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
			sync.set_base(bufnr, file.agent_lines)
		end
	end
end

---@param h Hunk
---@return string
function proposal.hunk_key(h)
	-- \031 as separator: NUL would make vim.fn convert the string to a Blob,
	-- which sha256() rejects.
	return vim.fn.sha256(table.concat(h.old_lines, "\n") .. "\031" .. table.concat(h.new_lines, "\n"))
end

---Pending (not yet accepted or skipped) hunks for a file, freshly recomputed.
---@param file ProposalFile
---@return Hunk[]
function proposal.pending_hunks(file)
	local old = S.old_lines_for(file.path)
	local hunks = diffview.compute_hunks(old, file.new_lines)
	return vim.tbl_filter(function(h)
		return not file.skipped[proposal.hunk_key(h)]
	end, hunks)
end

---Next file (from `order`) with pending hunks. During a run, only the file
---currently displayed in the window streams; others wait for agent_end.
---@return ProposalFile|nil file
---@return Hunk[]|nil pending
local function next_pending_file()
	if not S.proposal then
		return nil, nil
	end
	local cur_path = vim.api.nvim_buf_get_name(0)
	for _, path in ipairs(S.proposal.order) do
		if not S.run_active or path == cur_path then
			local file = S.proposal.files[path]
			local pending = proposal.pending_hunks(file)
			if #pending > 0 then
				return file, pending
			end
		end
	end
	return nil, nil
end

function proposal.total_pending()
	if not S.proposal then
		return 0
	end
	local n = 0
	for _, path in ipairs(S.proposal.order) do
		n = n + #proposal.pending_hunks(S.proposal.files[path])
	end
	return n
end

function proposal.clear_display()
	S.display = nil
	ui.close_all()
end

function proposal.finish_walk()
	local accepted, skipped_n = S.proposal.accepted, S.proposal.skipped_n
	settle_bases()
	S.proposal = nil
	proposal.clear_display()
	arrows.show()
	local modified = #vim.tbl_filter(function(b)
		return vim.bo[b].modified
	end, vim.api.nvim_list_bufs())
	local hint = modified > 0 and " · :w to save" or ""
	status.flash(string.format("✓ %d accepted · %d skipped%s", accepted, skipped_n, hint), 5000)
	vim.schedule(dequeue)
end

function proposal.discard(reason)
	if not S.proposal then
		return
	end
	local remaining = proposal.total_pending()
	settle_bases()
	S.proposal = nil
	proposal.clear_display()
	arrows.show()
	status.flash(
		string.format("%s (%d left) · %s to revise", reason, remaining, config.get().keymaps.request or "M-."),
		5000
	)
	vim.schedule(dequeue)
end

---If a floating window is focused (prompt bar, pickers, ...), move focus to
---the first normal window so navigation/rendering never hijacks a float.
local function focus_main_window()
	if vim.api.nvim_win_get_config(0).relative == "" then
		return
	end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_config(w).relative == "" then
			S.navigating = true
			vim.api.nvim_set_current_win(w)
			vim.schedule(function()
				S.navigating = false
			end)
			return
		end
	end
end

function proposal.walk_hint()
	local left = proposal.total_pending()
	local streaming = S.run_active and " · streaming" or ""
	return string.format("⇥ %d hunk%s%s · Tab / S-Tab / Esc", left, left == 1 and "" or "s", streaming)
end

-- Coalesce bursts of re-present requests (movement + scroll + text events can
-- all fire in one action) into a single deferred render to avoid flicker.
local present_scheduled = false
function proposal.schedule_present()
	if present_scheduled then
		return
	end
	present_scheduled = true
	vim.schedule(function()
		present_scheduled = false
		proposal.present()
	end)
end

function proposal.present()
	if not S.proposal or S.proposal.muted or prompt.is_open() then
		return
	end
	local file, pending = next_pending_file()
	if not file then
		if S.run_active then
			proposal.clear_display()
			return
		end
		proposal.finish_walk()
		return
	end

	focus_main_window()
	if vim.api.nvim_buf_get_name(0) ~= file.path then
		-- Only after the run: streamed presentation never leaves the buffer.
		S.navigating = true
		local ok = pcall(vim.cmd, "silent keepalt edit " .. vim.fn.fnameescape(file.path))
		vim.schedule(function()
			S.navigating = false
		end)
		if not ok then
			file.skipped["__unopenable__" .. file.path] = true
			S.proposal.files[file.path] = nil
			proposal.schedule_present()
			return
		end
		pending = proposal.pending_hunks(file)
		if #pending == 0 then
			proposal.schedule_present()
			return
		end
	end

	local hunk = pending[1]
	local target = diffview.hunk_buffer_line(hunk, 0)
	local total_lines = vim.api.nvim_buf_line_count(0)
	local display_target = math.max(1, math.min(target, total_lines))
	if not arrows.suppressed() then
		arrows.hide()
	end
	status.persistent(proposal.walk_hint())

	-- Stamp when the first hunk of this proposal became visible, so a stray Esc
	-- right as it appears can't accidentally dismiss it (see on_reject's grace).
	if S.proposal and not S.proposal.first_shown then
		S.proposal.first_shown = vim.uv.now()
	end

	S.display = {
		path = file.path,
		hunk = hunk,
		snapshot = vim.api.nvim_buf_get_lines(0, 0, -1, false),
		mode = "diff",
	}

	-- Center the hunk in the viewport so the change sits mid-screen, not wherever
	-- it happened to fall. Guarded by `navigating` so the cursor move doesn't read
	-- as the user dismissing the proposal / re-triggering present().
	S.navigating = true
	pcall(vim.api.nvim_win_set_cursor, 0, { display_target, 0 })
	pcall(vim.cmd, "normal! zz")
	vim.schedule(function()
		S.navigating = false
	end)

	local w0, wend = vim.fn.line("w0"), vim.fn.line("w$")
	if display_target >= w0 and display_target <= wend then
		ui.show_completion(diffview.render_groups(hunk, 0, vim.api.nvim_get_current_win()))
		if not ui.has_completion() then
			-- Renderer swallowed an error; fall back to the jump indicator so
			-- Tab still has something visible to act on.
			S.log("!! render failed for hunk at line " .. display_target .. " — showing jump indicator")
			S.display.mode = "jump"
			ui.show_cursor_prediction(display_target)
		end
	else
		S.display.mode = "jump"
		ui.show_cursor_prediction(display_target)
	end
end

---Record/refresh a file's content in the proposal, creating the proposal if
---this is its first edit. `merged_lines` is what the walk proposes (the
---3-way merge result once the run has finished; the raw agent content while
---streaming); `meta` carries the merge inputs for later re-merges.
---@param real string real project path
---@param merged_lines string[]
---@param meta {agent_lines: string[]|nil, base_lines: string[]|nil}|nil
function proposal.merge_file(real, merged_lines, meta)
	if not S.proposal then
		S.proposal = {
			files = {},
			order = {},
			accepted = 0,
			skipped_n = 0,
			muted = false,
			source = S.run and S.run.source or nil,
		}
	end
	local file = S.proposal.files[real]
	if not file then
		file = { path = real, new_lines = merged_lines, agent_lines = merged_lines, skipped = {} }
		S.proposal.files[real] = file
		table.insert(S.proposal.order, real)
	else
		file.new_lines = merged_lines
	end
	if meta then
		file.agent_lines = meta.agent_lines or file.agent_lines
		file.base_lines = meta.base_lines or file.base_lines
	end
end

---The user edited the displayed file mid-walk. Instead of discarding the
---proposal, re-merge: base vs the user's new buffer vs the agent's content.
---Non-overlapping user edits survive untouched; overlaps come back as
---conflict-marker hunks.
function proposal.remerge()
	local path = vim.api.nvim_buf_get_name(0)
	local file = S.proposal and S.proposal.files[path]
	if not file then
		-- the user edited a file the agent never touched; their business
		proposal.schedule_present()
		return
	end
	local ours = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local base = file.base_lines or { "" }
	file.new_lines = require("agentictab.agent.merge").three_way(base, ours, file.agent_lines)
	proposal.schedule_present()
end

---Handle a finished agent edit: stream the file's hunks if it's on screen.
---@param path string path as reported by the tool call (may be relative)
function proposal.on_agent_edit(path)
	if not S.run_active or S.discard_result then
		return
	end
	local abs = vim.fs.normalize(path)
	if abs:sub(1, 1) ~= "/" then
		abs = vim.fs.normalize((S.run and S.run.root or vim.fn.getcwd()) .. "/" .. path)
	end
	if abs ~= vim.api.nvim_buf_get_name(0) then
		return
	end
	if vim.fn.filereadable(abs) ~= 1 then
		return
	end
	local ok, new_lines = pcall(vim.fn.readfile, abs)
	if not ok then
		return
	end
	proposal.merge_file(abs, new_lines)
	proposal.present()
end

---Apply the displayed hunk to the buffer (deferred from the Tab mapping).
function proposal.accept()
	if not S.display or not S.proposal then
		events.reset_completing()
		return
	end
	local hunk = S.display.hunk

	if S.display.mode == "jump" then
		local target = diffview.hunk_buffer_line(hunk, 0)
		local total_lines = vim.api.nvim_buf_line_count(0)
		pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(target, total_lines)), 0 })
		events.reset_completing()
		proposal.present()
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	-- The buffer must still match what the hunk was computed against.
	if not vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), S.display.snapshot) then
		events.reset_completing()
		proposal.present()
		return
	end
	local _, end_line = diffview.apply(bufnr, hunk, 0)
	S.proposal.accepted = S.proposal.accepted + 1
	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	pcall(vim.api.nvim_win_set_cursor, 0, { math.min(end_line, total_lines), 0 })
	proposal.clear_display()
	proposal.schedule_present()
end

---Skip (remember and hide) the displayed hunk.
function proposal.skip()
	events.reset_completing()
	if not S.display or not S.proposal then
		return
	end
	local file = S.proposal.files[S.display.path]
	if file then
		file.skipped[proposal.hunk_key(S.display.hunk)] = true
		S.proposal.skipped_n = S.proposal.skipped_n + 1
	end
	proposal.clear_display()
	proposal.present()
end

return proposal
