# VMC-081j — The entity phase after the native slices

Status: Done
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081d](VMC-081d.md), [081g1](VMC-081g1.md), [081h](VMC-081h.md).
Closed with VMC-081 (October 30, 2026): live on the host.

After 081g1, 081g2, 081c2, 081h and the deletion of the Elixir mob path
(081d), a matched `mobs` pair against a75a314c showed the blocks and
spawning phases faster but the entity phase 1.1 to 1.3 ms slower, which
cancelled them. This slice finds where that time went, takes it back, and
continues with the entity phase's next round: the per-mob bookkeeping in the
section tick, the Elixir glue around it, idle sections, redstone contacts
and ageing.

## The regression

Bisect (`bench/tick_budget.exs` `mobs`, each image with its own harness, two
pinned cores of the development Mac's Linux VM, 60 s; the entity phase is
the mean of 60 sampled ticks, the callbacks are every tick's):

| Image | Entity phase (sampled) | Tick callback | Commit callback | Total per tick |
|---|---:|---:|---:|---:|
| a75a314c (base) | 6.12, 6.20 | 10.91, 11.07 | 1.87, 1.85 | 12.95, 13.25 |
| e75bc9d2 (081g2) | 6.20, 6.39, 6.54 | 9.88, 9.91, 11.10 | 2.02, 2.07, 2.43 | 12.05, 12.33, 13.76 |
| 474ff28e (081g1) | 6.71, 7.96 | 10.35, 10.51 | 2.04, 2.12 | 12.68, 12.89 |
| f6f1c203 (081h) | 7.37, 7.76, 6.73 | 11.15, 11.19, 10.91 | 0.72, 0.72, 0.84 | 12.14, 12.19, 12.08 |
| 07bac9c4 (Elixir path deleted) | 7.32, 7.84 | 11.36, 11.41 | 0.68, 0.79 | 12.22, 12.54 |
| 75cad9d1 (HEAD) | 7.63, 7.90 | 11.23, 11.06 | 0.71, 0.86 | 12.17, 12.23 |

The sampled phase seems to step at f6f1c203, with 474ff28e between, while
the same commit took about 1.2 ms out of the commit callback; on this host
these differences are within run-to-run noise (see Measurements). The whole-tick probe (`mkprobe081x.py`, adapted per revision;
scratch only) of a75a314c, e75bc9d2, 474ff28e and HEAD in matched pairs
splits the entity phase:

| ms per tick | base | e75 | 474 | HEAD |
|---|---:|---:|---:|---:|
| Entity phase, every section | 6.72, 6.04 | 7.26, 6.97 | 7.27, 6.81 | 7.57, 7.92 |
| Tracking outside its pass and publication | 0.24, 0.12 | 0.38, 0.48 | 0.62, 0.60 | 0.79, 0.86 |
| Section tick NIF | 2.86, 2.72 | 3.09, 2.94 | 3.04, 2.89 | 3.29, 3.40 |
| Collections, whole tick and commit | 0.72, 0.73 | | | 0.46, 0.44 |

- **Idle sections' tracking.** 63 of the 79 sections simulate nothing; each
  tick their tracking asks whether anything changed (`Tracking.idle?/4`:
  `views === tracking.last`). Inside the group process (`:erts_debug.same/2`
  over `:sys.replace_state/2`) those terms were equal but not the same term
  in every such section with entities, at HEAD and at a75a314c alike: a
  section's state reaches its group by message (load, handoff), which
  copies the store's views and the tracking's last views apart, and an idle
  pass never runs to join them again. So `===` walked every view of every
  idle section every tick (4 to 20 µs each), and the walk grew as rows
  grew. This is most of the growth outside the pass: 0.8 ms at HEAD.
- **Collections.** 081h made the commit callback the group's lightest
  allocator; the group's few large collections (about 70 a minute, up to
  20 ms each) now land inside ticks, mostly in the entity phase, which
  allocates the most. The total fell (0.72 to 0.45 ms a tick).
- **Native turns** are 10 to 15% slower at HEAD than at a75a314c with the
  physics, sensing and AI code unchanged and the same population; not
  explained by this probe.

## Design

