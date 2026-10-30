# VMC-081l — Item entities at rest

Status: In progress
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081j](VMC-081j.md).

A production profile of one player in a village (two vCPUs; 78 sections,
771 loaded entities, 149 active mobs) put the entity phase at about 13 ms
of a 21 ms tick, and items ahead of the native mobs inside it: the
region's `item_tick/2` held 31% of its stack samples, of which
`move_unplanned_items/2`, `commit_simulated_items/2`, `ItemStep.steps/1`
and `start_item_merging/2` are the items' own, and `Store.age_chunks/4`
another 9%. 1,568 merge plans had run since boot. This slice makes an
item's tick cost follow what changes about it, not that it exists.

## Where the work was

Per section tick, for every item in a simulated chunk:

- **Ageing** walked the chunk memberships, advanced its counters, bumped
  its revision, rebuilt its view, put it in the journal and stamped its
  `aged_tick` (`Store.age_chunks/4`).
- **Stepping** selected the items by walking every entity of the section
  (`move_unplanned_items/2`), built a kernel input, read its fire immunity,
  ran the kernel (`physics_items`, with `refresh` set), burning and rain,
  and committed the step: a second revision, view, spatial and journal
  write (`Store.advance/4`), whether or not anything but the age moved.
- **Merging** listed every entity again after each commit to stamp the
  items' physical revisions; a resting item's velocity still decays every
  tick (the kernel steps it each tick, and its horizontal velocity shrinks
  by its block's friction until it reaches a floating-point fixed point,
  about 1,400 ticks for a typical drop), which bumps its physical
  revision, so the stamp changed every tick and a merge plan (a copy of
  the whole store to a worker) started every 200 ms.
- **Primed TNT and falling blocks** were selected by walking every entity.

## Design

- **Event-driven merging.** Which items merge depends only on which items
  there are, where they stand, their stacks and whether they may merge.
  The spatial index, through which every view change passes, counts those
  changes (`Spatial`'s `items`); a merge plan starts only after one, and a
  velocity or counter change alone starts none. A failed plan still clears
  the stamp, so it is retried.
- **Selection by the spatial index.** The items phase visits the awake
  items of the simulated chunks (`Spatial.awake/2`) and their orbs, the
  block bodies phase the simulated chunks' objects (in id order, as a small
  store's map walk gave them), never every entity of the section.

## Resting items

An item whose tick leaves it as it was, but for its counters, rests: its
owner neither steps nor ages it until something its tick reads changes.

- **When.** After the items phase commits its steps, an item that
  `Store.advance/4` left unchanged (its place, velocity, ground and water
  flags, health, fire ticks and on-fire flag the very terms it had) rests,
  if what its tick reads (its cell two blocks around, which covers the
  kernel's scan, its supporting block and its contacts) lies in the
  section's own chunks, it has no pickup delay or an unlimited one, no
  portal cooldown, and does not burn. The kernel step is a pure function of
  the item's physical state, the published chunks it reads and the world
  border, and burning of its fire state, its contacts and (only when
  burning) rain: with those the same, its next tick is this one again, so
  only its age moves. A velocity still decaying is a change: such an item
  stays awake until the decay stops at its floating-point fixed point.
- **Its age on a chunk clock.** Each chunk holding resting items keeps a
  clock, the ticks it aged (owed ticks after a planning pause included,
  once a game tick as every entity ages). A resting entry keeps its
  counters as of the clock it rested at; `Store.settled/2` gives them as of
  now. Every store path that changes or hands out an item settles it
  (`current/4`: steps, replacements, removals, withdrawals), a step made
  from the entry as it rested (a piston's or an explosion's push) keeps its
  settled counters, merges read settled inputs, and records (frames, the
  baseline, checkpoints, `Store.records/1`) are settled. A store holding
  resting items with a running age counts as counters moving, so a
  checkpoint saves their age within the same five minutes as any other
  counter.
- **Expiry.** A resting item's despawn is a deadline: the spatial index
  keeps, per chunk, the clock at which each one's age reaches 6000, and the
  clock's advance takes the due ones, which expire in the tick every-tick
  ageing would expire them.
- **Waking.** The spatial index keeps, per chunk a resting item reads, the
  publication it read (the chunk's snapshot handle in the section's table)
  and the world border. At the start of each items phase (before ageing,
  so a change published earlier is read by this tick's steps as every
  tick's are) a chunk published anew wakes the items reading it, and a
  border change wakes all. Any view change of an item wakes it
  (`Spatial.put/4`), so a store path that does not know about resting can
  only leave an item awake, never asleep while it changes.

Per tick, a resting item had: a membership visit, a counter advance with a
new revision, a rebuilt view and a journal entry, an `aged_tick` stamp, a
kernel input with its fire immunity, a kernel step, burning, a
`simulated_tick` stamp and a step compared against its entry. Now it has
none; the section's resting work per tick is one table lookup per chunk
its resting items read and one clock advance per chunk holding them.
`item_rest_test.exs` checks records, views and expiry against every-tick
ageing over chunks out of simulation, owed ticks, a repeated game tick and
a wake partway; `item_simulation_region_test.exs` checks, in a running
section, that resting items' entries and views stay the same terms over
twenty ticks while their age runs, that a checkpoint saves that age, and
that removing the block under one wakes it and it falls.

## Checks

Resting items: the rest, item, merge, spatial, membership, bodies,
explosion, hopper, despawn, portal, void, handoff, checkpoint, journal,
storage, tick, activity, orb, redstone, piston, fluid, mining, villager,
import, group, lifecycle, replication and view suites (114 tests) and the
pickup, item, explosion and portal socket suites (6);
`check_vanilla.py --changed` through `heavy.py` (40 of 40, the item,
mob, storage and `tcp` stages among them).

Round one (merging, selection): the item, spatial, membership, bodies,
explosion, hopper, despawn, portal, void, handoff, checkpoint, tick,
activity, orb, redstone and piston suites (59 tests);
`check_vanilla.py --changed` through `heavy.py` (39 of 39, the item,
mob and `tcp` stages among them).
