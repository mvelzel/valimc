# VMC-077x — Generation does not stall at the edge

Status: Planned
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077w](VMC-077w.md) (a flying player's group keeps up; this
is what it uncovered), [VMC-077u](VMC-077u.md) (generation follows the player).

Found by VMC-077w (`bench/outrun_flight.exs` at 116 blocks/s, view distance
32, seed 20261020, `MIX_ENV=bench`): in four of six 150 s flights the
player's own chunk was missing once for 8 to 14 s while the region group
hosting it was idle (5 to 12 % busy, mailbox 0). During a 14 s gap a
diagnostic sampler of the pool's jobs and the scheduler's state (every
500 ms) saw:

- about 2,500 chunks wanted, 3,000 to 3,400 terrain jobs queued, no final
  chunk or decoration ready;
- the pool mostly empty between rounds of 7 to 8 short jobs;
- the scheduler working through 7 to 16 job results before each dispatch.
  It dispatches only when its mailbox is empty, and a dispatch after wants
  changed refreshes every priority (`Frontier.refresh/1`, the larger part of
  its time in a stack profile, with `needs/1`).

Over whole flights the pool was busy 41 to 61 % of the time chunks were
wanted, against 67 to 81 % before VMC-077w (when the group's backlog made
wants arrive late and in bursts).

Plan:

1. Find what the own chunk waits for in a gap: the chain of earlier
   decorations within 2 (`needs`), the terrain they need, and whether proto
   cells dropped or spilled under `worldgen_proto_cells` are made again.
2. Keep the pool full while work is queued: dispatch on a job's result
   without waiting for an empty mailbox (bounded per message), and wake on a
   freed slot whenever startable work was left out.
3. Make a refresh cost what changed in the wants, not the whole wanted set.
4. Measure on the outrun bench at 116 and 160 blocks/s for 150 s, at least
   three runs each.

Acceptance:

- At 116 blocks/s for 150 s no own chunk is missing for more than about 2 s.
- The pool is at least 75 % busy while chunks are wanted.
- Affected tests pass; `check_vanilla.py --changed`.
