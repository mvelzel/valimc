# VMC-078a — Natural-spawn group tick headroom

Status: Done
Milestone: M3
Depends on: [VMC-042a](VMC-042a.md), [VMC-041a](VMC-041a.md).
Parent gate: [VMC-078](VMC-078.md).

The short M3 tick gate passes with one survival player but exposes tail
latency with eight: four of 200 complete owner ticks exceed 50 ms around
260 natural mobs. Profile the complete tick and address the measured cause
before the parent accepts the budget. No flight or empty-world benchmark
can replace this workload.

Acceptance:

- The same bounded terrain, full benchmark Rust profile, client load,
  natural spawning, AI, physics, block rules and durability produce retained
  one/eight-player raw samples with revision, harness and host metadata.
- Identify the time or allocation path responsible for the eight-player
  tail; changes preserve vanilla decisions and shared owner authority.
- With matched runs after any change, the complete group tick's p99 stays
  within 50 ms. Record median, p95, p99, maximum, overruns, population and
  limitations, without a fastest-server or production-capacity claim.
- Run affected correctness/native checks for runtime changes; the parent
  remains pending until the budget and its other gates pass.

## Initial measurement (October 24, 2026)

`bench/survival_group.exs` runs real stationary survival sessions on an
isolated loopback port, inside glass shelters. Both datasets have seed 42's
same synthetic plains surface and three cave layers. Their natural mobs
spawn, choose goals, travel and interact normally; the complete owner also
runs block rules and durability. After 200 warm-up ticks, 200 measured ticks
run at a 50-ms cadence, under `MIX_ENV=bench` with the full Rust profile.
The graphical tester's separate server remains untouched.

On runtime `264113e1` (the measured main revision `8e40be28` adds docs only),
ten schedulers, host load about 4.5: one player has 86–87 mobs in sixteen
sections, p50/p95/p99 6.891/8.689/12.441 ms, max 15.027 ms and no overrun.
Eight players have 255–263 mobs in 32 sections, p50/p95/p99
27.970/34.210/62.280 ms, max 103.753 ms and four overruns. Both measured
intervals take 10.001 seconds and end with an empty owner mailbox. The
larger audience deliberately changes the loaded/simulated area and natural
population; these are budget checks, not equal-workload comparisons between
player counts. Before/after implementation comparisons must match the count
and this terrain/position scheme.

Private raw results: `.local/m3-gate-ticks/one.json`, `eight.json`,
`survival_group-run.exs` (the exact initial harness, including its harmless
socket-EOF teardown logs), and `.local/m3-gate-ticks-one.log` /
`.local/m3-gate-ticks-eight.log`. The public harness now records its own hash,
owner/GC data and metric deltas, has optional call profiling and cleanly
recognizes deliberately closed sockets. The initial FAIL remains evidence;
the follow-up below records the focused fix and its limits.

## Profiling

Separate diagnostic runs are not budget results: tracing and the randomly
seeded natural mobs change their costs. The retained call profile puts most
owner time in mob updates; coarse phase timings put about 19–21 ms of an
ordinary eight-player tick there, compared with about 4 ms in spawning.
A GC trace records 2,986 collections over 200 ticks (about 1,994 ms total,
longest 3.125 ms), so there is substantial allocation cost but no single
long collection explains a tail. Two slow coarse samples recur 100 ticks
apart; checkpoint creation is absent in those measured calls.

The mob phase rebuilds two immutable id/UUID indexes for every mob even
when it has no combat effect, and travel-cache keys include non-travel
attributes such as each natural mob's random follow-range bonus. Measure
these paths with a fixed-UUID mob workload before changing them, then
repeat the complete natural-spawn budget gate. Private diagnostics:
`eight-profile.json`, `eight-gc.json` / `diagnostic.exs`, and
`eight-coarse2.json` / `coarse.exs`, under `.local/m3-gate-ticks/`.

## Index reuse and follow-up

The mob phase now creates its ticker-position and UUID indexes once. Its
membership is fixed for the phase; moved or hurt bodies still come from
the current entries. Melee effects and the lethal-hit query share those
indexes, and final velocities use the same positions. No simulation
ordering, combat decision or native kernel changes. The travel-cache
candidate is left unchanged because the focused index change restores the
measured budget.

The deterministic 300-zombie floor workload (`bench/mob_ticks.exs`, 60
measured ticks, five warm-ups, fixed UUIDs) takes a median 22.76 ms before
and 10.35 ms after, including store application. Raw samples are in
`.local/m3-gate-ticks/mob-phase-before.json` and
`mob-phase-index-after.json`, with the exact `mob_phase.exs` harness. A
separate before/after run in one VM produces identical saved entity
records, SHA-256 `25ee80b3899b54ed0f704342c3ed6b7162e9d01bcdffb426e970d6e0ab3c3b8e`;
its timings ran alongside correctness work and are not comparison evidence.
The single-floor herd magnifies the former quadratic index construction;
its speedup does not describe the spread-out natural-spawn group.

The complete unprofiled gate, with the same terrain and client-position
scheme, now has one player / 88–94 mobs: p50/p95/p99
6.563/8.419/16.332 ms, max 18.636 ms, no overrun. Eight players / 270–296
mobs: 28.238/33.723/44.514 ms, max 61.316 ms, one overrun. Both pass the
50-ms p99 acceptance; intervals are 10.001/10.012 seconds, queues empty,
ten schedulers, host loads 4.27/3.73. Natural UUID/AI seeds and populations
vary, so these complete-group results establish the bounded budget only;
they do not establish an implementation speedup or production capacity.
Raw metadata and 200 tick samples each: `one-index-after.json` and
`eight-index-after.json` under `.local/m3-gate-ticks/`.

Validation: 23 affected movement, combat and dragon owner/actor/socket
tests pass. All six stages selected by `check_vanilla.py --changed` pass
(animals, Nether mobs, mob AI, hostiles, villagers and the official-codec
session), including the existing sequential combat/animal fixtures. No
Rust code changed. The fast parent suite passes 559 checks (217 excluded).
The exact source hashes are retained in
`.local/m3-gate-ticks/index-source-manifest.json`. Logs: `.local/m3-gate-index-tests.log` and
`.local/m3-gate-index-vanilla.log`. This closes the bounded tick-budget
finding; the parent still needs its survival and outstanding client gates.
