# Bura Fusion

Private derivative of [dphfox/Fusion](https://github.com/dphfox/Fusion), based on `v0.3-beta` (`77e603534ff4013f4049611826ff0309d6000b15`). The original MIT license and attribution are retained. Original documentation lives under `docs/` and describes the baseline.

## Focused changes

- `New` preserves Roblox engine defaults and applies only caller-supplied properties. This deliberately differs from Fusion 0.3: visual defaults belong in the consuming app's styles, and behavioral choices such as `ResetOnSpawn`, `ClearTextOnFocus` and `Anchored` must be explicit where needed. There is no defaults flag or global configuration.
- `[Fusion.Tag "Name"] = enabled` accepts a boolean or Fusion state. Backported from original commit `09b9f0a` with its lifetime formatter. It owns the named tag while bound; avoid multiple writers to the same tag. Static false does not remove a pre-existing tag. Hydrate retains its original owning/destructive cleanup semantics.
- Collection matching preserves surviving sub-objects before reusing unmatched entries, including false keys. This supports stable virtual-list cells.
- An observer or tween destroyed during a change no longer runs or subscribes again in that change. A destroyed observer also drops what it watched, so the change no longer pulls it, and an observer calls no more listeners once one of them destroys it. In Fusion 0.3, one queued before an older object destroyed it still runs: the dead callback fires and the object subscribes again, leaking a subscription per change, and pulling a destroyed For object made the list reconcile and subscribe to its input again. This happens whenever an older consumer tears down a scope that holds one, as when `[Children]` re-runs a computed whose scope owns an observer, a bound property or a For object, or a For object removes or rebuilds an entry built after its consumer. Listeners that only ever fired that way, such as an `onChange` inside a computed that `[Children]` re-runs, no longer fire. Springs get the same check for uniformity; a destroyed spring only subscribed again to its own stopwatch, which leaked nothing.
- `Graph/changeMany` (internal, not exported) changes several graph objects as one change: their dependents are invalidated in one walk, and each eager object runs at most once, in creation order, after all of them have changed. Called while a pass of eager objects is running, as from an eager object's own evaluation, it joins that pass: its eager objects run in creation order among the ones still waiting, and the caller is no longer busy when they run. `change` and `changeMany` share Fusion's walk, moved unchanged into `Graph/propagate`; only the eager pass changed, so that it can be joined.
- `ForEach` is a new For object that builds and keeps one child per identity, which the caller chooses, and passes each child its key and item as state objects. See below.

There is no new graph, mounting framework, stylesheet cascade, or unified New/Hydrate API.

## ForEach

`scope:ForEach(input, identify, function(use, scope, key, item, identity) ... end)` builds and keeps one child, the processor's output, per identity. Here an item is an entry's value, as in `for key, item in input`. `identify(key, item)` returns the entry's identity. The processor runs once per identity and receives the key and the item as read-only state objects, then the identity itself as a plain value. When an item changes or moves to another key, its states are updated and the child stays, where `ForPairs` and `ForValues` would run the processor again. A child never changes identity: when a key gets an item with another identity, it gets that identity's child or a new one, never the old child, which is cleaned up unless its identity moved elsewhere. Keys pass through. New identities build when the list is read. Unlike other For objects, the input is reconciled at construction and on every change even when nothing reads the list, so removed children are cleaned up then, and a destroyed input errors at construction.

**Choose the identity.** It is required, and arguments come key first, as in `ForPairs`.

- **By item**, for ids, Instances and other stable references: `function(_, item) return item end`. The item state never changes; the key state is the position. This replaces `table.find(use(ids), id)` inside a `ForValues` processor.
- **By field**, for records from snapshots or an `{[id]: record}` map: `function(_, record) return record.uid end`. Both states change. It needs no id list and per-row lookup, and gives the position as state.
- **By key**, only when the child should follow the slot, such as pool cells, numbered slots or star ratings: `function(key) return key end`. The key state never changes, and a child's own state (hover, springs, tweens) stays with the slot when its item changes.

`identify` must be pure: it gets no `use`, runs once per entry on every change, and an identity that changes over time or a fresh table per call rebuilds children. Identities are matched as table keys: by value for primitives and `Vector3`, by reference for tables, Instances and Roblox datatypes such as `Color3`, `UDim2` and `CFrame`, so return an id or a string for those. `false` is an identity. An entry whose identity is nil or NaN, or whose `identify` errors, is left out as a hole until it can be identified; the first such entry is logged on each change. Whether a key or item changed is checked with `==`, as in other For objects, so an item's `__eq` applies there.

**Read the states below the top level,** in a Computed or a bound property. A top-level `peek` of the key or item state goes stale unless the identity fixes that state; the identity argument never changes and is safe to use anywhere. A direct top-level `use` of a state that changes builds the child again and logs a one-time `forEachStateUsed`; a top-level use through another state object, such as a Computed of it, is not caught. The processor returns only the output: one carried over from `ForPairs` that still returns `key, output` logs `forEachExtraOutput` once, and its key is used as the output.

**Repeated identities** are matched in iteration order: the k-th entry with an identity takes the k-th child it had. In arrays that is index order. In maps it is each snapshot table's own iteration order, so equal-identity children in a map can swap keys between snapshots, which writes their key states but builds nothing. Nothing collides and nothing is logged.

**Holes.** A nil output, a processor that errors or an entry left out leaves a hole. When the input is an array, with keys 1 to n, holes close up in order, including a hole at index 1, so the output stays an array. Other keys never move. This differs from other For objects, which close holes in any number keys between the smallest and the largest. A processor that errors runs again when its key or item changes, or when a state it used before erroring changes.

**Updates are consistent.** One internal eager object per list writes every changed key and item state in a single `changeMany`, which joins the eager pass that is running. So the children's observers run in creation order with every other eager object in that change: an observer the parent created after the list runs first and can tear the list down before they react, and an item's observer can change the list's input, for example to remove its own entry. The limit is an eager object created before the list, or anything such an object reads: if it reads a key or item state as well as other state from the same change, it runs before the write and sees one stale value before it runs again. That includes a child of another list that is older than this one. `identify`, processors and the cleanup of removed children run while the list is updating, so writing its input from them is a cycle, as in other For objects.

**Cost.**
- A move writes only the moved children's key states, but inserting at the front of n items writes n key states.
- With records from fresh snapshot tables, every item state is written on every snapshot, so every item reader runs again, as with an id list and a per-row lookup. Records kept by reference are not written.
- A child's states live in its scope and its readers in the build scope, so each read takes Fusion's cross-scope lifetime check, as reading any outer state does.
- Replacing every identity builds fresh children, where `ForValues` recycles its leftover sub-objects; a search result list that rarely keeps identities and does not need positions is cheaper on `ForValues`.

**It does not cover selection fan-out,** where every child compares one shared state such as the selected id.

### Which to use

| You want | Use |
|---|---|
| A derived table, or new output keys | `ForPairs`, `ForValues` or `ForKeys` |
| A child per id that does not need its position | `ForValues` over the ids, as today |
| A child per item that needs its position as state | `ForEach` by item |
| A child per record, without an id list and a per-row lookup | `ForEach` by field, or by key for an `{[id]: record}` map |
| A pool of cells, numbered slots or star ratings | `ForEach` by key |
| Search results that rarely keep their items | `ForValues` |

`ForPairs`, `ForValues` and `ForKeys` map data, and `ForValues` over ids already keeps each child through reorders, so existing lists need no migration. Reach for `ForEach` when a child needs its position or its record as state, or when a pool re-points its children. A pooled virtual grid stays by key, with each slot holding a uid that keeps its slot while visible, rather than `ForEach` by uid over the visible window, which builds every row that enters.

### Upstream and the existing For objects

This is the fork's first constructor with no upstream origin. It borrows one idea from upstream's open issue `dphfox/Fusion#220`: passing keys and values to processors as state objects. Otherwise it is a keyed list like Solid 2's `For` with a key function, Svelte 5's keyed `each` and Angular's `@for` with `track`. Unlike the issue's proposal, it never hands a child to another identity, treats a top-level `use` of its own states as a mistake, uses its own reconciler rather than the shared disassembly, and has no output keys, so it cannot stand in for `ForKeys` or `ForPairs`.

`ForPairs`, `ForValues` and `ForKeys` are unchanged. Rebuilding them over `ForEach` is recorded in backlog.md: it would need an output-key stage, would make them reconcile eagerly, and must first pass a randomized differential proving identical behaviour.

## Development

Consumers should pin this private Git repository to an exact commit using pesde (`repo` and `rev`). Installation requires Git access to this repository; registry authentication is separate. See [backlog.md](backlog.md) for deferred work.

Build tests with `rojo build test-runner.project.json -o /tmp/fusion-tests.rbxl`, open the place in Studio and Play. The suite uses the bundled TestEZ and deterministic SpecExternal scheduler. Native styles also require a client integration check; a headless build does not establish engine styling behavior.
