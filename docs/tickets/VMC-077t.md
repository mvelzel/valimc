# VMC-077t — Flight without storage stalls

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077f](VMC-077f.md) (log and checkpoints),
[VMC-077s](VMC-077s.md) (a group's tick costs what changed),
[VMC-077e](VMC-077e.md) (tickets and unload).

Before: a live flight at view distance 32 over a fresh world left the world
invisible for many seconds once the player outran generation; the vanilla
client draws nothing while the chunk the camera is in is missing. Process
samples showed the log stripe (`Valimc.Storage.Log`) as the busiest process
(30–38 M reductions per 250 ms in file reads, CRCs, `fsync_dir` and full
syncs) and the player's group mailbox at 1,485.

Causes, from `call_time` over the flight (`PROFILE=calls`):

- Every region checkpoint asked the log for the section's frames since its
  last checkpoint (`Log.frames/3`), and the stripe answered by rereading and
  decoding every segment it held: 7,234 file reads and 230,000 frame decodes
  in 40 s, all in the one stripe process the group commits to.
- Folding a frame's column images (`apply_ops/2`, and `columns/2` on the
  pending map) passed over every record once per column: 27 M closure calls
  in 40 s, as fresh terrain brings thousands of scheduled-tick records.
- A section its group unloaded checkpointed synchronously inside the group:
  a `Log.sync`, the stripe call above, a relight and an `fsync_dir`, while
  the group's mailbox waited.
- A connection sent two ticket messages per section of its view (about 160
  at view distance 32) on every chunk it crossed; they were the most common
  message in the group's mailbox.
- The stripe listed its directory to prune after every `covered` report.

Acceptance:

- A section keeps the frames it cut since its checkpoint (at most 64 MiB;
  past that the checkpoint reads the log as before) and a checkpoint folds
  those, with the cells kept apart so a column drops its cells in one pass.
- A section its group unloads leaves its checkpoint to a task. Writes of one
  checkpoint file never overlap (a lock per file in `StorageRegistry`); the
  group waits only until the task holds it, a section loading again waits
  for the write in progress, and the task reports what it covers only once
  the log holds those frames. Without a reply waiting on a frame, the unload
  does not wait for the log. A supervisor shutdown stays synchronous.
- A view's tickets reach each group as one message (`Region.tickets/2`),
  applied before one commit.
- The stripe prunes only when its covered floor moved.
- `own_chunk_missing_ms`, `own_chunk_gaps` and `own_chunk_missing_max_ms`
  count how long connections lacked the chunk their player is in; a gap over
  a second is logged with the player's name.
- `bench/group_load.exs` reports the log stripes' reductions and queues and
  the client's own-chunk gaps, at `SPEED` blocks a client tick.

Measurements (`bench/group_load.exs`, 40 s, one spectator flying east at view
distance 32, simulation distance 10, fresh vanilla world, full fsync; before
a6dab913, after this ticket; raw results kept, untracked, in
`bench/results/group-load-077t-*`):

| | Before, 1.0 | After, 1.0 | Before, 2.5 | After, 2.5 |
|---|---|---|---|---|
| Group ticks (800 expected) | 572 | 843 | 273 | 679 |
| Tick p50 / p95 / max ms | 3.4 / 24 / 103 | 3.2 / 11 / 14 | 6.1 / 30 / 116 | 4.3 / 9.3 / 69 |
| Group mailbox p50 / p95 / max | 9 / 1,148 / 1,561 | 0 / 161 / 338 | 1,184 / 5,281 / 6,126 | 110 / 984 / 1,183 |
| Log stripe reductions/s p50 / p95 | 1.0 M / 395 M | 0 / 2.4 M | 126 M / 389 M | 0.2 M / 2.5 M |
| Log stripe queue p95 / max | 12 / 105 | 3 / 11 | 217 / 395 | 4 / 15 |
| Own chunk missing (client), longest / total | 0 | 0 | 12.5 s / 12.6 s | 0 |
| Chunk center lag p95 / max | 1 / 3 | 0 / 1 | 7 / 9 | 2 / 2 |

At 2.5 blocks a client tick (50 blocks a second) the player no longer
outruns its own chunk here. The remaining mailbox peaks follow generation
results, durable acknowledgements and chunk requests; terrain generation
itself (the scheduler's lane) is the largest cost in the profile.

## Loads read only their owner's frames

The flight samples' multi-second stalls had the player's group in a
synchronous call while the stripe read and decoded files. Two paths made the
stripe scan its whole log: the synchronous unload checkpoint (above) and
every load of a section, or login of a player, that had ever written a
frame (`Log.frames/3` reread all segments to find it, O(log) per load).

- Each stripe keeps, per owner, where each uncovered frame is (segment,
  offset, size): appends report it (`RegionLog.append_located/2`) and
  recovery takes it from the frames it decodes. `frames/3` answers from that
  index: nothing to read for an owner with no uncovered frame, otherwise a
  `pread` of exactly those frames (`RegionLog.read_at/1`, each checked).
- The caller finds an owner's stripes by keyed lookups and starts a world's
  stripes once, not on every load.
- A group blocks on the log only for `/save-all flush`, a shutdown, and an
  unload with a reply waiting on a frame; section loads run in the loading
  group's own `handle_continue`. Directory syncs happen once per new segment,
  pruned segments or checkpoint file, never per frame.

`bench/section_load.exs`: one stripe holding 256 MB of frames from 400
owners (10 frames of 64 KiB each), 20 loads each, p50 / max in µs:

| | Before (e06afee7) | After |
|---|---|---|
| Owner whose frames a checkpoint covers (a section loading again) | 54,796 / 67,909 | 3 / 20 |
| Owner with 10 frames in the log | 55,502 / 74,964 | 7,115 / 12,370 |
| Owner never written | 62 / 208 | 1 / 2 |
| `RegionStorage.open/2` of a fresh section | 107 / 4,244 | 56 / 1,164 |

An owner's frames are read as the group records they belong to, so the cost
follows that owner's commits, not the log.

A 120 s flight at 2.5 blocks a client tick (5.6 km, `bench/group_load.exs`
now samples the dirty CPU schedulers in 250 ms windows): the longest run of
windows under 10 % utilization was 500 ms before (e06afee7) and 250 ms after,
the client's own chunk was missing once for 361 ms before and never after,
and the group mailbox p95 went from 914 to 716. That flight never returns to
sections it left, so it does not load covered owners; the section-load bench
measures those.

Tests: `test/storage_log_index_test.exs` (frames come from the index, so
another owner's damaged frame mid-segment does not matter, where a scan
refuses the segment; covered and never-written owners read nothing; a
restarted stripe indexes again); `test/region_lifecycle_test.exs` (an unloaded section's change holds
when it loads again at once; a load waits while its checkpoint file is
written); the storage, checkpoint, group, generation and view tests pass
unchanged.
