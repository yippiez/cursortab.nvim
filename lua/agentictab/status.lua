-- Bottom-right status badge.
--
-- Shows a spinner + elapsed time + latest agent activity while a run is in
-- flight, a persistent hint while a proposal is being walked, and transient
-- messages otherwise. Rendered as a small floating window so it works
-- without any statusline integration.

---@class StatusModule
local status = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@type integer|nil
local win = nil
---@type integer|nil
local buf = nil
---@type uv.uv_timer_t|nil
local timer = nil
local frame_idx = 1
---@type integer runs waiting behind the active one; >0 shows "(n) queued"
local queued_count = 0
---@type integer|nil run start (ms)
local started_ms = nil
---@type string
local detail = ""
---@type string|nil persistent (non-spinner) text
local static_text = nil

local function ensure_win(width)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
	end
	local row = vim.o.lines - vim.o.cmdheight - 1
	local col = math.max(0, vim.o.columns - width - 1)
	local cfg = {
		relative = "editor",
		row = row - 1,
		col = col,
		width = width,
		height = 1,
		style = "minimal",
		border = "none",
		focusable = false,
		zindex = 150,
	}
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_config(win, cfg)
	else
		cfg.noautocmd = true
		win = vim.api.nvim_open_win(buf, false, cfg)
		vim.wo[win].winhighlight = "Normal:AgenticTabStatus"
	end
end

local function render(text)
	local width = math.max(1, vim.fn.strdisplaywidth(text))
	ensure_win(width)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
	vim.bo[buf].modifiable = false
end

local function stop_timer()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

function status.hide()
	stop_timer()
	static_text = nil
	started_ms = nil
	queued_count = 0
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	win = nil
end

local function tick()
	frame_idx = frame_idx % #FRAMES + 1
	local elapsed = started_ms and math.floor((vim.uv.now() - started_ms) / 1000) or 0
	local q = queued_count > 0 and string.format(" · (%d) queued", queued_count) or ""
	local text = string.format("%s %s%s · %ds", FRAMES[frame_idx], detail, q, elapsed)
	vim.schedule(function()
		if timer then
			render(text)
		end
	end)
end

---Start the running spinner.
function status.running()
	static_text = nil
	detail = "thinking"
	started_ms = vim.uv.now()
	if not timer then
		timer = vim.uv.new_timer()
		timer:start(0, 250, tick)
	end
end

---Set how many runs are waiting behind the active one. >0 shows "(n) queued".
---@param n integer
function status.queued(n)
	queued_count = math.max(0, n)
end

---Update the activity detail shown next to the spinner (e.g. current tool).
---@param text string
function status.set_detail(text)
	detail = text
end

---Show a persistent text (proposal walk hint).
---@param text string
function status.persistent(text)
	stop_timer()
	started_ms = nil
	static_text = text
	render(text)
end

---Show a transient message that fades after `ms` (default 4000).
---@param text string
---@param ms integer|nil
function status.flash(text, ms)
	stop_timer()
	started_ms = nil
	static_text = nil
	render(text)
	vim.defer_fn(function()
		if not timer and static_text == nil then
			status.hide()
		end
	end, ms or 4000)
end

return status
