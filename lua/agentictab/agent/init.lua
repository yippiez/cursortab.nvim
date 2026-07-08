-- Run lifecycle: the agentic backend behind the arrows.
--
-- A request comes in one of three modes — do: (make the change), bash: (run a
-- shell task), ask: (answer a question) — typed via the Alt+. bar or
-- dispatched from an arrow (dwell / review / user). Requests are
-- queued and go one at a time to a persistent `pi --mode rpc` process running
-- directly in the project root.
--
-- The agent works on the real files — no copies, no restore. Its edits stay
-- on disk. Open buffers are the user's: the walk presents diff(buffer, disk)
-- as Tab-acceptable hunks for every touched file with a loaded buffer, and
-- sync.lua reconciles buffer and disk whenever they diverge — merging on
-- save (:w 3-way merges your buffer with the agent's disk content) and on
-- reload. The bundled pi extension's pre-edit snapshot is only the merge
-- base, never restored.
--
-- Results come back as the UI's one primitive:
--   do:   inline diff proposals accepted hunk-by-hunk with Tab
--   bash: a red result arrow carrying the command and its output
--   ask:  a yellow result arrow carrying the answer
--
-- The module split: this file owns the pi session and the run lifecycle;
-- proposal.lua owns the hunk walk; arrows.lua owns the arrow registry and
-- result rendering; bash.lua owns command approval; expand.lua the detail
-- float; state.lua holds the shared data they all act on. dwell.lua and
-- review.lua feed suggestion arrows.
--
-- Invariant: buffers are only mutated by accepting hunks or by an explicit
-- merge (save/reload of a diverged file); the disk belongs to the agent and
-- to your saves.

local arrows = require("agentictab.agent.arrows")
local bash = require("agentictab.agent.bash")
local config = require("agentictab.config")
local context = require("agentictab.agent.context")
local diffview = require("agentictab.agent.diffview")
local dwell = require("agentictab.agent.dwell")
local events = require("agentictab.events")
local expand = require("agentictab.agent.expand")
local merge = require("agentictab.agent.merge")
local prompt = require("agentictab.agent.prompt")
local proposal = require("agentictab.agent.proposal")
local review = require("agentictab.agent.review")
local status = require("agentictab.status")
local sync = require("agentictab.agent.sync")
local ui = require("agentictab.ui")
local S = require("agentictab.agent.state")

---@class AgentModule
local agent = {}

local SYSTEM_PROMPT = table.concat({
	"You are the backend of a Neovim plugin whose UI is arrows and inline diff proposals.",
	"Every user message is tagged with a mode. Obey the mode strictly:",
	"",
	"[do] Make the requested code change.",
	"- Make code changes directly with your edit and write tools.",
	"- NEVER modify, create, or delete files via bash (no sed -i, no redirection, no patch, no rm).",
	"  Bash is strictly for reading, searching, building, and running tests.",
	"- Never create git commits.",
	"- Keep changes minimal and tightly focused on the request; match the existing code style.",
	"- The request is anchored to the user's cursor: words like 'here', 'this', 'above', 'below',",
	"  'this function' refer to the cursor position given in the editor context (the line marked",
	"  with '>'). Make the change at that location unless the request clearly says otherwise.",
	"- Your edits go straight to the files and stay there. When the user asks for a revision,",
	"  the files may contain your previous attempt, the user's own edits, or a mix — always",
	"  read the current file state first and revise in place; never assume your last version.",
	"- End your reply with at most one short sentence. No summaries, no explanations.",
	"",
	"[bash] Run a shell task.",
	"- Use your bash tool to run the appropriate command(s): read, search, build, test only.",
	"- NEVER modify, create, or delete project files, in bash mode do not use edit/write at all.",
	"- Reply with the command you ran and the salient output, trimmed to what matters.",
	"  The reply renders as plain ghost text in the editor: no markdown, no fences.",
	"",
	"[ask] Answer a question about the code.",
	"- Read and search with your tools as needed; NEVER edit, create, or delete files.",
	"- Reply concisely in plain text (it renders as ghost text): name files and line numbers.",
	"",
	"In every mode: do not ask clarifying questions; make the most reasonable assumption and",
	"proceed.",
	"",
	"Examples:",
	"",
	'User: "[do @ src/client.go:41] add a retry with backoff here"',
	"You: read src/client.go, use your edit tool to wrap the call at line 41 in a retry loop,",
	'and reply: "added exponential backoff, 3 attempts."',
	"",
	'User: "[bash @ auth/token.go:12] run this package\'s tests"',
	"You: run `go test ./auth/...` with your bash tool and reply:",
	'"go test ./auth/...\\nok  auth  0.41s (12 tests)" — or the failing test output if it fails.',
	"",
	'User: "[ask @ db/session.go:88] what writes to the session table besides this"',
	"You: grep for the table name, read the call sites, and reply:",
	'"session.Write in auth/login.go:88 and the backfill in db/seed.go:14."',
	"",
	'User: "[do @ lua/util.lua:7] TODO on this line says validate the config table, do it"',
	"You: edit util.lua to add the validation where the TODO sits, remove the TODO comment,",
	'and reply: "validated required keys with clear errors."',
}, "\n")

local log = S.log

---Start the next queued launch once the agent is fully idle (no active run and
---no proposal left to walk). Called whenever a run/proposal finishes.
function agent._dequeue()
	if #S.queue == 0 or S.busy() then
		return
	end
	local nxt = table.remove(S.queue, 1)
	status.queued(#S.queue)
	agent._start_run(nxt.text, false, nxt)
end

-- Pi session --------------------------------------------------------------------

local function extension_path()
	local source = debug.getinfo(1, "S").source:sub(2)
	local plugin_root = vim.fs.normalize(vim.fs.dirname(source) .. "/../../..")
	return plugin_root .. "/pi-ext/backup.ts"
end

local on_event -- forward declaration

---@param root string the real project root (session identity)
---@param cwd string|nil where the pi process runs (defaults to root)
local function session_ensure(root, cwd)
	cwd = cwd or root
	if S.client:is_running() and S.session_root == root then
		return true
	end
	S.client:stop()
	local pi_cfg = config.get().pi
	local cmd = { pi_cfg.cmd, "--mode", "rpc", "--no-session", "-e", extension_path() }
	if pi_cfg.provider then
		vim.list_extend(cmd, { "--provider", pi_cfg.provider })
	end
	if pi_cfg.model then
		vim.list_extend(cmd, { "--model", pi_cfg.model })
	end
	if pi_cfg.thinking then
		vim.list_extend(cmd, { "--thinking", pi_cfg.thinking })
	end
	vim.list_extend(cmd, pi_cfg.extra_args)
	vim.list_extend(cmd, { "--append-system-prompt", SYSTEM_PROMPT })

	local ok, err = S.client:start({
		cmd = cmd,
		cwd = cwd,
		env = {
			AGENTICTAB_BACKUP_DIR = S.backup_dir,
			AGENTICTAB_BASH_APPROVAL = config.get().bash.approval ~= "off" and "1" or "0",
		},
		on_event = vim.schedule_wrap(function(ev)
			on_event(ev)
		end),
		on_exit = function()
			vim.schedule(function()
				S.session_root = nil
				if S.run_active then
					S.run_active = false
					status.flash("pi process exited — its edits so far are on disk")
				end
			end)
		end,
	})
	if not ok then
		vim.notify("[agentictab] " .. (err or "failed to start pi"), vim.log.levels.ERROR)
		return false
	end
	S.session_root = root
	log("=== session started in " .. root .. " ===")

	-- Resolve the actual model for display (bar title, log)
	S.agent_label = vim.fn.fnamemodify(pi_cfg.cmd, ":t")
	if pi_cfg.model then
		S.agent_label = S.agent_label .. " · " .. pi_cfg.model
	end
	S.client:send({ type = "get_state" }, function(resp)
		local model = resp.data and resp.data.model
		if model and model.id then
			S.agent_label = vim.fn.fnamemodify(pi_cfg.cmd, ":t") .. " · " .. model.id
		end
	end)
	return true
end

-- Touched files -------------------------------------------------------------------

---Read the extension's manifest: which files the agent edited this run,
---their current (agent) content on disk, and the pre-edit snapshot that
---serves as the merge base. Nothing is restored — the agent's edits stay.
---@return {path: string, existed: boolean, new_lines: string[]|nil, base_lines: string[]|nil}[]
function agent._touched_entries()
	local entries = {}
	local metas = vim.fn.glob(S.backup_dir .. "/*.json", true, true)
	for _, meta_file in ipairs(metas) do
		local ok, meta = pcall(function()
			return vim.json.decode(table.concat(vim.fn.readfile(meta_file), "\n"))
		end)
		if ok and type(meta) == "table" and meta.path then
			local entry = { path = meta.path, existed = meta.existed == true, new_lines = nil, base_lines = nil }
			if vim.fn.filereadable(meta.path) == 1 then
				local ok_read, lines = pcall(vim.fn.readfile, meta.path)
				if ok_read then
					entry.new_lines = lines
				end
			end
			local orig = meta_file:gsub("%.json$", ".orig")
			if vim.fn.filereadable(orig) == 1 then
				local ok_base, base = pcall(vim.fn.readfile, orig)
				if ok_base then
					entry.base_lines = base
				end
			end
			table.insert(entries, entry)
		end
	end
	return entries
end

-- Handlers wired into events.lua ----------------------------------------------

-- Accept/skip run from an expr mapping where text and window changes are
-- forbidden (textlock), so the actual work is deferred to the main loop.
local function on_accept()
	vim.schedule(agent._do_accept)
end

function agent._do_accept()
	if S.pending_bash then
		events.reset_completing()
		bash.answer(true)
		return
	end
	proposal.accept()
end

local function on_skip()
	vim.schedule(agent._do_skip)
end

function agent._do_skip()
	proposal.skip()
end

local function on_reject(reason)
	if S.navigating or S.bar_opening or prompt.is_open() or prompt.just_closed() then
		return
	end
	if S.pending_bash then
		bash.answer(false)
		return
	end
	-- Result and dwell arrows only fall to a real Esc press; movement and
	-- mode changes leave them alone (results persist until dismissed).
	if reason == "esc" and arrows.dismiss() then
		return
	end
	if not S.proposal then
		return
	end
	-- 2s grace after the first hunk appears: swallow Esc so you can't
	-- accidentally dismiss (or cancel) a proposal the instant it shows up.
	if S.proposal.first_shown and (vim.uv.now() - S.proposal.first_shown) < 2000 then
		status.flash("hold — Esc again in a moment")
		return
	end
	if S.run_active then
		-- Esc during a streaming run cancels the whole thing.
		S.discard_result = true
		S.client:send({ type = "abort" })
		S.proposal = nil
		proposal.clear_display()
		status.flash("cancelling run…")
	else
		proposal.discard("dismissed")
	end
end

local function on_editor_event(name)
	if not S.proposal or S.navigating or S.bar_opening or prompt.is_open() then
		return
	end
	if name == "text_changed" then
		if not S.display then
			return -- nothing rendered; recompute happens on next present
		end
		if
			S.display.path == vim.api.nvim_buf_get_name(0)
			and vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), S.display.snapshot)
		then
			-- Spurious (e.g. checktime reload): content identical
			proposal.schedule_present()
		elseif S.run_active then
			-- User typed during streaming: hold presentations until agent_end
			S.proposal.muted = true
			proposal.clear_display()
			status.running()
		else
			-- User edited mid-walk: re-merge their buffer against the agent's
			-- content instead of discarding the proposal.
			proposal.remerge()
		end
	elseif name == "cursor_moved" or name == "insert_leave" or name == "scrolled" or name == "cmdline" then
		if not S.display then
			return
		end
		-- Visuals persist through movement; only re-render when they were
		-- actually cleared (scroll/cmdline) or a jump target scrolled into
		-- view and can upgrade to the inline diff.
		if not (ui.has_completion() or ui.has_cursor_prediction()) then
			proposal.schedule_present()
		elseif S.display.mode == "jump" then
			local target = diffview.hunk_buffer_line(S.display.hunk, 0)
			target = math.max(1, math.min(target, vim.api.nvim_buf_line_count(0)))
			if target >= vim.fn.line("w0") and target <= vim.fn.line("w$") then
				proposal.schedule_present()
			end
		end
	end
