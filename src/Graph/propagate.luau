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

	An eager object that errors does not stop the rest of the pass; the first
	error is rethrown once the pass is done.

	https://fluff.blog/2024/04/16/monotonic-painting.html
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local evaluate = require(Package.Graph.evaluate)
local evaluationStack = require(Package.Graph.evaluationStack)

local state = evaluationStack.state
local addTrace = evaluationStack.addTrace

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

local function evaluateRest(): ()
	local pass = runningPass :: {Types.GraphObject}
	while runningIndex < #pass do
		runningIndex += 1
		evaluate(pass[runningIndex], false)
	end
end

-- Entered again after an error, rather than protecting each object, which
-- keeps one pcall per pass.
local function runPass(): (boolean, unknown)
	local depth = state.depth
	local failed = false
	local firstError: unknown = nil
	while true do
		local ok: boolean, err: unknown = xpcall(evaluateRest, addTrace)
		if ok then
			return failed, firstError
		end
		evaluationStack.unwind(depth)
		if not failed then
			failed, firstError = true, err
		end
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
				-- An edge from before the dependent's current evaluation is
				-- ignored, as if it were gone (see evaluate).
				elseif dependent.validity == "busy" and dependent.dependencySet[searchTarget] == dependent._generation then
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
	-- A change made from an observer's callback runs in the callback's own
	-- thread, so its error stops only that thread and the outer pass carries
	-- on.
	state.passes += 1
	local failed, firstError = runPass()
	state.passes -= 1
	runningPass, runningIndex = outerPass, outerIndex
	if failed then
		error(firstError, 0)
	end
end

return propagate