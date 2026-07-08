-- Shared mutable state for one agent session/run, owned collectively by the
-- agent/ modules (init = lifecycle, proposal, arrows, bash). Everything here
-- is plain data plus the few readers that only need this data; behavior lives
-- in the sibling modules.

local rpc = require("agentictab.agent.rpc")

local S = {}

---The persistent `pi --mode rpc` client (one per nvim session).
S.client = rpc.new()

---@type string|nil project root the live pi process was started in
S.session_root = nil
---@type string what agent/model is behind the bar, e.g. "pi · deepseek-v4-flash"
S.agent_label = "pi"
---@type boolean a run is in flight
S.run_active = false
---@type boolean discard the run result when it completes (user cancelled)
S.discard_result = false
---@type {path: string, root: string, source: string|nil, mode: string, origin: {buf: integer, lnum: integer}, arrow_id: integer|nil}|nil in-flight run info
S.run = nil
---@type {text: string, mode: string, source: string|nil, buf: integer, lnum: integer, arrow_id: integer|nil}[]
--- launches waiting behind the active run. Runs serialize because they share
--- the repo and one backup dir; several can be fired and they drain one
--- after another, each marked by its user arrow.
S.queue = {}

---@class ProposalFile
---@field path string absolute path
---@field new_lines string[] what the walk proposes: the 3-way merge of base,
--- the user's buffer, and the agent's content (raw agent content while
--- streaming). Overlapping edits appear as conflict-marker blocks.
---@field agent_lines string[] the agent's final content (merge input)
---@field base_lines string[]|nil pre-run snapshot (merge base)
---@field skipped table<string, boolean> content-hashes of skipped hunks

---@class Proposal
---@field files table<string, ProposalFile>
---@field order string[]
---@field accepted integer
---@field skipped_n integer
---@field muted boolean user typed during streaming; hold presentations until agent_end
---@field first_shown integer|nil vim.uv.now() when the first hunk became visible
---@field source string|nil arrow source that launched the run ("user", "dwell", …)
---@type Proposal|nil
S.proposal = nil

---What is currently rendered.
---@type {path: string, hunk: Hunk, snapshot: string[], mode: "jump"|"diff"}|nil
S.display = nil

---Pending bash approval (extension blocks the command until we answer).
---@type {id: string, cmd: string}|nil
S.pending_bash = nil

-- Guards so our own window/buffer manipulation isn't mistaken for the user
-- rejecting the proposal.
S.navigating = false
S.bar_opening = false

---@type boolean|nil saved 'autoread' value while a run is in flight
S.saved_autoread = nil

S.backup_dir = vim.fn.stdpath("cache") .. "/agentictab/backup-" .. vim.fn.getpid()

S.log = require("agentictab.logview").append

function S.busy()
	return S.run_active or S.proposal ~= nil
end

---Backup key for a path (must match pi-ext/backup.ts).
function S.backup_key(path)
	return vim.fn.sha256(path)
end

function S.clear_backup_dir()
	vim.fn.delete(S.backup_dir, "rf")
	vim.fn.mkdir(S.backup_dir, "p")
end

---Pre-run content of a file, best source available.
---@param path string real project path
---@return string[]
function S.old_lines_for(path)
	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end
	if S.run_active then
		-- Mid-run the disk holds the agent's version; the backup extension's
		-- snapshot is the pre-run content.
		local orig = S.backup_dir .. "/" .. S.backup_key(path) .. ".orig"
		if vim.fn.filereadable(orig) == 1 then
			return vim.fn.readfile(orig)
		end
		return { "" } -- agent-created file
	end
	if vim.fn.filereadable(path) == 1 then
		return vim.fn.readfile(path)
	end
	return { "" }
end

return S
