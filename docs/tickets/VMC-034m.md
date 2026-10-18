# VMC-034m — Live regional cooking

Status: Implemented; actual-client acceptance pending. Depends on validated
[VMC-034k](VMC-034k.md) menus and [VMC-034l](VMC-034l.md) batches.

Loaded regional processors ignite, advance/cool, complete recipes and publish native
properties/lit states. Fuel, remainders, outputs and recipe uses commit together.
XP-bearing output remains refused until its award protocol exists; this ticket
cannot close the whole furnace feature.

## Ownership and persistence

One existing region clock dispatches at most one bounded cooking job per owner.
Workers select activity, simulate up to 1,024 processors and encode candidate frames.
Planning reserves no gameplay write slot: item motion and menu admission continue.
Container/block snapshots and owner epoch/token fence publication. Competing menu
writes win over an obsolete plan. Created remainders merge into current item state
without replacing newer motion/counters; capacity and UUID conflicts reject safely.

Stable processors sleep until external changes. Capacity-refused entries retry at
most once per second, or when capacity changes, while other processors continue.
Worker failure/timeout discards speculation and backs off without retiring gameplay.

Progress keeps content revisions stable and coalesces a separate viewer generation.
Unchanged inventories receive only four native properties. Timers checkpoint after
1,000 ms, following that turn's active step rather than skipping it, and flush
explicitly or on clean shutdown. Queued joint writes retain their successor snapshot;
timer-only writes preserve the clean-shutdown item-motion flush. A crash may rewind
uncheckpointed timers, never committed items.
Lit/content/recipe changes use the existing joint block/item/container WAL, including
content-changing no-op block fences. Publication follows acknowledgement; uncertainty
retires the owner. Lit toggles retain viewers and unchanged-content permits.

## Verification

Reference: pinned Mojang 26.3 server SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, native furnace `serverTick` and codecs.
`CookingTickOracle` plus `scripts/check_cooking_batch.exs` verifies 15,630 native
states through runtime selection, exact recipes/remainders, lit frames and revisions.
Raw evidence: `.local/cooking-runtime-native.json`,
`cooking-runtime-native-oracle.log`, `cooking-runtime-native-comparison.log`.

Targeted owner/runtime checks cover all three native durations, activity/backoff,
concurrent item motion and menu admission, stale blocks/contents, late timeout,
acknowledgement-before-publication, periodic/explicit checkpoints, exact shutdown
retention, queued-write ordering and actual region-clock/item-physics composition.
The base affected set passes 109 checks (seed494027). Focused follow-up checks cover
real-owner death behind a queued WAL, exact recovery, stale-epoch rejection and
checkpoint-step/shutdown/backoff ordering: 45 pass (seed354532), including the
13-test owner set. Changed-file
formatting and the public-tree audit pass. Logs:
`.local/cooking-runtime-{targeted,activity-tests,shutdown-tests}.log`.
Follow-up evidence: `.local/cooking-runtime-{replacement,checkpoint-order}-tests.log`.
No broad test/native-integration/production gate is due at this subticket boundary.

Matched pure-worker measurement: 1,024 stored entries, 64 or 1,024 active, ten warmups
and 100 alternating equal-result samples on ten schedulers. Reusing known activity
and remaining heat reduces sparse p50/p95 from 8.295/11.967 to 6.942/9.078 ms;
dense from 44.097/51.686 to 32.751/39.619 ms. Dense maximum remains 51.284 ms.
This excludes I/O, players and networking and establishes no server capacity claim.
Workload, baseline source, hashes and samples: `.local/cooking-runtime-bench.exs`,
`cooking-runtime-before.ex`, `cooking-runtime-bench.json`.

Separate owner observation measurement at `0cf793f`: 1,024 active furnaces with
timer checkpoints; 1,000 RPCs paced 1 ms while progress advances from 50 to 88.
p50/p95/max = 0.070/0.647/24.952 ms on ten schedulers. This excludes clients and
network load. Raw workload/results: `.local/cooking-owner-latency.{exs,json,log}`.

The prior batch-bound proof and property-byte measurements remain in private
`.local/cooking-batch-bench-whole.{exs,json}` and
`.local/cooking-progress-wire-bench.{exs,json,log}`; L's gate is closed at `bfac2bb`.
Frozen `cfd791e` baseline smoke passes: direct Java 26.3 join, flat terrain, `/stats`
and fresh logs. Dataset/report: `.local/client-tests/VMC-034m-reimplementation/baseline`.

## Pending client gate

Dedicated tester: fresh whole datasets and immutable implementation checkpoint.
Verify GUI ignition/progress/completion in furnace, smoker and blast furnace with
correct relative durations; depletion/full-output pause and wake; invalid fuel;
wet sponge/bucket; responsive transfers/cursor/offhand during cooking; dropped-item
motion; burnout retaining the menu; explicit XP-output refusal; fresh reconnect and
coordinated clean restart conserving source inventories, receipts and recipe uses.
Do not replace the tested checkpoint or restore one side of a committed transfer.
