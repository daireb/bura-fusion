--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local Tween = require(Fusion.Animation.Tween)
local Value = require(Fusion.State.Value)
local Computed = require(Fusion.State.Computed)
local Observer = require(Fusion.Graph.Observer)
local peek = require(Fusion.State.peek)
local doCleanup = require(Fusion.Memory.doCleanup)

return function()
	local it = getfenv().it

	it("does not resubscribe to its goal once its computed re-runs", function()
		local expect = getfenv().expect

		local scope = {}
		local goal = Value(scope, 0)
		local computed = Computed(scope, function(use, scope)
			Tween(scope, goal, TweenInfo.new(1))
			return use(goal)
		end)
		-- Read, then observe, so from the second change on the consumer is
		-- older than the inner tween and re-runs the computed while that tween
		-- is still queued.
		peek(computed)
		Observer(scope, computed)
		for value = 1, 10 do
			goal:set(value)
		end
		local dependents = 0
		for _ in goal.dependentSet do
			dependents += 1
		end
		-- The computed and its current inner tween.
		expect(dependents).to.equal(2)

		doCleanup(scope)
	end)
end
