--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Forms a dependency on a graph object.
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local evaluate = require(Package.Graph.evaluate)
local nameOf = require(Package.Utility.nameOf)

local function depend<T>(
	dependent: Types.GraphObject,
	dependency: Types.GraphObject
): ()
	if table.isfrozen(dependent.dependencySet) or table.isfrozen(dependency.dependentSet) then
		External.logError("cannotDepend", nil, nameOf(dependent, "Dependent"), nameOf(dependency, "dependency"))
	end
	-- Subscribed before the dependency is brought up to date, so that a
	-- dependent whose dependency errors still evaluates again when it changes.
	-- The mark is the dependent's current evaluation (see evaluate).
	dependency.dependentSet[dependent] = true
	dependent.dependencySet[dependency] = dependent._generation or true
	-- Ensure dependencies are evaluated and up-to-date
	-- when they are depended on. Also, newly created objects
	-- might not have any transitive dependencies captured yet,
	-- so ensure that they're present.
	evaluate(dependency, false)
end

return depend
