# Backlog

## Spring sleeping

Investigate stopping updates for settled springs and waking them when the goal, speed, damping or velocity changes. Measure the current idle cost before choosing an implementation.

Acceptance: settled springs stop scheduling unnecessary work, wake correctly, preserve expected motion and final values, and clean up normally. Cover scalar and supported structured values with focused regressions and compare idle work before and after. This is separate from the initial UI fork release.

## Destroyed For reconciles

`State/For/Disassembly.luau` has no destroyed check, so a destroyed For object that something pulls reconciles and subscribes to its input again. Destroyed observers no longer pull anything, which closed every measured case, such as `[Children]` re-running `Computed(function(use, scope) use(store) return scope:ForPairs(store, ...) end)` (11 dependents of `store` after 10 sets instead of 2). A destroyed tween still pulls its goal, so a goal that reads a destroyed For object would still reach it. A `self.scope == nil` check at the top of `Disassembly._evaluate`, like the ones `For` and `Computed` have, closes it for every caller and passed all specs. Deferred because it changes the reconcile shared by every For object.

Acceptance: a For object destroyed during a change of its input neither reconciles nor subscribes again whatever pulls it, and the existing For specs and a randomized differential against the current For objects agree.

## Animation update step

`Animation/ExternalTime.luau` calls `change` on each timer while iterating `allTimers`, and destroying a timer removes it from that array. When an animation's observer destroys an animation registered earlier during the step, the array shifts and the next live animation skips that frame. Stock Fusion has the same loop.

Acceptance: destroying any animation during an update step leaves every other live animation updated that frame, pinned by a spec.

## Duplicate walking

The invalidation walk in `Graph/propagate.luau` appends a dependent once for every path that reaches it and walks on from it each time, so diamonds compound. In a Lune model of a pooled inventory grid (28 cells of 61 graph objects), one scroll frame marked 3419 entries for 1319 distinct objects (2.6x) and queued 1344 eager entries for 476. Marking each object invalid as the walk reaches it cut that to 1319 and 476 and the frame from 3.2 to 1.8 ms. That changes the walk every app relies on and does not remove it, so it is deferred. Upstream has the same code.

Acceptance: each object is listed and walked once per change, eager objects still run once each in creation order, the `change` property specs and a randomized differential against the current walk agree, and a diamond-heavy graph is measured before and after.

## Sticky recompute

`Graph/evaluate.luau` recomputes a target when a dependency's `lastChange` is newer than the target's, and a target's `lastChange` only moves when it meaningfully changes. So a computed that once recomputed to an equal value after a real input change recomputes again on every later invalidation. In an earlier Lune model of the grid (28 cells of 40 bound values) these grew from 0 to 104 to 444 recomputes per scroll frame, taking the frame from 3.6 to 6.9 ms. Upstream accepted a fix in dphfox/Fusion#398 and reverted it in #420 because it broke property tests. Per-edge change stamps, as Preact and Vue keep per link, kept the model at 0 and gave the same Lune spec results as stock, but why the upstream fix broke the property tests is not understood.

Acceptance: explain the #420 revert, stop a computed that recomputed to an equal value from recomputing until a dependency changes, pass the full suite in Studio, and compare recomputes per frame in a scroll-heavy UI before and after.

## Legacy For objects over ForEach

`ForKeys`, `ForValues` and `ForPairs` could become thin wrappers over `ForEach`, as upstream's maintainer suggested keeping the existing objects as sugar over a general one. They differ today in four ways:
- **Laziness.** `ForEach` reconciles its input on every change even when nothing reads it. Every existing list would turn eager: input computeds would run while unmounted, and a destroyed input would error at construction.
- **Output keys.** `ForKeys` and `ForPairs` return keys from the processor and log collisions. `ForEach` has no output-key stage, and a processor that returned `use(key)` would run again on every move.
- **Rebuild timing.** `ForPairs` rebuilds inside the For object's own evaluation. `ForEach` writes states from an eager object, which changes the order older observers see, and warns on the top-level `use` a wrapper would need.
- **Recycling.** The shared disassembly hands leftover sub-objects to new pairs; `ForEach` never hands a child to another identity.

`ForEach` by item matched `ForValues` on outputs and processor runs over 5,000 random steps, which says nothing about `ForKeys` or `ForPairs`.

Acceptance: an output-key stage designed first; a randomized differential agrees with the current objects on outputs, processor runs, cleanups and consumer fires across arrays, maps, repeated values, holes and errors; the laziness difference is resolved or accepted; and the existing For specs and the full suite in Studio pass.

## Sparse number keys in For

`State/For/Disassembly.luau` closes holes by walking every integer between the smallest and the largest number output key, then renumbers the keys from the smallest. A list keyed by user ids, about 1e10 apart, with one nil output takes time in proportion to the gaps and loses its keys; a copy of the loop took 273 ms for gaps of 1e7. `ForEach` closes holes only when its input is an array. Deferred because it changes output keys that existing lists may rely on.

Acceptance: number keys that are not an array keep their places, or closing holes costs time in proportion to the entries; the For specs and a randomized differential against the current For objects agree on arrays.

## Cross-scope lifetime checks

Reading a `ForEach` key or item state from an object the processor built crosses scopes: the state lives in the child's scope and the reader in the build scope. `Memory/whichLivesLonger` then scans both scopes and allocates three tables per read. In Lune, with every item of 2,000 changed, the `ForEach` prototype by key took 37-40 ms and 1.7 MB per update against 30-32 ms and 1.3 MB for a value state kept in the build scope. Reusing scratch tables would speed up every cross-scope read. Deferred until a profile of the game shows it matters.

Acceptance: the same lifetime warnings as now, and fewer allocations per cross-scope read, measured.
