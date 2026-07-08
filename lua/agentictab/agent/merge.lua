-- Three-way merge: how agent edits are reconciled with user changes.
--
-- base   = the last content buffer and disk agreed on
-- yours  = the user's current buffer
-- agent  = what is on disk (the agent writes files directly)
--
-- Pure Lua on top of vim.diff (nvim's built-in xdiff) — synchronous, no git,
-- no subprocess, no temp files. Non-overlapping changes from both sides merge
-- cleanly; overlapping or touching regions become standard
-- `<<<<<<< yours / ======= / >>>>>>> agent` conflict blocks for the user to
-- resolve.

local M = {}

local xdiff = (vim.text and vim.text.diff) or vim.diff

---@class MergeChunk
---@field from integer first base line replaced (to = from-1 for pure insertions)
---@field to integer last base line replaced
---@field lines string[] replacement lines from the side

---One side's changes as base-anchored chunks.
---@param base_s string
---@param side_s string
---@param side string[]
---@return MergeChunk[]
local function side_chunks(base_s, side_s, side)
	local hunks = xdiff(base_s, side_s, { result_type = "indices" }) or {}
	local out = {}
	for _, h in ipairs(hunks) do
		local as, ac, bs, bc = h[1], h[2], h[3], h[4]
		-- count 0 means an insertion after line `start`; normalize to an
		-- empty span so [from, to] arithmetic works uniformly.
		local from = ac == 0 and as + 1 or as
		local to = ac == 0 and as or as + ac - 1
		local lines = {}
		for i = bs, bs + bc - 1 do
			lines[#lines + 1] = side[i]
		end
		out[#out + 1] = { from = from, to = to, lines = lines }
	end
	return out
end

---Replay one side's chunks over the base range [cs, ce].
---@param list MergeChunk[]
---@param cs integer
---@param ce integer
---@param base string[]
---@return string[]
local function segment(list, cs, ce, base)
	local out, p = {}, cs
	for _, c in ipairs(list) do
		for i = p, c.from - 1 do
			out[#out + 1] = base[i]
		end
		vim.list_extend(out, c.lines)
		p = c.to + 1
	end
	for i = p, ce do
		out[#out + 1] = base[i]
	end
	return out
end

---Merge synchronously. `clean` is false when the result contains conflict
---markers. Fast paths skip the diff when either side did not diverge.
---@param base string[]
---@param yours string[]
---@param agent string[]
---@return string[] merged, boolean clean
function M.three_way(base, yours, agent)
	if vim.deep_equal(yours, base) or vim.deep_equal(yours, agent) then
		-- User didn't diverge (or already matches the agent): take the agent's.
		return vim.deepcopy(agent), true
	end
	if vim.deep_equal(agent, base) then
		-- Agent didn't actually change this file: keep the user's.
		return vim.deepcopy(yours), true
	end

	local base_s = table.concat(base, "\n") .. "\n"
	local A = side_chunks(base_s, table.concat(yours, "\n") .. "\n", yours)
	local B = side_chunks(base_s, table.concat(agent, "\n") .. "\n", agent)

	local out, clean = {}, true
	local ai, bi, pos = 1, 1, 1
	while A[ai] or B[bi] do
		-- Seed a cluster with the earliest chunk, then absorb every chunk from
		-- either side that overlaps or touches it (touching regions conflict,
		-- matching git's behavior: no unchanged line separates the edits).
		local ya, yb = {}, {}
		local cs, ce
		local function absorb(bucket, c)
			bucket[#bucket + 1] = c
			cs = math.min(cs or c.from, c.from)
			ce = math.max(ce or c.to, c.to)
		end
		local a, b = A[ai], B[bi]
		if a and (not b or a.from <= b.from) then
			absorb(ya, a)
			ai = ai + 1
		else
			absorb(yb, b)
			bi = bi + 1
		end
		local grown = true
		while grown do
			grown = false
			a = A[ai]
			if a and a.from <= ce + 1 then
				absorb(ya, a)
				ai = ai + 1
				grown = true
			else
				b = B[bi]
				if b and b.from <= ce + 1 then
					absorb(yb, b)
					bi = bi + 1
					grown = true
				end
			end
		end

		-- Unchanged base up to the cluster.
		for i = pos, cs - 1 do
			out[#out + 1] = base[i]
		end
		pos = ce + 1

		local ys = segment(ya, cs, ce, base)
		local ts = segment(yb, cs, ce, base)
		if #ya == 0 then
			vim.list_extend(out, ts) -- agent-only change
		elseif #yb == 0 then
			vim.list_extend(out, ys) -- user-only change
		elseif vim.deep_equal(ys, ts) then
			vim.list_extend(out, ys) -- both made the same change
		else
			clean = false
			out[#out + 1] = "<<<<<<< yours"
			vim.list_extend(out, ys)
			out[#out + 1] = "======="
			vim.list_extend(out, ts)
			out[#out + 1] = ">>>>>>> agent"
		end
	end
	for i = pos, #base do
		out[#out + 1] = base[i]
	end
	return out, clean
end

return M
