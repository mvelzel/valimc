# Current work

Target: full vanilla Java 26.3 player experience (protocol 777) on Elixir 1.20.4 /
OTP 29.1.1, with Rust NIFs where native code measurably wins. This queue is
editable. [Compatibility](compatibility.md) describes the preview; the
[backlog](backlog.md) lists remaining features; [completed](history/completed.md)
indexes finished tickets. Evidence lives in tickets, not here.

## M1 — Foundations (complete)

VMC-062..069 replaced the preview's flat-world edit map, fsync-bound region writes,
per-feature transfers, mailbox block reads and monolithic connection with sections,
group commit, one transaction engine, snapshots, a game-time tick pipeline, the entity
model and a generated registry; see [architecture](architecture.md).

## M2 — Real worlds (complete)

VMC-010, 020..025, 026, 027, 028, 029c, 053 and 070..075 generate vanilla's
overworld, Nether and End live (terrain, features, structures, loot) with
portals, world settings and the world-generation commands; the gate is in
[VMC-025](tickets/VMC-025.md#m2-milestone-gate-october-21-2026). Commands on M3
systems (VMC-053h, k–n) move with those systems. Generation and tick time stay
matched against vanilla and Pumpkin, at least in Pumpkin's range.

## Foundations II (complete)

VMC-077 audited the code after M2 and rebuilt its foundations: everything that
interacts shares one owner (groups of 8 × 8 sections that merge and split, with
players, entities and blocks inside), one atomic frame per owner per tick in one
striped log, one entity store, one block fact table, Rust kernels for physics,
block rules, light and generation scheduling, and a layered module layout. The
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
| Blocks | Block rules, placement, mining | 029d → 029e → 039a → 032b |
| Fluids | A fluid module, fluid ticks | 031a |
| Mob families | One module set per family | 043b ∥ 043c ∥ 043d ∥ 043e ∥ 044a |
| Finale | The End fight, then the gate | 045a → 078 |

Phases:

1. **Now:** 043a, 029d and 031a. 029d and 031a share the block-rule
   engine, so they rebase often.
2. **After 043a:** 015i, 037n and 050a; Blocks goes on with 029e.
3. **After 015i:** 041a then 041b; 042a, 037o and 042b alongside.
4. **After 041b, 037n, 037o and 050a:** the families in parallel (043b
   first), plus 034n4c, 026d, 040a and 032b.
5. **Last:** 045a, then the gate.

When sessions are scarce, this order: 043a, 015i, 041a, 041b, 037n,
037o, 050a, 043b, 029d, 029e, 031a, 042a, 043c, 042b, 043d, 039a, 040a, 034n4c,
026d, 043e, 044a, 032b, 045a, 078.

Later: redstone and machines, enchanting and brewing, trading and raids,
vehicles, then commands/admin and certification.

## Paused

A furnace that holds items cannot be removed until its spill and stored
experience exist ([VMC-034f](tickets/VMC-034f.md)).

## Pending client gates

| Ticket | Remaining gate |
|---|---|
| [VMC-043a](tickets/VMC-043a.md) | Summoned zombie and primed TNT seen, killed, teleported across a group line and kept over a restart |

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Keep this file to open work: one row per open ticket, its remaining slice in a short
line. When a ticket is Done, drop its row, add it to the Done line and to
`history/completed.md`. `scripts/lint_docs.py` caps this file at 90 lines.
