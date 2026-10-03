--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Prompts a graph object to re-evaluate its own value. If it meaningfully
	changes, then dependents will have to re-evaluate their own values in the
	future.

	https://fluff.blog/2024/04/16/monotonic-painting.html
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local evaluate = require(Package.Graph.evaluate)
local propagate = require(Package.Graph.propagate)

local function change(
	target: Types.GraphObject
): ()
	if target.validity == "busy" then
		return External.logError("infiniteLoop")
	end

	local meaningfullyChanged = evaluate(target, true)
	if not meaningfullyChanged then
		return
	end

	propagate({target})
end

return change