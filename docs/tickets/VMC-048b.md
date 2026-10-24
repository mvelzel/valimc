# VMC-048b — Pistons and moving blocks

Status: Done
Milestone: M3
Depends on: [VMC-047a](VMC-047a.md), [VMC-015i](VMC-015i.md) (entities
are pushed).

Pistons and sticky pistons, as vanilla's `PistonBaseBlock` and
`PistonMovingBlockEntity`:

- **Pushing and pulling:** the push limit of 12, which blocks move or
  break, slime and honey groups, and immovable blocks, including blocks
  with block entities.
- **Moving blocks:** `moving_piston` block entities, which persist and hand
  off. Their collision geometry is in the physics kernel, replacing today's
  empty shape (the old VMC-014b5).
- **Entities:** players, mobs and items riding or pushed by moving blocks.
- **Timing:** zero-tick and pulse behaviour as vanilla times it.

Acceptance:

- Push and pull fixtures, including slime contraptions, match the oracle's
  block states and entity positions.
- A piston door works on the real client, and a player rides a moving
  block.

## What is live

- **Facts.** `RedstoneOracle facts` adds the `piston` component (sticky or
  not, its extend and contract sounds) and `pistons`: every block's push
  reaction where not `PUSH_PULL` (16 push only, 367 popped, 17 immoveable),
  the blocks no tool breaks and those with block entities, each the same
  for every state of its block.
- **Engine** (`valimc_core::rules::piston`), as the classes do it:
  - `checkIfExtend` after a base's placement, update or `setPlacedBy`:
    the signal from any side but its face or at the cell above, the
    structure resolver before an extension, and the retraction that drops
    its block (event 2) when the block two ahead is still extending and
    young, ticked this tick or the run is in the tick's first part
    (`isHandlingTick`).
  - Block events (`Level.blockEvent`) queue once each until the tick's
    event phase (`runBlockEvents`) runs them in order, those they raise
    too; a note block's plays there. `triggerEvent`: extension
    (`moveBlocks`), retraction with the moving base and the sticky pull,
    the head's and the two-ahead block's early landing (`finalTick`),
    sounds from the level random.
  - `PistonStructureResolver`: lines, slime and honey branches (they do
    not stick together), collisions reordered, the limit of 12, popped
    blocks, the border and build height. `moveBlocks` writes with vanilla's
    flags in its order, vacated cells in Java `HashMap` order, then the
    updates.
  - `Level.setBlock` hooks: a moving piston's block entity goes with its
    block; `affectNeighborsAfterRemoval` runs for a move by a piston
    (`UPDATE_MOVE_BY_PISTON`), which wire, torches, levers, buttons,
    plates, diodes, hooks and tripwire ignore.
  - Moving pistons' block entities (`valimc_core::piston::Moving`: the
    carried state, direction, extending, source, progress and its old
    value, last tick, tick order) tick in the order they were made:
    half a block, or they land as their block shaped by their neighbours
    (`updateFromNeighbourShapes`, waterlogging dropped, or placed and
    destroyed when it cannot stay).
  - Heads: a head goes when its base does (`updateShape`), tells its base
    of updates and breaks a fitting base with it.
  - A retracting base's neighbours read it as its extended base while it
    moves (survival, a diode's floor, wire's floor, attached components).
  - Writes without `UPDATE_CLIENTS` (a moving piston's cells) are not sent
    to clients: their own pistons make them from the block event.
- **Kernel** (`valimc_core::physics`): a moving piston's collision shape is
  its block entity's (`getCollisionShape`): the retracting base's extended
  shape joined with the head or carried block lagging its cell, as
  `Shapes.or` and `optimize` make it (`physics::join`: snapped boxes and
  index mergers, so grids and clips are vanilla's), passed through by a
  body a piston moves its way (`NOCLIP`). Chunk snapshots carry the
  stores' moving pistons. A tick's moving blocks push bodies
  (`moveCollidedEntities`, a slime block flinging them, `moveStuckEntities`
  on honey, `fixEntityWithinPistonBase`) with the piston mover's
  `Entity.move`: `limitPistonMovement`, collision with step-up, ground,
  restitution and block speed; while one block pushes, it and the blocks
  after it in the tick order stand as they were.
- **Owner** (`World.RegionData`, `TickPipeline`): each tick runs block
  events after the block ticks and moving pistons after the entities, in
  simulated chunks. Moving pistons persist as `{:piston, position}`
  records, live in the section's Rust store beside the cells (snapshots,
  rules) and move with their section; a run's changes to them commit with
  the section of their cell. Block events wait in the section that raised
  them. Pushes move the section's items, orbs, mobs and other bodies (an
  effect cloud ignores them), its siblings' and, through the group, its
  players: a player's session moves its own position as vanilla's server
  does, sending nothing. Pistons' block event packets go to clients within
  64 blocks with their sounds; chunk packets list moving pistons with their
  update tags. A placed piston runs `setPlacedBy`.

