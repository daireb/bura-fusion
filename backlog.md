# Backlog

## Spring sleeping

Investigate stopping updates for settled springs and waking them when the goal, speed, damping or velocity changes. Measure the current idle cost before choosing an implementation.

Acceptance: settled springs stop scheduling unnecessary work, wake correctly, preserve expected motion and final values, and clean up normally. Cover scalar and supported structured values with focused regressions and compare idle work before and after. This is separate from the initial UI fork release.
