--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Invalidates everything downstream of graph objects that have just
	meaningfully changed, then evaluates the eager objects among them in order
	of creation. Takes ownership of the list it is given.

	Asked to join the pass that is running, it evaluates nothing itself: its
	eager objects take their place, in order of creation, among the ones that
	pass has yet to evaluate.

	https://fluff.blog/2024/04/16/monotonic-painting.html
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local evaluate = require(Package.Graph.evaluate)

-- How long should this function run before it's considered to be in an infinite
-- cycle and error out?
local TERMINATION_TIME = 1

-- The eager objects of the innermost pass that is running, and how many of
-- them it has evaluated so far.
local runningPass: {Types.GraphObject}? = nil
local runningIndex = 0

local function byCreation(
	a: Types.GraphObject,
	b: Types.GraphObject
): boolean
	return a.createdAt < b.createdAt
end

local function runPass(): ()
	local pass = runningPass :: {Types.GraphObject}
	while runningIndex < #pass do
		runningIndex += 1
		evaluate(pass[runningIndex], false)
	end
end

local function propagate(
	searchInNow: {Types.GraphObject},
	joinRunningPass: boolean?
): ()
	local searchInNext: {Types.GraphObject} = {}
	local invalidateList: {Types.GraphObject} = {}

	local terminateBy = os.clock() + TERMINATION_TIME * External.safetyTimerMultiplier
	repeat
		if os.clock() > terminateBy then
			return External.logError("infiniteLoop")
		end
		local done = true
		for _, searchTarget in searchInNow do
			for dependent in searchTarget.dependentSet do
				if dependent.validity == "valid" then
					done = false
					table.insert(invalidateList, dependent)
					table.insert(searchInNext, dependent)
				elseif dependent.validity == "busy" then
					return External.logError("infiniteLoop")
				end
			end
		end
		searchInNow, searchInNext = searchInNext, searchInNow
		table.clear(searchInNext)
	until done

	local eagerList: {Types.GraphObject} = {}

	for _, invalidateTarget in invalidateList do
		invalidateTarget.validity = "invalid"
		if invalidateTarget.timeliness == "eager" then
			table.insert(eagerList, invalidateTarget)
		end
	end
	-- If objects are not executed in order of creations, then dynamic graphs
	-- may experience 'glitches' where nested graph objects see intermediate
	-- values before being destroyed.
	-- https://fluff.blog/2024/07/14/glitches-in-dynamic-reactive-graphs.html
	local outerPass, outerIndex = runningPass, runningIndex
	if joinRunningPass and outerPass ~= nil then
		for index = outerIndex + 1, #outerPass do
			table.insert(eagerList, outerPass[index])
			outerPass[index] = nil
		end
		table.sort(eagerList, byCreation)
		table.move(eagerList, 1, #eagerList, outerIndex + 1, outerPass)
		return
	end
	table.sort(eagerList, byCreation)
	runningPass, runningIndex = eagerList, 0
	-- Restored even when an eager object errors, so that no later change joins
	-- a pass that has stopped.
	local ok: boolean, err: unknown = pcall(runPass)
	runningPass, runningIndex = outerPass, outerIndex
	if not ok then
		error(err, 0)
	end
end

return propagate