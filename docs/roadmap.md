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
machinery, owner-mailbox block reads and a 5,800-line connection process. New
gameplay (more effects, containers, orb simulation) is paused until milestone M1
lands. See [architecture](architecture.md) for the target design.

## M1 — Foundations (now)

| Ticket | Slice | Status |
|---|---|---|
| [VMC-062](tickets/VMC-062.md) | Rust NIF toolchain and paletted section storage replacing the edit map | Next |
| VMC-063 | Region persistence v2: dirty-section deltas, group commit, no tick pauses | Planned |
| VMC-064 | One owner-transaction engine (idempotent ops, permits, outbox) and section fencing | Planned |
| VMC-065 | Published section snapshots for lock-free collision/observation reads | Planned |
| VMC-066 | Tick pipeline on game time: steppable clock, scheduled and random ticks | Planned |
| VMC-067 | Generic entity model; items and XP orbs migrate onto it | Planned |
| VMC-068 | Unified generated block/item registry, block behaviours, protocol constants | Planned |
| VMC-069 | Connection split: codec, login flow, job registry, slim replication | Planned |

Order matters only where tickets share code: 062 precedes 063/065; 064 precedes
067. VMC-068 and VMC-069 can proceed in parallel with the world work.

## M2 — Real worlds

Anvil import/export (Rust, VMC-020/021), lighting (Rust, VMC-022), clean-room
vanilla worldgen in Rust (noise, biomes, surface, carvers, then features and
structures; VMC-023..026) with stage-hash parity against vanilla dumps, dimensions
and portals (VMC-027/028). Performance target: generation throughput and tick time
benchmarked against the same seed on vanilla.

## M3 onward

Survival core on the entity model (mobs/AI, spawning, combat, projectiles),
redstone and block updates, then commands/admin and certification. Backlog
milestones C–F describe the remaining scope.

## Paused

Cooking-orb simulation ([VMC-034n4c](tickets/VMC-034n4c.md)) waits for the entity
model. Additional status effects and container variants wait for M1.

## Pending client gates

| Ticket | Remaining gate |
|---|---|
| [VMC-005b2a](tickets/VMC-005b2a.md) | Sustained multi-slot client drag |
| [VMC-005b2c](tickets/VMC-005b2c.md) | Client-generated clone/fill |

The first M1 client run will be a baseline regression (join, terrain, mining,
placement, chests, furnaces, items, reconnect) on the new section storage.

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Update a ticket's status and the table above when a slice changes state. On Done,
add the ticket to `history/completed.md`. `scripts/lint_docs.py` keeps this file
short.
