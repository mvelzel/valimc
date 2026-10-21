# VMC-077n — One generation scheduler per dimension

Status: In progress
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
- **Statuses.** A chunk is absent, then `terrain` (its proto chunk exists),
  then `decorated` (its own decoration ran over its 3 × 3), and final once its
  whole 3 × 3 is decorated. A final chunk is converted to a full chunk for the
  region that wants it; its proto chunk is dropped once the region has
  persisted it. In a terrain-only world a chunk is final after terrain.
- **Order and write areas.** Decorating a chunk reads and writes its 3 × 3,
  so two decorations conflict within distance 2. Each decoration gets a
  sequence number when some request first needs it: a request's undecorated
  chunks within 1, Z outer and X inner, in request order. A decoration starts
  once its 3 × 3 has terrain, no job holds any of those chunks, and no
  conflicting decoration with a smaller number is still undecorated, so
  decorations that touch each other always run in sequence order and the
  result depends only on the order of requests, as vanilla's depends on its
  order. Non-conflicting decorations and all terrain run in parallel.
- **Priority.** Every wanted chunk carries the smallest distance to a player
  that wants it (the regions' loading tickets); its dependencies inherit it.
  Ready work starts in priority order as long as the pool has room; terrain
  is bulk work and leaves the pool's last slot to decoration and full chunks.
- **Structure starts** are scheduler state: a start table per dimension,
  filled on first need (the starts within 8 chunks of a chunk's terrain or
  decoration) and passed into those jobs. Placement changes starts as vanilla
  does (temple heights settle in the first chunk that places them, once-only
  pieces stay placed); no transaction recomputes them, so `settle_live` and
  `PlacedOnce` are gone. A start is dropped once every chunk it reaches is
  decorated.
- **Durability (D3).** Proto chunks and starts live in memory. A graceful
  stop snapshots them; a start loads and deletes the snapshot. After a hard
  crash, chunks that were not yet full generate again (seams at the edge of
  what was generated are possible, as in vanilla). Only full chunks are
  durable, written by the live region as before.
- **Failures.** A deterministic generation error puts the chunk into an error
  state (counted in `worldgen_errors`) instead of retrying forever; a worker
  that dies retries its work. A region that asks for a chunk the scheduler
  already handed over (its log lost it) gets it generated again.
- **One pipeline.** Spawn search asks the scheduler for full chunks instead of
  emulating a transaction; `/place` and `/locate` keep the bounded pool.

Deleted: `Valimc.Worldgen.Proto` (owners, coordinator and participant),
`ProtoLog`, `TerrainBoard`, `ProtoRegistry`/`ProtoSupervisor`, the
`:generation` permit kind, the generation use of the transaction outbox,
receipts and delivery, the per-state worldgen pool and lease,
`first_full_columns`, `settle_live` and `PlacedOnce`.

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

Checks:

Client: none per slice; the VMC-077 milestone run covers generation.