end

---Tab pressed in normal mode with nothing visible: bash approval first, then
---a live proposal whose visuals were cleared (movement races, render
---failures — Tab must never dead-end while the hint says "Tab to accept"),
---then the arrow on this line, then a jump to the nearest arrow.
---@return boolean handled
local function on_tab_fallback()
	if S.pending_bash then
		vim.schedule(function()
			bash.answer(true)
		end)
		return true
	end
	if S.proposal then
		if S.display then
			vim.schedule(agent._do_accept)
		else
			proposal.schedule_present()
		end
		return true
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]

	local a = arrows.at_line(bufnr, lnum)
	if a and a.source ~= "result" and not a.status then
		vim.schedule(function()
			arrows.dispatch(a)
		end)
		return true
	end

	local near = arrows.nearest(bufnr, lnum)
	if near then
		local target = arrows.lnum(near)
		vim.schedule(function()
			pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
		end)
		return true
	end
	return false
end

-- Run lifecycle ---------------------------------------------------------------

local TOOL_VERBS = {
	read = "reading",
	edit = "editing",
	write = "writing",
	bash = "running",
	grep = "searching",
	find = "searching",
	ls = "listing",
}

---tool_execution_end carries no args; remember them from _start by call id.
---@type table<string, {name: string, path: string|nil}>
local tool_calls = {}

