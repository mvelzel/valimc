# VMC-077n — One generation scheduler per dimension

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (finding B1, B2, C1–C6; decision D3),
[VMC-075](VMC-075.md) (per-chunk generation), [VMC-077b](VMC-077.md) (the
generation pool).

Before: a decorated world's chunks were owned per 8 × 8 region by proto
owners, each with its own durable log, and finalizing chunks near a region
border ran a distributed two-phase commit (terrain requests, all-or-nothing
locks answered busy, durable prepare, an outbox with receipts and delivery,
recovery every 30 s). Terrain priority followed transaction start time
through a polled ETS board. Proto chunks crossed owners as encoded binaries.
Every worldgen call leased one of up to 64 lazily compiled states, each with
its own caches, and structure starts were recomputed per transaction from
hidden per-state caches, with temple heights settled by a deliberate
deviation (`settle_live`) and once-only pieces recorded in proto images
(`PlacedOnce`).

After: one scheduler per dimension owns every chunk's generation status, its
proto chunk as a native resource and the dimension's structure starts. It
hands work to the generation pool with explicit write areas; work that
overlaps waits in its queue and is woken when what it waits for finishes.

Design:

- **Rust context.** `SeedContext` (one per seed and noise settings) is
  compiled eagerly in `worldgen_new` on a dirty scheduler and shared through
  an `Arc`; each call takes a `Worldgen` handle on it. Its only mutable parts
  are the compile state (complete after compiling) and bounded caches of pure
  values (chunk biomes, carver biomes, structure environments). A
  `BiomeSource` enum replaces biome source strings. The 64-state pool and its
  lease are gone; `worldgen_memory` reports what a context holds.
- **Cells and jobs.** A proto chunk is a native cell (`ProtoCell`, a
  `ResourceArc` holding a lock and the chunk) that the scheduler lends to one
  job at a time: `gen_terrain` makes one, `gen_decorate` decorates a centre
  over its nine cells (locked in Z/X order for the call, put back whatever
  happens), `gen_full` makes a final cell full. Nothing is encoded between
  processes; `gen_encode`/`gen_decode` serve the snapshot only.
  `gen_reference` decorates an order over fresh terrain in one call, as the
  reference tests and the lost-chunk path use.
- **Statuses.** A chunk is absent, then `terrain`, then `decorated` (its own
  decoration ran over its 3 × 3), and final once its whole 3 × 3 is decorated.
  A final chunk is made full for the requests that want it; once its region
  has persisted it, it is `handed` (cell dropped), and its entry goes once its
  3 × 3 is handed too. In a terrain-only world a chunk is final after terrain;
  a flat-layer world's chunks are full at once.
- **Order and write areas.** Terrain holds its chunk, a decoration its 3 × 3,
  a full chunk its own cell. Two decorations conflict within distance 2. Each
  decoration gets a number when some request first needs it: the request's
  undecorated chunks within 1, Z outer and X inner. A decoration starts once
  its 3 × 3 has terrain, no job holds any of those chunks, and no conflicting
  decoration with a smaller number is still undecorated, so decorations that
  touch always run in number order and the result depends only on the order
  of requests, as vanilla's depends on its order. Terrain for later
  decorations runs while earlier ones wait; non-conflicting decorations and
  all terrain run in parallel.
- **Priority and dispatch.** Every wanted chunk carries the smallest squared
  distance to a ticket's centre that wants it (-1 for calls that wait). A
  numbered decoration inherits the smallest priority of the wanted chunks it
  writes into and of the later decorations within 2 that wait for it, so the
  chain a wanted chunk waits on runs at its priority. Work waits in priority
  queues: wanted final chunks, chunks to make alone, decorations that can run
  now, and the terrain of the needed decorations' 3 × 3. A job's end updates
  only its neighbourhood (terrain may make the decorations within 1 ready, a
  decoration those within 2 and the finals within 1); the queues are rebuilt
  only when wants change. Dispatch takes final chunks, then decorations, then
  terrain, which never takes the pool's last slot.
