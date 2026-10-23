# VMC-042b — Structure mobs and spawners

Status: In progress
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

- **042b1 — entities in the chunk's records.** Done (October 23, 2026).
- **042b2 — spawner blocks.** Done (October 23, 2026).
- **042b3 — structure spawn overrides.** Planned.

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
