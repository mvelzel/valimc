# VMC-077q — Bounded proto memory

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077n](VMC-077n.md) (one generation scheduler per dimension;
this ticket closes its first deferred item).

Before: a dimension's generation kept every proto chunk it made in memory
until shutdown. Chunks at the edge of what was generated (terrain, and
decorated chunks not final yet) are never handed over, so memory grew with
the explored perimeter: about 200 KB per overworld chunk, without bound on a
long flight.

After: at most `worldgen_proto_cells` (1,024) proto chunks per dimension
stay in memory while work does not need more; the rest are dropped or
spilled, and generation comes out the same.

Design:

- **What may go.** Past the cap, `Frontier.evictions/2` makes room down to
  seven eighths of it, least recently used first (a cell is used when it is
  made and whenever a job takes it). It keeps the cells within 2 of a
  wanted chunk, within 1 of a numbered decoration that is still needed, and
  those a job holds. The scheduler runs a batch of at most 64 per dispatch,
  and none again until more cells came in if a pass freed nothing.
- **Untouched terrain is dropped.** A terrain chunk with no decorated chunk
  within 1 holds nothing but its terrain. Its entry goes, and the frontier
  makes its terrain again when a decoration needs it. That comes out the
  same: terrain reads the seed, the biome source and the beards of the starts
  that reach the chunk, and placement never changes what a beard reads
  (`StartTable::view`). A start that reaches an undecorated chunk is never
  done, so it is still in the table.
- **Every other cell spills.** A cell a decoration wrote into cannot be
  made again cheaply. Its decoration, and those of its decorated neighbours,
  read their 3 × 3s as earlier decorations within 2 left them, and so on,
  transitively, in decoration-number order. Replaying that is not bounded.
  Regenerating the decoration alone (as the "made alone" path does) would
  change the chunk at its borders. So the scheduler writes the cell's
  encoding (`gen_encode`, about 20 KB against about 200 KB in memory, 0.2
  ms) to the dimension's scratch file, and the entry keeps `{:spilled,
  offset, size}`. A decoration job decodes the spilled cells of its 3 × 3 on
  the pool (0.3 ms each) and hands them back with its result. A full-chunk
  job decodes its cell and leaves it spilled, since making a chunk full
  changes nothing in it.
- **The scratch file is never durable state.** `generation.scratch` beside
  the snapshot (in the system temporary folder for a world without one) is
  removed at every start and stop. It is not synced, and its space is not
  reused: it grows with what spilled until the scheduler stops, on disk
  rather than in memory. A graceful stop's snapshot reads spilled cells' bytes
  straight from it. A start restores a snapshot's proto chunks into the
  scratch file, so a restart after a long session does not decode every
  perimeter chunk into memory at once.
- **Gauges.** Per dimension: `worldgen_cells_<dimension>` (proto chunks in
  memory), `worldgen_proto_bytes_<dimension>` (their heap bytes,
  `gen_cells_bytes`), `worldgen_memory_bytes_<dimension>` (now the context,
  the start table and the proto chunks), `worldgen_spilled_<dimension>` and
  `worldgen_scratch_bytes_<dimension>`; counters `worldgen_spills` and
  `worldgen_drops`. `Scheduler.stats/2` reports `in_memory`, `proto_bytes`,
  `spilled`, `spills` and `dropped`.

Acceptance:

- With 8 proto chunks in memory, chunks generated beside earlier ones (whose
  cells spilled) and after a graceful restart equal the reference
  decoration in number order (`worldgen_scheduler_test.exs`).
- Eviction keeps cells near wants, needed decorations and jobs, drops
  untouched terrain, spills the rest least recently used first, and spills
  at most a batch at a time (`worldgen_frontier_test.exs`).
- On a long flight, proto chunks in memory stay at the cap while uncapped
  they grow with the distance flown (measurements).

Measurements (October 22, 2026, `MIX_ENV=bench`, 10-core host shared with
other sessions at load 4 to 8; `bench/fresh_terrain.exs` with 40 hops of
256 blocks at view distance 10 on seed 20261020, a fresh world each run; raw
results in ignored `bench/results/flight-077q-cap1024.json` and
`flight-077q-cap1000000.json`):

| | Default cap (1,024) | No cap in effect |
|---|---|---|
| Proto chunks in memory after 10 km | 712 (142 MiB) | 3,080 (623 MiB) |
| Most at any hop | 864 (173 MiB) | 3,080 (623 MiB) |
| Spilled / dropped | 2,368 / 0 | 0 / 0 |
| Scratch file | 43.6 MiB | 0.4 MiB (the spawn search's snapshot) |
| Terrain / decoration jobs | 17,280 / 15,920 | 17,280 / 15,920 |
| View fill per hop, median (p90) | 1.91 s (3.28 s) | 1.90 s (3.24 s) |

Uncapped, memory grows by about 72 proto chunks (14.6 MiB) per hop. With
the cap it levels off below the cap from the eighth hop: the flight's
leftover edge spills, at about 18 KB a chunk on disk. Spilling costs no
regeneration (the same jobs ran) and no view-fill time. No terrain was
dropped on this flight, since every leftover terrain chunk had been
decorated into; dropping is covered by `worldgen_frontier_test.exs`.

Checks: `cargo build` (the new `ProtoChunk::heap_bytes` and
`gen_cells_bytes`); `test/worldgen_frontier_test.exs` (3) and
`test/worldgen_scheduler_test.exs` (8, the new one with 8 proto chunks in
memory, including the gauge's parity check); `mix test.fast` 479 of 479;
`mix test --only slow --only tcp` 201 of 201; `check_vanilla.py --changed`
209 of 209 stages (all selected: `config/config.exs` changed). The six live
generation stages also pass with `VALIMC_WORLDGEN_PROTO_CELLS=48`. That
setting spills hundreds of chunks over such an area (896 spills over 24 × 24
chunks in a probe), so generation matches vanilla while most of its proto
chunks come back from the scratch file.

`VALIMC_WORLDGEN_PROTO_CELLS` sets the cap at run time.

Client: none; generation is checked against the reference, and the VMC-077
milestone run flies over fresh terrain.

Deferred:

- The start table still keeps an entry per chunk it was asked for (VMC-077n),
  a few hundred bytes each.
- Spilled cells are not compressed (zlib would quarter them), and the scratch
  file's space is not reused; both only matter on disk.