on_event = function(ev)
	if ev.type == "agent_start" then
		log("── run started ──")
		tool_calls = {}
	elseif ev.type == "tool_execution_start" then
		if ev.toolCallId then
			tool_calls[ev.toolCallId] = { name = ev.toolName, path = ev.args and ev.args.path or nil }
		end
		local arg = ""
		if ev.args then
			arg = ev.args.path or ev.args.command or ev.args.pattern or ""
			arg = tostring(arg):gsub("\n.*", "")
		end
		local short = arg ~= "" and vim.fn.fnamemodify(arg, ":t") or ""
		if ev.toolName == "bash" then
			short = arg:sub(1, 30)
		end
		status.set_detail((TOOL_VERBS[ev.toolName] or ev.toolName) .. (short ~= "" and (" " .. short) or ""))
		log("→ " .. ev.toolName .. "(" .. arg:sub(1, 80) .. ")")
	elseif ev.type == "tool_execution_end" then
		local call = ev.toolCallId and tool_calls[ev.toolCallId] or nil
		if ev.toolCallId then
			tool_calls[ev.toolCallId] = nil
		end
		if ev.isError then
			log("  ✗ tool error")
		elseif (ev.toolName == "edit" or ev.toolName == "write") and call and call.path then
			-- Start reconciling this file right away (merge-on-save/reload),
			-- seeding the base from the extension's pre-edit snapshot.
			local abs = vim.fs.normalize(call.path)
			if abs:sub(1, 1) ~= "/" then
				abs = vim.fs.normalize((S.run and S.run.root or vim.fn.getcwd()) .. "/" .. call.path)
			end
			local orig = S.backup_dir .. "/" .. S.backup_key(abs) .. ".orig"
			local base = vim.fn.filereadable(orig) == 1 and vim.fn.readfile(orig) or nil
			sync.track(abs, base)
			-- Only do: runs stream proposals; ask/bash runs must not edit.
			if S.run and S.run.mode == "do" then
				proposal.on_agent_edit(call.path)
			end
		end
	elseif ev.type == "message_end" then
		local msg = ev.message
		if msg and msg.role == "assistant" and type(msg.content) == "table" then
			for _, part in ipairs(msg.content) do
				if part.type == "text" and part.text and part.text ~= "" then
					log(part.text)
				end
			end
		end
	elseif ev.type == "auto_retry_start" then
		status.set_detail("retrying")
	elseif ev.type == "extension_ui_request" then
		if ev.method == "confirm" and ev.title == "agentictab-bash" then
			bash.on_request(ev)
		elseif ev.method == "notify" then
			vim.notify("[pi] " .. (ev.message or ""), vim.log.levels.INFO)
		elseif ev.id and (ev.method == "confirm" or ev.method == "select" or ev.method == "input" or ev.method == "editor") then
			-- Unknown dialog from some other extension: don't hang the run
			S.client:send({ type = "extension_ui_response", id = ev.id, cancelled = true })
		end
	elseif ev.type == "agent_end" then
		agent._on_run_complete()
	end
