# VMC-026d — Eyes of ender; mobs and orbs through portals

Status: Planned
Milestone: M3
Depends on: [VMC-037o](VMC-037o.md), [VMC-015i](VMC-015i.md),
[VMC-034n4c](VMC-034n4c.md) (orb gaps),
[VMC-026](VMC-026.md) (its M3 carry-overs).

- **Eyes of ender.** Using one throws an `EyeOfEnder` toward the nearest
  stronghold's start (generation's structure starts, as `/locate` finds
  them). It drops or breaks with vanilla's chance.
- **Portal travel for every entity.** Items already travel
  ([VMC-026c](VMC-026c.md)). Mobs and experience orbs now travel through
  Nether and End portals and gateways too, by the same path. Each keeps its records across
  the dimension change, and the cooldowns match vanilla's.

Acceptance:

- An eye leads to the same stronghold as vanilla on fixed seeds.
- A zombie and an orb pass a Nether portal and arrive with their state.
