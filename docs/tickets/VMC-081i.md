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

## Which trackers tick: the pinned jar

Before this slice every tracker ticked every tick, so an entity outside
simulated chunks sent its 60-tick position resend and its 400-update sync.
Vanilla does not. `javap -c -p` of the pinned server jar (SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, `versions/26.3/server-26.3.jar`
of the bundle, JDK 25):

- `ChunkMap.tick()` walks `entityMap.values()`. For each `TrackedEntity` it
  compares `lastSectionPos` with `SectionPos.of(entity)`; when they differ
  it calls `updatePlayers` and stores the new section. It then calls
  `serverEntity.sendChanges()` only if the section changed, or
  `entity.needsSync` is set, or
  `distanceManager.inEntityTickingRange(sectionPos.chunk().pack())` is
  true (offsets 170 to 209); otherwise it skips the entity.
- `DistanceManager.inEntityTickingRange(long)` is
  `ChunkLevel.isEntityTicking(simulationChunkTracker.getLevel(chunk))`: the
  simulation-distance level, not the loading one.
- `ServerEntity.sendChanges` has no other caller (only `ChunkMap` and
  `ServerEntity` name it), and its `tickCount` advances only inside it.

ValiMC's simulated chunks (`Tickets`: player simulation, forced, portal
and post-teleport tickets) are the chunks whose entities tick, vanilla's
entity-ticking range. A section change, a `needsSync` (a teleport, a
sharp motion change) or anything else that changes the entity changes its
view, so "in a simulated chunk or its view changed" includes every case
vanilla ticks a tracker. It is wider by views that change for other
reasons (a portal cooldown, an item's counters) outside simulated chunks,
which tick their tracker once where vanilla would not.

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

The `mobs` scenario (`bench/tick_budget.exs`, two pinned cores of the
development Mac's Linux VM, 60 s, about 162 active mobs and 762 loaded
entities in 79 sections, 16 of them simulating). Before: 4e4426d3 (the
image of 081d's measurements); after: b1fb29ca. The host was shared with
other sessions, and the sampled entity phase moved by more than a
millisecond between runs of one image, so runs were interleaved.

| | before | after |
|---|---|---|
| Entity phase, first pairs (ms) | 7.09, 6.97 | 5.26, 5.11 |
| Entity phase, interleaved pairs (ms) | 5.83, 6.13, 6.18, 10.46 | 4.81, 5.97, 6.04, 6.41 |
| Entity phase, other runs (ms) | 8.49 | 7.03, 6.74 |
| Median of all runs (ms) | 6.97 | 5.99 |
| TPS (mean / lowest second) | 20.0 / 18.8–19.0 | 20.0 / 18.8–19.0 |
| Tick mean / p95, first pairs (ms) | 12.4 / 14.9, 12.6 / 24.3 | 10.1 / 13.5, 10.0 / 13.0 |

Probe (`.local/tick-budget/probe-081d-instrumentation.patch`'s harness with
tracking spans, ms per tick; before: `docker-resident3probe-1`, after:
`docker-trackprobe3-1`):

| | before | after |
|---|---:|---:|
| Tracking (`track_entities`, all 79 sections) | 2.41 | 1.36 with probe overhead |
| of it: the pass in the 16 sections that do anything | – | 0.36 |
| of it: diff of views / tracker ticks / native call | – | 0.02 / 0.13 / 0.05 |
| of it: projections of changed entities | – | 0.11 |
| of it: ETS writes (21 rows, 55 sources) | – | 0.26 |
| Sections idle (one comparison) | 0 of 79 | 63 of 79 |
| Frame bytes per tick | – | 387 |

The rest of the after figure is the probe's own counters in 79 calls a
tick (two ETS counter updates each); without them tracking is the pass and
the writes, about 0.62 ms.

The `explore` scenario (one run each, `docker-{pretrack,track2}-1-explore`):
entity phase 5.78 → 4.42 ms, tick mean 15.8 → 11.1 ms, p95 31.0 → 27.8 ms,
TPS 19.97 / 18.74 → 20.00 / 18.98. The moving player's connection filters
every row each tick, as before, and nothing regresses. Raw results in
`.local/tick-budget/results/docker-{pretrack,track1,track2,pair-before,pair-after,trackprobe3}-*.json`.

Checks: `cargo test -p valimc_core tracker`; clippy without new warnings;
`mix compile --warnings-as-errors`; the tracking, replication, session,
connection, entity, item, region, dragon and native test files with the
tcp and slow suites (133 files, 558 tests); the vanilla stages `entity`,
`entity_position`, `combat_packets`, `experience_orb`, `combat`,
`mob_travel` and `tcp`.

Left: metadata, attributes and equipment of native mobs are encoded in
Elixir from their rows; items keep Elixir trackers; a moving player's
connection still filters every row each tick (vanilla's `updatePlayer`
does the same on a player's move).
