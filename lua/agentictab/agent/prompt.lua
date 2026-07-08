-- Floating single-line prompt bar.
--
-- Opened by the request keymap. Submitting calls back with the typed text;
-- Esc cancels. Keeps a small history navigable with <Up>/<Down>.

---@class PromptModule
local prompt = {}

---@type integer|nil
local win = nil
---@type integer|nil
local buf = nil
---@type string[]
local history = {}
---@type integer
local history_pos = 0

-- Paste folding: the bar is a single-line float, so a multi-line paste would
-- overflow and break the UI. Since <CR> submits, any newline in the buffer can
-- only come from a paste — we stash the real (multi-line) content and show a
-- compact `[pasted N lines]` placeholder, expanding it again on submit.
---@type string|nil the real text behind the current placeholder
local paste_text = nil
---@type string|nil the visible placeholder token, e.g. "[pasted 12 lines]"
local paste_placeholder = nil
---@type boolean guard so the fold's own set_lines does not re-enter
local collapsing = false

---@return boolean
function prompt.is_open()
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@type integer|nil ms timestamp of the last close
local closed_at = nil

---Spacer virtual line the fallback placement inserts so the bar never covers
---real code.
---@type {buf: integer, id: integer}|nil
local spacer = nil

---Whether the bar closed within the last few event-loop ticks. The global
---Esc handler's deferred reject fires after the bar's own <Esc> mapping has
---already closed it; that reject must not also dismiss the proposal.
---@return boolean
function prompt.just_closed()
	return closed_at ~= nil and (vim.uv.now() - closed_at) < 200
end

local ns = vim.api.nvim_create_namespace("agentictab_prompt")

local function close()
	-- Mark closed BEFORE touching the window: nvim_win_close fires
	-- WinLeave/BufEnter synchronously, and their reject handlers consult
	-- just_closed().
	closed_at = vim.uv.now()
	local w, b = win, buf
	win = nil
	buf = nil
	paste_text = nil
	paste_placeholder = nil
	collapsing = false
	if spacer and vim.api.nvim_buf_is_valid(spacer.buf) then
		pcall(vim.api.nvim_buf_del_extmark, spacer.buf, ns, spacer.id)
	end
	spacer = nil
	if w and vim.api.nvim_win_is_valid(w) then
		vim.api.nvim_win_close(w, true)
	end
	if b and vim.api.nvim_buf_is_valid(b) then
		vim.api.nvim_buf_delete(b, { force = true })
	end
	vim.cmd.stopinsert()
end


