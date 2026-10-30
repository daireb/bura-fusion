--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Cleans up the tasks passed in as the arguments.
	A task can be any of the following:

	- an Instance - will be destroyed
	- an RBXScriptConnection - will be disconnected
	- a function - will be run
	- a table with a `Destroy` or `destroy` function - will be called
	- an array - `cleanup` will be called on each item
]]
local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
local scopePool = require(Package.Memory.scopePool)
local poisonScope = require(Package.Memory.poisonScope)
local parseError = require(Package.Logging.parseError)

-- A task that errors stays marked, as in Fusion 0.3: unmarking it would need a
-- pcall per task, which every cleanup would pay for.
local alreadyDestroying: {[Types.Task]: true} = {}

local doCleanup: (Types.Task) -> ()

-- Counts tasks taken out of scopes, so that a retry knows it got further.
local removed = 0

-- Each task leaves the scope before it runs, so after an error the loop picks
-- up with the next one.
local function cleanupTasks(
	task: {Types.Task}
): ()
	for index = #task, 1, -1 do
		local subtask = task[index]
		task[index] = nil
		removed += 1
		doCleanup(subtask)
	end
end

function doCleanup(
	task: Types.Task
): ()
	if alreadyDestroying[task] then
		return External.logError("destroyedTwice")
	end
	alreadyDestroying[task] = true

	-- case 1: Instance
	if typeof(task) == "Instance" then
		task:Destroy()

	-- case 2: RBXScriptConnection
	elseif typeof(task) == "RBXScriptConnection" then
		task:Disconnect()

	-- case 3: callback
	elseif typeof(task) == "function" then
		task()

	elseif typeof(task) == "table" then
		local task = (task :: any) :: {Destroy: (...unknown) -> (...unknown)?, destroy: (...unknown) -> (...unknown)?}

		-- case 4: destroy() function
		if typeof(task.destroy) == "function" then
			local task = (task :: any) :: {destroy: (...unknown) -> (...unknown)}
			task:destroy()

		-- case 5: Destroy() function
		elseif typeof(task.Destroy) == "function" then
			local task = (task :: any) :: {Destroy: (...unknown) -> (...unknown)}
			task:Destroy()

		-- case 6: table of tasks with an array part
		elseif task[1] ~= nil then
			local task = task :: {Types.Task}

			-- It is important to iterate backwards through the table, since
			-- objects are added in order of construction. A task that errors
			-- is logged and skipped, so that the rest of the scope is still
			-- cleaned up, as when a Computed or a For object discards a scope
			-- in the middle of a change. The loop is entered again after an
			-- error rather than protecting each task.
			while true do
				local before = removed
				local ok: boolean, err: unknown = xpcall(cleanupTasks, parseError, task)
				if ok then
					break
				end
				-- A task that could not be taken out of the scope, as from a
				-- frozen table, would fail the same way every time.
				if removed == before then
					alreadyDestroying[task] = nil
					error((err :: any).raw, 0)
				end
				External.logErrorNonFatal("cleanupTaskError", err :: any)
			end

			if External.isTimeCritical() then
				scopePool.giveIfEmpty(task)
			else
				poisonScope(task, "`doCleanup()` was previously called on this scope. Ensure you are not reusing scopes after cleanup.")
			end
		end
	end
	
	alreadyDestroying[task] = nil
end

return doCleanup