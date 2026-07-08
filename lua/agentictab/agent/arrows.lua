-- Arrows: the single UI primitive of agentictab.
--
-- Every suggestion and every result is an arrow anchored to a buffer line.
-- Two render styles:
--   eol    `⇥ fix the nil deref` appended after the line, like a suggestion
--   ghost  the same eol head plus virtual lines below (multi-line detail:
--          bash output, ask answers, review notes)
--
-- Arrow text is plain natural language — no kind prefixes. The action kind
-- is the colour group: gray = do, red = bash, yellow = ask.
--
-- Three suggestion sources feed the registry — dwell (cursor rested), review
-- (periodic reviewer), user (typed in the bar) — plus result arrows carrying
-- what a run produced, in the same colour groups (red arrow = bash,
-- suggestion or output).
--
-- Each arrow carries one action — do / bash / ask — dispatched to the agent.
-- Arrows anchor via extmarks, so they ride along with edits.

local arrows = {}

local ns = vim.api.nvim_create_namespace("agentictab_arrows")

---@class Arrow
---@field id integer
---@field buf integer
---@field source "dwell"|"review"|"user"|"result"
---@field kind "do"|"bash"|"ask"
---@field text string one-line display text (shown after "⇥ kind:")
---@field prompt string|nil full instruction for the agent (defaults to text)
---@field body string[]|nil ghost lines below the head (makes it a ghost arrow)
---@field run fun()|nil override: dispatch calls this instead of the agent
---@field status string|nil "queued"|"running" annotation (user arrows)
---@field hl string|nil highlight override
---@field extmark integer anchor extmark (position read back at use time)

---@type table<integer, Arrow>
local by_id = {}
local next_id = 0
---@type boolean arrows hidden while a proposal walk owns the screen
local suppressed = false

-- Sources earlier in this list win when several arrows land on one line.
local PRIORITY = { user = 1, result = 2, dwell = 3, review = 4 }

-- How many ghost lines a result body may occupy before truncating to expand.
local MAX_BODY = 12

-- Arrows carry no textual kind prefix — the action kind IS the colour group:
-- gray = do, red = bash, yellow = ask. Results reuse the same groups (a red
-- arrow is always bash, suggestion or output).
local KIND_HL = {
	bash = "AgenticTabArrowBash",
	ask = "AgenticTabArrowAsk",
}

local function arrow_hl(a)
	return a.hl or KIND_HL[a.kind] or "AgenticTabArrow"
end

---Current 1-indexed line of an arrow (extmark position), nil if gone.
---@param a Arrow
---@return integer|nil
function arrows.lnum(a)
	if not vim.api.nvim_buf_is_valid(a.buf) then
		return nil
	end
	local pos = vim.api.nvim_buf_get_extmark_by_id(a.buf, ns, a.extmark, {})
	if not pos or #pos == 0 then
		return nil
	end
	return pos[1] + 1
end

---@param s string
---@param max integer
---@return string
local function truncate(s, max)
	s = (s or ""):gsub("%s+", " ")
	if vim.fn.strchars(s) > max then
		s = vim.fn.strcharpart(s, 0, max - 1) .. "…"
	end
	return s
end

local label_chunks -- forward declaration

