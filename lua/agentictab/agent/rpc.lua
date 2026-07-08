-- JSONL RPC client for `pi --mode rpc`.
--
-- Instantiable: the plugin runs one long-lived pi process for the main agent
-- and lightweight ones for the dwell and review arrows. Commands go in as JSON
-- lines on stdin; events and command responses stream back on stdout.
-- Responses (type = "response") are correlated by `id` when the caller
-- supplies a callback; everything else is forwarded to `on_event`.

---@class RpcClient
---@field job_id integer|nil
local Rpc = {}
Rpc.__index = Rpc

---@class RpcModule
local M = {}

---Create a new (not yet started) client.
---@return RpcClient
function M.new()
	return setmetatable({
		job_id = nil,
		stdout_buf = "",
		next_id = 0,
		pending = {},
		on_event = nil,
		on_exit = nil,
	}, Rpc)
end

---@return boolean
function Rpc:is_running()
	return self.job_id ~= nil
end

function Rpc:_handle_line(line)
	if line == "" then
		return
	end
	if line:sub(-1) == "\r" then
		line = line:sub(1, -2)
	end
	local ok, msg = pcall(vim.json.decode, line)
	if not ok or type(msg) ~= "table" then
		return
	end
	if msg.type == "response" and msg.id and self.pending[msg.id] then
		local cb = self.pending[msg.id]
		self.pending[msg.id] = nil
		cb(msg)
		return
	end
	if self.on_event then
		self.on_event(msg)
	end
end

function Rpc:_handle_stdout(data)
	if not data then
		return
	end
	-- jobstart splits the stream on newlines: data[1] continues the previous
	-- chunk, the last element is the (possibly empty) start of the next line.
	data[1] = self.stdout_buf .. data[1]
	self.stdout_buf = table.remove(data)
	for _, line in ipairs(data) do
		self:_handle_line(line)
	end
end

---Start the pi process.
---@param opts {cmd: string[], cwd: string, env: table<string,string>|nil, on_event: fun(event: table), on_exit: fun(code: integer)|nil}
---@return boolean started
---@return string|nil err
function Rpc:start(opts)
	if self.job_id then
		return false, "already running"
	end
	self.stdout_buf = ""
	self.pending = {}
	self.on_event = opts.on_event
	self.on_exit = opts.on_exit

	local stderr_tail = {}
	local ok, id = pcall(vim.fn.jobstart, opts.cmd, {
		cwd = opts.cwd,
		env = opts.env,
		on_stdout = function(_, data)
			self:_handle_stdout(data)
		end,
		on_stderr = function(_, data)
			if data then
				for _, l in ipairs(data) do
					if l ~= "" then
						table.insert(stderr_tail, l)
						if #stderr_tail > 20 then
							table.remove(stderr_tail, 1)
						end
					end
				end
			end
		end,
		on_exit = function(_, code)
			self.job_id = nil
			self.pending = {}
			if code ~= 0 and #stderr_tail > 0 then
				vim.schedule(function()
					vim.notify("[agentictab] pi exited (" .. code .. "): " .. table.concat(stderr_tail, " | "), vim.log.levels.WARN)
				end)
			end
			if self.on_exit then
				self.on_exit(code)
			end
		end,
	})

	if not ok or id <= 0 then
		return false, "failed to spawn: " .. vim.inspect(opts.cmd[1])
	end
	self.job_id = id
	return true, nil
end

---Send a command. If `callback` is given, an `id` is attached and the callback
---fires with the matching response.
---@param cmd table
---@param callback fun(response: table)|nil
---@return boolean sent
function Rpc:send(cmd, callback)
	if not self.job_id then
		return false
	end
	if callback then
		self.next_id = self.next_id + 1
		local id = "ta-" .. self.next_id
		cmd = vim.tbl_extend("force", cmd, { id = id })
		self.pending[id] = callback
	end
	local ok, encoded = pcall(vim.json.encode, cmd)
	if not ok then
		return false
	end
	local sent = pcall(vim.fn.chansend, self.job_id, encoded .. "\n")
	return sent
end

---Stop the pi process.
function Rpc:stop()
	if self.job_id then
		local id = self.job_id
		self.job_id = nil
		self.pending = {}
		pcall(vim.fn.jobstop, id)
	end
end

return M
