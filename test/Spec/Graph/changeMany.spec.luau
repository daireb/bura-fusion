--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local changeMany = require(Fusion.Graph.changeMany)
local Value = require(Fusion.State.Value)
local Computed = require(Fusion.State.Computed)
local Observer = require(Fusion.Graph.Observer)
local peek = require(Fusion.State.peek)
local doCleanup = require(Fusion.Memory.doCleanup)

return function()
	local it = getfenv().it

	it("updates dependents of several targets in one pass", function()
		local expect = getfenv().expect

		local scope = {}
		local a = Value(scope, 1)
		local b = Value(scope, 10)
		local computations = 0
		local sum = Computed(scope, function(use)
			computations += 1
			return use(a) + use(b)
		end)
		local seen = {}
		Observer(scope, sum):onChange(function()
			table.insert(seen, peek(sum))
		end)
		computations = 0

		a._EXTREMELY_DANGEROUS_usedAsValue = 2
		b._EXTREMELY_DANGEROUS_usedAsValue = 20
		changeMany({a, b})

		expect(computations).to.equal(1)
		expect(#seen).to.equal(1)
		expect(seen[1]).to.equal(22)

		doCleanup(scope)
	end)

	it("runs the eager dependents of every target in order of creation", function()
		local expect = getfenv().expect

		local scope = {}
		local a = Value(scope, 1)
		local b = Value(scope, 10)
		local order = {}
		-- Created in the reverse of the target order.
		Observer(scope, b):onChange(function()
			table.insert(order, "b")
		end)
		Observer(scope, a):onChange(function()
			table.insert(order, "a")
		end)

		a._EXTREMELY_DANGEROUS_usedAsValue = 2
		b._EXTREMELY_DANGEROUS_usedAsValue = 20
		changeMany({a, b})

		expect(#order).to.equal(2)
		expect(order[1]).to.equal("b")
		expect(order[2]).to.equal("a")

		doCleanup(scope)
	end)
end
