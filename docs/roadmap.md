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

## M3 — Survival core (in progress)

Gate: [VMC-078](tickets/VMC-078.md), a fresh-world survival run to the dragon's
death. Slices: the [backlog](backlog.md#m3--survival-core). A lane owns its
code, so one session per lane runs at once; a lane's slices run in order.

| Lane | Owns | Slices |
|---|---|---|
| Entities (critical path) | Entity store, physics kernel, a new AI context | 043a → 015i → 041a → 041b |
| Combat | Living damage, a projectile kernel, orb motion | 037n → 037o → 034n4c → 026d |
| World effects | Explosions, primed TNT, falling blocks | 050a → 040a |
| Spawning | Spawn rules and caps, structure entities, spawners | 042a → 042b |
| Blocks | Block rules, placement, mining | 029e → 039a → 039b → 039c → 032b |
| Fluids | A fluid module, fluid ticks | 031a → 031b |
| Redstone | Power, components, pistons, item machines | 047a → 048a → 048b → 049a |
| Mob families | One module set per family | 043b ∥ 043c ∥ 043d ∥ 043e ∥ 044a |
| Finale | The End fight, then the gate | 045a → 078 |

Current order:

1. The M3 gate's findings ([083](tickets/VMC-083.md)): the failures and missing commands the gate run found, then one client run of what it could not observe. The survival route itself passed ([078](tickets/VMC-078.md)).
2. Then define M4 from the backlog.
3. Later: SIMD where data-parallel work dominates ([082](tickets/VMC-082.md)) and the performance items left in [081](tickets/VMC-081.md#closure).

Done: [081](tickets/VMC-081.md) (with [081c1](tickets/VMC-081c1.md), [081c3](tickets/VMC-081c3.md), [081d](tickets/VMC-081d.md), [081g1](tickets/VMC-081g1.md), [081g2](tickets/VMC-081g2.md), [081h](tickets/VMC-081h.md), [081j](tickets/VMC-081j.md), [081k](tickets/VMC-081k.md), [081l](tickets/VMC-081l.md)), [081c2](tickets/VMC-081c2.md), [081i](tickets/VMC-081i.md), [081c](tickets/VMC-081c.md), [081b](tickets/VMC-081b.md), [080k](tickets/VMC-080k.md), [032b](tickets/VMC-032b.md), [039b](tickets/VMC-039b.md), [039c](tickets/VMC-039c.md),
[037o1](tickets/VMC-037o1.md), [045a1](tickets/VMC-045a1.md),
[048b](tickets/VMC-048b.md), [049a](tickets/VMC-049a.md), [078b](tickets/VMC-078b.md), [078c](tickets/VMC-078c.md), [078d](tickets/VMC-078d.md), [078e](tickets/VMC-078e.md), [056a](tickets/VMC-056a.md), [056b](tickets/VMC-056b.md).

Later: enchanting, brewing, trading, raids, vehicles, commands/admin, certification.

## Paused

A furnace holding items stays until its spill and stored experience exist ([VMC-034f](tickets/VMC-034f.md)).

## Pending client gates

The October 30–31 gate run passed the survival route and most family
observations ([078](tickets/VMC-078.md)). The family tickets' remaining
observations and the run's failures are gathered in [083](tickets/VMC-083.md),
which closes them with one client run.

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Keep this file to open work: one row per open ticket, its remaining slice in a short
line. When a ticket is Done, drop its row, add it to the Done line and to
`history/completed.md`. `scripts/lint_docs.py` caps this file at 90 lines.
