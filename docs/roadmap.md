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

## Foundations II (VMC-077, in progress)

The pre-M3 audit's plan, decided October 21, 2026: players and everything that
interacts share one owner (dynamic groups of 8 × 8 sections), one atomic frame per
owner per tick, volatile proto chunks, no world migration. Phase 0 and waves 1–2
and waves 1–3 have landed; layout and the final client run remain.

| Ticket | Open slice | Status |
|---|---|---|
| [VMC-077i](tickets/VMC-077i.md) | Players owned by their group; final-run fixes: portal arrival, death experience, chest menus, chests at region lines | Awaiting client |
| [VMC-077k](tickets/VMC-077k.md) | Living rules for any entity | Foundation |
| VMC-077r | Phase 6: domain layout, layering check, docs of the new model | In progress |

Done in foundations II: phase 0, VMC-077a–g, 077j1–j3, 077l, 077m, 077n, 077o,
077h, 077p, 077q. The final client run passed apart from the fixes listed above.

## M3 onward

Survival core on the entity model (mobs/AI, spawning, combat, projectiles), redstone
and block updates, then commands/admin and certification; backlog milestones C–F
hold the rest. From VMC-026: the dragon fight (crystals, exit portal, new gateways),
thrown eyes of ender, and orbs (VMC-034n4c) and mobs through portals.

## Paused

Cooking-orb simulation ([VMC-034n4c](tickets/VMC-034n4c.md)) is unblocked by the
entity model (orbs already age and despawn). Additional status effects and container
variants can resume. Sugar cane and cactus growth need their placement survival rules
first ([VMC-066](tickets/VMC-066.md)). Removing a furnace that holds items is refused
until its spill and stored experience exist ([VMC-034f](tickets/VMC-034f.md)).

## Pending client gates

| Ticket | Remaining gate |
|---|---|
| [VMC-005b2c](tickets/VMC-005b2c.md) | Server CLONE/type-2 fill from a creative container menu (VMC-032) |

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Keep this file to open work: one row per open ticket, its remaining slice in a short
line. When a ticket is Done, drop its row, add it to the Done line and to
`history/completed.md`. `scripts/lint_docs.py` caps this file at 90 lines.
