# VMC-042a — Natural spawning and despawning

Status: Planned
Milestone: M3
Depends on: [VMC-015i](VMC-015i.md), [VMC-043a](VMC-043a.md).

Spawning follows vanilla's `NaturalSpawner`:

- mob categories and their per-player local caps (26.x);
- biome spawn lists from the data reports and spawn placement rules;
- light and the spawnable surface;
- pack sizes and the spawn tick cadence;
- the spawns made with a chunk when it generates.

Despawning follows the instant and random distances, persistence (name tags
and picked-up items) and the peaceful-difficulty rules. Spawning runs in each
group over its simulated chunks. A cap counts what the group sees near its
players, so no global process counts mobs.

Acceptance:

- In fixed seeds and positions, spawn attempts choose the oracle's mobs,
  positions and packs.
- Caps hold with several players in one group and in separate groups.
- Mobs despawn at vanilla's distances.
