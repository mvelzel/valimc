# VMC-015b — Gravity and air drag

Status: Pure kernel verified; live integration pending. October 15, 2026.
Follows VMC-015a. Not Done.

Build the pure velocity update from pinned native behavior, then compose it with
bounded collision work and player-owned ticks. Known client displacement is an
observation; server velocity used by forces and speed checks is separate.

Acceptance: exact native velocity fixtures for gravity, ground friction, air drag,
levitation and friction bypass; meaningful boundaries and repeated-tick traces.
Before live integration, define tick/input order, late-frame policy, fencing and
the client's correction/impulse behavior. Delegate actual jump/drop/impulse and
ground/ceiling contact checks on a frozen checkpoint. Retain VMC-015a's distance
and persistence invariants. Pure arithmetic alone does not complete this ticket.

Reference: same pinned 26.3 jar/hash as VMC-015a; `LivingEntity.travelInAir`,
`computeModifiedFriction`, `getEffectiveGravity`, `Player.travel` and connection
`tickPlayer`. Controlled native fixtures must retain actual integration math while
observing supplied collision-resolved velocities. World/fluid/AI simulation is
outside that oracle, not outside the server goal.

Checkpoint: original `Physics.AirMotion.step/2` consumes explicit environment
facts and collision-resolved velocity. It preserves native float32 friction/drag
rounding, double gravity/levitation order and friction bypass. It does not move
players or replace known client movement with velocity. Bounded invalid facts fail.

Checks: three targeted tests, 7,776 bit-exact native cases and two accumulated
200-step native traces pass. The traces change ground contact, gravity and
levitation. Commands: `mix test test/air_motion_test.exs`,
`python3 scripts/java_tool.py AirMotionOracle .local/air-motion-native.json`,
`mix run --no-start scripts/check_air_motion.exs .local/air-motion-native.json`.
Logs: `.local/air-motion-{tests,native,check}.log`; raw fixtures stay ignored.

Next: define the player tick/input boundary and scratch simulation position before
composition. Keep velocity generation and owner/source fences with results;
accepted client positions and server corrections remain authoritative. Reuse one
bounded per-player geometry lane with explicit input priority and late-tick policy,
rather than adding an independent stream of overlapping queries. Delegate the
composed client gate after implementation. VMC-015c fixes the observed freezing
reset defect. Frozen `91caf387` client checks retain ordinary movement/flight as
the baseline alongside this unused kernel; they do not validate live forces.

Composition boundary: native connection `tickPlayer` runs `doTick` and restores
the accepted position. Evolve velocity against a scratch body, then retain the
accepted client anchor rather than advancing it twice. The packet handler applies
`jumpFromGround` on ground→air/upward input before collision movement. Native
`Entity.restituteMovementAfterCollisions` resolves velocity before air drag;
its bounce/gravity/partial-collision math still needs a probe and implementation.
Keep these observations separate from implemented behavior. Private references:
`.local/{movement-handler,gravity-Entity,gravity-Player}.javap`.
