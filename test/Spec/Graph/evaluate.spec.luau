--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local Types = require(Fusion.Types)
local evaluate = require(Fusion.Graph.evaluate)
local depend = require(Fusion.Graph.depend)
local Observer = require(Fusion.Graph.Observer)
local Value = require(Fusion.State.Value)
local Computed = require(Fusion.State.Computed)
local peek = require(Fusion.State.peek)
local doCleanup = require(Fusion.Memory.doCleanup)

local Graphs = require(script.Parent.Parent.Parent.Util.Graphs)
local captureLogs = require(script.Parent.Parent.Parent.Util.captureLogs)

-- A state whose own evaluation errors, outside any processor, while its input
-- is 1.
local function Throwing(
	scope: {unknown},
	input: Types.Value<number>
): any
	local self = {
		type = "State",
		kind = "Throwing",
		timeliness = "lazy",
		scope = scope,
		createdAt = os.clock(),
		dependencySet = {},
		dependentSet = {},
		lastChange = nil,
		validity = "invalid",
		_EXTREMELY_DANGEROUS_usedAsValue = 0
	}
	function self._evaluate(self): boolean
		depend(self, input)
		if peek(input) == 1 then
			error("This is an intentional error from a unit test")
		end
		self._EXTREMELY_DANGEROUS_usedAsValue = peek(input)
		return true
	end
	return self
end

