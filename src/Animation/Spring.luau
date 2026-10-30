--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	A specialised state object for following a goal state smoothly over time,
	using physics to shape the motion.

	https://elttob.uk/Fusion/0.3/api-reference/animation/types/spring/
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
-- Memory
local checkLifetime = require(Package.Memory.checkLifetime)
-- Graph
local depend = require(Package.Graph.depend)
local change = require(Package.Graph.change)
local evaluate = require(Package.Graph.evaluate)
-- State
local castToState = require(Package.State.castToState)
local peek = require(Package.State.peek)
-- Animation
local ExternalTime = require(Package.Animation.ExternalTime)
local Stopwatch = require(Package.Animation.Stopwatch)
local packType = require(Package.Animation.packType)
local unpackType = require(Package.Animation.unpackType)
local springCoefficients = require(Package.Animation.springCoefficients)
-- Utility
local nicknames = require(Package.Utility.nicknames)

local EPSILON = 0.00001

type Self<T> = Types.Spring<T> & {
	_activeDamping: number,
	_activeGoal: T,
	_activeLatestP: {number},
	_activeLatestV: {number},
	_activeNumSprings: number,
	_activeSpeed: number,
	_activeStartP: {number},
	_activeStartV: {number},
	_activeTargetP: {number},
	_activeType: string,
	_speed: Types.UsedAs<number>,
	_damping: Types.UsedAs<number>,
	_goal: Types.UsedAs<T>,
	_stopwatch: Stopwatch.Stopwatch,
	_wake: Wake?
}

local class = {}
class.type = "State"
class.kind = "Spring"
class.timeliness = "eager"

local METATABLE = table.freeze {__index = class}

type Wake = Types.GraphObject & {
	arm: (Wake) -> (),
	_arming: boolean,
	_goal: Types.StateObject<unknown>,
	_stopwatch: Stopwatch.Stopwatch
}

--[[
	Wakes a sleeping spring's stopwatch when its goal changes.

	The spring itself never depends on its goal, as in Fusion 0.3. Like a
	playing spring, a woken one picks up its goal on its next step, after
	integrating the last frame's motion. A spring whose goal moves every frame,
	such as another animation, would otherwise restart its stopwatch before it
	ticked and stand still; and a goal set from downstream of the spring, such
	as by an observer of it, would form a cycle.

	The wake depends on the goal only from when the spring sleeps until the
	goal next changes, so a moving spring leaves a lazy goal lazy and adds
	nothing to a goal change.
]]
local wakeClass = {}
wakeClass.type = "Graph"
wakeClass.kind = "Spring.Wake"
wakeClass.timeliness = "eager"
-- Nothing may depend on the wake, so a goal change never reaches past it.
wakeClass.dependentSet = table.freeze {}

local WAKE_METATABLE = table.freeze {__index = wakeClass}

function wakeClass._evaluate(
	self: Wake
): boolean
	if self.scope == nil then
		return false
	end
	if self._arming then
		self._arming = false
		depend(self, self._goal)
	else
		-- The spring picks up the new goal on the step its timer next changes.
		self._stopwatch:unpause()
	end
	-- Also when arming: the wake then counts only goal changes after it.
	return true
end

--- Wakes the spring on the goal's next change. Called as the spring sleeps.
function wakeClass.arm(
	self: Wake
): ()
	if self.scope == nil then
		return
	end
	self._arming = true
	evaluate(self, true)
end

table.freeze(wakeClass)

local function Wake(
	scope: Types.Scope<unknown>,
	goal: Types.StateObject<unknown>,
	stopwatch: Stopwatch.Stopwatch
): Wake
	local self: Wake = setmetatable(
		{
			createdAt = os.clock(),
			dependencySet = {},
			lastChange = nil,
			scope = scope,
			validity = "invalid",
			_arming = false,
			_goal = goal,
			_stopwatch = stopwatch
		},
		WAKE_METATABLE
	) :: any
	local destroy = function()
		self.scope = nil
		for dependency in pairs(self.dependencySet) do
			dependency.dependentSet[self] = nil
		end
		table.clear(self.dependencySet)
	end
	self.oldestTask = destroy
	nicknames[self.oldestTask] = "Spring (internal wake)"
	table.insert(scope, destroy)
	evaluate(self, true)
	return self
end

