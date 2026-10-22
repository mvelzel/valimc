# VMC-077s — A group's tick costs what changed

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077f](VMC-077f.md) (keyed frames), [VMC-077j1](VMC-077j1.md)
(groups), [VMC-077e](VMC-077e.md) (simulation tickets).

Before: a live test at view distance 32 (simulation distance 10, fast
flight over fresh vanilla terrain) saturated the player's group process: its
mailbox passed 1,500 while the host idled, inputs applied in bursts and
corrections followed. Two costs grew with the state, not with the tick's
work:

- `ScheduledTicks.take_due/3` popped every due tick of a chunk outside
  simulation from one gb_set and added it back, every tick; at view distance
  32 nearly every loaded chunk is outside simulation and fresh terrain brings
  thousands of fluid ticks, so each section churned up to its 65,536 cap each
  tick. `rebase/2` dumped and reloaded them all; the cap silently dropped
  generation ticks.
- `RegionStorage.diff_parts/2` rebuilt every record of a part (ticks, items,
  containers, block entities) and diffed the maps whenever anything in the
  part changed; the tick queue changed every tick, so every section paid
  O(state) every tick.

Acceptance:

- Scheduled ticks are vanilla's `LevelTicks` shape: one container per chunk,
  a tick takes due ticks only from the simulated chunks' containers (in
  vanilla order across them, at most 65,536 a tick), and the others are never
  touched. No cap on how many a section holds. Dues are relative to a shift,
  so a rebase is O(1) (one `{:ticks, :shift}` record). Generated chunks'
  ticks are scheduled in one batch per chunk.
- A frame is built from what changed: the scheduled ticks' journal of touched
  pairs, and for items, containers and block entities only the entries that
  are not the terms last committed (an unchanged entry compares by identity).
  The motion and counter deferral keeps its rules.
- `bench/group_load.exs` before and after (raw results kept, untracked, in
  `bench/results/group-load-*.json`).

Measurements (`bench/group_load.exs`, 40 s, one creative player flying east
at a block a client tick, view distance 32, simulation distance 10, fresh
vanilla world; the host process sampled every 50 ms):

| | Before (834fdccf) | After |
|---|---|---|
| Group ticks in 40 s (800 expected) | 72 | 753 |
| Tick time p50 / p95 / max | — / 640 / 1,511 ms | 4.4 / 9.7 / 89 ms |
| Group mailbox p50 / p95 / max | 2,034 / 4,893 / 5,461 | 0 / 265 / 584 |
| Group reductions per second p50 / p95 | 44.9 M / 219.5 M | 3.4 M / 23.7 M |
| Distance flown | 783 | 781 |

The remaining mailbox peaks come with generation: installing generated
chunks, their light and their packets' encodes. Batching the generated
ticks took most of the install's share.
