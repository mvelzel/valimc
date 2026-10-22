# VMC-043a — Entity kinds beyond items and orbs

Status: Planned
Milestone: M3
Depends on: [VMC-077h](VMC-077h.md) (one entity store per owner).

Items and experience orbs are the only kinds in `Entity.Store`. M3 needs
living entities (mobs) and more non-living ones: primed TNT, falling blocks,
projectiles, end crystals and eyes of ender.

- **Generated entity facts.** An `EntityOracle` extracts every 26.3 entity
  type from the jar: category, dimensions and eye height, default attributes,
  fire immunity, its loot table, its spawn placement type and heightmap,
  persistence and despawn flags, tracking range and update interval. This is
  one fact source, read like the block facts.
- **Records.** One record schema for every kind. Living entities carry:
  - health, absorption and effects (from `Valimc.Living`, which players
    already use);
  - equipment, attributes and their modifiers, and the hurt and death
    timers;
  - an AI slot that VMC-041a fills.
- **Lifecycle and persistence.** Records persist, hand off between groups
  and survive restarts like items do.
- **Replication.** Trackers send spawn, metadata, equipment, head rotation,
  animations and hurt and death events, at each type's interval.
- **Testing aid.** `/summon` for every modelled type and `/kill` over
  entities, so later slices can test without spawning rules.

Acceptance:

- A summoned zombie and a summoned primed TNT (still inert) appear to the
  real client with vanilla metadata.
- Both persist across a restart and hand off across a group line.
- The entity facts match the oracle for every type.
