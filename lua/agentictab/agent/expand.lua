-- Expand float: full detail for whatever an arrow or the status line
-- truncated — a pending bash command, a long result arrow body — anchored
-- above the bottom-right status badge. Transient: any movement closes it.

local expand = {}

---@type integer|nil, integer|nil
local win, buf = nil, nil

function expand.close()
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	win, buf = nil, nil
end

---@return boolean
function expand.is_open()
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param title string
---@param text string
---@param ft string
function expand.open(title, text, ft)
	expand.close()
	local lines = vim.split(text, "\n")
	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = ft
	vim.bo[buf].modifiable = false

	local width = math.min(90, vim.o.columns - 4)
	local height = 0
	for _, l in ipairs(lines) do
		height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
	end
	height = math.max(1, math.min(height, 14))

	win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		row = math.max(0, vim.o.lines - vim.o.cmdheight - 3 - height),
		col = math.max(0, vim.o.columns - width - 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "left",
		focusable = false,
		zindex = 190,
	})
	vim.wo[win].wrap = true
end

return expand
