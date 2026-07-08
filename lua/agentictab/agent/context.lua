-- Editor context gathering for agent prompts.
--
-- Collects what the agent needs to infer intent: which file the user is in,
-- where the cursor is (with surrounding code), nearby diagnostics, and the
-- user's recent edit trajectory (uncommitted git diff). Buffers are saved to
-- disk before a run, so disk state matches what the user sees.

local config = require("agentictab.config")

---@class ContextModule
local context = {}

---Project root for a buffer: nearest .git ancestor, else the buffer's dir,
---else cwd.
---@param bufnr integer
---@return string
function context.project_root(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local start = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
	local root = vim.fs.root(start, ".git")
	return root or start
end

---@param bufnr integer
---@param root string
---@return string relative path (or absolute if outside root)
function context.relative_path(bufnr, root)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return "[No Name]"
	end
	local rel = name:sub(1, #root) == root and name:sub(#root + 2) or name
	return rel ~= "" and rel or name
end

---Cursor region snippet with a `>` marker on the cursor line.
---@param bufnr integer
---@param lnum integer 1-indexed cursor line
---@param radius integer
---@return string
local function cursor_snippet(bufnr, lnum, radius)
	local last = vim.api.nvim_buf_line_count(bufnr)
	local first = math.max(1, lnum - radius)
	local final = math.min(last, lnum + radius)
	local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, final, false)
	local out = {}
	for i, line in ipairs(lines) do
		local n = first + i - 1
		local marker = n == lnum and ">" or " "
		table.insert(out, string.format("%s%5d| %s", marker, n, line))
	end
	return table.concat(out, "\n")
end

---Diagnostics near the cursor, formatted one per line.
---@param bufnr integer
---@param lnum integer 1-indexed cursor line
---@return string|nil
local function nearby_diagnostics(bufnr, lnum)
	local radius = config.get().context.diagnostics_radius
	local diags = vim.diagnostic.get(bufnr)
	local out = {}
	local severity_label = { "ERROR", "WARN", "INFO", "HINT" }
	for _, d in ipairs(diags) do
		local dl = d.lnum + 1
		if math.abs(dl - lnum) <= radius then
			table.insert(out, string.format("- L%d [%s] %s", dl, severity_label[d.severity] or "?", d.message:gsub("\n", " ")))
		end
		if #out >= 20 then
			break
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out, "\n")
end

---Uncommitted-diff cache. gather() must never block the editor on git, so
---the diff is refreshed by an async job and gather returns the latest cached
---text (nil on the very first call for a file — the next gather has it).
---@type table<string, {tick: integer, text: string|nil, running: boolean}>
local diff_cache = {}

---Uncommitted diff for the file (the user's recent edit trajectory),
---served from the cache; kicks an async refresh when stale.
---@param root string
---@param relpath string
---@param bufnr integer
---@return string|nil
local function recent_diff(root, relpath, bufnr)
	if vim.fn.isdirectory(root .. "/.git") == 0 and vim.fn.filereadable(root .. "/.git") == 0 then
		return nil
	end
	local key = root .. "//" .. relpath
	local tick = vim.b[bufnr].changedtick
	local c = diff_cache[key]
	if not c or (c.tick ~= tick and not c.running) then
		diff_cache[key] = { tick = tick, text = c and c.text or nil, running = true }
		vim.system(
			{ "git", "-C", root, "diff", "--no-ext-diff", "HEAD", "--", relpath },
			{ text = true },
			vim.schedule_wrap(function(res)
				local entry = diff_cache[key]
				if not entry then
					return
				end
				entry.running = false
				if res.code ~= 0 or not res.stdout or res.stdout == "" then
					entry.text = nil
					return
				end
				local out = vim.split(res.stdout, "\n", { trimempty = true })
				local max = config.get().context.recent_diff_max_lines
				if #out > max then
					out = vim.list_slice(out, 1, max)
					table.insert(out, string.format("... (%d more diff lines truncated)", #out - max))
				end
				entry.text = table.concat(out, "\n")
			end)
		)
	end
	return c and c.text or nil
end

---@class GatheredContext
---@field root string
---@field relpath string
---@field bufnr integer
---@field lnum integer
---@field block string formatted context block for the prompt

---Gather context for the current window/buffer.
---@return GatheredContext
function context.gather()
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local lnum = cursor[1]
	local root = context.project_root(bufnr)
	local relpath = context.relative_path(bufnr, root)
	local ft = vim.bo[bufnr].filetype

	local parts = {}
	table.insert(parts, string.format("File: %s (filetype: %s). The cursor is on line %d, column %d — the line marked '>' below.", relpath, ft ~= "" and ft or "unknown", lnum, cursor[2] + 1))
	table.insert(parts, "Relational words in the request ('here', 'below', 'above', 'this') refer to that cursor line.")
	table.insert(parts, "Code around the cursor (> marks the cursor line):")
	table.insert(parts, "```" .. (ft or ""))
	table.insert(parts, cursor_snippet(bufnr, lnum, 20))
	table.insert(parts, "```")

	local diags = nearby_diagnostics(bufnr, lnum)
	if diags then
		table.insert(parts, "Diagnostics near the cursor:")
		table.insert(parts, diags)
	end

	local diff = recent_diff(root, relpath, bufnr)
	if diff then
		table.insert(parts, "The user's uncommitted changes to this file (their recent edit trajectory — the strongest signal of intent):")
		table.insert(parts, "```diff")
		table.insert(parts, diff)
		table.insert(parts, "```")
	end

	return {
		root = root,
		relpath = relpath,
		bufnr = bufnr,
		lnum = lnum,
		block = table.concat(parts, "\n"),
	}
end

return context
