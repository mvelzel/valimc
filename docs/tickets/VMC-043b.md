# VMC-043b — Overworld hostiles

Status: In progress
Milestone: M3
Depends on: [VMC-041b](VMC-041b.md), [VMC-037n](VMC-037n.md),
[VMC-037o](VMC-037o.md) (skeletons), [VMC-050a](VMC-050a.md) (creepers).

The mobs a survival night brings, with their goals, attacks, equipment
chances, burning in daylight, variants and loot:

- zombie, husk, drowned, zombie villager, babies and chicken jockeys;
- skeleton, stray and bogged;
- creeper, including charged creepers;
- spider and cave spider;
- enderman (blocks it carries, teleports, stare aggro);
- witch, slime, phantom and silverfish. Phantoms spawn from
  `PhantomSpawner`, which reads each player's time since rest
  (`time_since_rest`, kept by [VMC-040a](VMC-040a.md)).

Slices:

- [VMC-043b1](VMC-043b1.md) — what every hostile shares (local difficulty,
  `finalizeSpawn`'s equipment and enchantments, burning in daylight, item
  pickup) and the zombie family: zombies, husks and zombie villagers.
- [VMC-043b2](VMC-043b2.md) — drowned: swimming, tridents, going ashore at
  night, and the zombie's turtle egg trampling.
- [VMC-043b3](VMC-043b3.md) — skeleton, stray and bogged: the bow goal
  shooting through VMC-037o.
- [VMC-043b4](VMC-043b4.md) — creepers (charged ones too) exploding through
  VMC-050a, spiders and cave spiders.
- [VMC-043b5](VMC-043b5.md) — endermen.
- [VMC-043b6](VMC-043b6.md) — witches, slimes, phantoms (with
  `PhantomSpawner`) and silverfish.

Riding is [VMC-046](../backlog.md)'s: chicken and spider jockeys spawn as
vanilla's draws decide, with the mount beside its rider until mobs can ride.

Acceptance:

- Each mob's behaviour fixtures match the oracle.
- On the real client, a night in the open plays as in vanilla, and a
  skeleton and a player shoot each other (from VMC-037o).