- **Waking.** The scheduler starts work when its mailbox is empty, as far as
  the pool has room (`Pool.free/1`). A finished job, a want or a hand-over
  wakes it, and when the pool is full the next job to end anywhere wakes it
  (`Pool.notify/0`). Nothing answers busy and nothing polls. A pool job is a
  plain process its caller monitors, counted in an atomic slot counter, so
  starting one calls no other process (the task supervisor's synchronous
  start was the scheduler's largest cost under load).
- **Regions.** A region sends the scheduler its wanted absent chunks with
  their priorities whenever they change (not per installed chunk), receives
  each full chunk as `{:generated_full, scheduler, full}`, persists one frame
  at a time (what arrives meanwhile joins the next frame, so frames grow with
  the arrival rate), installs it once durable and reports it handed over. It
  monitors the scheduler and wants again when it restarts. On load it reports
  the chunks it has (`present`), so a neighbour wanted later knows them.
- **Structure starts** are scheduler state: a start table per dimension
  (`valimc_core::worldgen::starts`), filled on first need (the starts within
  8 chunks of a chunk's terrain or decoration) and passed into those jobs.
  Placement changes starts as vanilla does (temple heights settle in the first
  chunk that places them, once-only pieces stay placed); a chunk's starts are
  locked only while one decoration places one of them. A start is dropped once
  every chunk it reaches is decorated. `settle_live`, `PlacedOnce` and the
  per-state start caches are gone, and the structure oracle no longer
  emulates the settlement.
- **Durability (D3).** Proto chunks and starts live in memory. A graceful stop
  lets running jobs finish (up to 20 s) and snapshots chunks, statuses,
  numbers and starts (each piece's placement state) as the dimension's
  `generation.snapshot`; a start loads and deletes it. After a hard crash,
  chunks that were not yet full generate again (seams at the edge of what was
  generated are possible, as in vanilla). Only full chunks are durable,
  written by the live region as before. An idle scheduler (nothing wanted,
  running or awaiting hand-over) stops after a minute, with its snapshot.
- **Failures.** A deterministic error (a raise in a job) puts the chunk into
  a failed state, counts `worldgen_errors` and fails the wanted chunks within
  2 of it: their regions answer waiting calls `chunk_generating` and stop
  wanting them. A job whose worker dies is tried again, at most three times.
- **Lost and frozen chunks.** A chunk wanted again after it was handed over
  (its region lost it), or one that needs a decoration that can no longer run
  (a neighbour handed over or failed), is made alone over fresh terrain of
  its 3 × 3 with only its own decoration, as vanilla makes a chunk missing
  from its region file.
- **One pipeline.** Spawn search runs the overworld's scheduler state inline
  (`Frontier.run/2`), chunk by chunk as the search asks, and writes it as the
  snapshot, so the live scheduler starts from exactly those chunks;
  `first_full_columns` is gone. `/place` and `/locate` keep `Pool.run/2`,
  which now waits for a free slot instead of retrying every 10 ms.
- **Metrics.** `worldgen_errors`, `worldgen_microseconds` (job latency),
  per-dimension gauges `worldgen_cells_<dimension>` and
  `worldgen_memory_bytes_<dimension>` (context and start table;
  `Metrics.put/2`).

The pure core is `Valimc.Worldgen.Frontier` (statuses, numbers, wants, jobs
as closures); `Valimc.Worldgen.Scheduler` is the process per world and
dimension (registry `Valimc.Worldgen.Schedulers`, started on demand) that runs
it on the pool.

Deleted: `Valimc.Worldgen.Proto` (owners, coordinator and participant),
`ProtoLog`, `TerrainBoard`, `ProtoRegistry`/`ProtoSupervisor`, the
`:generation` permit kind, the generation use of the transaction outbox,
receipts and delivery, the per-state worldgen pool and lease, the
`worldgen_proto_*` NIFs, `first_full_columns`, `settle_live` and `PlacedOnce`
(proto format 5 only).

Acceptance:

- Live generation equals vanilla's decoration of the same chunks in the same
  order (the `worldgen_live*` stages, structures included, with the oracle's
  settlement emulation removed).
- A view's chunks generate nearest first; overlapping work queues, nothing
  answers busy, nothing polls.
- A graceful restart in the middle of generation resumes from the snapshot
  with the same chunks; a lost full chunk generates again.
- Measured against Pumpkin with the M2 gate method
  (`bench/worldgen_live.exs`, matched pairs) and the whole view after a long
  teleport (`bench/fresh_terrain.exs`).

Reference: vanilla 26.3 `ChunkMap.scheduleGenerationTask`, `ChunkStatus`,
`ChunkPyramid`, `ScatteredFeaturePiece.updateAverageGroundHeight`;
Moonrise's `ChunkTaskScheduler` (write radii, waiting neighbours, priority
inheritance); Pumpkin's `schedule.rs` (audit `.local/code-audit/`).

Measurements (October 22, 2026; 10-core host shared with other sessions,
load average 10–55; base is the commit before the scheduler, c50a4670, whose
proto owners already share VMC-077n's `SeedContext`; raw results in the
ignored `bench/results/077n-*`).

- Live generation, M2 gate method (`bench/worldgen_live.exs`, seed 20261020,
  4 × 4 regions with structures requested at once, three passes after a
  warm-up per run; runs alternate base, VMC-077n and Pumpkin's local
  `valimc_live` harness, three rounds, load 10–28). Final chunks per second:

  | | passes | median | mean |
  |---|---|---|---|
  | base (proto owners) | 332 363 459 · 284 410 461 · 345 384 386 | 384 | 380 |
  | VMC-077n | 210 263 443 · 401 377 464 · 438 453 514 | 438 | 396 |
  | Pumpkin | 601 534 475 · 565 408 403 · 632 601 562 | 562 | 531 |

  The median pair ratio is 0.75 × Pumpkin (pairs 0.49, 0.98, 0.75; the base
  0.68), as at the M2 gate (0.74 ×). ValiMC's pool runs 8 of the 10 cores'
  dirty schedulers (VMC-077b), Pumpkin all 10. On one thread, terrain and
  decoration per chunk are level with the base within this host's noise;
  making a final chunk full takes 0.20 ms against 0.35–0.60 ms (nothing is
  decoded).
- Where the time went: the first scheduler was level with the base because
  the scheduler process itself was the bottleneck. Simulated with instant
  jobs, it spent 1.33 ms per job rescanning the wanted chunks for work
  (now 13.5 µs with the queues); terrain refused by the pool forced a
  rebuild of every queue; and starting each job was a synchronous call to the
  task supervisor. With those fixed, a 4 × 4 request took 3.5 s instead of
  6.0 s at load 25. Decorations still run about one at a time on such a
  request: the numbering order is a wavefront, so the decoration chain, not
  the pool, bounds throughput.
- The whole view after a long teleport (`bench/fresh_terrain.exs`, decorated
  world, view distance 10, a join then three 512-block teleports, three
  alternating runs each, load 15–32): the first new chunk after a hop took a
  median 0.40 s against 1.14 s, the whole 473-chunk view 2.23 s (1.98–3.48)
  against 2.89 s (2.24–4.98), the whole view at join 1.96 s against 2.18 s.
  A first run here found every handed-over chunk made a second time alone
  (the priority map still listed it after delivery), 8–19 s per view; the
  delivery now drops it.

Checks: `cargo test` (valimc_core 83, including the start table snapshot and
the placement state round trip), `cargo clippy --all-targets`;
`test/worldgen_scheduler_test.exs` (reference equality for sequential and
concurrent requests, graceful restart from the snapshot with a once-only
mineshaft piece, a lost chunk made alone, terrain-only worlds, a failed job),
`test/worldgen_proto_test.exs`, `test/decorated_world_test.exs`,
`test/region_generation_test.exs`, the portal, preset, spawn, place and
connection test files; `mix test.fast` rebased on f952b6ca (472, 0 failures).
`check_vanilla.py --changed` on the rebased commit: 83 of 84 stages, among
them every worldgen_live stage (structures included, 2,816 + 704 + 192 final
chunks with the settlement emulation removed), worldgen_datapack, spawn,
place, locate and tcp; anvil_content failed once in that run (vanilla's save
of the exported world differed in one section) and passed twice alone, as on
main. Before the rebase: 70 of 70 on 984c55a9.

Client: none per slice; the VMC-077 milestone run covers generation.

Deferred:

- Proto chunks at the edge of what was generated (terrain, and decorated
  chunks that are not final) stay in memory until shutdown, so memory grows
  with the explored perimeter. Terrain no decoration wrote into could be
  dropped and made again; decorated chunks would need eviction to disk.
- The start table keeps an entry per chunk it was asked for, empty ones too
  (1.7 MiB after five 21 × 21 areas).
- Decoration parallelism is bounded by the numbering wavefront; Pumpkin
  decorates in nine colour classes at once. Another deterministic numbering
  would change the order the oracle checks.
- Pool jobs are plain processes: on an application stop a running NIF
  finishes on its own instead of being killed.
- A chunk made alone lacks its neighbours' decorations, as vanilla's
  regeneration of a chunk missing from its region file does.

Client: interim VMC-077 run on the frozen release of b8646a33 (October 22, 2026; evidence in ignored `.local/client-tests/VMC-077-interim/`): fresh terrain over 400 blocks across region lines with continuous features; a village by /locate; two Nether portal round trips. PASS.
