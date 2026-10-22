# VMC-043a — Entity kinds beyond items and orbs

Status: Awaiting client
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

## Implementation (October 22, 2026)

- **Facts.** `EntityOracle facts` writes `priv/registry/entity_facts.json`
  (stage `entity_facts`): all 161 types with id, category, width, height, eye
  height, fixed, fire immunity, summonable, saved, allowed in peaceful, spawn
  far from players, tracking range, update interval, delta tracking,
  description key, loot table, spawn placement and heightmap (registered
  types only), default attributes (living types), the mob categories' caps
  and despawn distances, and the entity data fields' indices and serializers.
  It replaces `priv/protocol/entities.json` and `EntityMetadata.java`;
  `Valimc.Data.EntityTypes` is its one reader.
- **Records.** `Entity.Body` is one schema for every kind but items and
  orbs: type, rotation and head yaw, motion, the type's own data and, for a
  living type (kind `:mob`), an `Entity.Mob` with its `Valimc.Living` state
  (health with the hurt and death timers, absorption, effects, fire, air,
  freezing), equipment by slot, attribute overrides with modifiers and an AI
  slot (nil until VMC-041a). Other types are kind `:object`. Modelled types
  are `minecraft:zombie` and `minecraft:tnt`; families and world effects add
  theirs.
- **Store.** `Entity.Store` builds, records, validates, advances (teleports
  and handoff steps), kills and ages bodies beside items and orbs; records
  persist by uuid like items, cross section lines in the group commit and
  group lines by the durable handoff. Item physics, merges, pickups and
  portals leave bodies alone; bodies are inert until VMC-015i.
- **Death.** `/kill` of a mob is vanilla's `genericKill`: health 0, the
  damage event and entity event 3, the dying pose, then 20 ticks of death
  animation (timers in `Living.Health`), the poof (event 60) and removal
  once that commit is durable. Any other entity is removed at once. Loot and
  XP are VMC-037n's.
- **Replication.** Owner trackers send a body's spawn (with pitch, yaw and
  head yaw), its non-default entity data, synced attributes and equipment on
  pairing, then at the type's update interval (or when data changed) motion
  if the type tracks it, relative moves with rotation, changed data,
  attributes and equipment, head yaw, and entity events the tick they
  happen. A connection sees a body within its type's tracking range.
- **Commands.** `/summon <type> [pos]` for modelled types (vanilla's
  summonable, spawnable-bounds and peaceful checks and messages; NBT and
  unmodelled types are refused as not supported yet). `/kill` and
  `/teleport` select bodies from published section views (`Targets.entities`
  with type, box, distance and sort options); a body teleports within its
  dimension only.
- Anvil export leaves bodies out until mobs are exported.

Reference: 26.3 `EntityType` (and its `UpdateInterval`), `EntityTypes`,
`SpawnPlacements`, `SpawnPlacementTypes`, `MobCategory`, `DefaultAttributes`,
`AttributeSupplier`, `ServerEntity.sendPairingData`/`sendChanges`,
`LivingEntity.kill`/`hurtServer`/`die`/`tickDeath`, `PrimedTnt` and `Zombie`
data definitions, `SummonCommand`, `KillCommand`.

Checks: `mix test test/entity_bodies_test.exs` (records, kill and death
timers, tracker frames, a zombie and a primed TNT kept over an owner restart
and handed across a group line, `/summon`, `/tp` and `/kill`); the entity,
store, item, region, storage and command suites that touch the changed
modules (85 tests); `check_vanilla.py --only entity_facts,entity --regen`
(facts equal the oracle; zombie and TNT spawns, mob and TNT data and the
zombie's attributes byte-equal vanilla's); `check_vanilla.py --changed`
26/26; `mix test.fast` 418/419, the one failure a block-query timeout under
host load that passes alone.

Client scenario (phase-end handoff): in a fresh world, `/summon zombie ~2 ~
~` and `/summon tnt ~ ~ ~3`: an adult zombie facing south and a primed TNT
block appear (the TNT does not flash or explode, the zombie does not move).
In creative, `/tp @e[type=zombie] ~800 200 ~` then `/tp @s ~800 200 ~`:
the zombie is there, hovering, in another group's section (it was handed
over). Restart the server and rejoin: the zombie and, back at the start,
the TNT are still there. `/kill
@e[type=zombie]` shows the hurt flash, the zombie falls over and poofs after
a second; `/kill @e[type=tnt]` removes the TNT at once.

Next: VMC-015i moves bodies; VMC-037n adds damage, loot and XP; families
add their types' data.
