# VMC-077x — Generation does not stall at the edge

Status: Done
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

## Findings

`bench/outrun_flight.exs` gained a `waits` sampler: while the player's chunk
has been missing for over a second it reads the scheduler's state every
500 ms and follows what the chunk waits for (the undecorated chunks of its
3 × 3 and, transitively, the earlier decorations within 2; their terrain;
the queues and the pool). Before is 68a322e3.

- The usual wait (1 to 2 s): a chain of 13 to 27 earlier decorations,
  already at the player's priority, all their terrain made, 1 to 4 able to
  run at once because they conflict within 2. Decorations run in number
  order, Z outer and X inner per request, so when generation trails the
  player the chain reaches back and sideways into the undecorated band.
  No cell of a chain was ever spilled or dropped and made again.
- A 6.5 s wait at 160 blocks/s (before): one decoration of a 27-long chain
  could start, but no queue held it and none ran for 4 s while the pool ran
  terrain; no want changed meanwhile (the player stood still), so nothing
  rebuilt the queues. A frozen chunk drops the numbers of the decorations it
  blocks without re-checking those that waited for them; that path now
  queues them. A debug copy of the new scheduler checked after every message
  that every urgent decoration able to start is queued or running: no
  exception in a 120 s flight at 160 blocks/s.
- Where the scheduler's time went (before, 116 blocks/s, the flight with a
  13.8 s wait, 27,744 busy samples): the whole rebuild 32 % (2,400 to 2,800
  per flight, about 15 ms each) and eviction passes 25 %. Proto cells were
  over `worldgen_proto_cells` (1,024) the whole flight, and every pass that
  freed a cell cleared the guard, so nearly every dispatch rebuilt the
  priorities and built a set of every chunk within 2 of about 2,700 wanted
  ones. Job results queued meanwhile; the pool was 40 to 60 % busy.
- With dispatch per result and incremental priorities, a profile at 160
  blocks/s showed the next costs: passing priorities of chunks newly wanted
  at the view's edge down their chains (35 %; each such chain spans the
  undecorated band, walked again for every new row), spill passes (10 to
  14 %, up to 64 dirty encodes the scheduler waited for each), and rebuilds.

## Changes

- A job's result starts the next job at once, as far as the pool has room;
  the scheduler no longer waits for an empty mailbox. Jobs start before the
  housekeeping (a rebuild, an eviction pass), and again after a rebuild.
  While terrain is left out for want of a slot, the next job to end anywhere
  wakes the scheduler.
- `Frontier.want/3` and `focus/4` look only at the chunks whose priority
  changed (an index of who wants each chunk). An urgent priority that went
  down (a call's, a chunk's within 4 of a player) passes at once down the
  chain of earlier decorations, most urgent first; others, and those that
  went up or away, wait for the whole rebuild (`refresh/1`), which the
  scheduler runs at most every 250 ms and at most a tenth of its time.
- Eviction passes test candidates one by one instead of building the
  protected set, and after a pass that could not get under the cap the next
  waits for an eighth of the cap more cells. A job of its own (one at a
  time, holding its chunks) encodes and writes the spills.
- Terrain starts only while a numbered decoration within 1 still needs it
  (or, in a terrain-only world, while the chunk is wanted): a leftover queue
  entry regenerated terrain of chunks already handed over with their 3 × 3
  (`decorated_world_test` caught it).
- The bench's counters add per-kind job times, rebuild time, spills and
  drops.

## Measurements

October 22, 2026, `MIX_ENV=bench`, 10-core host shared with other sessions
(load 9 to 17 before, 12 to 26 after, in each raw file);
`bench/outrun_flight.exs` 150 s at heading 115°, view distance 32, a fresh
world of seed 20261020 each run, `OUTRUN_SAMPLE=groups,waits`. Before is
68a322e3; after is 922a81ca (three runs per speed) and db03c751 (the fourth
116 run). Raw results in ignored `bench/results/outrun-077x-*.json`.

| | 116 before | 116 after | 160 before | 160 after |
|---|---|---|---|---|
| Blocks flown | 9,988–13,723 | 14,378–17,185 | 11,208–14,616 | 15,176–17,528 |
| Missing on entry / entered | 93–212 / 755–1,023 | 1–261 / 1,071–1,279 | 396–492 / 815–1,042 | 452–538 / 1,075–1,257 |
| Longest own-chunk wait per run | 1.7, 13.8, 2.0, 2.0 s | 0.5, 1.5, 1.9, 2.2 s | 6.5, 1.2, 0.9 s | 1.1, 0.6, 6.2 s |
| Chunks generated per second | 246–353 | 346–482 | 260–338 | 354–405 |
| Pool busy while chunks are wanted | 40–60 % | 75–85 % | 49–60 % | 74–79 % |
| Scheduler process busy | 53–73 % | 28–54 % | 52–65 % | 42–52 % |
| Whole rebuilds per flight (ms each) | 1,612–2,845 (about 15) | 414–594 (4 to 31) | 1,600–2,256 | 382–489 (24 to 36) |
| Largest group busy, median | 0.29–0.58 | 0.84–0.97 | 0.56–0.61 | 0.76–0.88 |

At 116 blocks/s the player flies almost the whole 150 s (17,145 blocks of
17,400 in the two runs on the less loaded host, one or two chunks missing on
entry). The longest wait after (2.2 s) is a chain: the player's chunk
needed 333 earlier decorations and 361 terrain chunks, cleared in about 2 s
at its priority. The 6.2 s wait at 160 is not generation: the group shed a
batch of sections (237 to 84) and for about 3 s no section wanted any chunk,
the player's included, while the scheduler and the group idled. The pool's
share is lowest on the most loaded host (74.8 % at load 26). The largest
group is now the busier side, with mailboxes up to 326.

Profile with the spill job and paced rebuilds (160 blocks/s, 22,126 busy
samples of the scheduler): rebuilds 16 %, checking the wanted chunks near
each chunk handed over for being made alone 7 % (922a81ca does it only when
the chunk blocks a decoration), lowering 6 %, the bench's own stats calls 6 %.

## Checks

`worldgen_frontier_test` (a want's priority passes down the chain at once),
`worldgen_scheduler_test`, and the region generation, decorated world,
portal, flight, dimension, settings, pool, group commit, storage and block
support test files with `--include slow --include tcp` (50 of 50);
`check_vanilla.py --changed` 10 of 10 stages (live generation in the three
dimensions with structures, datapacks, spawn, world settings, tcp);
`audit_public_tree.py`.

Client: none per slice; the next player-visible milestone run flies at view
distance 32.

Follow-ups: the batch of sections leaving the view stops all wants for
seconds; the largest group's installs are the next limit at 116 blocks/s;
7,000 to 20,000 cells spill per flight (the cap is small for view distance
32, and most spilled cells are chunks delivered and soon handed over).