end

---Finish an ask:/bash: run: no proposal walk, the final assistant text
---becomes a coloured result arrow at the request's origin line.
---@param run table the completed S.run
local function finish_result_run(run)
	S.proposal = nil -- stray edits in ask/bash mode are discarded, not proposed
	proposal.clear_display()
	arrows.remove(run.arrow_id)
	S.client:send({ type = "get_last_assistant_text" }, function(resp)
		local text = resp.data and resp.data.text
		vim.schedule(function()
			if text and text ~= "" then
				local buf = run.origin and vim.api.nvim_buf_is_valid(run.origin.buf) and run.origin.buf or nil
				arrows.result({
					kind = run.mode,
					buf = buf,
					lnum = buf and run.origin.lnum or nil,
					text = text,
				})
				status.flash(run.mode == "bash" and "bash result ready" or "answered")
			else
				status.flash("no reply")
			end
			agent._dequeue()
		end)
	end)
end

function agent._on_run_complete()
	if not S.run_active then
		return
	end
	S.run_active = false
	log("── run finished ──")
	if S.saved_autoread ~= nil then
		vim.o.autoread = S.saved_autoread
		S.saved_autoread = nil
	end

	proposal.clear_display()
	local entries = agent._touched_entries()

	-- Whatever happens next, every touched file with a buffer starts being
	-- reconciled: saves merge, reloads merge (sync.lua). The pre-edit
	-- snapshot seeds the merge base.
	for _, entry in ipairs(entries) do
		sync.track(entry.path, entry.base_lines or (entry.existed and nil or { "" }))
	end

	if S.discard_result then
		S.discard_result = false
		S.proposal = nil
		proposal.clear_display()
		if S.run then
			arrows.remove(S.run.arrow_id)
		end
		arrows.show()
		status.flash("run cancelled — edits made so far remain on disk")
		vim.schedule(agent._dequeue)
		return
	end

	if S.run and S.run.mode ~= "do" then
		arrows.show()
		finish_result_run(S.run)
		return
	end

	if S.run then
		arrows.remove(S.run.arrow_id)
	end

	-- Build the walk from the touched files that have a loaded buffer: the
	-- walk target is the 3-way merge of base (pre-edit snapshot) vs the
	-- user's buffer vs the agent's disk content, so user changes survive and
	-- overlaps present as conflict-marker hunks. Files without a buffer
	-- changed on disk directly — nothing to walk, just say so.
	local run = S.run
	local silent = 0
	for _, entry in ipairs(entries) do
		if entry.new_lines then
			local bufnr = vim.fn.bufnr(entry.path)
			if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
				local base = sync.base(bufnr) or entry.base_lines or { "" }
				local ours = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				local merged = merge.three_way(base, ours, entry.new_lines)
				proposal.merge_file(entry.path, merged, { agent_lines = entry.new_lines, base_lines = base })
			else
				silent = silent + 1
				log("changed on disk: " .. entry.path)
			end
		end
	end
	if silent > 0 then
		vim.notify(string.format("[agentictab] %d file%s changed on disk (not open)", silent, silent == 1 and "" or "s"), vim.log.levels.INFO)
	end
	agent._begin_walk(run)
