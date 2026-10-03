--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local ForValueStates = require(Fusion.State.ForValueStates)
local Value = require(Fusion.State.Value)
local Computed = require(Fusion.State.Computed)
local Observer = require(Fusion.Graph.Observer)
local External = require(Fusion.External)
local peek = require(Fusion.State.peek)
local doCleanup = require(Fusion.Memory.doCleanup)

return function()
	local it = getfenv().it

	it("builds each key once and updates its value in place", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {10, 20, 30})
		local builds, cleanups = 0, 0
		local values = {}
		local cells = ForValueStates(scope, data, function(_, scope, key, value)
			builds += 1
			values[key] = value
			table.insert(scope, function()
				cleanups += 1
			end)
			return Computed(scope, function(use)
				return use(value) * 2
			end)
		end)
		local before = peek(cells)
		expect(builds).to.equal(3)

		data:set({11, 20, 31})
		local after = peek(cells)
		expect(builds).to.equal(3)
		expect(cleanups).to.equal(0)
		expect(after[1]).to.equal(before[1])
		expect(peek(after[1])).to.equal(22)
		expect(peek(after[3])).to.equal(62)
		expect(peek(values[2])).to.equal(20)
		doCleanup(scope)
		expect(cleanups).to.equal(3)
	end)

	it("builds nothing until the list is read", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2})
		local builds = 0
		local cells = ForValueStates(scope, data, function(_, _, key, _)
			builds += 1
			return key
		end)
		data:set({3, 4, 5})
		expect(builds).to.equal(0)
		expect(#peek(cells)).to.equal(3)
		expect(builds).to.equal(3)
		doCleanup(scope)
	end)

	it("builds new keys and cleans removed ones", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2})
		local builds, cleanups = 0, 0
		local cells = ForValueStates(scope, data, function(_, scope, key, _value)
			builds += 1
			table.insert(scope, function()
				cleanups += 1
			end)
			return key
		end)
		peek(cells)
		data:set({1, 2, 3, 4})
		expect(#peek(cells)).to.equal(4)
		expect(builds).to.equal(4)
		data:set({5, 6})
		expect(#peek(cells)).to.equal(2)
		expect(builds).to.equal(4)
		expect(cleanups).to.equal(2)
		doCleanup(scope)
	end)

	it("rebuilds a reassigned key with a fresh value state", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {a = 1} :: {[string]: number})
		local seen = {}
		local cells = ForValueStates(scope, data, function(_, scope, key, value)
			local watcher = Computed(scope, function(use)
				table.insert(seen, `{key}={use(value)}`)
				return use(value)
			end)
			-- Eager, like a bound instance property.
			Observer(scope, watcher)
			return watcher
		end)
		peek(cells)
		Observer(scope, cells)
		-- `a` disappears and `c` appears in one update: the reconciler hands
		-- a's child to c, which must rebuild rather than show c's value as a.
		data:set({c = 3})
		local out = peek(cells)
		expect(out.a).to.equal(nil)
		expect(peek(out.c)).to.equal(3)
		for _, entry in seen do
			expect(entry).never.to.equal("a=3")
		end
		doCleanup(scope)
	end)

	it("warns and rebuilds when the processor uses its value at the top level", function()
		local expect = getfenv().expect

		local scope = {}
		local warnings = {}
		local logWarn = External.logWarn
		External.logWarn = function(messageID, ...)
			table.insert(warnings, messageID)
		end
		local data = Value(scope, {1})
		local builds = 0
		local cells = ForValueStates(scope, data, function(use, _, _, value)
			builds += 1
			return use(value) * 10
		end)
		expect(peek(cells)[1]).to.equal(10)
		data:set({2})
		expect(peek(cells)[1]).to.equal(20)
		External.logWarn = logWarn
		expect(builds).to.equal(2)
		expect(#warnings).to.equal(1)
		expect(warnings[1]).to.equal("forValueStatesValueUsed")
		doCleanup(scope)
	end)

	it("does nothing when equal contents are set again", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2})
		local builds, writes = 0, 0
		local cells = ForValueStates(scope, data, function(_, scope, _, value)
			builds += 1
			return Computed(scope, function(use)
				writes += 1
				return use(value)
			end)
		end)
		for _, cell in peek(cells) do
			peek(cell)
		end
		data:set({1, 2})
		for _, cell in peek(cells) do
			peek(cell)
		end
		expect(builds).to.equal(2)
		expect(writes).to.equal(2)
		doCleanup(scope)
	end)

	it("leaves a hole for a failing processor and retries it when its value changes", function()
		local expect = getfenv().expect

		local scope = {}
		local warnings = {}
		local logWarn = External.logWarn
		External.logWarn = function(messageID, ...)
			table.insert(warnings, messageID)
		end
		local data = Value(scope, {a = 1, b = 2} :: {[string]: number})
		local cells = ForValueStates(scope, data, function(_, _, key, value)
			if key == "a" and peek(value) == 1 then
				error("not ready yet")
			end
			return key
		end)
		local before = table.clone(peek(cells))
		data:set({a = 2, b = 2})
		local after = peek(cells)
		External.logWarn = logWarn
		expect(before.a).to.equal(nil)
		expect(before.b).to.equal("b")
		expect(after.a).to.equal("a")
		expect(after.b).to.equal("b")
		-- The failed build logs its error and nothing else.
		expect(#warnings).to.equal(0)
		doCleanup(scope)
	end)

	it("compacts holes from nil outputs like other For objects", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2, 3})
		local cells = ForValueStates(scope, data, function(_, scope, key, _)
			return if key == 2 then nil else key * 10
		end)
		local out = peek(cells)
		expect(#out).to.equal(2)
		expect(out[1]).to.equal(10)
		expect(out[2]).to.equal(30)
		doCleanup(scope)
	end)

	it("never shows a child its new value against stale shared state", function()
		local expect = getfenv().expect

		local scope = {}
		local source = Value(scope, 1)
		local input = Computed(scope, function(use)
			return {use(source) * 10}
		end)
		local observations, inconsistent = 0, 0
		local cells = ForValueStates(scope, input, function(_, scope, _, value)
			local pair = Computed(scope, function(use)
				return {use(value), use(source)}
			end)
			Observer(scope, pair):onChange(function()
				observations += 1
				local current = peek(pair)
				if current[1] ~= current[2] * 10 then
					inconsistent += 1
				end
			end)
			return pair
		end)
		-- [Children] peeks a For before it creates the observer that consumes
		-- it, so the children are older than their consumer.
		peek(cells)
		Observer(scope, cells)
		for step = 2, 6 do
			source:set(step)
		end
		expect(observations > 0).to.equal(true)
		expect(inconsistent).to.equal(0)
		doCleanup(scope)
	end)

	it("updates every changed key as one change", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {"a", "b"})
		local states = {}
		local cells = ForValueStates(scope, data, function(_, _, key, value)
			states[key] = value
			return value
		end)
		peek(cells)
		Observer(scope, cells)
		local both = Computed(scope, function(use)
			return use(states[1]) .. use(states[2])
		end)
		local seen = {}
		Observer(scope, both):onChange(function()
			table.insert(seen, peek(both))
		end)
		data:set({"b", "a"})
		expect(#seen).to.equal(1)
		expect(seen[1]).to.equal("ba")
		doCleanup(scope)
	end)

	it("lets a child's observer read the list while values update", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2, 3})
		local cells
		local reads = 0
		cells = ForValueStates(scope, data, function(_, scope, _, value)
			Observer(scope, value):onChange(function()
				-- As navigation or scroll-into-view code might.
				reads += #peek(cells)
			end)
			return value
		end)
		peek(cells)
		Observer(scope, cells)
		expect(function()
			data:set({4, 5, 6})
		end).never.to.throw()
		expect(reads).to.equal(9)
		doCleanup(scope)
	end)

	it("leaves no observer of a removed child subscribed", function()
		local expect = getfenv().expect

		local scope = {}
		local size = Value(scope, 6)
		local input = Computed(scope, function(use)
			local items = {}
			for index = 1, use(size) do
				items[index] = index
			end
			return items
		end)
		local cells = ForValueStates(scope, input, function(_, scope, key, _)
			-- Watches the source that removes it, so it is queued in the
			-- same change that destroys it.
			Observer(scope, size)
			return key
		end)
		peek(cells)
		Observer(scope, cells)
		size:set(3)
		size:set(1)
		local dependents = 0
		for _ in size.dependentSet do
			dependents += 1
		end
		-- the input computed and the one live child's observer
		expect(dependents).to.equal(2)
		doCleanup(scope)
	end)

	it("releases its input when destroyed during a change of that input", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2})
		local listScope = {}
		-- Older than the list, so it destroys the list after the list's own
		-- update was queued in the same change.
		Observer(scope, data):onChange(function()
			doCleanup(listScope)
		end)
		ForValueStates(listScope, data, function(_, _, key, _)
			return key
		end)
		data:set({3, 4})
		local dependents = 0
		for _ in data.dependentSet do
			dependents += 1
		end
		-- Only the older observer.
		expect(dependents).to.equal(1)
		doCleanup(scope)
	end)
end
