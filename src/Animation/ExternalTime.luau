--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Outputs the current external time as a state object.
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
-- Graph
local changeMany = require(Package.Graph.changeMany)
-- Utility
local nicknames = require(Package.Utility.nicknames)

export type ExternalTime = Types.StateObject<number> & {
	_wake: (ExternalTime) -> ()
}

type Self = ExternalTime

local class = {}
class.type = "State"
class.kind = "ExternalTime"
class.timeliness = "lazy"
class.dependencySet = table.freeze {}
class._EXTREMELY_DANGEROUS_usedAsValue = External.lastUpdateStep()

local METATABLE = table.freeze {__index = class}

-- Only timers that a playing stopwatch depends on are changed on each update
-- step, so a settled animation costs nothing per frame. A playing stopwatch
-- wakes its timer; the step drops a timer once nothing depends on it.
local activeTimers: {[Self]: true} = {}
-- The active timers, changed in order of creation. Entries that left
-- `activeTimers` are dropped by the next step.
local stepOrder: {Self} = {}
local stepOrderSorted = true

local function byCreation(
	a: Self,
	b: Self
): boolean
	return a.createdAt < b.createdAt
end

local function ExternalTime(
	scope: Types.Scope<unknown>
): ExternalTime
	local createdAt = os.clock()
	local self: Self = setmetatable(
		{
			createdAt = createdAt,
			dependentSet = {},
			lastChange = nil,
			scope = scope,
			validity = "invalid"
		}, 
		METATABLE
	) :: any
	local destroy = function()
		self.scope = nil
		activeTimers[self] = nil
	end
	self.oldestTask = destroy
	nicknames[self.oldestTask] = "ExternalTime"
	table.insert(scope, destroy)
	return self
end

--[[
	Changes this timer on every update step from now on, until nothing depends
	on it. A playing stopwatch calls this whenever it evaluates.
]]
function class._wake(
	self: Self
): ()
	if activeTimers[self] == nil and self.scope ~= nil then
		activeTimers[self] = true
		table.insert(stepOrder, self)
		stepOrderSorted = false
	end
end

function class._evaluate(
	self: Self
): boolean
	-- While someone else could call `change()` on this object, it wouldn't be
	-- idiomatic. So, since the only idiomatic time this function runs is when
	-- the external update step runs, it's safe enough to assume that the result
	-- has always meaningfully changed. The worst that can happen is unexpected
	-- refreshing for people doing unorthodox shenanigans, which is an OK trade.
	return true
end

-- Every active timer changes in one change, so every animation steps before
-- anything downstream of it runs, and an observer of several animations runs
-- once, with all of them stepped. Changing them can wake, drop or destroy
-- timers: one woken during the step is appended to `stepOrder` and first
-- changes on the next step, and one that left the set is skipped then.
External.bindToUpdateStep(function(
	externalNow: number
): ()
	class._EXTREMELY_DANGEROUS_usedAsValue = External.lastUpdateStep()
	if not stepOrderSorted then
		table.sort(stepOrder, byCreation)
		stepOrderSorted = true
	end
	local kept = 0
	for _, timer in stepOrder do
		if activeTimers[timer] == nil then
			continue
		elseif next(timer.dependentSet) == nil then
			activeTimers[timer] = nil
			continue
		end
		kept += 1
		stepOrder[kept] = timer
	end
	for index = kept + 1, #stepOrder do
		stepOrder[index] = nil
	end
	if kept > 0 then
		-- changeMany reads the list before anything can append to it.
		changeMany(stepOrder)
	end
end)

-- Do *not* freeze the class table, because it stores the shared value of all
-- external time objects, and is updated every frame because of that.
-- table.freeze(class)
return ExternalTime