end

---Start (or finish) the hunk walk once every merge has landed.
---@param run table|nil the completed run
function agent._begin_walk(run)
	if not S.proposal then
		arrows.show()
		status.flash("no changes proposed")
		S.client:send({ type = "get_last_assistant_text" }, function(resp)
			local text = resp.data and resp.data.text
			if text and text ~= "" then
				vim.schedule(function()
					if #text > 700 then
						text = text:sub(1, 700) .. "…"
					end
					local buf = run and run.origin and vim.api.nvim_buf_is_valid(run.origin.buf) and run.origin.buf or nil
					arrows.result({ kind = "ask", buf = buf, lnum = buf and run.origin.lnum or nil, text = text })
				end)
			end
		end)
		vim.schedule(agent._dequeue)
		return
	end

	-- Request file first, others sorted
	local request_path = run and run.path or ""
	table.sort(S.proposal.order, function(a, b)
		if (a == request_path) ~= (b == request_path) then
			return a == request_path
		end
		return a < b
	end)
	S.proposal.muted = false

	local left = proposal.total_pending()
	if left == 0 then
		proposal.finish_walk()
		return
	end
	local nfiles = 0
	for _, path in ipairs(S.proposal.order) do
		if #proposal.pending_hunks(S.proposal.files[path]) > 0 then
			nfiles = nfiles + 1
		end
	end
	if nfiles > 1 then
		vim.notify(string.format("[agentictab] %d hunks across %d files", left, nfiles), vim.log.levels.INFO)
	end
	if prompt.is_open() then
		-- User is typing a steer that arrived too late; presenting happens
		-- when the bar closes, and its submit becomes a revision.
		status.persistent(proposal.walk_hint())
		return
	end
	proposal.present()