---Head chunks for one arrow: `⇥ kind: text` plus status/label decorations.
---@param a Arrow
---@param label {label: string, typed: string}|nil picker label to append (eol style)
---@return table[] chunks
local function head_chunks(a, label)
	local hl = arrow_hl(a)
	local chunks = { { " ⇥ " .. truncate(a.text, 72), hl } }
	if a.status then
		chunks[#chunks + 1] = { " · " .. a.status, "AgenticTabHint" }
	end
	if label and not a.body then
		-- EOL arrows: the picker label sits at the very end of the arrow.
		chunks[#chunks + 1] = { " ", hl }
		label_chunks(chunks, label)
	end
	return chunks
end

---Append the label (typed prefix highlighted) to a chunk list.
---@param chunks table[]
---@param label {label: string, typed: string}
label_chunks = function(chunks, label)
	local typed = label.typed or ""
	local matched = typed ~= "" and label.label:sub(1, #typed) == typed
	if matched and #typed > 0 then
		chunks[#chunks + 1] = { typed, "AgenticTabPickerHit" }
		chunks[#chunks + 1] = { label.label:sub(#typed + 1), "AgenticTabPickerLabel" }
	else
		chunks[#chunks + 1] = { label.label, "AgenticTabPickerLabel" }
	end
end

---Ghost body lines for one arrow (truncated to MAX_BODY, hint line last).
---@param a Arrow
---@param label {label: string, typed: string}|nil picker label to place below (ghost style)
---@return table[][] virt_lines
local function body_lines(a, label)
	local hl = arrow_hl(a)
	local vlines = {}
	for i = 1, math.min(#a.body, MAX_BODY) do
		vlines[#vlines + 1] = { { "    " .. a.body[i], hl } }
	end
	if #a.body > MAX_BODY then
		vlines[#vlines + 1] = { { string.format("    … %d more lines · <M-e> expand", #a.body - MAX_BODY), "AgenticTabHint" } }
	end
	if label then
		-- Ghost arrows: the picker label sits below the ghost text.
		local chunks = { { "    ", hl } }
		label_chunks(chunks, label)
		chunks[#chunks + 1] = { " act on this arrow", "AgenticTabHint" }
		vlines[#vlines + 1] = chunks
	end
	return vlines
end

---Redraw every arrow of a buffer. Called after any registry change. Each
---arrow's extmark is re-set in place (never cleared wholesale — the extmarks
---are also the position anchors).
---@param buf integer
---@param opts {labels: table<integer, {label: string, typed: string}>}|nil
function arrows.render(buf, opts)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local labels = opts and opts.labels or {}
	local taken = {} -- one rendered arrow per line; priority decides
	for _, a in ipairs(arrows.list(buf)) do
		local lnum = arrows.lnum(a)
		if lnum then
			-- Suppression (a run/proposal walk owns the screen) hides suggestion
			-- arrows; user and result arrows stay visible.
			local visible = not (suppressed and a.source ~= "user" and a.source ~= "result")
				and lnum <= vim.api.nvim_buf_line_count(buf)
				and not taken[lnum]
			if visible then
				taken[lnum] = true
				a.extmark = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
					id = a.extmark,
					virt_text = head_chunks(a, labels[a.id]),
					virt_text_pos = "eol",
					virt_lines = a.body and body_lines(a, labels[a.id]) or nil,
				})
			else
				-- bare re-set drops the decorations but keeps the anchor
				a.extmark = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { id = a.extmark })
			end
		end
	end
end

---All live arrows of a buffer, sorted by line then source priority.
---@param buf integer|nil defaults to the current buffer
---@return Arrow[]
function arrows.list(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local out = {}
	for _, a in pairs(by_id) do
		if a.buf == buf and arrows.lnum(a) then
			out[#out + 1] = a
		end
	end
	table.sort(out, function(x, y)
		local lx, ly = arrows.lnum(x) or 0, arrows.lnum(y) or 0
		if lx ~= ly then
			return lx < ly
		end
		return (PRIORITY[x.source] or 9) < (PRIORITY[y.source] or 9)
	end)
	return out
end

---The highest-priority arrow on a line, if any.
---@param buf integer
---@param lnum integer
---@return Arrow|nil
function arrows.at_line(buf, lnum)
	for _, a in ipairs(arrows.list(buf)) do
		if arrows.lnum(a) == lnum then
			return a
		end
	end
	return nil
end

---Nearest arrow to a line (excluding that line).
---@param buf integer
---@param lnum integer
---@return Arrow|nil
function arrows.nearest(buf, lnum)
	local best, best_d
	for _, a in ipairs(arrows.list(buf)) do
		local l = arrows.lnum(a)
		local d = l and math.abs(l - lnum)
		if l and l ~= lnum and (not best_d or d < best_d) then
			best, best_d = a, d
		end
	end
	return best
end

-- Registry ------------------------------------------------------------------

---Add one arrow. `lnum` is consumed into an extmark anchor.
---@param spec {buf: integer, lnum: integer, source: string, kind: string, text: string, prompt: string|nil, body: string[]|nil, run: fun()|nil, status: string|nil, hl: string|nil}
---@return Arrow|nil
function arrows.add(spec)
	local buf = spec.buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
		return nil
	end
	local lnum = math.max(1, math.min(spec.lnum, vim.api.nvim_buf_line_count(buf)))
	next_id = next_id + 1
	local a = {
		id = next_id,
		buf = buf,
		source = spec.source,
		kind = spec.kind,
		text = spec.text,
		prompt = spec.prompt,
		body = spec.body,
		run = spec.run,
		status = spec.status,
		hl = spec.hl,
		extmark = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {}),
	}
	by_id[a.id] = a
	arrows.render(buf)
	return a
end

---@param id integer|nil
function arrows.remove(id)
	local a = id and by_id[id]
	if not a then
		return
	end
	by_id[id] = nil
	if vim.api.nvim_buf_is_valid(a.buf) then
		pcall(vim.api.nvim_buf_del_extmark, a.buf, ns, a.extmark)
		arrows.render(a.buf)
	end
end

---Drop all arrows of a source (optionally only in one buffer).
---@param source string
---@param buf integer|nil
function arrows.clear(source, buf)
	local touched = {}
	for id, a in pairs(by_id) do
		if a.source == source and (buf == nil or a.buf == buf) then
			by_id[id] = nil
			if vim.api.nvim_buf_is_valid(a.buf) then
				pcall(vim.api.nvim_buf_del_extmark, a.buf, ns, a.extmark)
				touched[a.buf] = true
			end
		end
	end
	for b in pairs(touched) do
		arrows.render(b)
	end
end

---Replace all arrows of a source in a buffer with a fresh list (one render).
---@param source string
---@param buf integer
---@param list {lnum: integer, kind: string, text: string, prompt: string|nil, body: string[]|nil, run: fun()|nil}[]
function arrows.set(source, buf, list)
	for id, a in pairs(by_id) do
		if a.source == source and a.buf == buf then
			by_id[id] = nil
			pcall(vim.api.nvim_buf_del_extmark, a.buf, ns, a.extmark)
		end
	end
	if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
		return
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	for _, spec in ipairs(list) do
		if spec.lnum >= 1 and spec.lnum <= line_count then
			next_id = next_id + 1
			by_id[next_id] = {
				id = next_id,
				buf = buf,
				source = source,
				kind = spec.kind,
				text = spec.text,
				prompt = spec.prompt,
				body = spec.body,
				run = spec.run,
				extmark = vim.api.nvim_buf_set_extmark(buf, ns, spec.lnum - 1, 0, {}),
			}
		end
	end
	arrows.render(buf)
end

---Update fields of a live arrow (status text, attach a result body, …).
---@param id integer
---@param fields table
function arrows.update(id, fields)
	local a = by_id[id]
	if not a then
		return
	end
	for k, v in pairs(fields) do
		a[k] = v
	end
	arrows.render(a.buf)
end

---@param id integer
---@return Arrow|nil
function arrows.get(id)
	return by_id[id]
end

-- Results ---------------------------------------------------------------------

---Wrap text to ghost-body lines at the window width.
---@param text string
---@return string[] body, string first
local function wrap_body(text)
	local width = math.max(40, vim.api.nvim_win_get_width(0) - 16)
	local lines = {}
	for _, l in ipairs(vim.split(text, "\n")) do
		l = l:gsub("%s+$", "")
		repeat
			lines[#lines + 1] = vim.fn.strcharpart(l, 0, width)
			l = vim.fn.strcharpart(l, width)
		until l == ""
	end
	local first = table.remove(lines, 1) or ""
	return lines, first
end

---@type integer|nil the most recent result arrow (for the expand float)
local last_result = nil

---Show a run result as a coloured arrow: yellow for ask:, red for bash:.
---The first line rides the anchor line; the rest is ghost text below.
---@param opts {kind: "ask"|"bash", buf: integer|nil, lnum: integer|nil, text: string}
---@return Arrow|nil
function arrows.result(opts)
	local buf = opts.buf or vim.api.nvim_get_current_buf()
	local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
	local body, first = wrap_body(opts.text)
	local a = arrows.add({
		buf = buf,
		lnum = lnum,
		source = "result",
		kind = opts.kind,
		text = first,
		prompt = opts.text,
		body = #body > 0 and body or nil,
	})
	if a then
		last_result = a.id
	end
	return a
end

---Full text of the most recent result arrow (for the expand float).
---@return string|nil
function arrows.last_result_text()
	local a = last_result and by_id[last_result]
	return a and (a.prompt or a.text) or nil
end

---Dismiss transient arrows (Esc): results first, then the dwell suggestion.
---@return boolean handled
function arrows.dismiss()
	for _, source in ipairs({ "result", "dwell" }) do
		local found = false
		for _, a in pairs(by_id) do
			if a.source == source then
				found = true
				break
			end
		end
		if found then
			arrows.clear(source)
			return true
		end
	end
	return false
end

-- Suppression -------------------------------------------------------------------

---Hide all arrows (a run/proposal walk owns the screen). Anchors survive.
function arrows.hide()
	suppressed = true
	local bufs = {}
	for _, a in pairs(by_id) do
		bufs[a.buf] = true
	end
	for b in pairs(bufs) do
		if vim.api.nvim_buf_is_valid(b) then
			arrows.render(b)
		end
	end
end

---Show arrows again after suppression.
function arrows.show()
	suppressed = false
	local bufs = {}
	for _, a in pairs(by_id) do
		bufs[a.buf] = true
	end
	for b in pairs(bufs) do
		if vim.api.nvim_buf_is_valid(b) then
			arrows.render(b)
		end
	end
end

---@return boolean
function arrows.suppressed()
	return suppressed
end

-- Dispatch ----------------------------------------------------------------------

---Act on an arrow: a `run` override executes directly; everything else
---launches the agent in the arrow's action mode. Suggestion arrows are
---consumed on dispatch.
---@param a Arrow
function arrows.dispatch(a)
	if a.source == "result" then
		return -- results carry no action; Esc dismisses them
	end
	local lnum = arrows.lnum(a) or 1
	arrows.remove(a.id)
	if a.run then
		local ok, err = pcall(a.run)
		if not ok then
			vim.notify("[agentictab] arrow action failed: " .. tostring(err), vim.log.levels.ERROR)
		end
		return
	end
	require("agentictab.agent").launch(a.prompt or a.text, {
		mode = a.kind,
		source = a.source,
		buf = a.buf,
		lnum = lnum,
	})
end

return arrows
