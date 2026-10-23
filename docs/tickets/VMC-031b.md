# VMC-031b — Bubble columns and lava's fire

Status: Awaiting client
Milestone: M3
Depends on: [VMC-031a](VMC-031a.md) (water and lava flow).

The two fluid behaviours VMC-031a left out, from pinned 26.3:

- **Bubble columns:** water sources over soul sand push up, over a magma
  block drag down; columns grow, shrink and turn back into water as their
  floor and the water above change.
- **Lava's fire:** lava's random ticks light what lava ignites near a player
  (`LavaFluid.randomTick`, the `fire_spread_radius_around_player` game rule).

Acceptance:

- Bubble column and lava fire fixtures match the oracle across section lines.
- On the real client, a column over soul sand pushes up and one over magma
  drags down, and lava beside planks lights them.

## What is live

- `valimc_core::rules::bubble`: a water source whose floor enables a column
  schedules its block tick (`LiquidBlock.onPlace`, `neighborChanged` and a
  shape update from below, 20 ticks); the tick fills the column upward
  (`BubbleColumnBlock.updateColumn`, flags 2: pushing up over the
  `enables_bubble_column_push_up` blocks, dragging down over the
  `enables_bubble_column_drag_down` ones, copying the column below). A
  column's shape update schedules its water and, when it cannot stand, its
  floor changed or a source to fill appeared above, its own tick 5 ticks out,
  which turns it back into water when its floor is gone.
- Lava's random ticks: the region's random tick sampler also picks lava
  cells, which run in the block rules as `ServerLevel.tickChunk` runs them,
  the block's random tick and then its fluid's (two `LavaFluid.randomTick`
  calls). Near a player (within the rule's radius, every player when it is
  -1) lava climbs up to two cells for an air cell beside something lava
  ignites, or tries three cells beside it for one with air above, and sets
  fire (`BaseFireBlock.getState`); a block in `blocks_lava_fire_spread` stops
  the climb. What lava ignites is a new fact bit (`ignitedByLava`,
  `priv/physics/fluids.json`).
- Fire's `onPlace`: new fire that cannot stand goes, and fire schedules its
  tick 30–39 ticks out (the level random). Fire breaking by a shape update
  raises no break event, as `Level.destroyBlock` spares fire.
- A fluid tick due this game tick still counts as scheduled while the block
  ticks run: a tick scheduled for it meanwhile is dropped, as vanilla's fluid
  `LevelTicks` holds it until the fluid phase drains it.

## Fixtures

`FluidOracle scenes` now also sets magma blocks and soul sand under water
pools, bubble columns, planks and hay, and random-ticks a random lava cell on
about one tick in three (some scenes keep lava from spreading fire), with
fire's own ticks left out on both sides. `check_fluids.exs`: 160 scenes of
320 ticks (seed 31001, 203,864 writes: 841 bubble column writes, 152 fires,
99 obsidian) match per tick; 600 scenes with seed 977 (763,119 writes, 3,336
bubble column writes, 531 fires) too. `test/fluid_region_test.exs` grows a
column over magma and lights planks beside lava in a region owner.

## Not here

- Fire's own ticks (burning, spreading, burning out) are VMC-031's
  (backlog); entities in bubble columns are the entity lanes'.
- Fire set by lava inside an empty portal frame does not open the portal
  (`BaseFireBlock.onPlace`'s portal search is `Valimc.World.Portal.Fire`'s,
  which only flint and steel and fire charges reach).

## Client scenario (phase-end handoff)

Pour water three deep over soul sand and over a magma block: the columns
appear and push up or drag down. Pour lava beside oak planks with a player
nearby: fire appears on or beside them within a few minutes.
