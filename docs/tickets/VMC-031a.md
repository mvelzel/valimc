# VMC-031a — Water and lava flow

Status: Awaiting client
Milestone: M3
Depends on: [VMC-077m](VMC-077m.md), [VMC-066](VMC-066.md) (scheduled
ticks).

Vanilla's `FlowingFluid` for water and lava:

- **Flow:** spread and its slope search, falling, infinite sources, and
  lava's slower spread and faster spread in the Nether.
- **Fluid interactions:** mixing that makes cobblestone, stone, obsidian and
  basalt.
- **Buckets and waterlogging:** buckets fill and empty, and waterlogged
  blocks behave correctly.
- **Generated fluids:** the post-processing marks generation leaves
  (VMC-024d) settle.
- **Cost:** fluid ticks run in the tick pipeline's scheduled ticks, and the
  slope search runs in the Rust engine.

Acceptance:

- Flow, mixing and source fixtures match the oracle, including across
  section and group lines.
- A bucket-built Nether portal frame (obsidian from lava and water) works on
  the real client.

## What is live

- `valimc_core::rules::fluid` is `FlowingFluid` with `WaterFluid` and
  `LavaFluid` on the block-update engine: a fluid tick recomputes a flowing
  cell (`getNewLiquid`: sources beside it, the same fluid above, drop-off),
  falls, and spreads to the sides toward the nearest way down
  (`getSpread`, `getSlopeDistance` with `SpreadContext`'s caches; water
  searches four cells, lava two, four where lava is fast). Two sources over a
  solid block or a source make a source (the `water_source_conversion` and
  `lava_source_conversion` game rules, defaults from the jar). Lava's
  dimension settings come from the dimension type (`fast_lava`: delay 10 and
  drop-off 1 in the Nether, else 30 and 2), and rising lava waits four
  times as long three times in four (`getSpreadDelay`, the level random).
  Flow between cells reads collision shapes (`canPassThroughWall`,
  `Shapes.mergedFaceOccludes` over the faces that touch the shared side).
- `LiquidBlock`'s hooks: `onPlace` and `neighborChanged` mix (lava beside or
  under water becomes obsidian from a source, cobblestone from flowing lava;
  lava on soul soil beside blue ice becomes basalt; each fizzes, level event
  1501) or schedule the fluid's tick; `updateShape` schedules it beside a
  source. Lava falling into water makes stone. Water washes away what it
  spreads into with its loot; lava fizzes.
- Waterlogging: a container takes a water source (`placeLiquid`) and
  schedules its water; every block holding water (waterlogged blocks, kelp,
  seagrass) schedules its water in a live shape update.
- Buckets (`Valimc.Player.Buckets`, `BucketItem.use`): the server casts the
  player's own ray (`Valimc.Physics.Clip`, vanilla's `BlockGetter.clip` with
  outline shapes, through sources for an empty bucket). An empty bucket picks
  up a source, a waterlogged block's water (it breaks if it cannot then
  stand), a bubble column or powder snow; a full one pours into a container
  that takes water, else beside the face, else once more beside it, replacing
  what a fluid may replace; water poured in the Nether evaporates. The world
  changes through the engine (`Region.bucket/2`), the held stack as
  `ItemUtils.createFilledResult` makes it.
- Fluid ticks are scheduled ticks keyed `{:fluid, id}`; the block phase runs
  the due block ticks, then the due fluid ticks, in the same engine call. A
  fluid tick whose reads (five cells around) would leave its group waits
  its fluid's delay and runs again, so a fluid at a group's edge flows once
  the groups merge.
- Generation's post-processing marks and fluid ticks (VMC-024d) are a stored
  part (`{:post, chunk}`), settled when the chunk first ticks with its eight
  neighbours generated in the group (`LevelChunk.postProcessGeneration`):
  each mark's fluid ticks at once and its block takes its neighbours' shape
  (flags 276), then the chunk's generation fluid ticks are due.

## Facts and fixtures

`FluidOracle` (pinned 26.3), stage `fluids`:

- `facts` → `priv/physics/fluids.json`: dimension attributes, conversion
  rule defaults, per state the `LiquidBlockContainer` fluids
  (`canPlaceLiquid`) and bucket replaceability, what `placeLiquid` with
  water sets (13,224 states), what `pickupBlock` sets first and gives
  (13,329 states).
- `outlines` → `priv/physics/outlines.json`: outline shapes (866
  geometries); 110 states move theirs by their position offset.
- `scenes`: flow over a probe `ServerLevel` whose block and fluid ticks are
  vanilla's own `LevelTicks`, in the overworld and the Nether, straddling
  chunk and 8 × 8 section lines; per tick the cell writes, level events and
  bucket outcomes. `check_fluids.exs` replays each scene through
  `rules::live::run` over four section stores read as one group's
  (`fluid_scene`): 160 scenes of 320 ticks (seed 31001, 166,174 writes:
  142,018 flowing, 1,146 new sources, 162 waterlogged, 69 obsidian, 4,117
  cobblestone, 5,597 stone, 41 basalt, 9,627 fizzes, 546 buckets emptied,
  262 picked up) match per tick; 600 scenes with seed 977 (654,648 writes)
  matched too.
- `clips`: 4,000 rays over 200 scenes (2,420 hits, 818 at fluid cells) and
  2,000 view vectors match `Valimc.Physics.Clip` (`check_clips.exs`).

`test/fluid_region_test.exs` runs fluids in region owners: water at a group's
edge waits and flows across the section line after a merge, mixing, and a
generated mark settling; `test/bucket_connection_test.exs` drives buckets
through a connection.

## Not here

- Bubble columns and lava's random ticks (fire) are
  [VMC-031b](VMC-031b.md).
- Bucket sounds for other players, the evaporation's smoke, statistics and
  advancements; an interaction shape's face override in the clip (cauldrons,
  composters, hoppers). A fluid shape is clipped at its own height (vanilla
  caches a fluid state's shape at the height of the first cell asked).
- A survival stack of empty buckets whose filled bucket has no room is
  refused instead of dropping it.

## Client scenario (phase-end handoff)

In survival with a water bucket and a lava bucket (and empty buckets): pour
lava into a 4 × 5 frame mould, pour water over it so the lava becomes
obsidian (a source) or cobblestone (flowing), pick the water back up, repeat
until the frame stands, light it with flint and steel and enter the portal.
Water and lava flow as in vanilla on the way, including across an 8 × 8
section line.
