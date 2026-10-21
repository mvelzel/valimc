# VMC-077f — One shared write-ahead log, keyed records, checkpoints

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (D2, D4), [VMC-063](VMC-063.md) (region log
and group commit), [VMC-074](VMC-074.md) (descriptor bounds), [VMC-077c](VMC-077c.md)
(chunks lit alone), [VMC-077e](VMC-077e.md) (tickets and unload).

Before: each region had its own store process and log directory, every
mutation queued a whole-value frame (the full item ledger, all containers, the
whole block entity set) and held its reply until the frame was durable through
six acknowledgement kinds; raw edits sat in a volatile cell map saved
periodically; the cell map grew forever and a load replayed the history behind
the last checkpoint; descriptors needed `FileBudget`; players had their own
partitioned log.

Scope: the storage layer and the owner's commit path. Not here: the owner
skeleton (VMC-077g), cross-owner transfers (their receipts stay as they are
until VMC-077h/077i), volatile proto owners (VMC-077n keeps their own
`ProtoLog` until it removes it).

Limits: item and container records are still validated by their binary codecs
before adoption (size caps), though frames store the values. The per-region
checkpoint replaces the whole file; per-section files were not needed once a
checkpoint is one write of the column images.

Acceptance:

- One write-ahead log per world folder (`Valimc.Storage.Log`): eight stripes
  under `log/wal.N`, each one process draining its queue into one append and
  one `datasync`. Region owners commit to stripes 0–5 by key, player files to
  6–7, so a player's save never queues behind a region's large frame. A frame
  is numbered by its owner; a crash loses only a suffix of an owner's frames.
  The log forgets segments once owners' checkpoints and synced files cover
  them. An append whose segment does not open (out of descriptors) wrote
  nothing and is retried, holding later commits, for 30 s. Owners monitor
  their stripe: one that goes down with frames in flight stops its owners,
  which reload the durable prefix (`storage_test.exs`).
- Keyed delta records (`Valimc.World.RegionStorage`): cells by position,
  column images by chunk, items by UUID, receipts and ledger entries by
  source, container entries by position, scheduled ticks by position and
  block, block entities by position, the game tick. A frame puts or deletes
  keys; no whole-value frames. Frames are split below 8 MiB and the log
  asserts the 64 MiB cap on encode (world-core E1); block entities are keyed
  ops (E2); the volatile `unsaved` cell map is gone (E6).
- D2: the owner adopts, publishes and replies at once and cuts one frame every
  50 ms from what changed. Only a cross-owner step's reply (a transfer's
  receipt or result, a receipt query, an orb delivery, a container decision)
  waits for its frame, which is cut at once; an item handoff starts only once
  its outgoing ledger record is durable. Deleted: the held-reply machinery
  (`finish_when_durable`, `release_when_durable`, the six acknowledgement
  kinds, the item write queue and backpressure), the per-kind store casts,
  the store process and lease, `FileBudget`, `PlayerLog`.
- Item motion goes into a frame at most once a second; item ages and delays
  and furnace burn and progress only into checkpoints (written at the latest
  five minutes after they move, like vanilla's autosave), unless they cross
  zero.
- Checkpoints (`Valimc.Storage.Checkpoint`, `r.X.Z.vmc`): every record of the
  region with its cells folded into column images taken from the Rust blocks
  and relit alone; written beside the owner after 1 MiB or 1,200 frames, five
  minutes after counters moved, on `/save-all` and at unload. A flushed region
  loads from its checkpoint alone. Export-only imported data (`chunk_extras`,
  imported entities) lives in `r.X.Z.extra`. The store no longer mirrors
  owner state.
- D4: per-region log directories, per-file snapshots and `players/wal.*` are
  refused with an error naming the files; no migration, no legacy reader.
- Exactly-once cross-owner effects keep their receipts, now in the same frames
  (`mining_region_test`, `placement_region_test`, `chest_spill_region_test`,
  `item_handoff_region_test`, `player_container_store_test`).

Measurements (`bench/storage_actions.exs`, `MIX_ENV=bench`, 10 schedulers,
128 items and 64 filled chests in the region; before at 9d5f72c, after on
this change rebased on c50a4670; raw results kept, untracked, in
`bench/results/storage-actions-{before,after}.json`). Bytes are what the
actions add to the world folder after a flush (the after run pauses
checkpoints so that is what reaches the log); they include the player's file
records. The after run shared the host with two other sessions' full checks
(load average 22–28 on 10 cores): its latencies are fsync-bound and within
noise of the before run, not a speed-up claim.

| Action | Bytes before | Bytes after | Median before | Median after |
|---|---|---|---|---|
| Pickup | 9,958 | 1,016 | 11.1 ms | 10.4 ms |
| Chest click | 9,933 | 4,808 | 14.7 ms | 14.5 ms |
| Block edit | 16 | 32 | 0.057 ms | 0.063 ms |
| Load of a region with 20,000 edited cells | — | — | 34.6 ms | 8.5 ms |

A block edit was 16 bytes because a raw edit was not durable at all until the
periodic save; it is now in the next frame. A click still writes the chest's
whole entry (27 slots) and the player's file twice. `bench/group_commit.exs`:
64 owners editing at once share 3.9 frames per datasync; 512 players saving at
once share 132 file records per datasync.

Checks: `mix test.fast` (485 passed); every socket and slow suite (`mix test
--only tcp --only slow`): 209/212, then the two fixed files pass (login
recovery, pose); the remaining failures are `player_fire_connection_test.exs`
"movement packets cannot advance ignition…" and "rain extinguishes…", whose
fixture sets fire on fire, which VMC-077m's block rules now remove (not this
change). `check_vanilla.py --changed origin/main`: 211/211 stages.
`bench/item_cross_merge.exs` (8 boundaries, conserved),
`scripts/audit_public_tree.py`.

Next: the owner skeleton (VMC-077g); entity store records replacing the item
ledger encoding (VMC-077h); proto owners volatile (VMC-077n), after which
`ProtoLog` and the region checkpoint format of `RegionLog` go.
