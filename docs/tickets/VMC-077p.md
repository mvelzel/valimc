# VMC-077p — Section snapshots as shared copy-on-write Rust resources

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077e](VMC-077e.md) (published reads through `World.View`),
[VMC-077l](VMC-077l.md) and [VMC-077l2](VMC-077l2.md) (the physics kernel),
[VMC-077j1](VMC-077j1.md) (section handoffs between group processes).

Before: an owner published each changed chunk into its ETS table as BEAM
terms: per section an integer, a palette tuple with a 4,096-byte binary or a
dense 8,192-byte binary, beside a 1 KB heights binary and a 3 KB biomes
binary that Rust computed for the whole chunk. Every committed batch
encoded its changed chunks again in full, so a one-block edit copied up to
24 sections, and the published copy sat beside the store's own sections
(about twice the block memory). The kernel decoded the section terms near
each query into borrowed views, and `World.View` decoded them in Elixir.

Scope: the native store and snapshot modules, `World.BlockSnapshot`,
`World.View`, the kernel's block source, and the readers that decoded rows
(portal access, spawn search, portal contacts). Audit items G3 and C7
(`.local/code-audit/boundary.md`, `world-core.md`).

## Design

- **Copy-on-write sections.** A column's sections and biomes are `Arc`s
  (`valimc_core::column`). A write clones a section only when a snapshot
  still shares it and the state really changes (`Arc::make_mut`); an
  untouched chunk's column is the base profile's, shared, until written.
- **Chunk snapshots** (`valimc_core::snapshot::ChunkSnapshot`): the 24
  section `Arc`s and the biomes of one chunk, the publication's revision and,
  per section, the revision of the publication that last changed it.
  Republishing a chunk copies 24 pointers and keeps the previous snapshot's
  revision for every section it still shares (pointer equality), so a
  publication costs work for the sections that changed, never for the
  chunk's cells.
- **Handles.** A snapshot is a `ResourceArc` (`valimc_nif::snapshot`), one
  ETS row per chunk, `{{:chunk, chunk}, handle}` or `:absent`. Readers copy
  the handle (a reference) out of the table; nothing locks, and the owner may
  publish newer handles meanwhile. Rows move with the table on a section
  handoff (VMC-077j1), so a merge or split republishes nothing; the old
  snapshot keeps reading what it published until the last reader drops it.
  A held handle keeps the sections it shares alive, so readers hold one for
  a call or a short job's `World.View`, never in an owner's state.
- **Reads in place.** The kernel's view is `{:rows, handles, outside}`: each
  handle is borrowed from its term for the call (`&Snapshot`, no reference
  count) and read without decoding. `World.View` calls batch NIFs: a state,
  many states across chunks (`blocks/2`), a search (`find/3`), the highest
  filled section, and a column's MOTION_BLOCKING height, lowest sky source
  and biome, computed from the snapshot when asked rather than at every
  publication. Spawn search reads a column in one call; portal contacts read
  their positions in one call.
- **Biomes after `/fillbiome`** are published at once, as blocks are; before,
  the published biomes stayed stale until the chunk's next block change.

Deleted: `snapshot_chunk` and `column_facts` (the term encoding and the
per-publication heights and biomes), the kernel's `Section` decoding and base
profile parameter, `View`'s Elixir section decoding (`at`, `matches`), the
portal reader's section scan, `Blocks.snapshot/2` and `Blocks.column_facts/2`.

## Acceptance

- A snapshot reads what the store held when it was published while the store
  writes past it; republishing renews only the written sections' revisions;
  shared sections count once in resident memory (`cargo test`, `snapshot.rs`;
  `block_snapshot_test.exs`, which also checks every snapshot NIF against the
  store's own reads).
- A section handed to another group keeps its published handle; the adopting
  group's first write republishes only that section (`region_group_test.exs`).
- Published heights, sky sources and biomes equal the owner's
  (`region_generation_test.exs`, the `sky_column` and `heightmap` stages), and
  `/fillbiome` publishes its biomes (`place_connection_test.exs`).
- Every physics, rain, portal and spawn reader reads handles; no BEAM copy of
  a section remains.

## Measurements

`MIX_ENV=bench` (full Rust profile) on 72917964 and on this ticket, three
pairs back to back in one heavy slot at load 6–12 on the shared 10-core host;
raw results in the ignored `bench/results/`
(`vmc-077p-{publication,kernel}-{before,after}-{1,2,3}.json`,
`vmc-077p-light-{before,after}.json`).

`bench/snapshot_publication.exs`: four regions of decorated terrain at seed
20261020, each loaded as an owner loads it (its 64 column images installed,
every chunk published into a fresh table). Resident block memory is the
store's sections plus what the publication holds apart from them; it is the
same in every run.

| Per region | Before | After |
|---|---|---|
| Resident block memory, loaded | 5.16–5.28 MB | 2.44–2.50 MB |
| of which the store's sections | 2.39–2.45 MB | 2.43–2.49 MB (with the snapshot records and the base profile) |
| of which published binaries and rows | 2.77–2.83 MB | 11 KB (rows) |
| Resident block memory after one edit in every chunk | 5.16–5.28 MB | 2.44–2.50 MB |

A loaded region holds its blocks in 2.1 times less memory: the published
copy is gone, and an edit costs one section's clone in the store, which the
next publication shares.

| Republish of one batch (medians) | Before | After |
|---|---|---|
| 1 chunk | 17 µs | under 1 µs |
| 8 chunks | 129–132 µs | 2 µs |
| 64 chunks | 1,069–1,108 µs | 16–18 µs |
| 64 chunks with the write that changed them | 1,078–1,116 µs | 39–44 µs |

A one-block change in each of 64 chunks republished in over a millisecond
before, the owner's whole budget for one NIF call; now in 16–18 µs, and the
write's copy-on-write clones add about 25 µs.

`bench/physics_kernel.exs` (the same moves and items): a move costs
15.0–16.5 µs of CPU against 15.5–16.0 µs before (median latency 14–15 µs
against 15, p95 18–19 µs both), and an item tick 1.22–1.32 µs per item in
the dry scene against 1.19–1.24 µs: unchanged within noise, since the
kernel decoded only the few sections near each query before.
`bench/light_install.exs` (one run each): installing four chunks takes a
median 182 µs against 183 µs and a region load's light 3.57 ms against
3.52 ms, so reading sections through an `Arc` costs light nothing measurable.

## Checks

`cargo test -p valimc_core --lib` (95), `cargo clippy --all-targets` with and
without `parity`; `mix test.fast` (477); `check_vanilla.py --changed` (77
stages: chunk sections, sky column, heightmap, the collision, movement,
player-rule and item stages, spawn, placement, TCP and the rest the store's
change reaches) all pass; the portal, dimension-travel, flight, landing,
lifecycle, pose, void, food, fire, mining, placement, pickup, item portal and
void, region lifecycle, regionizer, group, decorated-world, spawn-search and
place socket and slow files (76 tests) pass.

## Deferred

- The base profile's sections are shared by every column that starts from
  it; resident memory counts them once, but the store's memory budget still
  counts them per column, as when each column had its own copy.
- Light is not part of a snapshot; chunk packets still carry the owner's
  light.
- Pathfinding and commands outside the owner read through `World.View` when
  they arrive (VMC-041).

Client: none per slice; the VMC-077 milestone run covers movement and rain
over republished chunks.
