# VMC-077c — Per-chunk light

Status: Awaiting client
Note: Live in play; the VMC-077 milestone client run checks light at chunk and region borders.
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (audit finding C2/C8, boundary B3/F2),
[VMC-022](VMC-022.md) (light and the ring), [VMC-075](VMC-075.md) (per-chunk
generation), [VMC-077b](VMC-077.md) (the NIF split).

Before: a region lit itself and its one-chunk ring from scratch on the first
chunk request. Installing generated columns over the flat base profile changed
more than `RELIGHT_LIMIT` (16,384) cells per chunk, so every generated batch
recomputed light for the whole region and its ring (a 19.6 MB dense copy, about
73 ms on a dirty scheduler per four-chunk batch). Absent chunks and unknown ring
chunks were lit as flat terrain. `halo_edits` and `light_update` ran an
unbounded BFS on a normal scheduler, and every light change sent the chunk's
whole light to every client that had it.

After: light is kept chunk by chunk, the way vanilla's LIGHT step and Starlight
do it. A chunk is unknown to light until it is lit; light neither enters nor
leaves an unknown chunk. Each chunk is lit alone where it is made and keeps that
light in its column image; a region adopts it and only lets light cross the
chunk's faces. Runtime updates stay incremental and bounded, and light packets
carry only the sections that changed, to the clients vanilla sends them to.

Scope: light only. Not here: the storage engine (VMC-077f, which must keep
"stored light is the light of the stored blocks, or of blocks the stored edits
lead from"), tickets and unload (VMC-077e), the dispatch helper for other NIFs
(VMC-077b).

Acceptance:

- Engine (`valimc_core::light_grid`): per area chunk an optional slot (sky and
  block layers, the column's lowest sky sources, changed-section masks). A
  chunk is installed with its stored light or lit alone (`light_alone`: sky as
  a column fill down to each column's lowest source, whole sections at once
  where every column is open; sources queued only beside a column whose sources
  start higher; block light only from sections whose palette may hold an
  emitter), then the edge checks queue every cell on either side of its four
  faces that is at least two brighter than the cell across, and one increase
  pass spreads it. Installing can only add light, so no decrease runs.
  `cargo test`: chunks installed one at a time in any order, stored or lit
  fresh, equal a dense reference over the known chunks (unknown ones as
  opaque); incremental updates with an unknown chunk in the area equal the
  reference after every round.
- Persistence: column images are version 2 with a light flag; generation jobs
  (terrain in `RegionGeneration`, full chunks in `Proto`) and the import store
  each chunk's light alone (`Blocks.lit_images/2`, NIF `light_column_image`,
  dirty, off the owner). A region load adopts it (`Blocks.new/4` with the
  absent chunks, NIF `light_init`), lights untouched flat chunks from one flat
  column, computes only images without light (a `/fillbiome` re-image), then
  relights the edit history incrementally. Version 1 images are refused (D4).
  The imported vanilla light part (`Store.load_light`, `Anvil.Light.image/1`),
  which no owner read any more, is gone.
- Installing generated columns (`put_columns_lit`) never relights the region:
  the full recompute (`light_compute`, `RELIGHT_LIMIT`, the dense copy) is
  deleted. A known chunk replaced by different blocks relights its changed
  cells.
- Runtime updates: `Blocks.light_update/2` goes through `Native.dispatch/3`
  (more than 64 positions run dirty); on a normal scheduler Rust stops at a
  budget of 16,384 queue steps (25–30 ns a step in release, so about 0.5 ms),
  undoes the update (layers, lowest sources and change masks restored) and
  returns `too_large`, and the owner runs it again dirty. Halo
  edits only set the ring's blocks (`halo_set`) and relight through the same
  path; adopted ring images (`halo_put`, dirty) light the new ring chunks alone
  and touch only their seams.
- Absent chunks are unknown: an owner sends its neighbours only generated
  chunks for their rings, and a ring chunk is unknown until its owner sends it
  (no flat terrain stands in).
- Packets: Rust returns per chunk the sky and block sections whose levels
  differ from before the operation (a decrease that restores what it cleared
  does not count). `light_update` carries only those layers, all-zero ones in
  vanilla's empty masks (`Blocks.light_image/3`, `LightHalo.frames/3`). Light
  after block changes reaches a client only for a chunk on the edge of what it
  has (`ChunkMap.isChunkOnTrackedBorder`; inside it the client relights from
  the block updates); light from adopted images or installs reaches every
  client that has the chunk, since no block update tells it.
- The light oracle stage (`check_light.exs`, now lighting chunks one at a time
  as a live region installs them) and `anvil_content` pass.
- Measured: install cost per batch (`bench/light_install.exs`) and the whole
  view after a long teleport (`bench/fresh_terrain.exs`), matched against the
  commit before this slice.

Reference: vanilla 26.3 `ThreadedLevelLightEngine`, `LightEngine`
(`propagateLightSources`, `checkBlock`), `ChunkHolder.broadcastChanges`,
`ChunkMap.isChunkOnTrackedBorder`, `ClientboundLightUpdatePacketData`; Moonrise
Starlight's `ChunkLightTask` and edge checks (audit
`.local/code-audit/compare-paper-folia.md` §4).

