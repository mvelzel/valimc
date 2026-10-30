# VMC-081i — Native, change-driven entity tracking

Status: Done
Milestone: M3, at the user's request
Parent: [VMC-081](VMC-081.md).
Depends on: [081d](VMC-081d.md).

After 081d's resident ticks the `mobs` scenario's entity phase was 7.45 ms,
of which tracking took 2.41: every section walked every view every tick
(static ones included), ticked an Elixir tracker for each, projected every
view again, compared and copied the whole store's views into ETS, and
rebuilt rows from a walk of all views. Connections filtered every visible
row by range and re-examined every tracked entity every 50 ms. This slice
makes tracking native for native mobs and makes every part of it work on
what changed.

## Design

- **Trackers.** A native mob's tracker (`valimc_core::tracker::Tracker`:
  the base observers were sent, the motion, ground flag, rotation and head
  angle bytes, the update counter and the teleport delay) lives on its
  section's slot. `mob_section_track` (NIF `mob_track`) ticks the trackers
  of the section's mobs in simulated chunks and of those its owner names,
  in id order, and writes their packets (motion, a relative move with or
  without the rotation, the rotation alone or an absolute sync, the data
  changes the owner encoded, the head's yaw, as vanilla's
  `ServerEntity.sendChanges` orders them) straight into the section's
  frame. A tracker whose spawn changed (base, motion, rotation, head)
  comes back with its `add_entity` payload, encoded natively, for its row.
- **The owner's half** (`Entity.Tracking`) keeps for a native mob only its
  base, its incarnation and the entity events and data (`Body.shown/1`'s
  projection) already sent. When its view changed it names the mob to the
  section with the new events and the data changes it encodes (rare: a
  hurt, a name, equipment); a mob that only moved in a simulated chunk is
  not named. It starts a native tracker where it publishes the mob's first
  spawn, with that spawn's state; a slot the section finds without a
  tracker (a parcel back before its owner saw it leave) starts one itself
  and its owner gives it a new incarnation, so observers resync. Items,
  orbs, objects and Elixir mobs keep `Entity.Tracker`.
- **Only what changed.** A pass compares the store's views with the last
  pass's (an untouched store is the same term), so a section whose store
  and players did not change and that simulates nothing costs one
  comparison. Trackers tick only for entities in simulated chunks (vanilla's
  entity-ticking chunks, `ChunkMap.tick`) or whose view changed. Changed
  entities alone are projected into their row view again (a native mob
  that only moved keeps the rest of its projection), and only their
  chunks' rows are rewritten. The owner's views are published one ETS row
  per entity, rewritten when it changes, where the whole map was copied
  each tick.
- **One frame.** The tick's packets of every kind (native, Elixir and the
  players standing in the section) are one binary of entries `<<entity
  id::32, packet id::16, size::32, payload>>`. Observers take sub-binaries
  of the entries for the ids they track and frame them as they are.
- **Membership on change.** A connection keeps which entities it observes
  (`Session.EntityMembership`): a chunk's row is filtered by range again
  only when its stamp changed (a row holding a player every pass, since
  whether a player is shown is not in its row alone), and a move of the
  player, its view or what decides which players it sees filters them all,
  as vanilla's `updatePlayer` runs for an entity that changed section or a
  player that moved. Its tracker (`Entity.Observer`) examines only the ids
  the changed rows held or hold and the ones waiting for a spawn's budget;
  it keeps a count of tracked entities per region instead of walking them
  for every read. Two rows naming one entity (a handoff) or more than 1,024
  candidates fall back to the whole selection, chunk order and the newer
  ownership generation deciding as before.

Metadata, attributes and equipment are still encoded in Elixir: they
change rarely, their values come back in the row the store needs anyway,
and encoding them natively would need the data serializers and the item
stack codec in Rust. Items keep Elixir trackers: after this slice their
tracking is the trackers of items in simulated chunks, at a 20-tick
interval.

## Acceptance

- The native tracker sends what `Tracker.tick_body/2` sends, tick for tick:
  `native_tracker_test` (random walks with turns, landings, far jumps,
  motion and data changes for four types, the spawn included) and
  `native_mob_section_test` (a wolf falling, landing, hurt and named in a
  region, each tick's published frame against an Elixir tracker over the
  same views).
- Incremental membership equals the full selection and the observer ends
  in the state a full pass gives, over random row changes with handoff
  duplicates (`entity_membership_test`).
- A static section publishes nothing and its trackers tick only in
  simulated chunks; moves, data, colliders, a new tracker and a departure
  rewrite only the rows they touch (`tracking_publication_cache_test`).
- The `mobs` scenario's entity phase drops by the tracking share; the
  explore scenario does not regress.

## Measurements

Pending.

Checks: pending.
