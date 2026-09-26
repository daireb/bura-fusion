--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local ForValues = require(Fusion.State.ForValues)
local ForKeys = require(Fusion.State.ForKeys)
local ForPairs = require(Fusion.State.ForPairs)
local Value = require(Fusion.State.Value)
local peek = require(Fusion.State.peek)
local doCleanup = require(Fusion.Memory.doCleanup)

return function()
	local it = getfenv().it

	it("preserves the surviving value's output when the pool shrinks", function()
		local expect = getfenv().expect
		local scope = {}
		local data = Value(scope, { first = "one", second = "two", third = "three" } :: { [string]: string })
		local computations = 0
		local forValues = ForValues(scope, data, function(_, _, value)
			computations += 1
			return { value = value }
		end)
		local before = peek(forValues).third
		expect(computations).to.equal(3)

		data:set({ third = "three" })
		expect(peek(forValues).third).to.equal(before)
		expect(computations).to.equal(3)
		doCleanup(scope)
	end)

	it("preserves both genuine matches when duplicate values shrink", function()
		local expect = getfenv().expect
		local scope = {}
		local data = Value(scope, { "same", "same", "other" })
		local computations = 0
		local forValues = ForValues(scope, data, function(_, _, value)
			computations += 1
			return { value = value }
		end)
		local before = peek(forValues)
		local first, second, other = before[1], before[2], before[3]
		expect(computations).to.equal(3)

		data:set({ "same", "other" })
		local after = peek(forValues)
		expect(after[1] == first or after[1] == second).to.equal(true)
		expect(after[2]).to.equal(other)
		expect(computations).to.equal(3)
		doCleanup(scope)
	end)

	it("preserves an unchanged ForPairs key with duplicate values", function()
		local expect = getfenv().expect
		local scope = {}
		local data = Value(scope, { a = 1, b = 1 } :: { [string]: number })
		local callbackOrder = {}
		local computations = 0
		local forPairs = ForPairs(scope, data, function(_, _, key, value)
			computations += 1
			table.insert(callbackOrder, key)
			return key, { value = value }
		end)
		local before = peek(forPairs)
		local removedKey, survivorKey = callbackOrder[1], callbackOrder[2]
		expect(computations).to.equal(2)

		data:set({ [survivorKey] = 1 })
		expect(peek(forPairs)[survivorKey]).to.equal(before[survivorKey])
		expect(peek(forPairs)[removedKey]).to.equal(nil)
		expect(computations).to.equal(2)
		doCleanup(scope)
	end)

	it("reuses a value when its key changes to false", function()
		local expect = getfenv().expect
		local scope = {}
		local data = Value(scope, { [true] = "same" })
		local computations = 0
		local forValues = ForValues(scope, data, function(_, _, value)
			computations += 1
			return { value = value }
		end)
		local before = peek(forValues)[true]
		expect(computations).to.equal(1)

		data:set({ [false] = "same" })
		expect(peek(forValues)[false]).to.equal(before)
		expect(peek(forValues)[true]).to.equal(nil)
		expect(computations).to.equal(1)
		doCleanup(scope)
	end)

	it("keeps a false key while ForKeys values change", function()
		local expect = getfenv().expect
		local scope = {}
		local data = Value(scope, { [false] = "old", [true] = "other" })
		local computations = 0
		local forKeys = ForKeys(scope, data, function(_, _, key)
			computations += 1
			return if key then "TRUE" else "FALSE"
		end)
		expect(peek(forKeys).FALSE).to.equal("old")
		expect(computations).to.equal(2)

		data:set({ [false] = "new" })
		expect(peek(forKeys).FALSE).to.equal("new")
		expect(peek(forKeys).TRUE).to.equal(nil)
		expect(computations).to.equal(2)
		doCleanup(scope)
	end)

	it("keeps a false key while ForPairs values change", function()
		local expect = getfenv().expect
		local scope = {}
		local data = Value(scope, { [false] = "old", [true] = "other" })
		local forPairs = ForPairs(scope, data, function(_, _, key, value)
			local outputKey = if key then "TRUE" else "FALSE"
			return outputKey, value
		end)
		expect(peek(forPairs).FALSE).to.equal("old")

		data:set({ [false] = "new" })
		expect(peek(forPairs).FALSE).to.equal("new")
		expect(peek(forPairs).TRUE).to.equal(nil)
		doCleanup(scope)
	end)
end
