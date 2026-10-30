--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local External = require(Fusion.External)

--- Collects the IDs of the messages logged through one External function
--- while the callback runs, and restores it even if the callback throws.
local function captureLogs(
	name: string,
	callback: () -> ()
): {string}
	local logged = {}
	local external = External :: any
	local original = external[name]
	external[name] = function(messageID)
		table.insert(logged, messageID)
	end
	local ok, err = pcall(callback)
	external[name] = original
	if not ok then
		error(err, 0)
	end
	return logged
end

return captureLogs
