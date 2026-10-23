# VMC-043b — Overworld hostiles

Status: Planned
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

Acceptance:

- Each mob's behaviour fixtures match the oracle.
- On the real client, a night in the open plays as in vanilla.
