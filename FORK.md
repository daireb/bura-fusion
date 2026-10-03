# Bura Fusion

Private derivative of [dphfox/Fusion](https://github.com/dphfox/Fusion), based on `v0.3-beta` (`77e603534ff4013f4049611826ff0309d6000b15`). The original MIT license and attribution are retained. Original documentation lives under `docs/` and describes the baseline.

## Focused changes

- `New` preserves Roblox engine defaults and applies only caller-supplied properties. This deliberately differs from Fusion 0.3: visual defaults belong in the consuming app's styles, and behavioral choices such as `ResetOnSpawn`, `ClearTextOnFocus` and `Anchored` must be explicit where needed. There is no defaults flag or global configuration.
- `[Fusion.Tag "Name"] = enabled` accepts a boolean or Fusion state. Backported from original commit `09b9f0a` with its lifetime formatter. It owns the named tag while bound; avoid multiple writers to the same tag. Static false does not remove a pre-existing tag. Hydrate retains its original owning/destructive cleanup semantics.
- Collection matching preserves surviving sub-objects before reusing unmatched entries, including false keys. This supports stable virtual-list cells.
- An observer, tween or spring destroyed during a change is not evaluated by that change. In Fusion 0.3 it still runs if an older object destroyed it after it was queued, as when `[Children]` re-runs a computed whose scope owned it: the dead callback fires and the object subscribes again, leaking a subscription per change.

There is no new graph, mounting framework, stylesheet cascade, or unified New/Hydrate API.

## Development

Consumers should pin this private Git repository to an exact commit using pesde (`repo` and `rev`). Installation requires Git access to this repository; registry authentication is separate. See [backlog.md](backlog.md) for deferred work.

Build tests with `rojo build test-runner.project.json -o /tmp/fusion-tests.rbxl`, open the place in Studio and Play. The suite uses the bundled TestEZ and deterministic SpecExternal scheduler. Native styles also require a client integration check; a headless build does not establish engine styling behavior.
