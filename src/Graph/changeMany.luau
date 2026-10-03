--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Prompts several graph objects to re-evaluate their own values as one
	change. Every target is evaluated first, then their dependents are
	invalidated in one walk and the eager ones are evaluated in one pass, in
	order of creation. So no eager object sees some targets changed and others
	not, and eager objects keep their creation order across targets.

	The targets should be distinct, independent sources. A value must already
	hold its new value, and should differ from its old one as `Value:set`
	ensures, because evaluating a value always counts as a meaningful change.
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local evaluate = require(Package.Graph.evaluate)
local propagate = require(Package.Graph.propagate)

local function changeMany(
	targets: {Types.GraphObject}
): ()
	-- Check every target before evaluating any, so that an error leaves the
	-- graph as it was.
	for _, target in targets do
		if target.validity == "busy" then
			return External.logError("infiniteLoop")
		end
	end
	local changed: {Types.GraphObject} = {}
	for _, target in targets do
		if evaluate(target, true) then
			table.insert(changed, target)
		end
	end
	if changed[1] ~= nil then
		propagate(changed)
	end
end

return changeMany