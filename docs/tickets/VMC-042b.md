# VMC-042b — Structure mobs and spawners

Status: Awaiting client
Milestone: M3
Depends on: [VMC-043a](VMC-043a.md), [VMC-042a](VMC-042a.md).

Today generation only advances the random a structure's mobs would draw
(`worldgen/structure/mobs.rs`). An unmodelled one fails its chunks, for
example a drowned chicken jockey in a cold ocean ruin.

- **Entities from generation.** Template entities and piece spawns become
  real entities in the chunk's records. These include villages, mansions,
  monuments, witch huts, outposts, igloos, ocean ruins and end cities'
  shulkers.
- **Spawners.** Spawner block entities spawn on their own schedule:
  dungeons, fortress blazes, mineshaft cave spiders and stronghold
  silverfish.
- **Failure policy.** An entity type without behaviour yet still exists as
  a persisted entity, and generation never fails for it.
- **Structure spawn overrides.** Natural spawning (VMC-042a) reads each
  structure's spawn overrides: witches and cats in a swamp hut, guardians
  in a monument, pillagers at an outpost, nothing in an ancient city or a
  trial chamber, and the fortress enemies (blazes, wither skeletons) on its
  nether bricks. The structure starts and references a chunk's spawn
  reads have to stay with the loaded chunk after generation (today the
  starts live only in the generation frontier).

Acceptance:

- Every structure in the vanilla generation checks places its entities,
  matching the oracle's records.
- A fortress spawner spawns blazes for the player.
- Natural spawns inside structures choose the oracle's override mobs
  (`NaturalSpawnOracle` scenes with structure starts).
- No generation error remains for entities.

## Slices

- **042b1 — entities in the chunk's records.** Implemented (October 23, 2026).
- **042b2 — spawner blocks.** Implemented (October 23, 2026).
- **042b3 — structure spawn overrides.** Implemented (October 23, 2026).

## 042b1 — entities in the chunk's records

- **Records.** A generated entity (`worldgen::region::Entity`) keeps its
  type, position and yaw, and now what else generation gave it as SNBT (a
  template's entity NBT, a mineshaft minecart's loot table and seed, an end
  city frame's facing and elytra), whether it is persistent
  (`setPersistenceRequired`: a hut's witch and cat, a ruin's drowned and its
  zombie nautilus, a mansion's illagers, an elder guardian, a template
  mob's `PersistenceRequired`) and whether it rides the entity added before
  it. Proto chunks carry them (format 6), full chunks hand them to the
  region, and `/place` adopts its own.
- **Bodies.** `Body.generated/3` makes a body of any known type: a modelled
  one as `new/1` makes it, any other inert with its type's data at the
  client's defaults, keeping the SNBT (`preserved`) for its family. Records
  of any known type restore. A frame's spawn data is its facing.
- **Failure policy.** A baby zombie's or drowned's chicken jockey draws
  the chicken's `finalizeSpawn` (variant, sound variant, `Mob`'s) and adds
  the chicken before its rider; a type whose `finalizeSpawn` is not modelled
  draws nothing. No entity fails generation.
- **Checks.** `DecorationOracle`'s added entities also record persistence,
  the vehicle's type and a minecart's or frame's data; `check_decoration`
  and now `check_live_decoration` compare them, and the live check counts
  the records the region keeps. The checks caught the elder guardian's and
  the zombie nautilus's persistence.

Not here: riding (a rider is a body beside its vehicle until vehicles),
a frame's item in its entity data (it shows empty), what families read
from `preserved` (professions, equipment).

## 042b2 — spawner blocks

- **Kernel.** `spawning::block_spawner` is `BaseSpawner.serverTick`: a
  non-spectator player within the required range, the countdown, `count`
  spots within the spawn range (`getSpawnAABB` free of blocks), the
  spawner's spawn rules (`EntitySpawnReason.SPAWNER`: `checkMobSpawnRules`
  passes, surface monsters need no sky, silverfish no distance; a monster
  still needs darkness), the nearby count of its type, the yaw, the mob's
  walk target and obstruction, then a new delay. `finalizeSpawn` is the
  families'.
- **Group.** `World.Spawning.plan/1` collects the group's spawner block
  entities in simulated chunks, parses each compound once (type, delays,
  count, ranges) and keeps its countdown by position; those with a player
  in range and their block still a spawner go into the same
  `natural_spawn` call, after the natural spawns and despawns. Their mobs
  are plain bodies adopted by their sections; each spawn is level event
  2004 at the spawner. Game rule `spawner_blocks_work` (default on).
