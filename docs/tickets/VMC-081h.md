# VMC-081h — Durability and replication from deltas

Status: Done
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081d](VMC-081d.md), [081i](VMC-081i.md).
Closed with VMC-081 (October 30, 2026): the durability half is live; replication from per-chunk frames is not started and is left as future work in [VMC-081](VMC-081.md#closure).

After 081d and 081i the `mobs` scenario's commit callback cost 1.72 ms per
tick beside the 12 ms tick, all of it re-deriving what the owner had just
changed: the native cut built every moving mob's whole stationary record as
a term to hash it (about 20 calls of 44 µs a tick, to write about 20
records), `RegionStorage` compared every Elixir part with what it last
committed (the store's entries walked twice per commit, native ones
included, only to be thrown away), and the group prepared frames after every
callback (36 a tick while exploring, each cutting every touched section when
one had a frame). This slice makes every frame cost what changed.

## Design

- **Native records.** A section's slot keeps the hashes of what the last
  frame wrote: the whole record's and its settled part's (the record
  without position, rotation, velocity, ground, motion and mind, its tick
  counters by their sign). The settled hash is taken from the mob in place
  (`record::hash_stationary`, field for field with `record_with`, numbers as
  Elixir's `==` compares them), so a cut of a mob whose change may wait
  hashes a few dozen words and builds nothing; a record is built only to be
  written, or on the motion pass. A mob whose tick counters alone moved (its
  age, egg timer, hurt, death, fire, air, freezing and effect ticks, portal
  cooldown, player memory, a held item's use) waits for the motion pass like
  one that only moved; a counter crossing zero is written at once, as an
  item's age and a furnace's burn wait (`RegionStorage.wait/4`) and within
  what the durability contract lets counters lose. Mutation flags were
  rejected: hundreds of AI and vitals paths write these fields, and a missed
  flag loses data, where the hash cannot. `stationary_hash_follows_the_record`
  and `the_settled_hash_keeps_only_the_sign_of_counters` check every field.
- **Journals.** `Store` and `ScheduledTicks` keep a journal (`dirty`) of the
  uuids and chunks whose records changed, written where they change: every
  entry write of an Elixir entity that its record holds (not tick stamps,
  idle time, the on-fire flag or native mobs), every scheduled, taken or
  re-queued tick (not freezing or thawing, which change no record). The
  owner hands the journals to its storage at each cut and clears them
  (`RegionData.take_parts/1`); the storage builds each named record once and
  weighs it against the one it last wrote (`written`), which keeps the motion
  and counter waits exact. A plan adopted from a worker keeps the owner's
  journal (`Store.adopt/2`), and the plan fence compares stores without
  their journals (`Store.same?/2`). The small parts that seldom change
  (containers, block entities, comparators, pistons, post-processing,
  structures, the arena, the handoff ledger) keep the identity-first
  comparison; containers stay compared because the cooking plan's fence is
  their whole value.
- **The check.** The test build compares every journal with a whole
  comparison of the parts at each cut and fails the owner on a change no
  journal named, so every test that changes the world checks the journals.
- **Frames per tick.** A group prepares frames at the end of each tick and on
  its commit timer, not after every callback; a frame a callback cut for a
  reply that waits on it (an entity handoff, a generated chunk's handover)
  waits at most until the tick ends. A group stepped by hand (tests) has no
  tick end and prepares after each callback as before. Frames still go out
  as one record per cut, sections and players together.
- **Checkpoints.** The task builds the records of every part but the
  entities (the ticks' frozen binaries are decoded there, off the owner).

Durability is unchanged: group commit with one append and sync per stripe
drain, a crash loses at most a suffix of frames, handoff receipts are
durable before they are sent, and a section moves only once its frames are.

Acceptance:

- A cut of a mob that only moved builds no term; every saved field change is
  written in the same frame as before, travel-only changes on the motion pass.
- Frames carry exactly the records that changed, found without walking a part
  (the test-build check holds over the suites).
- An owner killed once its frames are durable reloads exactly what it held;
  one killed while its frames wait reloads the state after one of its changes
  (`storage_journal_test.exs`).
- The commit callback falls on `mobs` and explore; no tick regression (the
  combined quiet-host measurement decides).

Reference: pinned 26.3 is unaffected (storage is ValiMC's own); `Entity.saveWithoutId`
fields as `record.rs` documents.

Checks: `cargo test -p valimc_core --lib mobs` (68), clippy without new
warnings; storage, journal, log, checkpoint, region, item, handoff, fluid,
dragon and generation tests; `mix test.fast`.

## Measurements

The 081x probe (`.local/tick-budget/mkprobe081x.py`) in docker on two pinned
cores, base `a75a314c` against this slice, interleaved on a host loaded by
other agents (load 12–16; tick times swing 15–26 ms between runs, so only
ratios inside a pair mean much). ms per tick unless noted; `hb`/`ha` before
and after (`results/probe081x-h*.json`).

| | Mobs before (`hb3`) | Mobs after (`ha3`) | Explore before | Explore after |
|---|---:|---:|---:|---:|
| Native cut (NIF) | 1.05 (52.9 µs/call) | 0.52 (34.7 µs/call) | 0.75 | 0.51 |
| Frames encoded per tick | 6.06 | 0.68 | 8.61 | 8.09 |
| Checkpoint (`maybe_checkpoint`) | 0.24 | 0.06 | 0.75 | 0.60 |
| `prepare_frames` calls per tick | 2.85 | 1.88 | 21.8 | 1.94 |
| `prepare_frames` | 0.22 | 0.35 | 1.72 | 0.82 |
| Whole diff (`diff_parts`) | 1.89 | 2.00 | 1.61 | 1.07 |
| Commit callback mean (ms) | 2.61 | 2.60 | 0.98 | 0.98 |

- Native: building a moving mob's stationary term was not the cost (only
  mobs that changed are touched); writing was. Chickens' egg timers, ages,
  hurt and fire ticks change every tick and wrote the whole record every
  tick. With counters waiting for the motion pass the native cut halves and
  the frames a group encodes fall from 6 to 0.7 per tick.
- Journals: entity and tick changes cost 1.4 and 0.4 µs per cut (`ha3`'s
  inner spans). The comparison of the small parts then dominated (88.8 µs
  per cut against 35.5 for all parts before): a part rebuilt equal (a
  chunk's kept post-processing marks, every tick) was compared deep at every
  cut, since only a change replaced the term kept. The storage now keeps the
  current term after an equal comparison, and post-processing keeps an
  unchanged chunk's marks as they were; that fix is not yet in a probe.
- Explore: preparing frames once per tick instead of after each of about 36
  callbacks halves `prepare_frames`; the tick's end now does the cut that
  callbacks did (`tick_lifecycle` 0.77 → 1.09).
- The first pairs (`hb1`/`ha1`, `hb2`/`ha2`, before the counter waits) show
  the same diff regression; `ha1` also ran 28 major collections the others
  did not (host memory pressure; `ha2` on the same image ran none).

The coordinator measures all 081 slices together on a quiet host.

Next: replication from deltas (connections filter prepared per-chunk frames
instead of rebuilding replication maps).