end

---Unwind a run that never reached the agent (session/prompt failure).
---@param msg string|nil
local function abandon_run(msg)
	S.run_active = false
	S.discard_result = false
	if S.saved_autoread ~= nil then
		vim.o.autoread = S.saved_autoread
		S.saved_autoread = nil
	end
	if S.run then
		arrows.remove(S.run.arrow_id)
	end
	arrows.show()
	status.hide()
	if msg then
		status.flash(msg)
	end
	vim.schedule(agent._dequeue)
end

---Compose and send the initial (or revision) prompt for a run. The agent
---works directly on the repo; the bundled pi extension snapshots each file
---before its first edit, and those snapshots become the merge bases when the
---run ends.
---@param text string user instruction
---@param revision boolean whether a previous proposal was just rejected
---@param opts {mode: string|nil, source: string|nil, buf: integer|nil, lnum: integer|nil, arrow_id: integer|nil}|nil
function agent._start_run(text, revision, opts)
	opts = opts or {}
	local mode = opts.mode or "do"
	local ctx = context.gather()

	-- do: edits and bash: builds/tests read the real files — save buffers so
	-- the disk matches what the user sees. ask: is read-only; the cursor area
	-- travels in the context block.
	if mode ~= "ask" then
		vim.cmd("silent! wall")
	end
	if not session_ensure(ctx.root, ctx.root) then
		return
	end
	S.clear_backup_dir()

	S.run = {
		path = vim.api.nvim_buf_get_name(ctx.bufnr),
		root = ctx.root,
		source = opts.source,
		mode = mode,
		origin = { buf = opts.buf or ctx.bufnr, lnum = opts.lnum or ctx.lnum },
		arrow_id = opts.arrow_id,
	}
	S.discard_result = false
	S.run_active = true
	S.proposal = nil
	proposal.clear_display()
	arrows.hide()
	if opts.arrow_id then
		arrows.update(opts.arrow_id, { status = "running" })
	end
	S.saved_autoread = vim.o.autoread
	vim.o.autoread = false
	status.running()

	local parts = {}
	if revision then
		table.insert(
			parts,
			"The user reviewed your edits and wants changes. The files may still contain your previous attempt (possibly mixed with the user's own edits) — read their current state and revise in place with this feedback:"
		)
	end
	table.insert(parts, string.format("[%s @ %s:%d] %s", mode, ctx.relpath, ctx.lnum, text))
	table.insert(parts, "")
	table.insert(parts, "--- editor context (auto-attached) ---")
	table.insert(parts, ctx.block)

	log("")
	log("USER (" .. mode .. "): " .. text)

	S.client:send({ type = "prompt", message = table.concat(parts, "\n") }, function(resp)
		if not resp.success then
			vim.schedule(function()
				vim.notify("[agentictab] prompt rejected: " .. (resp.error or "unknown"), vim.log.levels.ERROR)
				abandon_run(nil)
			end)
		end
	end)
