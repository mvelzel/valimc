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
