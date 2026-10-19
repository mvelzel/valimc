# VMC-034n4a — Supplied XP orb motion kernels

Status: **Done within unused supplied-kernel scope**, checkpoint `7d0a946`.
Part of [orb simulation](VMC-034n4.md). Basic output/pickup is complete in
VMC-034n5 and must not be reimplemented. These kernel/baseline gates are closed.

Slice: pure launch, acceleration, post-collision drag/bounce and age transition.
Owners supply authoritative contacts, selected target offset and post-move facts;
this introduces no live movement or mutable storage yet.

Acceptance:

- Observe pinned Mojang26.3 `ExperienceOrb` constructors/tick/water/attraction and
  compare native outputs bit-for-bit. Control RNG draws, contacts and collision
  callbacks, not the native arithmetic being measured.
- Cover directed launch and normalization thresholds, dry/embedded/no-gravity,
  water cap, lava float32 draws, target acceleration, support friction, bounce
  using pre-move Y, and age increment before the6,000-tick discard. Reject missing
  or unbounded inputs. No global state, RNG calls, tasks or per-orb processes.
- Keep immutable birth/adoption/consumption proofs unchanged. Geometry/current
  collection, escape, target selection, merge, durable moving bodies/expiry and
  moving-owner handoff remain separate gates before live simulation.
- Dedicated client baseline on the exact frozen checkpoint: join/terrain/stats,
  actual smelt/take/XP gain, empty output negatives and fresh reconnect retention.
  This unused kernel cannot claim visible launch/motion from that baseline.

Reference: Mojang26.3 server SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`,
`ExperienceOrb` constructors, `tick`, `followNearbyPlayer`, `setUnderwaterMovement`,
`getAirDrag`, `Entity.applyGravity` and `Vec3.normalize`. Private observations
stay under `.local/`; only original probes and Elixir implementation are public.

Checks: changed-file formatting, affected kernel/pickup tests, focused native
probe and delegated baseline. This subticket does not trigger broad checks.

Implemented: `Physics.OrbMotion` is pure bounded arithmetic, with explicit double
launch draws,24-bit lava draws and a supplied target offset. Water caps ascent
even with no gravity; embedded bodies skip dry gravity. Lava replaces prior
acceleration, then attraction applies. Friction scales every post-move axis;
landing bounce uses pre-move Y with a strict gravity threshold. Native normalize
uses the float32 value of1e-5, including the zero/underflow boundary. Age produces
a terminal decision at6,000; no storage or body removal is performed here.

Checks (2026-10-19): original `OrbMotionOracle` executes native constructors and
ticks; `check_orb_motion.exs` passes56 bit-exact launches,5,184 supplied-contact/
collision ticks and5 age boundaries. Includes stone/ice/honey, dry/water/lava,
embedded/no-gravity, target offsets, collision callbacks and RNG draw counts.
42 affected tests pass across the initial41/42 run (seed978238) and six corrected
kernel boundaries (seed674184). Correction canonicalizes integer velocity inputs
to doubles in the no-gravity/embedded branches; the native comparison still passes.
Raw observations/logs: `.local/orb-motion-{native.json,native.log,check.log,targeted.log,boundary.log}`.

Measurement at7d0a946: `.local/orb-motion-bench-7d0a946.{exs,json,log}` retains
source/script hashes,30 samples after5 warmups, AppleM4/10 schedulers and exact
workload. Mixed dry/water/lava/target/support preparation+finish+age p50/p95 is
119/228µs at128 records,461/770µs at512,2.81/4.45ms at2,816. Launch batches at
2,816 cost2.01/3.02ms. Pure arithmetic only: no geometry, RNG generation, I/O,
owners or sockets; shared host during GUI work. No TPS/capacity/comparative claim.

Actual Java26.3 baseline (2026-10-19): all three groups **PASS** on frozen7d0a946.
Dedicated tester joined terrain/stats, actually smelted/took one gold ingot,
observed XP11→12/bar4/9→5/9, repeated empty ordinary/Shift output negatives and
verified a fresh whole-world restart. Dataset `.local/client-tests/VMC-034n4a/world`
is a complete accepted N5 copy plus recorded raw gold1/coal1 fixture, with no
one-sided restore. Final flushed disk: gold11/steak3, XP12/level1/progress
0.555555522441864, three learned recipes, six awards/births/consumed units,
source/typed42, container sequence41, nil cursor/outbox, no active views. Prior
five immutable award/birth/consumption maps remain intact. Report and exact
fingerprints/reconciliation: `.local/client-tests/VMC-034n4a/{report.md,final-disk.log,reconciliation.log}`;
run01–02 retain client logs. No gameplay/protocol error; all owned clients/server
stopped,0players and flush:ok, port25565 clear. Baseline proves existing gameplay
preserved; unused kernels make no graphical launch/travel/fluid/expiry claim.

Next: [mutable body storage/terminal expiry](VMC-034n4b.md), followed by geometry,
live scheduling/admission/replication and moving-owner handoff. No live orb
simulation claim; do not repeat the completed arithmetic/baseline work.
