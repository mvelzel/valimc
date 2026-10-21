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

## M2 — Real worlds (in progress)

| Ticket | Open slice | Status |
|---|---|---|
| [VMC-026](tickets/VMC-026.md) | Nether, End and portals: live, with items through portals and stronghold portal rooms; client check of a generated portal room pending | Awaiting client |
| [VMC-010](tickets/VMC-010.md) | Administration: lists, admin commands, save control, idle timeout and console live; RCON remains | In progress |
| [VMC-053](tickets/VMC-053.md) | Commands: world and administration commands live; `place` waits for structures | In progress |

Done in M2: VMC-020..025, 026a..c, 027, 028, 029c, 070..075 (see [completed](history/completed.md)).
Commands on M3 systems (VMC-053h, k–n) move with those systems. Generation and tick
time stay matched against vanilla and Pumpkin, at least in Pumpkin's range.

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
| [VMC-026](tickets/VMC-026.md) | A generated stronghold's portal room: frames filled, the End, the credits and back |

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Keep this file to open work: one row per open ticket, its remaining slice in a short
line. When a ticket is Done, drop its row, add it to the Done line and to
`history/completed.md`. `scripts/lint_docs.py` caps this file at 90 lines.
