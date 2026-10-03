--!strict
--!nolint LocalUnused
--!nolint LocalShadow
local task = nil -- Disable usage of Roblox's task scheduler

--[[
	Constructs and returns a new For state object which builds and keeps one
	child per identity, passing each child its key and item as state objects.

	The identify callback names each item's identity: its key, the item
	itself, or a field such as an id. The processor runs once per identity and
	receives the key and the item as read-only state objects, followed by the
	identity itself. When an item changes or moves to another key, those state
	objects are updated and the child stays, where ForPairs and ForValues would
	run the processor again. Items with the same identity are matched to
	children in iteration order. Keys pass through, and a nil output leaves a
	hole; when the input is an array, holes close up in order.

	The processor runs inside a computed, as in every For object, so any state
	it uses at the top level runs it again. A child built again because it used
	its own key or item state that way logs a warning, once per list.

	Implementation notes:
	- The reconciler matches items to children by identity in one pass, and
	  only marks children whose key or item changed as dirty, so no state
	  object is written inside the reconcile.
	- One eager distributor per list writes the dirty children's state objects
	  as a single change, so a reader of several children sees one consistent
	  update. It is created right after the For object, so it is older than
	  every child, and its change joins the creation-ordered eager pass that is
	  running. Nothing can depend on it, so it is never pulled while busy.
	- The distributor pulls the reconciler, so unlike other For objects the
	  input is reconciled at construction and on every change, even when
	  nothing reads the list. Children still build only when it is read.
	- A child never changes identity, so its state objects live as long as the
	  child and survive a rebuild. A processor that errors leaves a hole, and
	  runs again when its key or item changes.
]]

local Package = script.Parent.Parent
local Types = require(Package.Types)
local External = require(Package.External)
-- Graph
local changeMany = require(Package.Graph.changeMany)
local depend = require(Package.Graph.depend)
local evaluate = require(Package.Graph.evaluate)
-- State
local Value = require(Package.State.Value)
local Computed = require(Package.State.Computed)
local castToState = require(Package.State.castToState)
local peek = require(Package.State.peek)
-- Logging
local parseError = require(Package.Logging.parseError)
-- Memory
local doCleanup = require(Package.Memory.doCleanup)
local deriveScope = require(Package.Memory.deriveScope)
-- Utility
local isSimilar = require(Package.Utility.isSimilar)
local nameOf = require(Package.Utility.nameOf)
local never = require(Package.Utility.never)
local nicknames = require(Package.Utility.nicknames)

type Identify<K, VI, I> = (key: K, item: VI) -> I
type Processor<K, VI, VO, I, S> = (Types.Use, Types.Scope<S>, Types.StateObject<K>, Types.StateObject<VI>, I) -> VO?

type Child = {
	scope: Types.Scope<unknown>?,
	key: unknown,
	item: unknown,
	keyState: Types.Value<unknown>,
	itemState: Types.Value<unknown>,
	output: Types.Computed<unknown>,
	failed: boolean,
	-- The next child with the same identity, in iteration order.
	nextDuplicate: Child?
}

type List = {
	dirty: {[Child]: true},
	warnedStateUsed: boolean
}

type Reconciler = Types.GraphObject & {
	_inputTable: Types.UsedAs<{[unknown]: unknown}>,
	_identify: Identify<unknown, unknown, unknown>,
	_processor: Processor<unknown, unknown, unknown, unknown, unknown>,
	-- The first child of each identity.
	_children: {[unknown]: Child},
	-- The number of items when the input is an array, so holes close up.
	_arrayLength: number?,
	-- Whether the last reconcile left out an item it could not identify.
	_skipped: boolean,
	_list: List
}

type Distributor = Types.GraphObject & {
	_reconciler: Reconciler,
	_list: List
}

type Self<K, VO> = Types.For<K, VO> & {
	_reconciler: Reconciler
}

local function Child<K, VI, VO, I, S>(
	scope: Types.Scope<S>,
	identity: I,
	key: K,
	item: VI,
	processor: Processor<K, VI, VO, I, S>
): Child
	local self = {} :: any
	self.scope = scope
	self.key = key
	self.item = item
	self.failed = false
	self.nextDuplicate = nil
	-- Created before the computed that uses them, so that they outlive it.
	self.keyState = Value(scope, key)
	self.itemState = Value(scope, item)
	self.output = Computed(scope, function(use, buildScope): VO?
		self.failed = false
		local ok, outputValue = xpcall(processor, parseError, use, buildScope, self.keyState, self.itemState, identity)
		if ok then
			return outputValue
		end
		local error: Types.Error = outputValue :: any
		error.context = `while processing key {tostring(self.key)}`
		External.logErrorNonFatal("callbackError", error)
		doCleanup(buildScope)
		table.clear(buildScope)
		-- Runs the processor again when the key or item changes.
		self.failed = true
		use(self.keyState)
		use(self.itemState)
		return nil
	end)
	return self
end