---Open the prompt bar: a borderless one-line float at the cursor with an
---inline `⇥` prefix you type after.
---@param opts {prefix: string|nil, prefill: string|nil, on_submit: fun(text: string), on_cancel: fun()|nil}
function prompt.open(opts)
	if prompt.is_open() then
		close()
	end
	paste_text = nil
	paste_placeholder = nil
	collapsing = false

	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	if opts.prefill and opts.prefill ~= "" then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.prefill })
	end

	local prefix = "  " .. (opts.prefix or "⇥") .. " "
	vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
		virt_text = { { prefix, "AgenticTabPrompt" } },
		virt_text_pos = "inline",
		right_gravity = false,
	})

	-- Placeholder while empty so the open bar is unmissable
	local placeholder_id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
		virt_text = { { "your request… (Enter sends · Esc cancels)", "AgenticTabHint" } },
		virt_text_pos = "eol",
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			local empty = (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
			if placeholder_id and not empty then
				pcall(vim.api.nvim_buf_del_extmark, buf, ns, placeholder_id)
				placeholder_id = nil
			elseif not placeholder_id and empty then
				placeholder_id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
					virt_text = { { "your request… (Enter sends · Esc cancels)", "AgenticTabHint" } },
					virt_text_pos = "eol",
				})
			end
		end,
	})

	-- Render like eol ghost text: a borderless float starting at the end of
	-- the current line when that fits on screen. When it doesn't, insert a
	-- blank virtual line below the cursor line and put the bar on that row —
	-- the code below shifts down instead of being covered.
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_get_current_line()
	local parent_buf = vim.api.nvim_get_current_buf()
	local sp = vim.fn.screenpos(0, lnum, math.max(#line, 1))
	local max_row = vim.o.lines - vim.o.cmdheight - 1
	local row, col
	if sp.row and sp.row > 0 and sp.row - 1 <= max_row and sp.endcol and sp.endcol > 0 and vim.o.columns - sp.endcol >= 30 then
		row = sp.row - 1
		col = sp.endcol
	else
		-- Make sure the row below the line's last screen row is visible
		if not sp.row or sp.row == 0 or sp.row >= max_row then
			local view = vim.fn.winsaveview()
			pcall(vim.fn.winrestview, { topline = view.topline + 1 })
			sp = vim.fn.screenpos(0, lnum, math.max(#line, 1))
		end
		spacer = {
			buf = parent_buf,
			id = vim.api.nvim_buf_set_extmark(parent_buf, ns, lnum - 1, 0, {
				virt_lines = { { { "", "Normal" } } },
				virt_lines_above = false,
			}),
		}
		local csp = vim.fn.screenpos(0, lnum, math.max(vim.fn.col("."), 1))
		-- The spacer occupies the screen row after the line's last row; as a
		-- 0-indexed float row that is exactly sp.row.
		row = (sp.row and sp.row > 0) and sp.row or ((csp.row and csp.row > 0) and csp.row or 1)
		col = math.max(0, ((csp.col and csp.col > 0) and csp.col or 1) - 1)
		col = math.min(col, math.max(0, vim.o.columns - 40))
	end
	row = math.max(0, math.min(row, max_row))
	local width = math.max(30, vim.o.columns - col)

	local ok_open
	ok_open, win = pcall(vim.api.nvim_open_win, buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = 1,
		style = "minimal",
		border = "none",
		zindex = 200,
	})
	if not ok_open then
		win = nil
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		buf = nil
		return
	end
	vim.wo[win].winhighlight = "Normal:AgenticTabPrompt"

	-- Fold a multi-line paste into a single-line `[pasted N lines]` placeholder
	-- so the height-1 bar never overflows. The full text is stashed and
	-- restored on submit; typing before/after the placeholder is preserved, and
	-- pasting again re-folds the accumulated content.
	local function collapse_paste()
		if collapsing then
			return
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if #lines <= 1 then
			return
		end
		local joined = table.concat(lines, "\n")
		-- expand a prior placeholder first so re-pastes accumulate real content
		if paste_placeholder and paste_text and joined:find(paste_placeholder, 1, true) then
			joined = joined:gsub(vim.pesc(paste_placeholder), function()
				return paste_text
			end, 1)
		end
		joined = joined:gsub("\n+$", "") -- drop a paste's trailing blank line(s)
		local _, nl = joined:gsub("\n", "")
		paste_text = joined
		paste_placeholder = string.format("[pasted %d lines]", nl + 1)
		collapsing = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { paste_placeholder })
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win, { 1, #paste_placeholder })
		end
		collapsing = false
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = collapse_paste,
	})

	history_pos = #history + 1

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = table.concat(lines, " ")
		-- restore the real pasted content in place of its placeholder
		if paste_placeholder and paste_text and text:find(paste_placeholder, 1, true) then
			text = text:gsub(vim.pesc(paste_placeholder), function()
				return paste_text
			end, 1)
		end
		text = vim.trim(text)
		close()
		if text ~= "" then
			-- history entries must stay single-line (set_text can't take newlines)
			table.insert(history, (text:gsub("%s*\n%s*", " ")))
			if #history > 50 then
				table.remove(history, 1)
			end
			opts.on_submit(text)
		elseif opts.on_cancel then
			opts.on_cancel()
		end
	end

	local function cancel()
		close()
		if opts.on_cancel then
			opts.on_cancel()
		end
	end

	local function set_text(text)
		-- replacing the whole buffer discards any active paste placeholder
		paste_text = nil
		paste_placeholder = nil
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
		vim.api.nvim_win_set_cursor(win, { 1, #text })
	end

	local function history_prev()
		if history_pos > 1 then
			history_pos = history_pos - 1
			set_text(history[history_pos])
		end
	end

	local function history_next()
		if history_pos <= #history then
			history_pos = history_pos + 1
			set_text(history[history_pos] or "")
		end
	end

	local map_opts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set({ "i", "n" }, "<CR>", submit, map_opts)
	vim.keymap.set({ "i", "n" }, "<Esc>", cancel, map_opts)
	vim.keymap.set("i", "<Up>", history_prev, map_opts)
	vim.keymap.set("i", "<Down>", history_next, map_opts)

	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(function()
				if prompt.is_open() then
					cancel()
				end
			end)
		end,
	})

	vim.cmd.startinsert({ bang = true })
end

return prompt
