--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Constructs and returns a new For state object which processes values as
	state objects and preserves keys.

	The processor runs once per key and receives that key's value as a
	read-only state object. When the value changes, the state object is updated
	and the processor's output, the child, stays in place, where ForPairs and
	ForValues would run the processor again. A nil output leaves a hole, which
	is compacted in arrays as in every For object.

	The processor runs inside a computed, as in every For object, so any state
	it uses at the top level runs it again. Using its own value state that way
	defeats the point, so it logs a warning once per list.

	Implementation notes:
	- The shared disassembly reconciles as usual and stays lazy. Sub-objects
	  only mark a key whose value changed as dirty.
	- One eager distributor per list updates the dirty keys' value states in a
	  single change, so a reader of several keys sees one consistent update.
	  It is created right after the For object, so it runs before any child in
	  the creation-ordered eager pass. Nothing can depend on it, so no user
	  code runs while an object it could pull is busy.
	- A sub-object handed to a different key (one key removed and another
	  added in the same update) rebuilds against a fresh value state, so no
	  child ever sees another key's value.
	- A processor that errors leaves a hole, and runs again when its value
	  changes.

	This is the fixed-key subset of the state arguments proposed upstream:
	https://github.com/dphfox/Fusion/issues/220
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
-- Graph
local changeMany = require(Package.Graph.changeMany)
local depend = require(Package.Graph.depend)
local evaluate = require(Package.Graph.evaluate)
-- State
local For = require(Package.State.For)
local Value = require(Package.State.Value)
local Computed = require(Package.State.Computed)
local ForTypes = require(Package.State.For.ForTypes)
-- Logging
local parseError = require(Package.Logging.parseError)
-- Memory
local doCleanup = require(Package.Memory.doCleanup)
-- Utility
local isSimilar = require(Package.Utility.isSimilar)
local nicknames = require(Package.Utility.nicknames)

type Processor<K, VI, VO, S> = (Types.Use, Types.Scope<S>, K, Types.StateObject<VI>) -> VO?

type List = {
	dirty: {[any]: true},
	warned: boolean
}

type Distributor = Types.GraphObject & {
	_disassembly: Types.GraphObject,
	_list: List
}

local SUB_OBJECT_META = {
	__index = {
		roamKeys = false,
		roamValues = true,
		invalidateInputKey = function(self): ()
			-- Only happens when this sub-object is handed to a new key. Detach
			-- the old build's value state first, so the new key's value is
			-- never written into it; the key change rebuilds the child.
			self._valueState = nil
			self._failed = false
			self._keyState:set(self.inputKey)
		end,
		invalidateInputValue = function(self): ()
			-- Written later by the distributor, outside the reconcile.
			if self._valueState ~= nil or self._failed then
				self._list.dirty[self] = true
			end
		end,
		useOutputPair = function(self, use)
			return self.inputKey, use(self._outputValueState)
		end
	}
}

local function SubObject<K, VI, VO, S>(
	scope: Types.Scope<S>,
	initialKey: K,
	initialValue: VI,
	processor: Processor<K, VI, VO, S>,
	list: List
): ForTypes.SubObject<S, K, K, VI, VO>
	local self = {} :: any
	self.maybeScope = scope
	self.inputKey = initialKey
	self.inputValue = initialValue
	self._list = list
	self._valueState = nil
	self._failed = false
	self._retry = nil
	self._keyState = Value(scope, initialKey)
	self._outputValueState = Computed(scope, function(use, buildScope): VO?
		local key = use(self._keyState)
		-- Owned by this build, so a rebuild destroys it with the old child.
		local valueState = Value(buildScope, self.inputValue)
		self._valueState = valueState
		self._failed = false
		local ok, outputValue = xpcall(processor, parseError, use, buildScope, key, valueState)
		if ok then
			if not list.warned and self._outputValueState.dependencySet[valueState] then
				list.warned = true
				External.logWarn("forValueStatesValueUsed", tostring(key))
			end
			return outputValue
		end
		local error: Types.Error = outputValue :: any
		error.context = `while processing key {tostring(key)}`
		External.logErrorNonFatal("callbackError", error)
		self._valueState = nil
		self._failed = true
		-- The distributor bumps this when the value changes, to retry.
		if self._retry == nil then
			self._retry = Value(scope, 0)
		end
		use(self._retry)
		doCleanup(buildScope)
		table.clear(buildScope)
		return nil
	end)
	return setmetatable(self, SUB_OBJECT_META) :: any
