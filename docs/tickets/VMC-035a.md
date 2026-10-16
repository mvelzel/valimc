# VMC-035a — Dropped-item launch and motion

Status: Launch/motion kernels verified; live composition pending. October16,2026.
Parent: VMC-035.
Related: VMC-018c3.

Acceptance: drops leave the player's camera using accepted pose/eye height,
directed or scattered launch and native pickup delay. Continue through authoritative
gravity/collision and bounded replication; reconnect retains committed item state.
Keep retry receipts stable as items move/are consumed. Define cross-owner movement
and persistence before enabling live motion. No per-item process or client-owned
physics; sleeping/resting items should cost no unnecessary tick work.

First checkpoint: pure launch from supplied pose/eye height and four uniform native
float draws. Reference pinned26.3 `LivingEntity.createItemStackToDrop`,
`ItemEntity` and `Mth`. Actual native probe observes720 directed/scattered launches,
six yaws/five pitches/three eye heights/four seeds; world ID allocation controlled.
Raw `.local/DropLaunchProbe.java`, `.local/drop-launch-native.{json,log}`;
private inspection `.local/drop-{livingentity,entity}-bytecode.txt`. Native delay40;
launch starts at actual eyeY minus float32(0.3), with nonzero directed/scattered
velocity. Current preview instead freezes items using no-gravity metadata.

Actual client after composition: drop one then several items in a fresh whole
dataset, observe from source and distance, landing/pickup delay, changed poses,
reconnect and region-boundary conservation. Pure kernels alone do not fix the
stationary preview or complete this ticket. This foundation uses baseline smoke;
the live composition will require the full feature scenario.

Pure implementation passes three boundary/direction checks (seed847312) and720
native launch observations. Origin, vertical velocity and pickup delay match
exactly; horizontal libm jitter differs by at most4.34e-19, below the1e-15 bound.
The kernel consumes supplied random values, allocates no process and owns no item.
Native public driver `scripts/ItemDropOracle.java`; comparison `scripts/check_item_drop.exs`.
Raw `.local/{item-drop-targeted,drop-launch-check}.log`.

`ItemMotion.prepare/2` applies gravity or deep-fluid buoyancy before collision;
`finish/3` applies drag/friction to the supplied post-collision velocity, then the
item's downward ground bounce. Resting items can skip movement until a supplied
support refresh. Scheduling stays with BEAM owners rather than copying Java IDs.
Eight launch/motion tests pass (seed966618). Original `ItemMotionOracle` observes
1,152 actual `ItemEntity.tick` calls across stone/ice/slime friction, dry/water/lava,
four depth boundaries, grounded/gravity flags, refresh phases and four velocities.
Requests and post-step velocities match exactly. Collision and contacts are supplied;
base-tick effects, merging and lifecycle are excluded. Raw
`.local/item-motion-{final-targeted.log,public-native.json,public-native.log,public-check.log}`;
private inspection `.local/item-entity-bytecode.txt`. Both public probes also pass
through registered `java_tool.py` invocations and their Elixir checkers; raw
`.local/item-{drop,motion}-registered-{native.json,native.log,check.log}`.

[Saved motion](VMC-035a1.md) and [accepted-step replication](VMC-035a2.md) are
validated foundations. [Fenced travel batches](VMC-035a3.md) now compose sampled
geometry and motion; their actual-client gate follows. Next: automatic owner
scheduling, efficient motion checkpoints, resting/support wakeups and cross-owner handoff. Retain
source retry receipts after moves/pickups so old deliveries cannot recreate items.
Live composition remains pending. Frozen `f31f178` baseline client smoke passed:
actual flat-world join/render, walking/SDL look, log→four planks/returning two logs,
fresh reconnect with exact inventory/pose and `/stats`. Three owned launches
stopped; original full snapshot restored, source0/nil, zero edits/items/receipts,
four owners flushed. Module MD5s unchanged;736 tracked blobs rehashed. Frozen
compile and eight targeted tests pass; no broad suite/build rerun was needed for
these unreachable kernels. Report `.local/client-tests/VMC-035a/report.md`;
proof `.local/item-motion-kernel-proof.json`. This validates the foundation's
baseline only; live launch/landing/pickup and full item behavior remain open.

Inspiration: pinned Pumpkin `b0c48b2` (`entity/item.rs`) protects coupled merge
updates with ordered reservations; Steel `f6fb4e4` (`item_entity.rs`) keeps item
lifecycle state separate from common entity state. Use owner-local batch updates
and fenced cross-owner intents here, rather than copying their per-item locks/
atomics. Their constants/coverage are not the behavioral oracle; pinned native
observations above include float boundaries and directed-drop delay40. Keep
upstream checkouts and inspected bytecode private under ignored research paths.
