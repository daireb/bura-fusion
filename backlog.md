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

## Identity-keyed value states

`ForValueStates` keys each child by its key, so a child's own state follows the key. Lists of items with their own identity stay on `ForValues` over ids or `ForPairs` keyed by id, where a child that needs its position has to look it up from shared state, so a reorder reaches every child. The dual would key children by item and pass the position as state, as Solid's `<For>` passes a reactive index, so a reorder updates only the children that moved. Deferred until a list needs it.

Acceptance: a child follows its item across reorders without rebuilding, receives its position as state that changes only when the item moves, and is cleaned up when its item leaves; existing For objects are unchanged; specs mirror the `ForValueStates` ones.
