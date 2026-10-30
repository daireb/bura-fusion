--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	The graph objects that are evaluating, innermost last, so that an error out
	of one leaves none of them busy.

	Fusion 0.3 left an object whose evaluation errored busy for good, and every
	later change that reached it raised `infiniteLoop`. Rather than protecting
	every evaluation, the code that catches an error returns the objects
	deeper than itself to valid: the outermost evaluation, an eager pass, a
	processor, and any evaluation whose deeper ones did not return, as when
	user code caught the error.
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)

local evaluationStack = {}

--- Read and written by evaluate and propagate on hot paths.
evaluationStack.state = {
	-- How many objects are evaluating.
	depth = 0,
	-- How many eager passes are running; a pass catches its own errors.
	passes = 0
}

local stack: {Types.GraphObject} = {}
evaluationStack.stack = stack

--[[
	Returns every object evaluating deeper than `depth` to valid. Each keeps its
	old value and stays subscribed to what it used before and what it used this
	time (see `evaluate`), so it evaluates again when one of those changes, as a
	Computed whose processor errors does.
]]
function evaluationStack.unwind(
	depth: number
): ()
	local state = evaluationStack.state
	for index = state.depth, depth + 1, -1 do
		local object = stack[index]
		if object ~= nil then
			object.validity = "valid"
			stack[index] = nil
		end
	end
	state.depth = depth
end

--- Adds the stack an error was raised at, which rethrowing it loses, unless it
--- already carries one.
function evaluationStack.addTrace(
	err: unknown
): unknown
	if typeof(err) == "string" and string.find(err, "---- Stack trace ----", 1, true) == nil then
		return `{err} \n---- Stack trace ----\n{debug.traceback(nil, 2)}`
	end
	return err
end

return evaluationStack
