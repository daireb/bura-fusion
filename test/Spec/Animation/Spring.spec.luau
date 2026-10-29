--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local External = require(Fusion.External)
local Spring = require(Fusion.Animation.Spring)
local Tween = require(Fusion.Animation.Tween)
local Value = require(Fusion.State.Value)
local Computed = require(Fusion.State.Computed)
local Observer = require(Fusion.Graph.Observer)
local peek = require(Fusion.State.peek)
local doCleanup = require(Fusion.Memory.doCleanup)

local FRAME = 1 / 60

return function()
	local it = getfenv().it

	local now = 0
	local function step(frames: number?)
		for _ = 1, frames or 1 do
			now += FRAME
			External.performUpdateStep(now)
		end
	end

	-- The update step changes an animation's timer only while its stopwatch
	-- depends on it.
	local function isAsleep(animation: any): boolean
		return next(animation._stopwatch._timer.dependentSet) == nil
	end

	it("sleeps once settled and wakes when its goal changes", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 0)
		local spring = Spring(scope, goal, 30, 1)
		step(120)
		expect(isAsleep(spring)).to.equal(true)
		expect(peek(spring)).to.equal(0)

		goal:set(10)
		expect(isAsleep(spring)).to.equal(false)
		step()
		local first = peek(spring) :: number
		expect(first > 0 and first < 10).to.equal(true)
		step(240)
		expect(peek(spring)).to.equal(10)
		expect(isAsleep(spring)).to.equal(true)

		doCleanup(scope)
	end)

	it("wakes for a computed goal", function()
		local expect = getfenv().expect

		local scope = {}
		local base = Value(scope, 1)
		local spring = Spring(scope, Computed(scope, function(use)
			return use(base) * 2
		end), 30, 1)
		step(120)
		expect(isAsleep(spring)).to.equal(true)

		base:set(5)
		step(240)
		expect(peek(spring)).to.equal(10)

		doCleanup(scope)
	end)

	it("ignores a goal that changes and changes back before the next step", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 0)
		local spring = Spring(scope, goal, 20, 1)
		step(120)

		goal:set(7)
		goal:set(0)
		step(3)
		expect(peek(spring)).to.equal(0)

		doCleanup(scope)
	end)

	it("moves from a position or velocity set while asleep", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 1)
		local spring = Spring(scope, goal, 20, 0.5)
		step(240)
		expect(isAsleep(spring)).to.equal(true)

		spring:setPosition(4)
		step(2)
		local moved = peek(spring) :: number
		expect(moved > 1 and moved < 4).to.equal(true)
		step(480)
		expect(peek(spring)).to.equal(1)

		spring:addVelocity(25)
		step(2)
		expect((peek(spring) :: number) > 1).to.equal(true)
		step(480)
		expect(peek(spring)).to.equal(1)
		expect(isAsleep(spring)).to.equal(true)

		doCleanup(scope)
	end)

	it("follows a goal that is itself animating", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 0)
		local leader = Spring(scope, goal, 10, 1)
		local follower = Spring(scope, leader, 20, 1)
		local doubled = Spring(scope, Computed(scope, function(use)
			return (use(leader) :: number) * 2
		end), 20, 1)
		step(120)

		goal:set(10)
		step(20)
		-- Picking up a moving goal must not restart the follower's stopwatch
		-- before it ticks, which would hold it still until the leader settles.
		local leaderAt = peek(leader) :: number
		expect(leaderAt > 1 and leaderAt < 10).to.equal(true)
		expect((peek(follower) :: number) > 0.5).to.equal(true)
		expect((peek(doubled) :: number) > 1).to.equal(true)
		step(480)
		expect(peek(follower)).to.equal(10)
		expect(peek(doubled)).to.equal(20)

		doCleanup(scope)
	end)

	it("recovers from a NaN goal", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 1)
		local spring = Spring(scope, goal, 20, 1)
		step(60)
		goal:set(0 / 0)
		step(10)
		goal:set(4)
		step(240)
		expect(peek(spring)).to.equal(4)

		doCleanup(scope)
	end)

	it("keeps observers quiet while asleep", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 0)
		local spring = Spring(scope, goal, 30, 1)
		local fires = 0
		Observer(scope, spring):onChange(function()
			fires += 1
		end)
		goal:set(5)
		step(240)
		local settledFires = fires
		step(120)
		expect(fires).to.equal(settledFires)

		doCleanup(scope)
	end)

	it("sleeps a finished tween and wakes it when its goal changes", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 0)
		local tween = Tween(scope, goal, TweenInfo.new(0.25))
		goal:set(1)
		step(30)
		expect(peek(tween)).to.equal(1)
		step()
		expect(isAsleep(tween)).to.equal(true)

		goal:set(0)
		step()
		local moving = peek(tween) :: number
		expect(moving < 1 and moving > 0).to.equal(true)

		doCleanup(scope)
	end)

	it("updates every other animation when one destroys another mid-step", function()
		local expect = getfenv().expect

		local scope = {}
		local victimScope = {}
		local goal = Value(scope, 0)
		local victim = Spring(victimScope, goal, 20, 1)
		local destroyer = Spring(scope, goal, 20, 1)
		local last = Spring(scope, goal, 20, 1)
		local destroyed = false
		Observer(scope, destroyer):onChange(function()
			if not destroyed then
				destroyed = true
				doCleanup(victimScope)
			end
		end)
		step()
		goal:set(10)
		step()
		local before = peek(last)
		step()
		-- The victim's timer comes before the destroyer's, so destroying it
		-- must not shift `last` out of this step.
		expect(peek(last) ~= before).to.equal(true)

		doCleanup(scope)
	end)
end
