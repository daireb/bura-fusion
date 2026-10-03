--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local ForEach = require(Fusion.State.ForEach)
local Value = require(Fusion.State.Value)
local Computed = require(Fusion.State.Computed)
local Observer = require(Fusion.Graph.Observer)
local External = require(Fusion.External)
local peek = require(Fusion.State.peek)
local doCleanup = require(Fusion.Memory.doCleanup)

local function byKey(key, _)
	return key
end

local function byItem(_, item)
	return item
end

local function byUid(_, record)
	return record.uid
end

-- Collects the IDs of the messages logged through one External function
-- while the callback runs, and restores it even if the callback throws.
local function captureLogs(
	name: string,
	callback: () -> ()
): {string}
	local logged = {}
	local external = External :: any
	local original = external[name]
	external[name] = function(messageID)
		table.insert(logged, messageID)
	end
	local ok, err = pcall(callback)
	external[name] = original
	if not ok then
		error(err, 0)
	end
	return logged
end

return function()
	local it = getfenv().it

	it("keeps each identity's child through changes and moves", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {{uid = "a", n = 1}, {uid = "b", n = 2}, {uid = "c", n = 3}})
		local builds, cleanups = 0, 0
		local keys, items = {}, {}
		local cells = ForEach(scope, data, byUid, function(_, scope, key, item, uid)
			builds += 1
			keys[uid], items[uid] = key, item
			table.insert(scope, function()
				cleanups += 1
			end)
			return {uid = uid}
		end)
		local before = table.clone(peek(cells))
		-- Fresh records, reordered, with one changed.
		data:set({{uid = "c", n = 3}, {uid = "a", n = 10}, {uid = "b", n = 2}})
		local after = peek(cells)
		expect(builds).to.equal(3)
		expect(cleanups).to.equal(0)
		expect(after[1]).to.equal(before[3])
		expect(after[2]).to.equal(before[1])
		expect(after[3]).to.equal(before[2])
		expect(peek(keys.a)).to.equal(2)
		expect(peek(keys.c)).to.equal(1)
		expect(peek(items.a).n).to.equal(10)
		doCleanup(scope)
		expect(cleanups).to.equal(3)
	end)

	it("builds nothing until the list is read", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2})
		local builds = 0
		local cells = ForEach(scope, data, byKey, function(_, _, _, item)
			builds += 1
			return item
		end)
		data:set({3, 4, 5})
		expect(builds).to.equal(0)
		expect(#peek(cells)).to.equal(3)
		expect(builds).to.equal(3)
		doCleanup(scope)
	end)

	it("builds new identities and cleans removed ones", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {"a", "b"})
		local builds, cleanups = 0, 0
		local cells = ForEach(scope, data, byItem, function(_, scope, _, _, id)
			builds += 1
			table.insert(scope, function()
				cleanups += 1
			end)
			return id
		end)
		peek(cells)
		data:set({"a", "b", "c", "d"})
		expect(#peek(cells)).to.equal(4)
		expect(builds).to.equal(4)
		data:set({"d", "e"})
		expect(#peek(cells)).to.equal(2)
		expect(builds).to.equal(5)
		expect(cleanups).to.equal(3)
		doCleanup(scope)
	end)

	it("never hands a child to another identity", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {{uid = "a"}})
		local builds, cleanups = 0, 0
		local seen = {}
		local cells = ForEach(scope, data, byUid, function(_, scope, _, item, uid)
			builds += 1
			table.insert(scope, function()
				cleanups += 1
			end)
			-- Eager, like a bound instance property.
			Observer(scope, item):onChange(function()
				table.insert(seen, `{uid}={peek(item).uid}`)
			end)
			return uid
		end)
		peek(cells)
		Observer(scope, cells)
		-- The same key now holds another identity: a's child goes, c's is built.
		data:set({{uid = "c"}})
		expect(peek(cells)[1]).to.equal("c")
		expect(builds).to.equal(2)
		expect(cleanups).to.equal(1)
		expect(#seen).to.equal(0)
		doCleanup(scope)
	end)

	it("matches repeated identities in order, including false", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {false, false} :: {boolean})
		local builds = 0
		local cells = ForEach(scope, data, byItem, function(_, _, key, _)
			builds += 1
			return {key = key}
		end)
		local before = table.clone(peek(cells))
		data:set({true, false, false})
		local after = peek(cells)
		expect(builds).to.equal(3)
		expect(#after).to.equal(3)
		expect(after[2]).to.equal(before[1])
		expect(after[3]).to.equal(before[2])
		expect(peek(after[2].key)).to.equal(2)
		expect(peek(after[3].key)).to.equal(3)
		doCleanup(scope)
	end)

	it("updates every changed state as one change", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {"a", "b"})
		local states = {}
		local cells = ForEach(scope, data, byKey, function(_, _, _, item, key)
			states[key] = item
			return item
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

	it("writes only the states whose key or item changed", function()
		local expect = getfenv().expect

		local scope = {}
		local first, second = {uid = 1}, {uid = 2}
		local data = Value(scope, {first, second})
		local keyRuns, itemRuns = {0, 0}, {0, 0}
		local cells = ForEach(scope, data, byUid, function(_, scope, key, item, uid)
			return {
				Computed(scope, function(use)
					use(key)
					keyRuns[uid] += 1
					return uid
				end),
				Computed(scope, function(use)
					use(item)
					itemRuns[uid] += 1
					return uid
				end)
			}
		end)
		local function readAll()
			for _, cell in peek(cells) do
				peek(cell[1])
				peek(cell[2])
			end
		end
		readAll()
		-- Equal contents in a new table change nothing.
		data:set({first, second})
		readAll()
		-- Moving the same unfrozen records changes only their keys.
		data:set({second, first})
		readAll()
		-- A fresh record changes only its own item.
		data:set({{uid = 2}, first})
		readAll()
		expect(keyRuns[1]).to.equal(2)
		expect(keyRuns[2]).to.equal(2)
		expect(itemRuns[1]).to.equal(1)
		expect(itemRuns[2]).to.equal(2)
		doCleanup(scope)
	end)

	it("warns only when a top-level use of its own state builds a child again", function()
		local expect = getfenv().expect

		local scope = {}
		local warnings = {}
		local logWarn = External.logWarn
		External.logWarn = function(messageID, ...)
			table.insert(warnings, messageID)
		end
		-- A child matched by its item never sees the item change, so using it
		-- at the top level is harmless.
		local ids = Value(scope, {"a", "b"})
		local idBuilds = 0
		local byValue = ForEach(scope, ids, byItem, function(use, _, _, item)
			idBuilds += 1
			return use(item)
		end)
		peek(byValue)
		ids:set({"b", "a"})
		peek(byValue)
		-- A record's item does change, so using it builds the child again.
		local records = Value(scope, {{uid = 1, n = 1}})
		local recordBuilds = 0
		local byField = ForEach(scope, records, byUid, function(use, _, _, item)
			recordBuilds += 1
			return use(item).n
		end)
		peek(byField)
		records:set({{uid = 1, n = 2}})
		peek(byField)
		records:set({{uid = 1, n = 3}})
		local out = peek(byField)
		External.logWarn = logWarn
		expect(idBuilds).to.equal(2)
		expect(out[1]).to.equal(3)
		expect(recordBuilds).to.equal(3)
		expect(#warnings).to.equal(1)
		expect(warnings[1]).to.equal("forEachStateUsed")
		doCleanup(scope)
	end)

	it("warns once when a processor returns more than its output", function()
		local expect = getfenv().expect

		local scope = {}
		local warnings = {}
		local logWarn = External.logWarn
		External.logWarn = function(messageID, ...)
			table.insert(warnings, messageID)
		end
		local data = Value(scope, {"a", "b"})
		-- Carried over from a ForPairs processor, which returns its key first.
		local cells = ForEach(scope, data, byItem, function(_, _, key, _, id)
			return peek(key), id
		end)
		local out = peek(cells)
		External.logWarn = logWarn
		expect(out[2]).to.equal(2)
		expect(#warnings).to.equal(1)
		expect(warnings[1]).to.equal("forEachExtraOutput")
		doCleanup(scope)
	end)

	it("leaves a hole for a failing processor and retries it when its key or item changes", function()
		local expect = getfenv().expect

		local scope = {}
		local warnings = {}
		local logWarn = External.logWarn
		External.logWarn = function(messageID, ...)
			table.insert(warnings, messageID)
		end
		local a, b = {uid = "a", ready = false}, {uid = "b", ready = true}
		local data = Value(scope, {x = a, z = b} :: {[string]: any})
		local cells = ForEach(scope, data, byUid, function(_, _, key, item)
			local record = peek(item)
			if not record.ready or peek(key) == "z" then
				error("not ready yet")
			end
			return record.uid
		end)
		local before = table.clone(peek(cells))
		-- a's item changes and b moves to another key.
		data:set({x = {uid = "a", ready = true}, w = b})
		local after = peek(cells)
		External.logWarn = logWarn
		expect(next(before)).to.equal(nil)
		expect(after.x).to.equal("a")
		expect(after.w).to.equal("b")
		-- The failed builds log their errors and nothing else.
		expect(#warnings).to.equal(0)
		doCleanup(scope)
	end)

	it("leaves out an item it cannot identify until it can", function()
		local expect = getfenv().expect

		local scope = {}
		local errors = {}
		local logErrorNonFatal = External.logErrorNonFatal
		External.logErrorNonFatal = function(messageID, ...)
			table.insert(errors, messageID)
		end
		local data = Value(scope, {{uid = "a"}, {}, {}, {uid = "d"}} :: {any})
		local cells = ForEach(scope, data, function(_, record)
			if record.broken then
				error("no uid yet")
			end
			return record.uid
		end, function(_, _, _, _, uid)
			return uid
		end)
		local first = table.clone(peek(cells))
		data:set({{uid = "a"}, {uid = "b", broken = true}, {uid = "d"}})
		local second = table.clone(peek(cells))
		data:set({{uid = "a"}, {uid = "b"}, {uid = "d"}})
		local third = peek(cells)
		External.logErrorNonFatal = logErrorNonFatal
		expect(#first).to.equal(2)
		expect(first[2]).to.equal("d")
		expect(#second).to.equal(2)
		expect(#third).to.equal(3)
		expect(third[2]).to.equal("b")
		-- One log for each change that left items out.
		expect(#errors).to.equal(2)
		expect(errors[1]).to.equal("forEachIdentityMissing")
		expect(errors[2]).to.equal("callbackError")
		doCleanup(scope)
	end)

	it("logs a bad input or a failing cleanup without breaking its input", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {"a", "b", "c"} :: any)
		local cleanups = 0
		local cells = ForEach(scope, data, byItem, function(_, scope, _, _, id)
			table.insert(scope, function()
				cleanups += 1
				if id == "a" then
					error("cleanup failed")
				end
			end)
			return id
		end)
		peek(cells)
		local errors = captureLogs("logErrorNonFatal", function()
			-- a's cleanup errors, and b is still cleaned up.
			data:set({"c"})
			-- As a computed might return before its data loads.
			data:set(nil)
		end)
		expect(#errors).to.equal(2)
		expect(errors[1]).to.equal("callbackError")
		expect(errors[2]).to.equal("forEachInputNotTable")
		expect(cleanups).to.equal(3)
		expect(next(peek(cells))).to.equal(nil)
		data:set({"d"})
		expect(peek(cells)[1]).to.equal("d")
		doCleanup(scope)
	end)

	it("closes holes in an array and keeps other keys where they are", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2, 3} :: {[number]: number})
		local cells = ForEach(scope, data, byKey, function(_, _, _, item)
			local value = peek(item)
			return if value == 1 then nil else value * 10
		end)
		local out = peek(cells)
		expect(#out).to.equal(2)
		expect(out[1]).to.equal(20)
		expect(out[2]).to.equal(30)
		-- Number keys that do not form an array keep their places.
		data:set({[10] = 1, [20] = 2, [30] = 3})
		out = peek(cells)
		expect(out[10]).to.equal(nil)
		expect(out[20]).to.equal(20)
		expect(out[30]).to.equal(30)
		doCleanup(scope)
	end)

	it("never shows a child its new item against stale shared state", function()
		local expect = getfenv().expect

		local scope = {}
		local source = Value(scope, 1)
		local input = Computed(scope, function(use)
			return {use(source) * 10}
		end)
		local observations, inconsistent = 0, 0
		local cells = ForEach(scope, input, byKey, function(_, scope, _, item)
			local pair = Computed(scope, function(use)
				return {use(item), use(source)}
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

	it("lets a child's observer read the list while states update", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {1, 2, 3})
		local cells
		local reads = 0
		cells = ForEach(scope, data, byKey, function(_, scope, _, item)
			Observer(scope, item):onChange(function()
				-- As navigation or scroll-into-view code might.
				reads += #peek(cells)
			end)
			return item
		end)
		peek(cells)
		Observer(scope, cells)
		expect(function()
			data:set({4, 5, 6})
		end).never.to.throw()
		expect(reads).to.equal(9)
		doCleanup(scope)
	end)

	it("lets an item's observer remove its own entry", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {{uid = "a", done = false}, {uid = "b", done = false}})
		local cleaned = {}
		local cells = ForEach(scope, data, byUid, function(_, scope, _, item, uid)
			table.insert(scope, function()
				table.insert(cleaned, uid)
			end)
			-- A finished entry removes itself, as a quest or a toast might.
			Observer(scope, item):onChange(function()
				if peek(item).done then
					local remaining = {}
					for _, record in peek(data) do
						if record.uid ~= uid then
							table.insert(remaining, record)
						end
					end
					data:set(remaining)
				end
			end)
			return uid
		end)
		peek(cells)
		Observer(scope, cells)
		data:set({{uid = "a", done = true}, {uid = "b", done = false}})
		local out = peek(cells)
		expect(#out).to.equal(1)
		expect(out[1]).to.equal("b")
		expect(#cleaned).to.equal(1)
		expect(cleaned[1]).to.equal("a")
		doCleanup(scope)
	end)

	it("keeps its input working when an item's observer writes its own item through it", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {{id = 1, done = false}, {id = 2, done = false}, {id = 3, done = false}})
		local items, labels = {}, {}
		local cells = ForEach(scope, data, byKey, function(_, scope, _, item, slot)
			items[slot] = item
			labels[slot] = Computed(scope, function(use)
				return use(item).id
			end)
			-- Removing its own entry moves the next item into this slot, which
			-- writes the item this observer is reacting to: a cycle.
			Observer(scope, item):onChange(function()
				local record = peek(item)
				if record.done then
					local remaining = {}
					for _, other in peek(data) do
						if other ~= record then
							table.insert(remaining, other)
						end
					end
					data:set(remaining)
				end
			end)
			return labels[slot]
		end)
		-- Younger than the list's internal writer, older than its children.
		local fires = 0
		Observer(scope, data):onChange(function()
			fires += 1
		end)
		peek(cells)
		Observer(scope, cells)
		local errors = captureLogs("logErrorNonFatal", function()
			data:set({{id = 1, done = true}, {id = 2, done = false}, {id = 3, done = false}})
		end)
		expect(#errors).to.equal(1)
		expect(errors[1]).to.equal("forEachCycle")
		expect(#peek(cells)).to.equal(2)
		-- The states keep their old values until the input changes again.
		expect(peek(items[1]).id).to.equal(1)
		local records = table.clone(peek(data))
		table.insert(records, {id = 4, done = false})
		data:set(records)
		expect(peek(items[1]).id).to.equal(2)
		expect(peek(labels[1])).to.equal(2)
		expect(peek(labels[2])).to.equal(3)
		expect(fires).to.equal(3)
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
		ForEach(listScope, data, byKey, function(_, _, _, item)
			return item
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

	it("cleans every child when a removed child's cleanup destroys the list", function()
		local expect = getfenv().expect

		local scope = {}
		local data = Value(scope, {"a", "b"})
		local listScope = {}
		local cleanups = 0
		local cells = ForEach(listScope, data, byItem, function(_, scope, _, _, id)
			table.insert(scope, function()
				cleanups += 1
				-- Removing a closes the whole list, as a panel might.
				if id == "a" then
					doCleanup(listScope)
				end
			end)
			return id
		end)
		peek(cells)
		expect(function()
			data:set({"b", "c"})
		end).never.to.throw()
		expect(cleanups).to.equal(2)
		expect(next(data.dependentSet)).to.equal(nil)
		doCleanup(scope)
	end)
end
