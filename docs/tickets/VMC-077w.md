# VMC-077w — A flying player's group keeps up

Status: Done
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

## Now

- **Deliveries with credit.** The scheduler sends a group
  `{:generated, scheduler, [{key, epoch, fulls}]}` only while fewer than two
  of its deliveries are unacknowledged (`Scheduler.delivered/1`); what finishes
  meanwhile waits in the scheduler's outbox and goes next, at most 64 chunks,
  ranked by the nearest focused player's score (`Frontier.rank/2`), sections
  in the order of their first chunk. A group whose requesters go down loses
  its outbox; a section that moved gets its chunks forwarded by the group it
  left, which acknowledges.
- **One pass per section.** A section installs a delivery's chunks with one
  `put_columns`, one publish, one light change and one durable wait; the halo
  images its siblings get are sibling effects, merged per sibling into one
  `halo_put` (neighbours in other groups still get messages).
- **No calls or lookups on the hot path.** Chunk encodes take a slot of a
  counter (`Jobs.init_slots!/2`) and spawn their worker at once; slot workers
  are never killed and report their own failure (`{:job_down, ...}`), so an
  encode costs its group one message. The group keeps the log stripe's pid and
  passes it to `Log.commit_group/5`; a region wants and hands over through the
  scheduler pid it monitors. The scheduler finds a job's monitor by its ref.
- **Cuts follow what changed.** A group cuts only the sections touched since
  its last cut (a section whose storage and stored parts are the same terms is
  not touched, so a tick that changed nothing touches nothing), forced cuts
  and unloads included; the commit timer sweeps every section once a second
  for what is due by time alone. Checkpoint reports go to their section; a
  broadcast commits once; a log record of several owners' frames is
  acknowledged in one message (`{:storage_durable_all, acks}`).
- **Ticks per chunk.** Scheduled ticks are one record per chunk
  (`{:ticks, chunk}`, the chunk's container in order); the journal marks
  chunks. Older worlds' per-tick records are refused (no migration).
  `take_due` visits the fewer of the ticking chunks and the chunks with ticks
  and returns the same term when nothing is due. Sections outside simulation
  skip block ticks; a section with no entities or players that published
  nothing skips its entity publish.
- `bench/outrun_flight.exs` takes `OUTRUN_SAMPLE=groups,stacks,scheduler_stacks`:
  every group every 2 s (sections, reductions, mailbox, memory, the largest's
  busy share sampled every 10 ms and its mailbox's contents above 50) and
  the largest group's or the scheduler's stack every 2 ms.

## Measurements

October 22, 2026, `MIX_ENV=bench`, 10-core host shared with other sessions
(load 8 to 26, in each raw file); `bench/outrun_flight.exs` 150 s at heading
115°, view distance 32, a fresh world of seed 20261020 each run,
`OUTRUN_SAMPLE=groups`. Before is 66c61114 with only the bench's samplers;
after is d049c6a0 plus the scheduler's job index (second runs in brackets).
Raw results in ignored `bench/results/outrun-077w-*.json`. Busy is the share
of 10 ms samples in which the largest group was running or runnable (dirty
NIF calls included).

| | 116 before | 116 after | 160 before | 160 after |
|---|---|---|---|---|
| Blocks flown / chunks entered | 6,595 / 488 | 12,702 / 941 (13,033 / 967) | 7,104 / 510 | 14,456 / 1,027 (10,200 / 731) |
| Missing on entry | 264 | 161 (180) | 356 | 584 (357) |
| Missing time, median of the missed / p90 | 304 / 589 ms | 121 / 99 ms (109 / 104) | 209 / 627 ms | 104 / 199 ms (149 / 381) |
| Missing time, max | 2,659 ms | 11,055 ms (11,541) | 2,066 ms | 574 ms (2,493) |
| Own chunk after the flight stops | 15 ms | 124 ms (209) | 490 ms | 20 ms (1,143) |
| Chunks generated per second | 170 | 324 (329) | 185 | 333 (237) |
| Pool busy while chunks are wanted | 67 % | 54 % (56 %) | 66 % | 61 % (41 %) |
| Largest group busy, median | 0.83 | 0.53 (0.51) | 0.91 | 0.57 (0.29) |
| Largest group reductions per second, median / max | 11.0 / 28.2 M | 6.0 / 25.5 M (6.4 / 24.5) | 14.8 / 30.2 M | 8.2 / 24.6 M (4.0 / 26.9) |
| Largest group mailbox, median / max | 72 / 1,509 | 0 / 101 (0 / 138) | 91 / 1,504 | 1 / 92 (0 / 160) |
| Largest group sections, max | 181 | 279 (242) | 160 | 300 (257) |

Per generated chunk the largest group now spends about a fifth of the
reductions it did (11.0 M/s for 170 chunks/s before, 6.0 M/s for 324 after),
and the player flies twice as far. Its mailbox no longer grows: its median is
0, and the peaks (85 to 160) come in the first 20 s of a flight, when the
spawn view's sections commit and checkpoint, or at an unload batch; in those
samples it holds encode results, chunk calls, halo edits and acknowledgements,
never generated chunks. A stack profile of the largest group at 116 blocks/s
(`stacks`, 20,154 busy samples) puts installs at 32 % (`put_columns` 21 %, a
dirty NIF), halo images 19 %, the tick pipeline 8 %, chunk serving 5 %,
light updates for served chunks 4 %, and cuts under 3 %.

At 160 blocks/s generation cannot keep up and the player waits at the edge;
when the flight ends, its chunk arrives no later than chunks did while it
flew (20 ms and 1.1 s, against a median of 104 to 149 ms and a p90 of 199 to
381 ms of the missed): the group no longer holds a backlog that standing still
would drain.

Not met here: in four of six 150 s runs at 116 blocks/s with this ticket, the
player's own chunk was missing for 8 to 14 s once, while the largest group
was idle (5 to 12 % busy, mailbox 0). A diagnostic copy of the bench that
read the pool's jobs and the scheduler's state every 500 ms (not committed)
showed, during the 14 s gap, about 2,500 chunks wanted, 3,000 to 3,400
terrain jobs queued, no final chunk or decoration ready, the pool mostly
empty between rounds of 7 to 8 short jobs, and the scheduler working through
7 to 16 job results before each dispatch (it dispatches only when its mailbox
is empty, and a dispatch after wants changed refreshes every priority). So
the generation scheduler, not the group, is now what stalls at the edge; the
pool's share while chunks are wanted (41 to 61 %) is lower than before, when
the group's backlog kept wants arriving late and in bursts. Follow-up:
[VMC-077x](VMC-077x.md).

Checks: the region, group, lifecycle, loading, light, log, storage,
generation, scheduler, pool, tick, item, view and flight test files that
touch these paths, with `--include tcp --include slow` (71, 60, 33 and 16 of
the same in the runs as the slices landed, all passing); `mix test.fast` 410
of 410; `check_vanilla.py --changed` 13 of 13 stages (live generation and
structures, tcp, spawn, world settings and upgrade among them);
`audit_public_tree.py`.

Client: none per slice; the next player-visible milestone run flies at view
distance 32.

