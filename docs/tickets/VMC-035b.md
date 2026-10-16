# VMC-035b — Item merging

Status: In progress; automatic motion remains VMC-035a6's separate gate.

Acceptance: nearby compatible item entities combine with conserved counts and
components, native recipient selection, age/delay and stack limits. Full,
infinite-age, permanent-delay, expired, differently targeted or incompatible
entities refuse. Compare actual pinned26.3 `ItemEntity.isMergable`, `tryToMerge`,
`areMergable`, `merge` and bounding-box contact, including custom stack sizes.

First checkpoint: pure native-verified pair kernel and bounded, atomic same-owner
plans with fresh handles. Preserve the recipient's position/velocity/UUID and
ownership generation; remove exhausted donors and retain birth/handoff receipts.
The caller must persist the whole result before publishing. Cross-owner merging
needs explicit authority transfer; published views cannot authorize mutation.

Client scenario after live composition: actual Q drops combine, unlike components
remain separate, whole-stack/capacity boundaries conserve totals, and fresh
reconnect preserves the result. One dedicated tester owns the verdict. Kernel
checks alone do not complete the graphical/live gate.

Reference: pinned26.3 bytecode `ItemEntity`, cached privately as
`.local/item-entity-bytecode.txt`. Native combined counts above the effective
maximum refuse rather than partially merge; entity merging additionally caps the
recipient at64. Equal counts select the other entity. Recipient age is the minimum
and pickup delay the maximum. Search expands the item AABB by(0.5,0,0.5).

Kernel checkpoint:30 affected checks pass(seed349462), including stale/batch
refusal, effective identity, custom99/cap64, replay and retained outgoing/incoming/
birth history.1,881 actual native pair callbacks and90 AABB boundaries match;
raw `.local/item-merge-native{.json,.log,-check.log}` and targeted log remain
ignored. The isolated oracle compilation avoids the concurrent full-suite Java
output directory. Live discovery/scheduling, durable owner composition, cross-owner
merging and actual-client verification remain open; checkpoint stays local.

Durable owner API checkpoint: trusted same-owner pairs now plan on the bounded
item worker pool with a250ms acceptance deadline, freeze conflicting item updates
and publish only after the leased writer acknowledges one atomic file.50 affected
checks pass(seed861324), `.local/item-merge-region-targeted.log`: paused writes,
no early publication, competing/stale/refused work, pool saturation, failed writes
and owner recovery retain exact stacks/receipts. Automatic discovery and graphical
merging remain open; this checkpoint stays local.

Automatic checkpoint: immutable identity groups discover≤32 disjoint pairs outside
the owner, at most every200ms. Physical stamps skip unchanged populations; new
births/motion/stack edits wake discovery. Movement receives priority, discovery
runs after accepted motion (or while resting), and failures invalidate the stamp
for bounded retry.41 affected checks pass(seed44132), including automatic merge,
idle counters/no jobs, incompatible names and new-birth wake;
`.local/item-merge-automatic-targeted.log`.

`bench/item_simulation.exs` now spaces items2 blocks apart to retain populations
with merging enabled; this differs from the earlier workload.2048 moving items
measured19.93–20.43 updates/s in2s windows, no busy/refusal/timeout;2048 resting
items used no geometry/merge jobs. `.local/item-merge-cadence-bench-01.log`.
`bench/item_merging.exs` includes owner load,5ms convergence polling and durable
writes:256 coincident stone1 items per owner converge in2.11–2.13s across1/8
owners, preserving256 items as five native-compatible residual stacks.32 items
with4KiB components converge in0.91–0.92s. Final idle windows have zero geometry/
merge jobs; runtime/disk UUIDs and stacks agree. Use run02 (run01 measured an early
count threshold): `.local/item-merge-bench-02.log` and matching ignored datasets.
These are local workloads without sockets/pickup/cross-owner merging, not a server
comparison. Actual graphical/live integration gates remain pending.
