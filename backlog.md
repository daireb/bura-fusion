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
