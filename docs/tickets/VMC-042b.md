# VMC-042b — Structure mobs and spawners

Status: Planned
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
