-- Hunk computation, rendering groups, and buffer application.
--
-- A proposal is a list of hunks per file, computed with vim.diff between the
-- user's buffer content (old) and the agent's produced content (new). Hunks
-- are rendered one at a time through the existing cursortab UI group format
-- and applied to the buffer only when accepted. Because earlier accepted or
-- skipped hunks shift line numbers, every hunk stores original (old-file)
-- coordinates and callers thread a per-file `delta` through render/apply.

---@class DiffviewModule
local diffview = {}

---@class Hunk
---@field kind string "modification" | "addition" | "deletion"
---@field old_start integer 1-indexed first old line (modification/deletion); for addition: the old line AFTER which to insert (0 = before first line)
---@field old_count integer number of old lines replaced/removed (0 for addition)
---@field old_lines string[]
---@field new_lines string[]

-- Merge raw vim.diff hunks whose gap is <= this many unchanged lines into a
-- single modification hunk, so tightly clustered edits render as one block.
local MERGE_GAP = 3

---@param old_lines string[]
---@param new_lines string[]
---@return Hunk[]
function diffview.compute_hunks(old_lines, new_lines)
	local old_text = table.concat(old_lines, "\n") .. "\n"
	local new_text = table.concat(new_lines, "\n") .. "\n"
	if old_text == new_text then
		return {}
	end

	local ok, indices = pcall(vim.diff, old_text, new_text, { result_type = "indices" })
	if not ok or type(indices) ~= "table" then
		return {}
	end

	---@type Hunk[]
	local hunks = {}
	for _, h in ipairs(indices) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
		local hunk = {
			old_start = start_a,
			old_count = count_a,
			old_lines = {},
			new_lines = {},
		}
		if count_a == 0 then
			hunk.kind = "addition"
		elseif count_b == 0 then
			hunk.kind = "deletion"
		else
			hunk.kind = "modification"
		end
		for i = start_a, start_a + count_a - 1 do
			table.insert(hunk.old_lines, old_lines[i] or "")
		end
		for i = start_b, start_b + count_b - 1 do
			table.insert(hunk.new_lines, new_lines[i] or "")
		end
		table.insert(hunks, hunk)
	end

	-- Merge close-together hunks (absorbing the unchanged gap lines)
	---@type Hunk[]
	local merged = {}
	for _, hunk in ipairs(hunks) do
		local prev = merged[#merged]
		if prev then
			local prev_end = prev.old_start + math.max(prev.old_count, prev.kind == "addition" and 0 or prev.old_count) - 1
			if prev.kind == "addition" then
				prev_end = prev.old_start
			end
			local gap_start = prev_end + 1
			local this_start = hunk.kind == "addition" and hunk.old_start + 1 or hunk.old_start
			local gap = this_start - gap_start
			if gap >= 0 and gap <= MERGE_GAP then
				-- Rebuild prev as a modification spanning both hunks plus the gap
				local new_prev = {
					kind = "modification",
					old_start = prev.kind == "addition" and prev.old_start + 1 or prev.old_start,
					old_lines = {},
					new_lines = {},
				}
				-- prev's old + new
				vim.list_extend(new_prev.old_lines, prev.old_lines)
				vim.list_extend(new_prev.new_lines, prev.new_lines)
				-- gap lines (identical on both sides)
				for i = gap_start, this_start - 1 do
					table.insert(new_prev.old_lines, old_lines[i] or "")
					table.insert(new_prev.new_lines, old_lines[i] or "")
				end
				-- this hunk's old + new
				vim.list_extend(new_prev.old_lines, hunk.old_lines)
				vim.list_extend(new_prev.new_lines, hunk.new_lines)
				new_prev.old_count = #new_prev.old_lines
				merged[#merged] = new_prev
				goto continue
			end
		end
		table.insert(merged, hunk)
		::continue::
	end

	return merged
end
---First buffer line the hunk touches (1-indexed), with delta applied.
---@param hunk Hunk
---@param delta integer
---@return integer
function diffview.hunk_buffer_line(hunk, delta)
	if hunk.kind == "addition" then
		-- Rendered as virt lines above old_start+1 (or below EOF)
		return math.max(1, hunk.old_start + delta + 1)
	end
	return hunk.old_start + delta
end

---Build a DiffResult for a hunk, at its delta-shifted buffer position.
---
---Every hunk renders as a uniform before/after diff: the old lines get the
---deletion highlight, the new content appears as a block directly below.
---(Char-level ghost text and side-by-side/stacked overlays proved fragile
---in practice and are intentionally not used.)
---@param hunk Hunk
---@param delta integer accumulated line delta for the file
---@param _win integer|nil unused (kept for call-site compatibility)
---@return DiffResult
function diffview.render_groups(hunk, delta, _win)
	local buffer_line = diffview.hunk_buffer_line(hunk, delta)
	local groups = {}

	if hunk.kind == "addition" then
		table.insert(groups, {
			type = "addition",
			start_line = 1,
			end_line = #hunk.new_lines,
			buffer_line = buffer_line,
			lines = hunk.new_lines,
			old_lines = {},
		})
	else
		-- Old lines highlighted as removed…
		table.insert(groups, {
			type = "deletion",
			start_line = 1,
			end_line = #hunk.old_lines,
			buffer_line = buffer_line,
			lines = {},
			old_lines = hunk.old_lines,
		})
		-- …new content as a block right below them.
		if #hunk.new_lines > 0 then
			table.insert(groups, {
				type = "addition",
				start_line = 1,
				end_line = #hunk.new_lines,
				buffer_line = buffer_line + #hunk.old_lines,
				lines = hunk.new_lines,
				old_lines = {},
			})
		end
	end

	return {
		groups = groups,
		startLine = buffer_line,
		cursor_line = 1,
		cursor_col = 0,
	}
end

---Apply a hunk to a buffer at its delta-shifted position.
---@param bufnr integer
---@param hunk Hunk
---@param delta integer accumulated line delta for the file
---@return integer delta_change (#new - #old)
---@return integer end_line 1-indexed last line of the applied region (cursor target)
function diffview.apply(bufnr, hunk, delta)
	if hunk.kind == "addition" then
		local at = hunk.old_start + delta -- 0-indexed insertion point == after this many lines
		vim.api.nvim_buf_set_lines(bufnr, at, at, false, hunk.new_lines)
		return #hunk.new_lines, at + #hunk.new_lines
	end

	local start0 = hunk.old_start + delta - 1
	local end0 = start0 + hunk.old_count
	vim.api.nvim_buf_set_lines(bufnr, start0, end0, false, hunk.new_lines)
	local delta_change = #hunk.new_lines - hunk.old_count
	local end_line = math.max(1, start0 + math.max(#hunk.new_lines, 1))
	return delta_change, end_line
end

return diffview