local function Spring<T>(
	scope: Types.Scope<unknown>,
	goal: Types.UsedAs<T>,
	speed: Types.UsedAs<number>?,
	damping: Types.UsedAs<number>?
): Types.Spring<T>
	local createdAt = os.clock()
	if typeof(scope) ~= "table" or castToState(scope) ~= nil then
		External.logError("scopeMissing", nil, "Springs", "myScope:Spring(goalState, speed, damping)")
	end

	-- A constant goal gets a stopwatch too, so that the setters work on it as
	-- on a state goal; it settles on the goal on its first step and sleeps.
	local goalState = castToState(goal)
	local stopwatch = Stopwatch(scope, ExternalTime(scope))
	stopwatch:unpause()
	local wake = nil
	if goalState ~= nil then
		wake = Wake(scope, goalState, stopwatch)
	end

	local speed = speed or 10
	local damping = damping or 1

	local self: Self<T> = setmetatable(
		{
			createdAt = createdAt,
			dependencySet = {},
			dependentSet = {},
			lastChange = nil,
			scope = scope,
			validity = "invalid",
			_activeDamping = -1,
			_activeGoal = nil,
			_activeLatestP = {},
			_activeLatestV = {},
			_activeNumSprings = 0,
			_activeSpeed = -1,
			_activeStartP = {},
			_activeStartV = {},
			_activeTargetP = {},
			_activeType = "",
			_damping = damping,
			_EXTREMELY_DANGEROUS_usedAsValue = peek(goal),
			_goal = goal,
			_speed = speed,
			_stopwatch = stopwatch,
			_wake = wake
		},
		METATABLE
	) :: any
	local destroy = function()
		self.scope = nil
		for dependency in pairs(self.dependencySet) do
			dependency.dependentSet[self] = nil
		end
	end
	self.oldestTask = destroy
	nicknames[self.oldestTask] = "Spring"
	table.insert(scope, destroy)
	
	if goalState ~= nil then
		checkLifetime.bOutlivesA(
			scope, self.oldestTask,
			goalState.scope, goalState.oldestTask,
			checkLifetime.formatters.animationGoal
		)
	end
	local speedState = castToState(speed)
	if speedState ~= nil then
		checkLifetime.bOutlivesA(
			scope, self.oldestTask,
			speedState.scope, speedState.oldestTask,
			checkLifetime.formatters.parameter, "speed"
		)
	end
	local dampingState = castToState(damping)
	if dampingState ~= nil then
		checkLifetime.bOutlivesA(
			scope, self.oldestTask,
			dampingState.scope, dampingState.oldestTask,
			checkLifetime.formatters.parameter, "damping"
		)
	end

	-- Eagerly evaluated objects need to evaluate themselves so that they're
	-- valid at all times.
	evaluate(self, true)

	return self
end

function class.addVelocity<T>(
	self: Self<T>,
	deltaValue: T
): ()
	evaluate(self, false) -- ensure the _active params are up to date
	local deltaType = typeof(deltaValue)
	if deltaType ~= self._activeType then
		External.logError("springTypeMismatch", nil, deltaType, self._activeType)
	end
	local newStartV = unpackType(deltaValue, deltaType)
	for index, velocity in self._activeLatestV do
		newStartV[index] += velocity
	end
	self._activeStartP = table.clone(self._activeLatestP)
	self._activeStartV = newStartV
	-- Also the latest state, which a parameter change reconfigures from.
	self._activeLatestV = table.clone(newStartV)
	self._stopwatch:zero()
	self._stopwatch:unpause()
	change(self)
end

function class.get<T>(
	self: Self<T>
): never
	return External.logError("stateGetWasRemoved")
end

function class.setPosition<T>(
	self: Self<T>,
	newValue: T
): ()
	evaluate(self, false) -- ensure the _active params are up to date
	local newType = typeof(newValue)
	if newType ~= self._activeType then
		External.logError("springTypeMismatch", nil, newType, self._activeType)
	end
	self._activeStartP = unpackType(newValue, newType)
	self._activeStartV = table.clone(self._activeLatestV)
	-- Also the latest state, which a parameter change reconfigures from.
	self._activeLatestP = table.clone(self._activeStartP)
	self._stopwatch:zero()
	self._stopwatch:unpause()
	change(self)
end

function class.setVelocity<T>(
	self: Self<T>,
	newValue: T
): ()
	evaluate(self, false) -- ensure the _active params are up to date
	local newType = typeof(newValue)
	if newType ~= self._activeType then
		External.logError("springTypeMismatch", nil, newType, self._activeType)
	end
	self._activeStartP = table.clone(self._activeLatestP)
	self._activeStartV = unpackType(newValue, newType)
	-- Also the latest state, which a parameter change reconfigures from.
	self._activeLatestV = table.clone(self._activeStartV)
	self._stopwatch:zero()
	self._stopwatch:unpause()
	change(self)
end

