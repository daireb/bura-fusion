--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Prompts several graph objects to re-evaluate their own values as one
	change. Dependents of all of them are invalidated in a single walk and the
	eager ones are evaluated once, in creation order, so an object that reads
	two of the targets never sees one updated and the other not.

	The targets should be independent sources, such as values.
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local evaluate = require(Package.Graph.evaluate)
local propagate = require(Package.Graph.propagate)

local function changeMany(
	targets: {Types.GraphObject}
): ()
	local changed: {Types.GraphObject} = {}
	for _, target in targets do
		if target.validity == "busy" then
			return External.logError("infiniteLoop")
		end
		if evaluate(target, true) then
			table.insert(changed, target)
		end
	end
	if changed[1] ~= nil then
		propagate(changed)
	end
end

return changeMany