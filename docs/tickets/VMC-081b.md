# VMC-081b — Elixir quick wins before the native core

Status: Done
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081a](VMC-081a.md).

Low-risk changes to the current owner, chosen and measured with the 081a
harness. They are a stopgap: the native core (081d onward) replaces most of
these paths.

## The owner's heap was the largest single cost

Tracing the combat owner's collections (`GCTRACE=1`) showed garbage collection
took about 41% of its tick time: in 20 seconds, 43 full collections of about
40 ms and 87 minor ones of about 23 ms. Ticks ran at about 13 ms with a 50–70 ms
spike every few ticks; the spikes were half of all tick time.

The owner allocates tens of megabytes per tick, while its live state was about
180 MB. A section-field breakdown (`HEAP=1`) put almost all of it in pending
block and fluid ticks that generation leaves in every rendered chunk, which never
tick, and in the commit baseline that shares them. Every full collection copied
all of it.

- **Frozen scheduled ticks.** The tick containers of chunks outside simulation
  are frozen into one off-heap binary each (`ScheduledTicks.freeze/2`) when
  generation installs them and every 100 ticks after. A frozen chunk thaws when
  it ticks again or gets a tick, in its original order. Storage reads frozen and
  live containers alike, so its records and recovery are unchanged; a chunk's
  record is rewritten once when it freezes or thaws.
- **A large young heap for groups hosting players.** With the live state
  small, a 64 MB minimum heap (`:region_min_heap_words`, 8M words) makes
  collections rare, and each copies only what is live. Groups without players
  keep the VM default, so idle groups reserve nothing; tests keep the default.
  A 256 MB minimum gained little more (17.2 against 17.5 ms) for 720 MB of heap.

Replacing the post-adopt full collection with two minor collections was tried
and reverted: it made collections slower (27 ms against 17 ms mean).

## Work repeated for every section of a wide view

- **Block rule reach.** A rule run passes the stores and ungenerated chunks of
  the sections beside its own (at least 128 blocks on every side), found by key
  rather than by walking the group. It locked and listed every store of the
  group at view 32. Vanilla has no such edge; no single run cascades that far.
  Comparator contexts read the same neighbours.
- **Spawning inputs.** The plan no longer rebuilds an id-to-section map of every
  loaded entity each tick; it resolves only the mobs it discards or resets.
  Spawner block entities and kept structure starts are read only in sections
  with simulated chunks. The native plan gets the stores and ungenerated chunks
  of sections beside simulated ones; every section's mobs still count for the caps.
- **Mob motion.** A type's motion kind is derived once per owner, not for every
  mob input of every tick.
- **Entity trackers.** A tracker keeps the projection observers have of its
  body (`Body.shown/1`), so each tick projects only the new body.
- **Chunk encoding.** A chunk's block entities are found once per encode,
  using integer bounds instead of floor division per entry.
- **Hoppers.** A section without containers skips the hopper phase.
- **Tick deadline.** The next tick is scheduled from its absolute deadline
  after the work, not from a delay computed before it.

## Results

`bench/tick_budget.exs` on the development Mac with `+S 2:2 +SDcpu 2:2`, 60
seconds after warm-up, against a worktree at 77e3dc98 with only the harness and
profiler histograms added. Combat: about 155 active mobs, 735 loaded entities,
79 sections. Percentiles are histogram bucket bounds.

| | Combat before | Combat after | Explore before | Explore after |
|---|---:|---:|---:|---:|
| Tick mean | 24.6 ms | 17.4–17.5 ms | 13.5 ms | 8.0 ms |
| Tick p95 / p99 | ≤75 / ≤75 ms | ≤30 / ≤30 ms | ≤50 / ≤75 ms | ≤15 / ≤30 ms |
| Lowest one-second TPS | 15.8–16.0 | 19.0 | 18.0 | 18.9 |
| Entity phase (sampled) | 18.9–20.3 ms | 14.3 ms | 8.6 ms | 5.3 ms |
| Post-adopt collections per minute | — | — | 1,060 ms | 280 ms |
| Owner heap, maximum | 399 MiB | 210 MiB | 399 MiB | 210 MiB |

Exploration generated only about 890 chunks a minute in both: the generation
path, not the tick, limits it (081c). Capture 8 on the VPS took about three
times this Mac's baseline tick, so the hosted combat tick should still be near
the 50 ms budget. These are stopgap gains; the budgets need the native core.
Raw results, logs and the template stay in ignored `.local/tick-budget/`.

Acceptance:

- Behavior, order, durability and ownership unchanged, apart from the rule
  reach edge above.
- Matched 081a runs before and after on the same host (above).

Checks: profile-work, spawn-input, tick-pipeline (frozen ticks), storage,
natural spawning, phantom spawner, redstone, hopper, container, placement,
block-entity, tracker, mob and region suites pass (60 region, storage,
generation, light, handoff and group tests among them). `check_vanilla.py
--changed` selects all 261 stages (a configuration change); all pass, with the
unchanged world-settings extraction still not verified (no cached regeneration).

Deployed `13373b2d6893776845d0d57348ed9a4622192e60` to the existing Hetzner host
on October 29 with the same `valimc_data:/data` volume, view 32, simulation 10
and public diagnostic origin. The image and release symlink match, the server
listens on 25565 and readiness returns HTTP 200. This verifies deployment, not
gameplay TPS; the user takes new combat and exploration profiles. The log is in
ignored `.local/hetzner/deploy-081b.log`.
