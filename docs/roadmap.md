# Current work

Target: full vanilla Java 26.3 player experience (protocol 777) on Elixir 1.20.4 /
OTP 29.1.1, with Rust NIFs where native code measurably wins. This queue is
editable. [Compatibility](compatibility.md) describes the preview; the
[backlog](backlog.md) lists remaining features; [completed](history/completed.md)
indexes finished tickets. Evidence lives in tickets, not here.

## M1 — Foundations (complete)

VMC-062..069 replaced the preview's flat-world edit map, fsync-bound region writes, per-feature
transfers, mailbox block reads and monolithic connection with sections, group commit, one
transaction engine, snapshots, a game-time tick pipeline, the entity model and a generated registry;
see [architecture](architecture.md).

## M2 — Real worlds (complete)

VMC-010, 020..025, 026, 027, 028, 029c, 053 and 070..075 generate vanilla's overworld, Nether and
End live (terrain, features, structures, loot) with portals, world settings and the world-generation
commands; the gate is in [VMC-025](tickets/VMC-025.md#m2-milestone-gate-october-21-2026). Commands
on M3 systems (VMC-053h, k–n) move with those systems. Generation and tick time stay matched against
vanilla and Pumpkin, at least in Pumpkin's range.

## Foundations II (complete)

VMC-077 audited the code after M2 and rebuilt its foundations: everything that interacts shares one
owner (groups of 8 × 8 sections that merge and split, with players, entities and blocks inside), one
atomic frame per owner per tick in one striped log, one entity store, one block fact table, Rust
kernels for physics, block rules, light and generation scheduling, and a layered module layout. The
final client run and its rechecks passed; see [VMC-077](tickets/VMC-077.md).

## M3 — Survival core (planned)

Gate: [VMC-078](tickets/VMC-078.md), a fresh-world survival run to the dragon's
death. Slices: the [backlog](backlog.md#m3--survival-core). A lane owns its
code, so one session per lane runs at once; a lane's slices run in order.

| Lane | Owns | Slices |
|---|---|---|
| Entities (critical path) | Entity store, physics kernel, a new AI context | 043a → 015i → 041a → 041b |
| Combat | Living damage, a projectile kernel, orb motion | 037n → 037o → 034n4c → 026d |
| World effects | Explosions, primed TNT, falling blocks | 050a → 040a |
| Spawning | Spawn rules and caps, structure entities, spawners | 042a → 042b |
| Blocks | Block rules, placement, mining | 029e → 039a → 032b |
| Fluids | A fluid module, fluid ticks | 031a → 031b |
| Redstone | Power, components, pistons, item machines | 047a → 048a → 048b → 049a |
| Mob families | One module set per family | 043b ∥ 043c ∥ 043d ∥ 043e ∥ 044a |
| Finale | The End fight, then the gate | 045a → 078 |

Phases:

1. **Now:** 043a, 029d and 031a (029d and 031a share the rule engine).
2. **After 043a and 029d:** 015i, 037n, 050a, 047a; Blocks goes on (029e).
3. **After 015i:** 041a then 041b; 042a, 037o and 042b alongside.
4. **After 041b, 037n, 037o, 050a:** families in parallel (043b first),
   plus 034n4c, 026d, 040a, 032b; Redstone goes on (048a, 048b, 049a).
5. **Last:** 045a, then the gate.

When sessions are scarce: 043a, 015i, 041a, 041b, 037n, 037o, 050a, 043b, 029e, 031a, 047a, 042a,
043c, 042b, 048a, 043d, 039a, 048b, 040a, 049a, 034n4c, 026d, 043e, 044a, 032b, 045a, 078.

Later: enchanting, brewing, trading, raids, vehicles, commands/admin, certification.

## Paused

A furnace holding items stays until its spill and stored experience exist ([VMC-034f](tickets/VMC-034f.md)).

## Pending client gates

| Ticket | Remaining gate |
|---|---|
| [VMC-037n](tickets/VMC-037n.md), [037o](tickets/VMC-037o.md) | A zombie's hits on armor and a raised shield, once VMC-041a's melee goal attacks; bows, crossbows, stuck arrows picked up, snowballs, eggs, an ender pearl, a splash potion and a punched fireball |
| [VMC-047a](tickets/VMC-047a.md) | A button-operated iron door and a lever-lit lamp |
| [VMC-042a](tickets/VMC-042a.md), [042b](tickets/VMC-042b.md) | Generated animals at spawn; monsters at night 24+ blocks away; peaceful clears them; they despawn 128 blocks away unless name-tagged; a village's villagers and a swamp hut's witch when their chunks first load; witches spawning in the hut; a fortress spawner's blazes near the player |
| [VMC-034n4c](tickets/VMC-034n4c.md) | A furnace's orbs scatter; orbs hop in lava; orbs lying together merge |
| [VMC-026d](tickets/VMC-026d.md) | A thrown eye of ender flies toward the stronghold; a zombie and orbs cross a Nether portal |
| [VMC-041a1](tickets/VMC-041a1.md), [041a2](tickets/VMC-041a2.md), [043a1](tickets/VMC-043a1.md) | A summoned zombie hunts, chases and hits a survival player, loses one behind a wall, only looks at a creative one; a pig wanders, follows a carrot and panics when hit; a piglin admires a dropped gold ingot; `/tp` of the nearest dropped item; `/kill @e[type=item]` and `@e[type=experience_orb]` remove them |
| [VMC-040a](tickets/VMC-040a.md) | Two clients: one asleep keeps the night, both skip it; monsters forbid sleep; bed respawn and its fallback; an anchor charges and explodes outside the Nether; a bed explodes in the Nether |
| [VMC-039a](tickets/VMC-039a.md) | A tilled, watered farm grows wheat, a stem its pumpkin, cane and a sapling's tree; bone meal; trampling |

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Keep this file to open work: one row per open ticket, its remaining slice in a short
line. When a ticket is Done, drop its row, add it to the Done line and to
`history/completed.md`. `scripts/lint_docs.py` caps this file at 90 lines.
