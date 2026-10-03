# Bura Fusion

Private derivative of [dphfox/Fusion](https://github.com/dphfox/Fusion), based on `v0.3-beta` (`77e603534ff4013f4049611826ff0309d6000b15`). The original MIT license and attribution are retained. Original documentation lives under `docs/` and describes the baseline.

## Focused changes

- `New` preserves Roblox engine defaults and applies only caller-supplied properties. This deliberately differs from Fusion 0.3: visual defaults belong in the consuming app's styles, and behavioral choices such as `ResetOnSpawn`, `ClearTextOnFocus` and `Anchored` must be explicit where needed. There is no defaults flag or global configuration.
- `[Fusion.Tag "Name"] = enabled` accepts a boolean or Fusion state. Backported from original commit `09b9f0a` with its lifetime formatter. It owns the named tag while bound; avoid multiple writers to the same tag. Static false does not remove a pre-existing tag. Hydrate retains its original owning/destructive cleanup semantics.
- Collection matching preserves surviving sub-objects before reusing unmatched entries, including false keys. This supports stable virtual-list cells.
- An observer or tween destroyed during a change no longer runs or subscribes again in that change. A destroyed observer also drops what it watched, so the change no longer pulls it, and an observer calls no more listeners once one of them destroys it. In Fusion 0.3, one queued before an older object destroyed it still runs: the dead callback fires and the object subscribes again, leaking a subscription per change, and pulling a destroyed For object made the list reconcile and subscribe to its input again. This happens whenever an older consumer tears down a scope that holds one, as when `[Children]` re-runs a computed whose scope owns an observer, a bound property or a For object, or a For object removes or rebuilds an entry built after its consumer. Listeners that only ever fired that way, such as an `onChange` inside a computed that `[Children]` re-runs, no longer fire. Springs get the same check for uniformity; a destroyed spring only subscribed again to its own stopwatch, which leaked nothing.
- `Graph/changeMany` (internal, not exported) changes several graph objects as one change: their dependents are invalidated in one walk, and each eager object runs at most once, in creation order, after all of them have changed. `change` and `changeMany` share Fusion's walk, moved unchanged into `Graph/propagate`.
- `ForValueStates` is a new For object that passes each value to its processor as a state object. See below.

There is no new graph, mounting framework, stylesheet cascade, or unified New/Hydrate API.

## ForValueStates

`scope:ForValueStates(input, function(use, scope, key, value) ... end)` keeps one child, the processor's output, per key of `input`. The processor runs once per key and receives the key's value as a read-only state object. When the value changes, that state object is updated and the child updates in place, where `ForPairs` and `ForValues` would run the processor again and rebuild it. Keys pass through, and nil outputs leave holes that are compacted in arrays, as in other For objects. New keys build when the list is read, removed keys are cleaned up, and a processor that errors leaves a hole and runs again when its value changes.

- **Use the value state below the top level,** in a Computed or a bound property. The processor runs inside a computed like every For processor, so `use(value)` at its top level runs it again on every change, and logs a one-time `forValueStatesValueUsed` warning.
- **Use it only where the key is the identity:** pool slots, numbered slots, star ratings, or maps keyed by id whose values are fresh records. Items with their own identity stay on `ForValues` or `ForPairs` keyed by id. Otherwise a child's own state, such as hover, springs or selection tweens, follows the slot rather than the item.
- **Updates are consistent inside the list.** One internal eager object per list writes every changed value state in a single `changeMany`, so a reader of several keys sees them change together. The limit is an object created before the list: if it reads a value state as well as other state from the same change, it runs before the write and sees one stale value per change before it runs again.
- **It does not cover selection-style fan-out,** where every child compares one shared state such as the selected id. A change to that state still reaches every child.

This is the fork's first constructor with no upstream origin. Upstream's open dphfox/Fusion#220 proposes passing keys and values to processors as state objects, with one For object replacing `ForKeys`, `ForValues` and `ForPairs` as the end state; it has not been built. `ForValueStates` is the fixed-key subset of that proposal, built as the dedicated object the maintainer suggested prototyping first. It changes no existing For object and no part of the graph.

## Development

Consumers should pin this private Git repository to an exact commit using pesde (`repo` and `rev`). Installation requires Git access to this repository; registry authentication is separate. See [backlog.md](backlog.md) for deferred work.

Build tests with `rojo build test-runner.project.json -o /tmp/fusion-tests.rbxl`, open the place in Studio and Play. The suite uses the bundled TestEZ and deterministic SpecExternal scheduler. Native styles also require a client integration check; a headless build does not establish engine styling behavior.