end

---Route bar-submitted text by the state at submit time: a steer typed while
---the run was still going may land after it finished, in which case it
---becomes a revision (or a fresh do: request).
local function steer_or_revise(text)
	if S.run_active then
		log("USER (steer): " .. text)
		S.client:send({ type = "steer", message = text })
		status.set_detail("steered")
	elseif S.proposal then
		S.proposal = nil
		proposal.clear_display()
		agent._start_run(text, true, { mode = "do" })
	else
		agent.launch(text, { mode = "do", source = "user" })
	end
end

-- Public API -------------------------------------------------------------------

---@type table<string, string> the Alt+. mode chooser keys
local MODE_KEYS = { a = "ask", b = "bash", d = "do" }

local chooser_ns = vim.api.nvim_create_namespace("agentictab_chooser")

---Blocking mode chooser rendered at the cursor, styled like the <leader>tt
---picker: a/b/d as highlighted label chips, each mode word in its colour
---group. Returns the chosen mode or nil.
---@return string|nil
local function choose_mode()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		-- No real line to anchor to (help, quickfix, …): fall back to the badge.
		status.persistent("⇥ a ask · b bash · d do · Esc cancel")
		vim.cmd("redraw")
		local ok, ch = pcall(vim.fn.getcharstr)
		status.hide()
		return ok and MODE_KEYS[ch] or nil
	end
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local mark = vim.api.nvim_buf_set_extmark(buf, chooser_ns, row - 1, 0, {
		virt_text = {
			{ " ⇥ ", "AgenticTabArrow" },
			{ "a", "AgenticTabPickerLabel" },
			{ " ask", "AgenticTabArrowAsk" },
			{ " · ", "AgenticTabHint" },
			{ "b", "AgenticTabPickerLabel" },
			{ " bash", "AgenticTabArrowBash" },
			{ " · ", "AgenticTabHint" },
			{ "d", "AgenticTabPickerLabel" },
			{ " do", "AgenticTabArrow" },
			{ " · Esc cancel", "AgenticTabHint" },
		},
		virt_text_pos = "eol",
		priority = 5001,
	})
	vim.cmd("redraw")
	local ok, ch = pcall(vim.fn.getcharstr)
	pcall(vim.api.nvim_buf_del_extmark, buf, chooser_ns, mark)
	vim.cmd("redraw")
	return ok and MODE_KEYS[ch] or nil
end

---Entry point for the request keymap (Alt+. by default). While a run or
---proposal is live the bar steers/revises it; otherwise a single keypress
---picks the mode — a ask: · b bash: · d do: — and the bar opens with that
---prefix.
function agent.request_key()
	if prompt.is_open() then
		return
	end
	-- opening the bar to steer while a bash approval is pending declines it
	if S.pending_bash then
		bash.answer(false)
	end

	S.bar_opening = true
	if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
		vim.cmd.stopinsert()
	end

	local function open_bar(prefix, on_submit)
		prompt.open({
			prefix = prefix,
			on_submit = on_submit,
			on_cancel = function()
				if S.proposal then
					proposal.schedule_present()
				end
			end,
		})
		vim.schedule(function()
			S.bar_opening = false
		end)
	end

	if S.run_active then
		open_bar("⇥ steer:", steer_or_revise)
		return
	elseif S.proposal then
		open_bar("⇥ revise:", steer_or_revise)
		return
	end

	-- Mode chooser: one blocking keypress, rendered at the cursor with the
	-- picker's label styling.
	local mode = choose_mode()
	if not mode then
		S.bar_opening = false
		return
	end
	open_bar("⇥ " .. mode .. ":", function(text)
		agent.launch(text, { mode = mode, source = "user" })
	end)
end

---Toggle the expand float: full text of whatever was truncated — a pending
---bash command, or the latest result arrow's body.
function agent.expand()
	if expand.is_open() then
		expand.close()
		return
	end
	if S.pending_bash then
		expand.open("bash", S.pending_bash.cmd, "sh")
		return
	end
	local text = arrows.last_result_text()
	if text then
		expand.open("result", text, "markdown")
	else
		status.flash("nothing to expand")
	end
