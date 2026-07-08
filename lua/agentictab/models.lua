-- Runtime model picker (<leader>tm).
--
-- Lists the models `pi --list-models` reports and applies the chosen
-- provider/model to config.get().pi IN MEMORY for the current session only.
-- The default configuration is never touched and nothing is written to disk,
-- so restarting Neovim reverts to whatever setup() configured.

local config = require("agentictab.config")

local M = {}

---Parse the `pi --list-models` table (columns: provider model context ...).
---@param out string
---@return {provider: string, model: string}[]
local function parse(out)
	local items = {}
	for line in out:gmatch("[^\n]+") do
		local provider, model = line:match("^(%S+)%s+(%S+)")
		-- skip the header row and any warning/blank noise
		if provider and model and provider ~= "provider" and model ~= "model" then
			items[#items + 1] = { provider = provider, model = model }
		end
	end
	return items
end

---Open a picker; the selection applies to this session only.
function M.pick()
	local pi = config.get().pi
	vim.system({ pi.cmd or "pi", "--list-models" }, { text = true }, function(res)
		vim.schedule(function()
			local out = res.stdout or ""
			if out == "" then
				vim.notify(
					"agentictab: `pi --list-models` produced no models" .. (res.stderr and (" — " .. res.stderr) or ""),
					vim.log.levels.ERROR
				)
				return
			end
			local items = parse(out)
			if #items == 0 then
				vim.notify("agentictab: no models reported by pi", vim.log.levels.WARN)
				return
			end
			local current = pi.model
			vim.ui.select(items, {
				prompt = "agentictab model (this session only)",
				format_item = function(it)
					local label = it.provider .. "/" .. it.model
					if it.model == current then
						label = label .. "  (current)"
					end
					return label
				end,
			}, function(choice)
				if not choice then
					return
				end
				-- mutate the live config table in place: session-only, never saved
				pi.provider = choice.provider
				pi.model = choice.model
				vim.notify(
					string.format("agentictab: model → %s/%s (this session)", choice.provider, choice.model),
					vim.log.levels.INFO
				)
			end)
		end)
	end)
end

return M