local function cleanupChild(
	child: Child?
): ()
	while child ~= nil do
		local scope = child.scope
		if scope ~= nil then
			-- Cleared before the cleanup runs, so that nothing it sets off can
			-- clean this child again.
			child.scope = nil
			doCleanup(scope)
		end
		child = child.nextDuplicate
	end
end

local reconcilerClass = {}
reconcilerClass.type = "Graph"
reconcilerClass.kind = "ForEach.Reconciler"
reconcilerClass.timeliness = "lazy"

local RECONCILER_META = table.freeze {__index = reconcilerClass}

function reconcilerClass._evaluate(
	self: Reconciler
): boolean
	if self.scope == nil then
		return false
	end
	local outerScope = self.scope :: Types.Scope<unknown>
	local inputState = castToState(self._inputTable)
	if inputState ~= nil then
		if inputState.scope == nil then
			External.logError(
				"useAfterDestroy",
				nil,
				`The input {nameOf(inputState, "table")}`,
				`the ForEach object that is watching it`
			)
		end
		depend(self, inputState)
	end

	local oldChildren = self._children
	local newChildren: {[unknown]: Child} = {}
	local lastDuplicates: {[unknown]: Child}? = nil
	local dirty = self._list.dirty
	local count = 0
	local maxIndex = 0
	local isArray = true
	local skipped = false
	for key, item in peek(self._inputTable) do
		count += 1
		if isArray then
			if typeof(key) == "number" and key >= 1 and key % 1 == 0 then
				maxIndex = math.max(maxIndex, key)
			else
				isArray = false
			end
		end
		local ok, identity = xpcall(self._identify, parseError, key, item)
		if not ok or identity == nil or identity ~= identity then
			-- Logs only the first item left out on each change.
			if not skipped then
				if ok then
					External.logErrorNonFatal("forEachIdentityMissing", nil, tostring(key))
				else
					local error: Types.Error = identity :: any
					error.context = `while identifying key {tostring(key)}`
					External.logErrorNonFatal("callbackError", error)
				end
				skipped = true
			end
			continue
		end
		-- Take this identity's oldest unmatched child, so that repeated
		-- identities keep their order.
		local child = oldChildren[identity]
		if child ~= nil then
			oldChildren[identity] = child.nextDuplicate :: any
			child.nextDuplicate = nil
			if child.key ~= key then
				child.key = key
				dirty[child] = true
			end
			if child.item ~= item then
				child.item = item
				dirty[child] = true
			end
		else
			child = Child(deriveScope(outerScope), identity, key, item, self._processor)
		end
		local first = newChildren[identity]
		if first == nil then
			newChildren[identity] = child
		else
			if lastDuplicates == nil then
				lastDuplicates = {}
			end
			local lastDuplicates = lastDuplicates :: {[unknown]: Child}
			local last = lastDuplicates[identity] or first
			last.nextDuplicate = child
			lastDuplicates[identity] = child
		end
	end
	self._children = newChildren
	self._arrayLength = if isArray and maxIndex == count then count else nil
	self._skipped = skipped
	-- Children left unmatched lost their item. They are cleaned last, because
	-- a cleanup may destroy this list, which then cleans the children above.
	for _, child in oldChildren do
		cleanupChild(child)
	end

	return true
end

table.freeze(reconcilerClass)

local distributorClass = {}
distributorClass.type = "Graph"
distributorClass.kind = "ForEach.Distributor"
distributorClass.timeliness = "eager"
-- Nothing may depend on the distributor, so nothing can pull it while busy.
distributorClass.dependentSet = table.freeze {}

local DISTRIBUTOR_META = table.freeze {__index = distributorClass}

local function write(
	list: List,
	roots: {Types.GraphObject},
	child: Child,
	state: Types.Value<unknown>,
	newValue: unknown,
	name: string
): ()
	local oldValue = state._EXTREMELY_DANGEROUS_usedAsValue
	-- The reference check comes first, so a table that is not frozen is not
	-- written again just because it moved.
	if oldValue == newValue or isSimilar(oldValue, newValue) then
		return
	end
	state._EXTREMELY_DANGEROUS_usedAsValue = newValue
	table.insert(roots, state)
	if not list.warnedStateUsed and not child.failed and child.output.dependencySet[state] then
		list.warnedStateUsed = true
		External.logWarn("forEachStateUsed", name, tostring(child.key), name)
	end
end

function distributorClass._evaluate(
	self: Distributor
): boolean
	if self.scope == nil then
		return false
	end
	-- Pulls the reconcile, which marks the children whose key or item changed.
	depend(self, self._reconciler)
	local list = self._list
	local dirty = list.dirty
	-- Always returns false, so its last change time stays put and it checks
	-- the dirty set whenever it is invalidated, whatever the clock says.
	if next(dirty) == nil then
		return false
	end
	local roots: {Types.GraphObject} = {}
	for child in dirty do
		if child.scope == nil then
			continue
		end
		write(list, roots, child, child.keyState, child.key, "key")
		write(list, roots, child, child.itemState, child.item, "item")
	end
	table.clear(dirty)
	-- Joins the eager pass this distributor runs in, so the children's eager
	-- objects keep their creation order with the rest of that pass.
	changeMany(roots)
	return false
