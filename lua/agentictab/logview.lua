-- Live agent log: every run event (prompts, tool calls, approvals, dwell
-- queries) appends here as it happens. Toggled into a bottom split for
-- debugging; windows showing the log auto-scroll to follow new lines.

---@class LogviewModule
local logview = {}

local MAX_LINES = 2000

---@type string[]
local lines = {}
---@type integer|nil
local buf = nil

local function buf_valid()
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function ensure_buf()
	if buf_valid() then
		return buf
	end
	buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, "agentictab://log")
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "agentictab-log"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_call(buf, function()
		vim.cmd([[
			syntax match AgenticTabLogMeta /^──.*$/
			syntax match AgenticTabLogMeta /^===.*$/
			syntax match AgenticTabLogDwell /^dwell:.*$/
			syntax match AgenticTabLogTool /^→ \S*/
			syntax match AgenticTabLogError /^\s*[✗!].*$/
			syntax match AgenticTabLogOk /^\s*✓.*$/
			syntax match AgenticTabLogUser /^USER.*$/
		]])
	end)
	return buf
end

---Append a (possibly multi-line) entry.
---@param entry string
function logview.append(entry)
	local new = vim.split(entry, "\n")
	vim.list_extend(lines, new)

	local overflow = #lines - MAX_LINES
	if overflow > 0 then
		lines = vim.list_slice(lines, overflow + 1, #lines)
	end

	if buf_valid() then
		vim.bo[buf].modifiable = true
		if overflow > 0 then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		else
			-- Replace the trailing empty line a fresh buffer starts with
			local count = vim.api.nvim_buf_line_count(buf)
			if count == 1 and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == "" then
				vim.api.nvim_buf_set_lines(buf, 0, 1, false, new)
			else
				vim.api.nvim_buf_set_lines(buf, -1, -1, false, new)
			end
		end
		vim.bo[buf].modifiable = false

		-- Follow the tail in any window showing the log
		local last = vim.api.nvim_buf_line_count(buf)
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) == buf then
				pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
			end
		end
	end
end

---Toggle the bottom log window.
function logview.toggle()
	ensure_buf()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == buf then
			vim.api.nvim_win_close(win, true)
			return
		end
	end
	local prev = vim.api.nvim_get_current_win()
	vim.cmd("botright 12split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixheight = true
	vim.wo[win].wrap = true
	local last = vim.api.nvim_buf_line_count(buf)
	pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
	-- Keep focus where the user was working
	if vim.api.nvim_win_is_valid(prev) then
		vim.api.nvim_set_current_win(prev)
	end
end

---@return string[]
function logview.get_lines()
	return vim.deepcopy(lines)
end

return logview