Measurements (October 21, 2026; 10-core host shared with other sessions,
load average 22–46). Base is the commit before this slice (203b802), runs
alternate base and new; raw results in the ignored `bench/results/`
(`light-install-vmc077c-*`, `fresh-terrain-vmc077c-*`).

- `bench/light_install.exs` (seed 20261020, six terrain regions per run, their
  64 chunks installed four at a time nearest the centre first, three runs):

  | | base 203b802 | per chunk |
  |---|---|---|
  | install per 4-chunk batch, p50 / p95 / max | 32.4 / 66.8 / 213 ms | 0.28 / 1.19 / 4.4 ms |
  | installs per region | 411–830 ms | 3–12 ms |
  | light work of a region load, median | 40.4 ms | 4.3 ms |
  | lighting a chunk alone, in the generation job | — | 0.15 ms median |

  An earlier pair against 3728248 under heavier load: 65 ms against 0.5 ms
  (p50), 1.2 s against 15 ms per region, loads 107 ms against 6 ms.
- `bench/fresh_terrain.exs` (decorated world, view distance 10, a join then
  three 512-block teleports, three runs each): the whole view after a hop took
  2.8–7.1 s (median 3.8) before and 2.9–6.2 s (median 4.2) after, the first new
  chunk 1.1 s and 1.5 s, the whole view at join 3.0 s and 3.2 s: no difference
  beyond this host's noise. On today's main (VMC-075's per-chunk generation,
  VMC-077b's pool, VMC-077e's tickets) a decorated batch is 16 chunks and
  generation dominates, so the whole-region relights were not the large share
  of the view's latency the audit suspected; what this slice removes is owner
  blocking (about 0.4–0.8 s per region of dirty calls) and its tail.

Checks: `cargo test` (valimc_core 79, with and without the parity feature),
`cargo clippy --all-targets` with and without it; the light, halo, generation,
import, chunk streaming and lifecycle test files; `mix test.fast` on fa46077
(501, 0 failures); light, anvil_content, chunk_sections, heightmap,
region_files and world_upgrade again on fa46077 (VMC-077d's fact table).
`check_vanilla.py --changed` on f3d92ed: 37 of 38 stages pass,
light among them (now installing chunks one at a time, each with its light
alone, against vanilla's engine), anvil_content, chunk_sections, heightmap,
region_files and world_upgrade; tcp timed out once waiting for a movement
correction (tcp-plain, host load about 40) and passed alone.

Client: none per slice; the VMC-077 milestone run covers light at chunk and
region borders after teleports.

Deferred:

- A ring chunk adopted from a neighbour is lit alone again here; the
  neighbour could send the light its image was stored with.
- Chunk packets still carry all 26 light sections; vanilla leaves out sky
  sections above the terrain.
- `/fillbiome` re-images a column without its light, so that chunk is lit
  alone at each load until it is generated or imported again.
- A ring chunk of a neighbour that unloads keeps its last blocks and light.