end

local distributorClass = {}
distributorClass.type = "Graph"
distributorClass.kind = "ForValueStates.Distributor"
distributorClass.timeliness = "eager"
-- Nothing may depend on the distributor, so nothing can pull it while busy.
distributorClass.dependentSet = table.freeze {}

local DISTRIBUTOR_META = table.freeze {__index = distributorClass}

function distributorClass._evaluate(
	self: Distributor
): boolean
	if self.scope == nil then
		return false
	end
	-- Pulls the reconcile, which marks the keys whose values changed.
	depend(self, self._disassembly)
	local dirty = self._list.dirty
	-- Always returns false, so its last change time stays put and it checks
	-- the dirty set whenever it is invalidated, whatever the clock says.
	if next(dirty) == nil then
		return false
	end
	local roots: {Types.GraphObject} = {}
	for subObject in dirty do
		if subObject.maybeScope == nil then
			continue
		end
		local valueState = subObject._valueState
		if valueState ~= nil then
			if valueState.scope ~= nil and not isSimilar(valueState._EXTREMELY_DANGEROUS_usedAsValue, subObject.inputValue) then
				valueState._EXTREMELY_DANGEROUS_usedAsValue = subObject.inputValue
				table.insert(roots, valueState)
			end
		elseif subObject._failed and subObject._retry ~= nil then
			subObject._retry._EXTREMELY_DANGEROUS_usedAsValue += 1
			table.insert(roots, subObject._retry)
		end
	end
	table.clear(dirty)
	changeMany(roots)
	return false
end

table.freeze(distributorClass)

local function ForValueStates<K, VI, VO, S>(
	scope: Types.Scope<S>,
	inputTable: Types.UsedAs<{[K]: VI}>,
	processor: Processor<K, VI, VO, S>
): Types.For<K, VO>
	if typeof(inputTable) == "function" then
		External.logError("scopeMissing", nil, "ForValueStates", "myScope:ForValueStates(inputTable, function(use, scope, key, value) ... end)")
	end
	local list: List = {
		dirty = {},
		warned = false
	}
	local self = For(
		scope,
		inputTable,
		function(scope, initialKey, initialValue)
			return SubObject(scope, initialKey, initialValue, processor, list)
		end
	)

	-- Created after the For object, so older than every child it builds.
	local distributor: Distributor = setmetatable(
		{
			createdAt = os.clock(),
			dependencySet = {},
			lastChange = nil,
			scope = scope,
			validity = "invalid",
			_disassembly = (self :: any)._disassembly,
			_list = list
		},
		DISTRIBUTOR_META
	) :: any
	local destroy = function()
		distributor.scope = nil
		for dependency in pairs(distributor.dependencySet) do
			dependency.dependentSet[distributor] = nil
		end
		-- A change that already queued the distributor would otherwise pull
		-- the destroyed disassembly, which would reconcile and subscribe to
		-- the input again.
		table.clear(distributor.dependencySet)
	end
	distributor.oldestTask = destroy
	nicknames[distributor.oldestTask] = "ForValueStates (internal distributor)"
	table.insert(scope, destroy)

	-- Eagerly evaluated objects need to evaluate themselves so that they're
	-- valid at all times. This reconciles the input, but builds no children
	-- until the list is read.
	evaluate(distributor, true)

	return self
end

return ForValueStates