return function()
	local describe = getfenv().describe
	local it = getfenv().it

	it("lets the rest of a change run when an eager object errors, leaving nothing busy", function()
		local expect = getfenv().expect

		local scope = {}
		local input = Value(scope, 0)
		local throwing = Throwing(scope, input)
		local olderRuns = 0
		Observer(scope, throwing):onChange(function()
			olderRuns += 1
		end)
		local youngerRuns = 0
		Observer(scope, input):onChange(function()
			youngerRuns += 1
		end)

		expect(function()
			input:set(1)
		end).to.throw("intentional")
		expect(youngerRuns).to.equal(1)
		expect(throwing.validity).to.equal("valid")
		input:set(2)
		expect(youngerRuns).to.equal(2)
		expect(olderRuns).to.equal(1)
		expect(peek(throwing)).to.equal(2)

		doCleanup(scope)
	end)

	it("leaves no cycle behind when a processor catches a cyclic use", function()
		local expect = getfenv().expect

		local scope = {}
		local input = Value(scope, 0)
		local first, second
		first = Computed(scope, function(use)
			use(input)
			return use(second)
		end)
		second = Computed(scope, function(use)
			return use(first)
		end)
		captureLogs("logErrorNonFatal", function()
			peek(first)
		end)
		local runs = 0
		Observer(scope, input):onChange(function()
			runs += 1
		end)
		input:set(1)
		expect(runs).to.equal(1)

		doCleanup(scope)
	end)

	it("leaves nothing busy when a processor catches an error from what it uses", function()
		local expect = getfenv().expect

		local scope = {}
		local input = Value(scope, 0)
		local throwing = Throwing(scope, input)
		input:set(1)
		-- Computed for the first time, so the error reaches its processor
		-- rather than its check of what it used. It is not subscribed to what
		-- errored, so it also uses the input to hear of the fix.
		local computed = Computed(scope, function(use)
			use(input)
			return use(throwing)
		end)
		local errors = captureLogs("logErrorNonFatal", function()
			expect(peek(computed)).to.equal(nil)
		end)
		expect(errors[1]).to.equal("callbackError")
		expect(throwing.validity).to.equal("valid")
		input:set(2)
		expect(peek(computed)).to.equal(2)

		doCleanup(scope)
	end)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "always ensures the target is valid",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object.validity = if index % 2 == 0 then "valid" else "invalid"
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return index // 2 % 2 == 0
					end
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			for _, object in graph.allObjects do
				evaluate(object, false)
				if object.validity ~= "valid" then
					return `{Graphs.nameOf(object)} was not valid`
				end
			end
			return Graphs.check(
				graph.allObjects,
				Graphs.tests.validity("valid")
			)
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "always ensures the last change time is non-nil, even after meaningless changes",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object.validity = if index % 2 == 0 then "valid" else "invalid"
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return index // 2 % 2 == 0
					end
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			for _, object in graph.allObjects do
				local beforeTime = object.lastChange
				evaluate(object, false)
				if object.lastChange == nil then
					return `{Graphs.nameOf(object)} had a nil change time`
				end
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "does *not* evaluate prior dependencies",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return true
					end
				end
				local targets = Graphs.selectors.noConnections(graph.allObjects, "dependent")
				for _, object in 
					Graphs.selectors.distance(graph.allObjects, targets, "dependency", 1)
				do
					object.validity = "invalid"
				end
				return {graph}
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local targets = Graphs.selectors.noConnections(graph.allObjects, "dependent")
			for _, target in targets do
				evaluate(target, false)
			end
			return Graphs.check(
				Graphs.selectors.distance(graph.allObjects, targets, "dependency", 1),
				Graphs.tests.validity("valid")
			) or Graphs.check(
				Graphs.selectors.distance(graph.allObjects, targets, "dependency", 2),
				Graphs.tests.validity("valid")
			)
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "allows further evaluating/depending on objects during evaluation",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return true
					end
					object.validity = "invalid"
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local targets = Graphs.selectors.noConnections(graph.allObjects, "dependent")
			local diagnosis: string | false = false
			for _, target in targets do
				local dependencies = Graphs.selectors.distance(graph.allObjects, {target}, "dependency", 1)
				evaluate(target, false)
				diagnosis = diagnosis or Graphs.check(
					dependencies,
					Graphs.tests.validity("valid")
				)
			end
			return diagnosis
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "properly clears dependency connections for objects that compute",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for _, object in graph.allObjects do
					(object :: any).TEST_OLD_DEPS = table.clone(object.dependencySet)
					object.validity = "invalid"
					object._evaluate = function()
						(object :: any).TEST_MARKER = true
						return false
					end
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local foundTestMarker = false
			for _, object in graph.allObjects do
				evaluate(object, false)
				if not (object :: any).TEST_MARKER then
					continue
				end
				foundTestMarker = true
				if next(object.dependencySet) ~= nil then
					return `{Graphs.nameOf(object)} had dependencies after revalidation`
				end
				for dependency in (object :: any).TEST_OLD_DEPS do
					if dependency.dependentSet[object] ~= nil then
						return `{Graphs.nameOf(object)} wasn't cleared from the dependent set of an old dependency`
					end
				end
			end
			if not foundTestMarker then
				return "no test marker was found - this is a spec bug"
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "preserves dependent connections",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return true
					end
					object.validity = "invalid"
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			for _, object in graph.allObjects do
				if next(object.dependentSet) == nil then
					continue
				end
				evaluate(object, false)
				if next(object.dependentSet) == nil then
					return `{Graphs.nameOf(object)} did not have dependents after revalidation`
				end
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "does *not* evaluate dependents",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return true
					end
					object.validity = "invalid"
				end
				local targets = Graphs.selectors.noConnections(graph.allObjects, "dependency")
				local dependents = Graphs.selectors.distance(graph.allObjects, targets, "dependent", 1)
				for _, dependent in dependents do
					dependent._evaluate = function()
						error(`{Graphs.nameOf(dependent)} was evaluated`, 0)
					end
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local targets = Graphs.selectors.noConnections(graph.allObjects, "dependency")
			for _, target in targets do
				evaluate(target, false)
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "does *not* run computations for already-valid objects with a last change",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					object._evaluate = function()
						error(`{Graphs.nameOf(object)} was evaluated`, 0)
					end
					object.validity = "valid"
					object.lastChange = math.huge
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			for _, target in graph.allObjects do
				evaluate(target, false)
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "forcibly runs computations if specified to",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for index, object in graph.allObjects do
					object._evaluate = function()
						(object :: any)._TEST_MARKER = true
						return false
					end
					object.validity = "valid"
					object.lastChange = math.huge
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			for _, target in graph.allObjects do
				evaluate(target, true)
			end
			for _, object in graph.allObjects do
				if (object :: any)._TEST_MARKER ~= true then
					return `{Graphs.nameOf(object)} was not evaluated`
				end
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "runs computations for invalid objects with no change time",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for _, object in graph.allObjects do
					object.validity = "invalid"
					object._evaluate = function()
						(object :: any).TEST_MARKER = true
						return false
					end
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local didAnyTests = false
			for _, object in graph.allObjects do
				if object.validity ~= "invalid"  or object.lastChange ~= nil then
					continue
				end
				didAnyTests = true
				evaluate(object, false)
				if not (object :: any).TEST_MARKER then
					return `{Graphs.nameOf(object)} did not compute despite being invalid`
				end
			end
			if not didAnyTests then
				return "no tests were done - this is a spec bug"
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "runs computations for invalid objects with non-nil change time",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for _, object in graph.allObjects do
					object._evaluate = function()
						(object :: any).TEST_MARKER = true
						return false
					end
				end
				local searchNow = Graphs.selectors.noConnections(graph.allObjects, "dependency")
				for depth = 0, math.huge do
					local searchNext = {}
					local seen = {}
					for _, searchTarget in searchNow do
						searchTarget.lastChange = -depth
						searchTarget.validity = if depth == 0 then "valid" else "invalid"
						for dependent in searchTarget.dependentSet do
							if seen[dependent] then
								continue
							end
							seen[dependent] = true
							table.insert(searchNext, dependent)
						end
					end
					if #searchNext == 0 then
						break
					end
					searchNow = searchNext
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local didAnyTests = false
			for _, object in graph.allObjects do
				if object.validity ~= "invalid" or object.lastChange == nil then
					continue
				end
				didAnyTests = true
				evaluate(object, false)
				if not (object :: any).TEST_MARKER then
					return `{Graphs.nameOf(object)} did not compute despite being invalid`
				end
			end
			if not didAnyTests and #graph.allObjects > 1 then
				return "no tests were done - this is a spec bug"
			end
			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "does not compute if meaningful changes turn into meaningless changes",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for _, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object.validity = "invalid"
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return true
					end
				end

				local transitives = Graphs.selectors.noConnections(graph.allObjects, "dependency")
				local directs = Graphs.selectors.distance(graph.allObjects, transitives, "dependent", 1)
				local targets = Graphs.selectors.distance(graph.allObjects, directs, "dependent", 1)

				for _, direct in directs do
					local dependencySet = table.clone(direct.dependencySet)
					local doEvaluate = direct._evaluate
					direct._evaluate = function()
						doEvaluate(direct)
						return false
					end
				end

				for _, target in targets do
					target.lastChange = -math.huge
					target._evaluate = function()
						error(`{Graphs.nameOf(target)} was evaluated`, 0)
					end
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local transitives = Graphs.selectors.noConnections(graph.allObjects, "dependency")
			local directs = Graphs.selectors.distance(graph.allObjects, transitives, "dependent", 1)
			local targets = Graphs.selectors.distance(graph.allObjects, directs, "dependent", 1)

			for _, target in targets do
				evaluate(target, false)
			end

			return false
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "throws an error for malformed graphs in finite time",
		filters = {Graphs.filters.malformed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for _, object in graph.allObjects do
					local dependencySet = table.clone(object.dependencySet)
					object._evaluate = function()
						object.dependencySet = table.clone(dependencySet)
						for dependency in object.dependencySet do
							evaluate(dependency, false)
						end
						return true
					end
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local ok, err = pcall(function()
				for _, object in graph.objects do
					for _, object in graph.objects do
						object.validity = "invalid"
						object.lastChange = nil
					end
					evaluate(object, false)
				end
			end)
			if ok then
				return "Should not have completed without errors"
			elseif string.find(err, "infiniteLoop", 1, true) ~= nil then
				return false
			else
				return err
			end
		end
	} (describe)

	Graphs.propertyTest {
		testing = "evaluate",
		it = "throws when encountering a busy object",
		filters = {Graphs.filters.wellFormed},
		preparation = {
			count = 1,
			prepare = function(
				graph: Graphs.Graph
			)
				for _, object in graph.allObjects do
					object.validity = "busy"
				end
			end
		},
		perform = function(
			graph: Graphs.Graph
		)
			local ok, err = pcall(function()
				for _, object in graph.objects do
					evaluate(object, false)
				end
			end)
			if ok then
				return "Should not have completed without errors"
			elseif string.find(err, "infiniteLoop", 1, true) ~= nil then
				return false
			else
				return err
			end
		end
	} (describe)
end