function class._evaluate<T>(
	self: Self<T>
): boolean
	-- A destroyed animation can still be queued in the change that destroyed
	-- it. Evaluating it would subscribe it to its stopwatch again.
	if self.scope == nil then
		return false
	end
	local nextFrameGoal = peek(self._goal)
	-- Protect against NaN goals.
	if nextFrameGoal ~= nextFrameGoal then
		External.logWarn("springNanGoal")
		-- Sleep until the goal changes again, which wakes the stopwatch.
		self._stopwatch:pause()
		depend(self, self._stopwatch)
		-- A constant goal has no wake: only a setter moves it again.
		if self._wake ~= nil then
			self._wake:arm()
		end
		return false
	end
	local nextFrameGoalType = typeof(nextFrameGoal)
	local discontinuous = nextFrameGoalType ~= self._activeType

	local stopwatch = self._stopwatch
	local elapsed = peek(stopwatch)
	depend(self, stopwatch)
	local settled = false

	local oldValue = self._EXTREMELY_DANGEROUS_usedAsValue
	local newValue: T

	if discontinuous then
		-- Propagate changes in type instantly throughout the whole reactive
		-- graph, even if simulation is logically one frame behind, because it
		-- makes the whole graph behave more consistently.
		newValue = nextFrameGoal
	elseif elapsed <= 0 then
		newValue = oldValue
	else
		-- Calculate spring motion.
		-- IMPORTANT: use the parameters from last frame, not this frame. We're
		-- integrating the motion that happened over the last frame, after all.
		-- The stopwatch will have captured the length of time needed correctly.
		local posPos, posVel, velPos, velVel = springCoefficients(
			elapsed, 
			self._activeDamping, 
			self._activeSpeed
		)
		local isMoving = false
		for index = 1, self._activeNumSprings do
			local startP = self._activeStartP[index]
			local targetP = self._activeTargetP[index]
			local startV = self._activeStartV[index]
			local startD = startP - targetP
			local latestD = startD * posPos + startV * posVel
			local latestV = startD * velPos + startV * velVel
			if latestD ~= latestD or latestV ~= latestV then
				External.logWarn("springNanMotion")
				latestD, latestV = 0, 0
			end
			if math.abs(latestD) > EPSILON or math.abs(latestV) > EPSILON then
				isMoving = true
			end
			local latestP = latestD + targetP
			self._activeLatestP[index] = latestP
			self._activeLatestV[index] = latestV
		end
		-- Sleep and snap to goal if the motion has decayed to a negligible amount.
		if not isMoving then
			for index = 1, self._activeNumSprings do
				self._activeLatestP[index] = self._activeTargetP[index]
			end
			settled = true
		end
		-- Pack springs into final value.
		newValue = packType(self._activeLatestP, self._activeType) :: any
	end

	-- Reconfigure spring when any of its parameters are changed.
	-- This should happen after integrating the last frame's motion.
	-- NOTE: don't need to add a dependency on these objects! they do not cause
	-- a spring to wake from sleep, so the stopwatch dependency is sufficient.
	local nextFrameSpeed = peek(self._speed) :: number
	local nextFrameDamping = peek(self._damping) :: number
	if
		discontinuous or
		nextFrameGoal ~= self._activeGoal or
		nextFrameSpeed ~= self._activeSpeed or
		nextFrameDamping ~= self._activeDamping
	then
		self._activeTargetP = unpackType(nextFrameGoal, nextFrameGoalType)
		self._activeNumSprings = #self._activeTargetP
		if discontinuous then
			self._activeStartP = table.clone(self._activeTargetP)
			self._activeLatestP = table.clone(self._activeTargetP)
			self._activeStartV = table.create(self._activeNumSprings, 0)
			self._activeLatestV = table.create(self._activeNumSprings, 0)
		else
			self._activeStartP = table.clone(self._activeLatestP)
			self._activeStartV = table.clone(self._activeLatestV)
		end
		self._activeType = nextFrameGoalType
		self._activeGoal = nextFrameGoal
		self._activeDamping = nextFrameDamping
		self._activeSpeed = nextFrameSpeed
		stopwatch:zero()
		stopwatch:unpause()
	elseif settled then
		-- Sleep at rest on the goal: with its stopwatch stopped, the update
		-- step no longer changes this spring, and the step that wakes it
		-- integrates from rest rather than from the motion it settled from.
		self._activeStartP = table.clone(self._activeLatestP)
		self._activeStartV = table.create(self._activeNumSprings, 0)
		stopwatch:pause()
		stopwatch:zero()
		-- A constant goal has no wake: only a setter moves it again.
		if self._wake ~= nil then
			self._wake:arm()
		end
	end

	-- Push update and check for similarity.
	-- Don't need to use the similarity test here because this code doesn't
	-- deal with tables, and NaN is already guarded against, so the similarity
	-- test doesn't actually add any new safety here.
	self._EXTREMELY_DANGEROUS_usedAsValue = newValue
	return oldValue ~= newValue
end

table.freeze(class)
return Spring :: Types.SpringConstructor