# Bura Fusion

Private derivative of [dphfox/Fusion](https://github.com/dphfox/Fusion), based on `v0.3-beta` (`77e603534ff4013f4049611826ff0309d6000b15`). The original MIT license and attribution are retained. Original documentation lives under `docs/` and describes the baseline.

## Focused changes

- `New` preserves Roblox engine defaults and applies only caller-supplied properties. This deliberately differs from Fusion 0.3: visual defaults belong in the consuming app's styles, and behavioral choices such as `ResetOnSpawn`, `ClearTextOnFocus` and `Anchored` must be explicit where needed. There is no defaults flag or global configuration.
- `[Fusion.Tag "Name"] = enabled` accepts a boolean or Fusion state. Backported from original commit `09b9f0a` with its lifetime formatter. It owns the named tag while bound; avoid multiple writers to the same tag. Static false does not remove a pre-existing tag. Hydrate retains its original owning/destructive cleanup semantics.
- Collection matching preserves surviving sub-objects before reusing unmatched entries, including false keys. This supports stable virtual-list cells.
- An observer or tween destroyed during a change no longer runs or subscribes again in that change. A destroyed observer also drops what it watched, so the change no longer pulls it, and an observer calls no more listeners once one of them destroys it. In Fusion 0.3, one queued before an older object destroyed it still runs: the dead callback fires and the object subscribes again, leaking a subscription per change, and pulling a destroyed For object made the list reconcile and subscribe to its input again. This happens whenever an older consumer tears down a scope that holds one, as when `[Children]` re-runs a computed whose scope owns an observer, a bound property or a For object, or a For object removes or rebuilds an entry built after its consumer. Listeners that only ever fired that way, such as an `onChange` inside a computed that `[Children]` re-runs, no longer fire. Springs get the same check for uniformity; a destroyed spring only subscribed again to its own stopwatch, which leaked nothing.
- `Graph/changeMany` (internal, not exported) changes several graph objects as one change: their dependents are invalidated in one walk, and each eager object runs at most once, in creation order, after all of them have changed. `change` and `changeMany` share Fusion's walk, moved unchanged into `Graph/propagate`.

There is no new graph, mounting framework, stylesheet cascade, or unified New/Hydrate API.

## Development

Consumers should pin this private Git repository to an exact commit using pesde (`repo` and `rev`). Installation requires Git access to this repository; registry authentication is separate. See [backlog.md](backlog.md) for deferred work.

Build tests with `rojo build test-runner.project.json -o /tmp/fusion-tests.rbxl`, open the place in Studio and Play. The suite uses the bundled TestEZ and deterministic SpecExternal scheduler. Native styles also require a client integration check; a headless build does not establish engine styling behavior.
