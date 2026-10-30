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

## Checks

Round one (merging, selection): the item, spatial, membership, bodies,
explosion, hopper, despawn, portal, void, handoff, checkpoint, tick,
activity, orb, redstone and piston suites (59 tests);
`check_vanilla.py --changed` through `heavy.py` (39 of 39, the item,
mob and `tcp` stages among them).
