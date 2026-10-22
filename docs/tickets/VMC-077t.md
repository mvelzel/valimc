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

Tests: `test/region_lifecycle_test.exs` (an unloaded section's change holds
when it loads again at once; a load waits while its checkpoint file is
written); the storage, checkpoint, group, generation and view tests pass
unchanged.