- **Idle phases are not entered.** `TickPipeline.idle?/2`: block events,
  moving pistons, hoppers and cooking act only in simulated chunks, so a
  section that simulates nothing skips them; its entity phase is skipped
  unless a drop or a portal arrival waits or its tracking has views to pass
  (`RegionData.entities_idle?/1`). The block phase always runs (it stamps
  the game tick and retries the rules backlog). An idle tracking keeps the
  very terms it compared (`Tracking.same/3`), so the next test is identity.
- **Cells counted by class.** A Region's store counts its contact blocks
  (plates, weighted plates, buttons, tripwire) and portal blocks per chunk
  as cells change, beside the random-tick counts (`valimc_core::cell_count`,
  installed with `set_counted_states`). Redstone contacts run only for
  entities whose cells reach a chunk holding a contact block, in the section
  or the siblings beside it its run reaches, and not at all without one
  (`contact_chunks`, `mob_section_contacts/2`); a mob's portal sweep runs
  only where its section's store holds a portal block. A store whose states
  were never installed (an oracle's scene) counts as holding any.
- **Mob glue.** The owner counts its simulated mobs by the chunk index only
  to pick the call's scheduler; the section picks its mobs itself. Sensed
  items go as packed tuples. Rows compare family data counters (an age, an
  egg timer, a creeper's swell: `record::COUNTERS`) by sign only, as the
  settled hash does: the owner reads no counter from a row, so a chicken's
  egg timer no longer sends its row every tick. The POI claims keep their
  term while unchanged, and the group tells a section which siblings hold a
  leash knot (`knotted`) instead of each mob tick asking all of them.
- **Ageing.** Every mob ages in its section: the owner's ageing walks only
  the other kinds' chunk memberships, and a tick without owed ticks builds
  its budget directly.

## Measurements

The matched runs on the development Mac are inside its run-to-run noise:
the a75a314c baseline's entity phase alone spans 4.8 to 6.3 ms across
runs (tick callback 9.8 to 11.9 ms) with the host never quiet, so no
sub-millisecond gain or regression is claimed here, the bisect's step
included. What stands is deterministic: idle sections compared copied
views every tick (seen inside the group process at a75a314c and HEAD), 63
of 79 sections entered six phases that changed nothing, a chicken's egg
timer sent its row every tick (row changes fell from about 19 to 2 a tick
in the probe), and contacts and portal sweeps ran without any such block.
Raw results: `.local/tick-budget/results/x081-*.json`.

## Per-mob work in the section tick

Each change is justified by the work it removes; none is timed.

- **Shared deep parts.** A mob's family data, equipment and attribute
  overrides sit behind an `Arc` (`mobs::model`): copying a mob copies three
  references, and a write copies a part only while another holder shares
  it (`Arc::make_mut`); a write of the value a field already holds (the
  same integer, atom or float bits) is no write. Copies of those parts per
  tick before: one per kept mob (the fallback), one per sensed animal or
  brain mob (its row's data), one per changed row (its key's data). A
  shared part also compares by identity first (a row's data, what
  observers were shown).
- **The fallback** is the mob alone (its parts shared as above); what
  observers were shown, which no turn changes, is copied only when a move
  out of the section waits (`tick::finish`), not for every kept mob at the
  tick's start. Which mobs keep one is unchanged, so restores are exactly
  as before.
- **One kernel input per turn.** The ticker reads of a mob before its own
  step only its place, motion, size and whether it is alive and pushed
  (its grid cell, the earlier mobs' pushes, the players' pushes at the
  end); `tick::kernel_body` gives exactly those, and the whole input
  (travel attributes, controls, hops, floats, effects, impulses, hooks) is
  built once, at the step. Before: twice per turning mob per tick.
- **Travel attributes** depend on a mob's type and overrides alone: a slot
  keeps them with the overrides they came from (`Slot::travel`), and while
  those are the same term they are not computed again (seven attribute
  evaluations per tick per mob with overrides, before).
- **Sensing** is begun once per section tick, as it was; each turning
  mob's row is built again because its own turn changes it, but a row no
  longer copies the family data (a reference, above).

## Deadline-based ageing

A mob's timers (portal cooldown, hurt time, hurt cooldown, player memory,
death animation) are due only while one runs; at rest, `Body.tick/1`
changes nothing and ageing only counts its idle and lived ticks. Each
chunk of a section keeps an ageing clock (the ticks its mobs aged in all
and the game tick it last aged); a slot holds its counts as of its chunk's
clock (`Slot::clock`), brought up to date by every mutable access, by a
change of chunk, and when it leaves (`MobSection::counters` reads them in
place). `tick::age` advances the clocks of the chunks it is given and
visits only the mobs whose timers may be due (`MobSection::timed`): every
mob changed outside a turn (`get_mut`, `peek_mut`, an arrival) and every
mob a turn left with a timer running or below the world (`tick::finish`
decides for each stepped mob); a visited mob whose timers come to rest
leaves the set. Bookkeeping that starts no timer (a turn's start and end,
tracking, ageing's report) uses `peek_kept`. Per tick a resting mob in an
ageing chunk had: a slot visit, a copy and compare of its health, its body
tick, three counter writes and an `Aged` entry for the report; now none,
its chunk's clock counts for it. A mob that arrives in a tick in which it
already aged or turned (a sibling's handoff) is visited, so its exclusion
holds as before; `deadline_ageing_counts_and_times_as_every_tick_would`
checks the counts and timers against every-tick ageing over moves between
chunks and such an arrival.

## Native turns' gap, read

The probe put native turns 10 to 15% above a75a314c's, with the kernel,
sensing and thinking alike. Read for its cause, a75a314c..86a7e77c:

- **The turn itself** gained no work: `Tick::run` and `turn` lost the
  Elixir yield's bookkeeping (the moved list, the pushes for Elixir mobs)
  and nothing was added; the physics kernel, sensing and the AI are
  unchanged but for 081d's vanilla fixes (a farmer's secondary POIs, a
  spear's melee test, an animal's death experience draw), which add no
  per-turn work.
- **081g2's census marks** are one flag test per mutable access (the
  first marks the mob for the spawning phase's refresh), not turn work.
- **081h's record hashing** runs in the cut, once per touched mob per cut,
  outside the turn; it replaced building each touched mob's stationary
  record.
- **Test-only checks** are not in the bench or release builds: one
  `debug_assert!` (compiled out, `opt-level` 3 with LTO), `cfg(test)`
  modules, and the `parity` feature only adds the oracle NIFs.

None of these explains a uniform 10 to 15%, which also showed in the
pure-Rust kernel step; on a host whose runs vary by more than that, the
gap is not established. What reading did find, at a75a314c as now: a
section's slots (1,424 bytes each: the mob inline with its bookkeeping)
sat inline in its `BTreeMap`, so each turn's `take` and `put` moved the
slot and shifted its node's later slots (up to 10 of them) both ways.
Slots are boxed now: those moves are a pointer each.

The harness's view load stalled intermittently (the group kept ticking,
the client's view never completed), on images before and after 081h.

## Checks

Boxed slots: `cargo test -p valimc_core` (211) and clippy (no new
warnings); the region, entity, tracking, storage, spawning and mob suites
(301); `check_vanilla.py --changed` through `heavy.py` (43 of 43, the mob
stages among them).

Deadline-based ageing: `cargo test -p valimc_core` (211) and clippy (no
new warnings); the region, entity, tracking, storage, spawning and mob
suites (301); `check_vanilla.py --changed` through `heavy.py` (43 of 43,
the mob stages among them) and `natural_spawning` and `entity`.

Per-mob work: `cargo test -p valimc_core` (210) and clippy of both crates
(no new warnings); the region, entity, tracking, storage and mob suites
(300 of 301; `region_tick_test`'s tick-duration case failed once under the
full run's load and passes alone, three of three);
`check_vanilla.py --changed` through `heavy.py`: 123 of 123 stages, the
mob stages' scenes among them (every scene mob keeps a fallback and takes
the light ticker body).

Round one:

`mix compile --warnings-as-errors`; `cargo test` of `valimc_core` (the
cell counts, the row data) and clippy of both crates (no new warnings);
the region, entity, tracking, storage, item, portal, redstone, hopper,
spawning and mob suites (301 tests); `check_vanilla.py --changed`: 127 of
127 stages passed, the mob stages (mob_ai, hostile_ai, animals, village,
nether_mobs, natural_spawning, combat) and redstone among them.