- **Fixtures.** `NaturalSpawnOracle fixtures` ticks a vanilla
  `BaseSpawner` loaded from the compound decoration saves in scenes of a
  dungeon (zombies, skeletons, spiders; lit, peaceful, a player out of
  range), a fortress (blazes), a mineshaft corridor (cave spiders) and a
  stronghold (silverfish), its mobs cleared every 250 ticks; each spawn
  records the level random after its `finalizeSpawn`, from which the kernel
  goes on. `check_natural_spawning` compares every tick's spawns and delay.

Not here: spawn potentials (a spawner always spawns the type its spawn
data names), a spawn data's own position or entity data, the poof entity
event and the block event the client's spin reads; the countdown restarts
from the saved `Delay` after a restart or a group change.

## 042b3 — structure spawn overrides

- **Kept starts.** Decorating a chunk records the starts it references
  whose structures override spawns (`spawn_overrides` in the structure
  facts): the structure, the start's box (`getBoundingBox`, grown with its
  terrain adaptation) and the boxes of its pieces that reach the chunk, as
  placement left them. Proto chunks carry them (format 7), the full chunk
  hands them to its section (`RegionData` `structures`, persisted as
  `{:structures, chunk}` records) and natural spawning sends those of the
  simulated chunks with each tick.
- **Kernel.** `spawning::structures` is `NaturalSpawner.mobsAt`: a monster
  on nether bricks inside a fortress's box is one of the fortress's
  enemies; inside a start whose structure overrides the category (in any
  of its pieces, or anywhere in its box) the override's spawners replace
  the biome's, for both the pick and the position check (`canSpawnMobAt`
  matches a spawner by type and counts, not weight, as `SpawnerData`
  equality does: a fortress's zombified piglins fit the Nether wastes'
  list). The overrides come
  from `priv/worldgen/structures.json` (`Worldgen.Facts.spawn_overrides/0`)
  into the spawn facts.
- **Checks.** `StructurePlacementOracle live` lists each final chunk's
  kept starts from vanilla's references and starts; `check_live_decoration`
  compares them and the region's parts. `NaturalSpawnOracle` scenes hold
  structure starts (a probe `StructureManager` whose starts every chunk
  their box reaches references): a swamp hut (by night, and its creatures),
  a monument, an outpost, a fortress's nether bricks and pieces, an
  ancient city and a trial chamber's pieces.

Not here: imported worlds' starts and references (Anvil's
`structures` compound) are not read, so their chunks spawn as their biomes.

## Checks (October 23, 2026)

Every `worldgen_structure_placement*`, `worldgen_live*` (with structures,
2,816 overworld final chunks), `worldgen_decoration*`, `worldgen_datapack`
and `place` stage passes with the entities' new records; they caught the
elder guardian's and the zombie nautilus's persistence, and a hut's height
kept from before its placement. `natural_spawning`: 56,800 spawn ticks
(12,674 mobs, the six structure scenes among them) and 73,200 spawner ticks
(343 mobs, every delay) equal vanilla's; it caught `canSpawnMobAt`'s
weight-blind match. `test/natural_spawning_test.exs` (a spawner's blazes, a
hut's witches), `test/full_chunk_test.exs` (records of any type),
`test/entity_bodies_test.exs`; `cargo test -p valimc_core`; `mix test.fast`
471/471.

Reference: 26.3 `BaseSpawner`, `SpawnerBlockEntity`, `NaturalSpawner`
(`mobsAt`, `isInNetherFortressBounds`, `canSpawnMobAt`),
`ChunkGenerator.getMobsAt`, `StructureManager`, `StructureSpawnOverride`,
`Zombie`/`Drowned.finalizeSpawn`, `Chicken`, `AgeableMob`, `SwampHutPiece`,
`OceanRuinPieces`, `OceanMonumentPieces`, `WoodlandMansionPieces`,
`EndCityPieces`, `MineshaftPieces`, `StructureTemplate.placeEntities`, the
spawn predicates of `Monster` and `Silverfish`; decompiled privately with
Vineflower 1.12.0 (`research/decompiled/vmc-042b`).

## Client scenario (phase-end handoff)

In a fresh vanilla world: `/locate structure village_plains`, fly there —
villagers (standing still) and the village's animals are there when the
chunks first load, and stay after a reconnect. `/locate structure
swamp_hut` at night: the witch and the black cat stand in the hut, and new
monsters spawning on its floor are witches. In the Nether, `/locate
structure fortress` and find a blaze spawner: within 16 blocks of it, in
survival, blazes appear around it (with the spawner's flames) every 10–40
seconds, at most six nearby; walking 20 blocks away stops them.