## Facts and fixtures

`PistonOracle` (pinned 26.3, stage `pistons`) runs over a probe level
whose block events queue and run as `ServerLevel` runs them and whose block
entities live and tick as `LevelChunk` and `Level.tickBlockEntities` keep
them:

- `scenes`: pistons and sticky pistons in every direction among stone,
  glass, slime, honey, obsidian, bedrock, glazed terracotta, chests,
  furnaces, popped blocks, power sources, observers, repeaters, lamps and
  note blocks, with player sets, `setPlacedBy`, lever and button uses (some
  toggled twice in a tick), lines at and past the push limit, sticky pulls
  on 1 to 3 tick pulses and piston doors, across the x 128 section line and
  the z 0 chunk line. Each tick: actions, block ticks, block events, block
  entities. Per tick the writes, sounds, block events raised and run, and
  every moving piston's block entity. `check_pistons.exs` replays them on
  the live engine over four section stores. 200 scenes of 160 ticks (seed
  48201: 67,330 writes, 6,713 block events run, 3,881 extensions, 2,577
  retractions, 186 drops, 19,796 moving block states) and 400 (seed 9117:
  133,856 writes, 12,974 block events, 38,550 moving block states) match
  tick by tick.
- `pushes`: a piston or sticky piston in any direction behind a line of
  stone, slime or honey with items and armor stands around and on it.
  `check_piston_pushes.exs` replays each block entity phase in the kernel:
  400 scenes (seed 48202: 2,400 phases, 560 entities moved) give vanilla's
  feet and velocity bit for bit, and its ground.
- `PistonCollisionOracle`'s moving pistons with block entities, no longer
  skipped: 19,957 shapes (every moved grid, the head, base and noclip
  cases) and 119,886 clips match bit for bit (stage `collision_shapes`).

Scenes keep containers (a container's removal draws from the level random
for its spill, which ValiMC's owner does with its own) and have no loot
tables (popped blocks draw nothing either); a note block's own sound is
the owner's.

`test/piston_region_test.exs`: a lever extends a sticky piston at the
tick's event phase, its moving blocks persist with the section's parts and
land, and it pulls its block back; a block pushed up collides as it moves
and carries an item.

## Not here

- Pushes leave out what an entity's move does beyond its motion: fall
  damage, `applyEffectsFromBlocks` (a pushed entity's plates count at the
  next contacts pass) and the stuck multiplier's reset.
- A group's sections run their phases one section after another, so a
  contraption across a section line ticks its block events and moving
  blocks in each section's order, and a block event raised in a section
  runs in that section's next event phase.
- Block events at cells of chunks that do not tick run with their section
  (vanilla keeps them until those chunks tick).
- A moving piston without its block entity (an imported one) stays;
  `MovingPistonBlock.useWithoutItem` and a creative player's head break
  (`playerWillDestroy`) are not modelled.

Reference: Minecraft 26.3 (`PistonBaseBlock`, `PistonStructureResolver`,
`PistonHeadBlock`, `MovingPistonBlock`, `PistonMovingBlockEntity`,
`PistonMath`, `Shapes`, `IndirectMerger`, `NonOverlappingMerger`,
`DiscreteCubeMerger`, `BitSetDiscreteVoxelShape`, `VoxelShape`,
`Entity.move`, `LevelChunk`, `Level`, `ServerLevel`, `NoteBlock`),
decompiled privately under `research/decompiled/vmc-048b`.

Checks: `cargo test -p valimc_core` (124), `cargo clippy --all-targets`
with `parity` (no new findings), `cargo fmt`; `mix test --stale` (695
passed) and the piston, storage, redstone, placement, fluid, falling
block, explosion, mining and chest tests; `check_vanilla.py --changed
--regen` passed all 107 selected stages (`pistons`, `redstone`,
`redstone_wire`, `placement`, `collision_shapes` and `tcp` among them).

## Client gate (October 24, 2026)

The dedicated M3 run 4 tester passed the two-high sticky door's extension
and return after actual button use. A player rode a block upward from
Y −59 to −58. The grounded honey retry carried the player exactly one
block east, with ground true before and after, superseding the earlier
ambiguous half-block observation. Actual lever/button input and graphical
motion establish the passes; owner position reads supplement them.

The frozen run-01..11 lineage and fixture limits are in the private report
`.local/client-tests/M3-run-04/report.md`; the exact honey reads are
`honey-grounded-before.txt` and `honey-grounded-after.txt` beside it.
The completed parent check on main also passed the `pistons` and collision
stages within all 100 selected vanilla stages, and the 558-check fast suite.
These observations close the stated door/rider/honey graphical gate;
other push permutations remain covered by native fixtures, with the
implementation limits above unchanged.
