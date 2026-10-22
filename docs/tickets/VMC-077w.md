# VMC-077w — A flying player's group keeps up

Status: In progress
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077u](VMC-077u.md) (generation follows the player; this is
its install follow-up), [VMC-077v](VMC-077v.md) (spectators fly into chunks
not loaded, its other follow-up).

Live report (October 22, 2026, dev server, spectator at the top scroll speed,
view distance 32): once the player catches up with generation, generation
never recovers while they keep flying; it does once they stand still for a
while.

## Findings

Live samples (`.local/rubberband/samples.log`, ignored): the region group
hosting the player ran one scheduler flat out (2–5 million reductions per
250 ms) with 300–1,400 messages queued for the whole flight, mostly in chunk
installs (`Native.put_columns_lit`, `Native.halo_put`); the dirty schedulers
were 0–40 % busy and the player lacked its own chunk for 13–15 s twice. The
server also corrected the spectator 45 times (`geometry {:missing_block, …},
mode spectator`) at the edge of generated terrain; VMC-077v removed that.

Bench (`bench/outrun_flight.exs` at 116 blocks/s, `MIX_ENV=bench`, fresh world
of seed 20261020; a profiling copy adds a 2 ms stack sampler of the largest
group and a 2 s per-group sampler):

- One group holds the whole loaded area: 150–320 sections (sections out of
  view leave in batches about every 30–70 s), 150–500 MB.
- That group used 40–62 million reductions every 2 s through a 150 s flight,
  a whole scheduler, with 400–1,100 messages queued; 435 chunks/s installed.
- Where its running time went (7,518 busy samples of 17,687): chunk install
  25 % (`Blocks.put_columns` 15 %, `ScheduledTicks.schedule_all` 5 %),
  `LightHalo.handle` 15 %, `commit_frames` 21 % (`RegionStorage.diff_parts`
  14 %, `ScheduledTicks.changes` 3 %), the tick pipeline 8 % (`block_ticks`
  `Enum.any?` 6 %), `serve_chunk` starting an encode job through a
  synchronous `GenServer.call` 7 %, `Owners.ensure` (`Scheduler.whereis` per
  `handed_over`, `Log.ensure_stripe` per commit) 5.5 %.
- While the group lags, wants reach the scheduler late (the pool had no
  wanted chunk at times while the mailbox held about 500), and the player's
  own input, focus and chunk sends wait in the same mailbox. Standing still
  stops new work and lets the mailbox drain: the reported hysteresis.

The bench player keeps up at 116 blocks/s on the full Rust profile (306 of
1,107 chunks missing on entry, at most 0.7 s), but with no headroom: any extra
cost (the dev build, the real client sharing the host, longer flights) tips
the one group into a backlog it cannot leave while the player moves.

## Plan

The group's cost per generated chunk must fall well under its share of one
scheduler at the flight's rate, and its mailbox must stay bounded whatever
the rate (no unbounded mailbox; AGENTS.md):

1. **Deliveries with credit, in batches.** The scheduler sends a group (per
   requester) a delivery only while fewer than a small number are
   unacknowledged; what finishes meanwhile waits in the scheduler (its cells
   are already there) and goes in the next delivery, own chunk and nearest
   first. The group installs a delivery's chunks per section in one pass: one
   `put_columns`, one publish, one light change, one halo frame set, one
   durable wait. Generation results then never queue in the group.
2. **No synchronous calls on the group's hot path:** encode jobs start
   asynchronously; the scheduler's and stripe's pids are kept, not looked up
   per message.
3. **Frames and ticks proportional to what changed:** `diff_parts`,
   `ScheduledTicks.changes`/`schedule_all` and `block_ticks` should cost per
   changed chunk, not per section or per tick entry, once installs batch.
4. Measure before and after on `bench/outrun_flight.exs` at 116 and 160
   blocks/s for 150 s, recording the largest group's reductions per second,
   mailbox peak and median, chunks per second and missing time; keep the
   profiling sampler as an option of the bench.

Acceptance:

- At 116 blocks/s for 150 s the largest group's mailbox stays bounded (no
  growth over the flight; peak well under 100 messages), and its scheduler
  share leaves headroom (under about 60 % of one scheduler).
- At a speed generation cannot match, the player waits at the edge but the
  pool stays busy while chunks are wanted, and once the player stops, the
  own chunk arrives within the same time as when flying (no hysteresis).
- Affected tests pass; `check_vanilla.py --changed`.