end

---The pending bash command awaiting approval, if any (for the picker).
---@return string|nil
function agent.pending_bash()
	return S.pending_bash and S.pending_bash.cmd or nil
end

---Approve or deny the pending bash command.
---@param approved boolean
function agent.approve_bash(approved)
	bash.answer(approved)
end

---Launch a run in a mode: a typed bar request, a dispatched arrow. A user
---arrow marks the request at its origin line while it is queued/running.
---@param text string
---@param opts {mode: string|nil, source: string|nil, buf: integer|nil, lnum: integer|nil}|nil
function agent.launch(text, opts)
	opts = opts or {}
	opts.mode = opts.mode or "do"
	opts.buf = opts.buf or vim.api.nvim_get_current_buf()
	opts.lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]

	local pending = arrows.add({
		buf = opts.buf,
		lnum = opts.lnum,
		source = "user",
		kind = opts.mode,
		text = text,
		prompt = text,
		status = S.busy() and "queued" or "running",
	})
	opts.arrow_id = pending and pending.id or nil

	if S.busy() then
		-- serialize behind the active run; it drains when the agent goes idle
		S.queue[#S.queue + 1] = { text = text, mode = opts.mode, source = opts.source, buf = opts.buf, lnum = opts.lnum, arrow_id = opts.arrow_id }
		status.queued(#S.queue)
		status.flash(string.format("queued · (%d) waiting", #S.queue))
		return
	end
	agent._start_run(text, false, opts)
end

---Cancel a running agent (edits already made stay on disk; the sync layer
---reconciles them with your buffers on save/reload).
function agent.cancel()
	-- stop-all: drop everything queued behind the active run first
	local had_queue = #S.queue
	for _, q in ipairs(S.queue) do
		arrows.remove(q.arrow_id)
	end
	S.queue = {}
	status.queued(0)
	if S.pending_bash then
		bash.answer(false)
	end
	if S.run_active then
		S.discard_result = true
		S.client:send({ type = "abort" })
		status.set_detail("cancelling")
	elseif S.proposal then
		proposal.discard("dismissed")
	elseif had_queue > 0 then
		status.flash(string.format("cleared %d queued agent%s", had_queue, had_queue == 1 and "" or "s"))
	else
		status.flash("nothing to cancel")
	end
end

---Drop the conversation context (fresh session, same process).
function agent.reset_session()
	if S.run_active then
		agent.cancel()
	end
	if S.client:is_running() then
		S.client:send({ type = "new_session" })
	end
	log("=== session reset ===")
	status.flash("session reset")
end

---Open the transcript log in a scratch split.
function agent.show_log()
	require("agentictab.logview").toggle()
end

---@return string one of "idle" | "running" | "proposing"
function agent.state()
	if S.run_active then
		return "running"
	elseif S.proposal then
		return "proposing"
	end
	return "idle"
end

-- Test hooks: drive the visuals without a live run (see scripts/arrows-test).
agent._show_result = arrows.result
agent._show_bash_ghost = bash.ghost_show

---Wire handlers and safety autocmds. Called from setup().
function agent.setup()
	local pi_cfg = config.get().pi
	S.agent_label = vim.fn.fnamemodify(pi_cfg.cmd, ":t") .. (pi_cfg.model and (" · " .. pi_cfg.model) or "")

	events.handlers.accept = on_accept
	events.handlers.partial_accept = on_skip
	events.handlers.reject = on_reject
	events.handlers.event = on_editor_event
	events.handlers.tab_fallback = on_tab_fallback

	dwell.setup(S.busy)
	review.setup(S.busy)

	local group = vim.api.nvim_create_augroup("AgenticTabAgent", { clear = true })
	-- Result arrows intentionally persist — only the transient expand float is
	-- torn down on movement.
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "InsertEnter", "BufLeave" }, {
		group = group,
		callback = function()
			expand.close()
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			S.client:stop()
		end,
	})
end

return agent
