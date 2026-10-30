# VMC-081j — The entity phase after the native slices

Status: In progress
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081d](VMC-081d.md), [081g1](VMC-081g1.md), [081h](VMC-081h.md).

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

The sampled phase steps at f6f1c203, with 474ff28e between; but the same
commit took 1.2 ms out of the commit callback and about 0.8 ms out of each
tick's total. The whole-tick probe (`mkprobe081x.py`, adapted per revision;
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

Pending.

## Checks

Pending.
