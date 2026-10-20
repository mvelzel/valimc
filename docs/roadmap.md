# Current work

Target: full vanilla Java 26.3 player experience (protocol 777) on Elixir 1.20.4 /
OTP 29.1.1, with Rust NIFs where native code measurably wins. This queue is
editable. [Compatibility](compatibility.md) describes the preview; the
[backlog](backlog.md) lists remaining features; [completed](history/completed.md)
indexes earlier tickets. Evidence lives in tickets, not here.

## Direction

The October 2026 audit found the preview's gameplay slices sound but its
foundations unable to carry full vanilla at scale: a flat-world edit map instead of
chunk sections, one fsync-bound write at a time per region, per-feature transfer
machinery, owner-mailbox block reads and a 5,800-line connection process. M1
replaced them (October 2026); see [architecture](architecture.md). Gameplay work
resumes on these foundations alongside M2.

## M1 — Foundations (complete)

| Ticket | Slice | Status |
|---|---|---|
| [VMC-062](tickets/VMC-062.md) | Rust NIF toolchain and paletted section storage replacing the edit map | Done |
| [VMC-063](tickets/VMC-063.md) | Region log with group commit; no tick pauses | Done |
| [VMC-064](tickets/VMC-064.md) | One owner-transaction engine and section fencing | Done |
| [VMC-065](tickets/VMC-065.md) | Published section snapshots for lock-free collision/observation reads | Done |
| [VMC-066](tickets/VMC-066.md) | Tick pipeline on game time: steppable clock, scheduled and random ticks | Done |
| [VMC-067](tickets/VMC-067.md) | Generic entity model; items and XP orbs migrate onto it | Done |
| [VMC-068](tickets/VMC-068.md) | Unified generated block/item registry, block behaviours, protocol constants | Done |
| [VMC-069](tickets/VMC-069.md) | Connection hot path (slim peers, frame once, counters), then split | Done |

## M2 — Real worlds (in progress)

| Ticket | Slice | Status |
|---|---|---|
| [VMC-020](tickets/VMC-020.md) | One bounded NBT codec (native disk reads), world schemas, golden vanilla world | Foundation |
| [VMC-021](tickets/VMC-021.md) | Anvil import (region files, chunks, biomes, block entities, entities, XP orbs, stored light) and export vanilla loads | Done |
| [VMC-022](tickets/VMC-022.md) | Light equal to vanilla's engine, live on edits and across region borders, in all packets | Done |
| [VMC-029c](tickets/VMC-029c.md) | Blocks that lose their support break (plants, torches, two-block halves), found in imported terrain | Done |
| [VMC-023](tickets/VMC-023.md) | Seeded noise and biomes: random sources, noises, compiled density functions and chunk biomes equal vanilla's | Foundation |

Next: clean-room vanilla terrain in Rust on VMC-023's noise and biomes (terrain,
carvers, aquifers and surfaces, then features and structures; VMC-024..026) with
stage-hash parity against vanilla dumps, dimensions and portals (VMC-027/028).
Performance target: generation throughput and tick time benchmarked against the
same seed on vanilla.

## M3 onward

Survival core on the entity model (mobs/AI, spawning, combat, projectiles),
redstone and block updates, then commands/admin and certification. Backlog
milestones C–F describe the remaining scope.

## Paused

Cooking-orb simulation ([VMC-034n4c](tickets/VMC-034n4c.md)) is unblocked by the
entity model (orbs already age and despawn). Additional status effects and
container variants can resume. Sugar cane and cactus growth need their placement
survival rules first ([VMC-066](tickets/VMC-066.md)).
Removing a furnace that holds items is refused until its spill and stored
experience exist ([VMC-034f](tickets/VMC-034f.md)).

## Pending client gates

| Ticket | Remaining gate |
|---|---|
| [VMC-005b2c](tickets/VMC-005b2c.md) | Server CLONE/type-2 fill from a creative container menu (VMC-032) |

The M1 milestone client run passed on `127934a` (see [VMC-069](tickets/VMC-069.md)),
with the item despawn fix checked on `6243c8c` ([VMC-067](tickets/VMC-067.md)) and
block ticks, survival XP orbs and flight stop on `fdca2df` ([VMC-066](tickets/VMC-066.md)).

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Update a ticket's status and the table above when a slice changes state. On Done,
add the ticket to `history/completed.md`. `scripts/lint_docs.py` keeps this file
short.
