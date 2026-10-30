--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Evaluates the graph object if necessary, so that it is up to date.
	Returns true if it meaningfully changed.

	An error out of `_evaluate`, or out of a dependency it checks, leaves no
	object busy (see `evaluationStack`). Only the outermost evaluation outside
	an eager pass, and the outermost one in each listener, pays for a pcall.

	https://fluff.blog/2024/04/16/monotonic-painting.html
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local evaluationStack = require(Package.Graph.evaluationStack)

local state = evaluationStack.state
local stack = evaluationStack.stack
local unwind = evaluationStack.unwind
local addTrace = evaluationStack.addTrace

local evaluate: (Types.GraphObject, boolean) -> boolean

local function compute(
	target: Types.GraphObject,
	forceComputation: boolean,
	firstEvaluation: boolean
): boolean
	local needsComputation = firstEvaluation or forceComputation
	if not needsComputation then
		for dependency in target.dependencySet do
			evaluate(dependency, false)
			if dependency.lastChange > target.lastChange then
				needsComputation = true
				break
			end
		end
	end
	local targetMeaningfullyChanged = false
	if needsComputation then
		-- What it used before stays subscribed while it evaluates, so that an
		-- error leaves it subscribed to that and to what it used this time.
		-- `depend` marks each edge with this generation; the walk ignores the
		-- unmarked ones, as if they were gone, and they are dropped once it
		-- succeeds.
		local generation = (target._generation or 0) + 1
		target._generation = generation
		target.validity = "busy"
		targetMeaningfullyChanged = target:_evaluate() or firstEvaluation
		local dependencySet = target.dependencySet
		for dependency, mark in dependencySet do
			if mark ~= generation then
				dependency.dependentSet[target] = nil
				dependencySet[dependency] = nil
			end
		end
	end
	if targetMeaningfullyChanged then
		target.lastChange = os.clock()
	end
	target.validity = "valid"
	return targetMeaningfullyChanged
end

function evaluate(
	target: Types.GraphObject,
	forceComputation: boolean
): boolean
	if target.validity == "busy" then
		return External.logError("infiniteLoop")
	end
	local firstEvaluation = target.lastChange == nil
	if not (firstEvaluation or forceComputation or target.validity == "invalid") then
		return false
	end
	-- A source, such as a Value or a timer, can depend on nothing, so its
	-- evaluation only counts the change: it cannot error, and needs no place
	-- on the stack. `Value:set` comes through here on every change.
	if table.isfrozen(target.dependencySet) then
		local changed = target:_evaluate() or firstEvaluation
		if changed then
			target.lastChange = os.clock()
		end
		target.validity = "valid"
		return changed
	end
	local depth = state.depth
	local index = depth + 1
	state.depth = index
	stack[index] = target
	local changed: boolean
	if depth == state.base and state.passes == 0 then
		local ok: boolean, result: unknown = xpcall(compute, addTrace, target, forceComputation, firstEvaluation)
		if not ok then
			-- Not on the stack any more if it yielded, and its observer took
			-- it off (see Observer).
			if stack[index] == target then
				unwind(depth)
			end
			error(result, 0)
		end
		changed = result :: boolean
	else
		changed = compute(target, forceComputation, firstEvaluation)
	end
	-- Only false if a processor yielded and resumed after the stack moved on;
	-- the depth is then left to whatever is evaluating now.
	if stack[index] == target then
		-- An error that something below this caught and did not unwind, such
		-- as user code's own pcall, leaves deeper objects behind.
		if state.depth ~= index then
			unwind(index)
		end
		stack[index] = nil
		state.depth = depth
	end
	return changed
end

return evaluate