end

table.freeze(distributorClass)

local class = {}
class.type = "State"
class.kind = "For"
class.timeliness = "lazy"

local METATABLE = table.freeze {__index = class}

function class.get<K, VO>(
	_self: Self<K, VO>
): never
	External.logError("stateGetWasRemoved")
	return never()
end

function class._evaluate<K, VO>(
	self: Self<K, VO>
): boolean
	if self.scope == nil then
		return false
	end
	local reconciler = self._reconciler
	depend(self, reconciler)
	local output: {[unknown]: unknown} = self._EXTREMELY_DANGEROUS_usedAsValue
	table.clear(output)
	-- An item left out for want of an identity leaves a hole like a nil
	-- output.
	local hasHoles = reconciler._skipped
	for _, child in reconciler._children do
		local child: Child? = child
		while child ~= nil do
			depend(self, child.output)
			local outputValue = peek(child.output)
			if outputValue == nil then
				hasHoles = true
			else
				output[child.key] = outputValue
			end
			child = child.nextDuplicate
		end
	end
	-- Holes in an array close up in order. Other keys never move, so a map
	-- with number keys keeps them.
	local arrayLength = reconciler._arrayLength
	if hasHoles and arrayLength ~= nil then
		local output: {[number]: unknown} = output :: any
		local moveToIndex = 1
		for moveFromIndex = 1, arrayLength do
			local outputValue = output[moveFromIndex]
			if outputValue == nil then
				continue
			end
			-- The ordering is important in case the indices are the same
			output[moveFromIndex] = nil
			output[moveToIndex] = outputValue
			moveToIndex += 1
		end
	end
	return true
end

table.freeze(class)

local function ForEach<K, VI, VO, I, S>(
	scope: Types.Scope<S>,
	inputTable: Types.UsedAs<{[K]: VI}>,
	identify: Identify<K, VI, I>,
	processor: Processor<K, VI, VO, I, S>
): Types.For<K, VO>
	if typeof(inputTable) == "function" then
		External.logError("scopeMissing", nil, "ForEach", "myScope:ForEach(inputTable, function(key, item) ... end, function(use, scope, key, item) ... end)")
	elseif typeof(identify) ~= "function" or typeof(processor) ~= "function" then
		External.logError("forEachIdentifyMissing")
	end
	local list: List = {
		dirty = {},
		warnedStateUsed = false
	}

	local reconciler: Reconciler = setmetatable(
		{
			createdAt = os.clock(),
			dependencySet = {},
			dependentSet = {},
			scope = scope,
			validity = "invalid",
			_inputTable = inputTable,
			_identify = identify,
			_processor = processor,
			_children = {},
			_arrayLength = nil,
			_skipped = false,
			_list = list
		},
		RECONCILER_META
	) :: any
	local destroyReconciler = function()
		reconciler.scope = nil
		for dependency in pairs(reconciler.dependencySet) do
			dependency.dependentSet[reconciler] = nil
		end
		-- Anything that still pulls the reconciler then pulls nothing.
		table.clear(reconciler.dependencySet)
		for _, child in reconciler._children do
			cleanupChild(child)
		end
	end
	reconciler.oldestTask = destroyReconciler
	nicknames[reconciler.oldestTask] = "ForEach (internal reconciler)"
	table.insert(scope, destroyReconciler)

	local self: Self<K, VO> = setmetatable(
		{
			createdAt = os.clock(),
			dependencySet = {},
			dependentSet = {},
			scope = scope,
			validity = "invalid",
			_EXTREMELY_DANGEROUS_usedAsValue = {},
			_reconciler = reconciler
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
	nicknames[self.oldestTask] = "ForEach"
	table.insert(scope, destroy)

	-- Created after the For object, so older than every child it builds.
	local distributor: Distributor = setmetatable(
		{
			createdAt = os.clock(),
			dependencySet = {},
			lastChange = nil,
			scope = scope,
			validity = "invalid",
			_reconciler = reconciler,
			_list = list
		},
		DISTRIBUTOR_META
	) :: any
	local destroyDistributor = function()
		distributor.scope = nil
		for dependency in pairs(distributor.dependencySet) do
			dependency.dependentSet[distributor] = nil
		end
		-- A change that already queued the distributor would otherwise pull
		-- the reconciler.
		table.clear(distributor.dependencySet)
	end
	distributor.oldestTask = destroyDistributor
	nicknames[distributor.oldestTask] = "ForEach (internal distributor)"
	table.insert(scope, destroyDistributor)

	-- Eagerly evaluated objects need to evaluate themselves so that they're
	-- valid at all times. This reconciles the input, but builds no children
	-- until the list is read.
	evaluate(distributor, true)

	return self
end

return ForEach :: Types.ForEachConstructor