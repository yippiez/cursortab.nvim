-- Buffer↔disk reconciliation. The agent works directly on the files — no
-- copies, no restore — so a file can hold agent content while the user's
-- buffer holds their own changes. This module tracks, per agent-touched
-- buffer, the last content buffer and disk agreed on (the merge base), and
-- reconciles on the user's schedule:
--
--   :w      the buffer is 3-way merged with the disk (base vs yours vs
--           agent) and the merge result is written; your changes are never
--           lost, overlaps become conflict markers in the buffer.
--   reload  when nvim notices the disk changed under an UNMODIFIED buffer,
--           it simply reloads; under a modified buffer the merge runs first,
--           the merged content is written, and the buffer reloads that.
--
-- Only buffers of files the agent has touched are intercepted; every other
-- file keeps nvim's stock write path.

local logview = require("agentictab.logview")
local merge = require("agentictab.agent.merge")

---@class SyncModule
local sync = {}

---@type table<integer, string[]> bufnr → content at last buffer↔disk sync
local bases = {}
---@type table<integer, boolean> bufnr → write/reload hooks installed
local attached = {}

local group = vim.api.nvim_create_augroup("AgenticTabSync", { clear = true })

---@param buf integer
---@return string[]|nil
function sync.base(buf)
	return bases[buf]
end

---Record that buffer and disk agree on `lines` (walk finished, file saved…).
---@param buf integer
---@param lines string[]
function sync.set_base(buf, lines)
	bases[buf] = lines
end

---@param path string
---@return string[]|nil
local function read_disk(path)
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or nil
end

---Write the buffer, merging with the disk first when the agent changed it
---underneath. Runs as the buffer's BufWriteCmd.
---@param buf integer
local function save(buf)
	local path = vim.api.nvim_buf_get_name(buf)
	local yours = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local disk = read_disk(path)
	local base = bases[buf] or disk or yours

	local towrite = yours
	if disk and not vim.deep_equal(disk, base) and not vim.deep_equal(disk, yours) then
		local merged, clean = merge.three_way(base, yours, disk)
		towrite = merged
		if not vim.deep_equal(merged, yours) then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, merged)
		end
		if clean then
			vim.notify("[agentictab] merged the agent's disk changes into your save", vim.log.levels.INFO)
		else
			vim.notify("[agentictab] saved with conflict markers — the agent changed the same lines", vim.log.levels.WARN)
		end
		logview.append("sync: merge on save " .. path .. (clean and " (clean)" or " (conflicts)"))
	end

	local ok = pcall(vim.fn.writefile, towrite, path)
	if not ok then
		vim.notify("[agentictab] write failed: " .. path, vim.log.levels.ERROR)
		return
	end
	bases[buf] = towrite
	vim.bo[buf].modified = false
	-- Resync nvim's "changed since reading" bookkeeping with the new mtime.
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.cmd, "silent! checktime " .. buf)
		end
	end)
end

---nvim noticed the disk changed under this buffer (FileChangedShell).
---@param buf integer
local function disk_changed(buf)
	if not vim.bo[buf].modified then
		vim.v.fcs_choice = "reload" -- take the agent's content
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(buf) then
				bases[buf] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			end
		end)
		return
	end
	-- Modified buffer: merge now, write the result, and reload it. The user's
	-- changes ride into the merged file; overlaps become conflict markers.
	local path = vim.api.nvim_buf_get_name(buf)
	local disk = read_disk(path)
	if not disk then
		vim.v.fcs_choice = ""
		return
	end
	local yours = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local merged, clean = merge.three_way(bases[buf] or disk, yours, disk)
	pcall(vim.fn.writefile, merged, path)
	vim.v.fcs_choice = "reload"
	logview.append("sync: merge on reload " .. path .. (clean and " (clean)" or " (conflicts)"))
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(buf) then
			bases[buf] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		end
		if not clean then
			vim.notify("[agentictab] agent and buffer changed the same lines — conflict markers left in " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.WARN)
		end
	end)
end

---Start reconciling a file the agent touched. `base_lines` is the content
---from just before the agent's first edit (the extension's snapshot); it
---seeds the merge base only if the buffer isn't tracked yet.
---@param path string absolute path
---@param base_lines string[]|nil
function sync.track(path, base_lines)
	local buf = vim.fn.bufnr(path)
	if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
		return -- no buffer: the disk is simply the truth
	end
	if not bases[buf] and base_lines then
		bases[buf] = base_lines
	end
	if attached[buf] then
		return
	end
	attached[buf] = true
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			save(buf)
		end,
	})
	vim.api.nvim_create_autocmd("FileChangedShell", {
		group = group,
		buffer = buf,
		callback = function()
			disk_changed(buf)
		end,
	})
	-- Any full reload re-syncs the base with what was read.
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		buffer = buf,
		callback = function()
			bases[buf] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			bases[buf] = nil
			attached[buf] = nil
		end,
	})
end

sync._save = save -- test hook
sync._disk_changed = disk_changed -- test hook

return sync
