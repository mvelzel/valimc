# VMC-077h — One entity store per owner

Status: Awaiting client
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (phase 3, D1), [VMC-077f](VMC-077f.md) (keyed
records), [VMC-077g](VMC-077g.md) (owner skeleton), [VMC-077l](VMC-077l.md)
(items step in the kernel).

Before: items lived in `Items` with a 256-item and 512 KiB cap per region,
validated by encoding the whole region's items, with network ids from
`System.unique_integer` and a new id on every handoff; receipt tables refused
their 4,097th source for good; XP orbs were a cooking ledger inside the
containers record; cross-region merges had their own escrow protocol; and
observers pulled every entity's absolute packets, re-encoded by the owner on
every step.

Scope: the region owner's entities (items now, orbs, later mobs and
projectiles), their persistence, handoffs, merges and replication. Not here:
players in owners and the player-sourced transfer protocols (VMC-077i), which
keep working on the store.

Acceptance:

- One entity store per owner (`Valimc.World.Entities`, the `store` of the
  owner's `RegionEntities`): entities by network id with a uuid index, each of
  a kind, persisted one record per entity (`{:entity, uuid}`). No count or size
  cap per region, and receipt tables take any number of sources. Records of
  the older format are refused (D4).
- Network ids come from one `:atomics` counter (`Valimc.World.EntityIds`) for
  players and every entity kind.
- One handoff for every kind (`Valimc.World.EntityHandoffs`): the source
  withdraws a cohort of at most 32 records into one durable outgoing intent,
  the destination adopts it and records its receipt (applied or rejected) in
  the same frame, and the source clears the intent once that receipt is
  durable. Records keep their uuid, kind and hops and, within one VM, their
  network id, which stays out of the digest and off disk. The digest is a
  SHA-256 of the transfer's deterministic term; the legacy `ItemLedger` codec
  is gone. Portal crossings keep their tagged `{dimension, key}` ends.
- A cross-region merge is the donor handed over with its target's uuid, then
  merged on arrival as vanilla merges two items; a target that is gone or
  changed rejects it, and the donor comes back when the source clears. Only
  whole donors cross (vanilla merges at most 64 items at once). Discovery stays
  an observation of the neighbours' snapshots; the merge escrow, inbox,
  permits, transfer record, query protocol and owner receipt table are deleted.
- Experience orbs are entities of kind `:orb` (`%{value, count, age}`) in the
  store; they left the containers record. Withdrawing a furnace's earned
  output decides its award and spawns the orbs (vanilla's per-recipe split,
  `Valimc.World.ExperienceOrbs`) at the player in the same commit, or hands
  them to the owner of that position through the one handoff (a withdrawal
  waits while that slot is taken). Orbs age with the other entities and
  despawn at 6000 ticks; they still do not move (as before). An XP pickup keeps
  the player's container-kind request and takes one unit from the orb entity
  under the same receipt; its consumed-units fence is no longer used. Anvil
  import and export read and write orb entities. Deleted: pending cooking
  awards, cooking orb births, bodies, consumptions, transfers, delivery and
  runtime, and containers formats 4 to 8 (refused, D4).
- Replication is encoded once, by the owner (`EntityTracker`, vanilla's
  `ServerEntity`, kept beside the store in `EntityTracking` so a plan's copy of
  the store never rolls a tracker back). Each tick an entity's changes become
  packets at its type's update interval (20 ticks for items and orbs, sooner on
  a sharp change of motion): relative moves (26.3 `move_entity_pos`, the
  `VecDelta` codec), motion, metadata, an absolute sync on landing, after 400
  ticks or past a short's reach. They form the tick's frame, kept in a ring of
  64 ticks in the publication table, and only chunk rows whose observed views
  changed are rewritten, each stamped with the tracking tick. Rows hold only
  what connections read.
- A connection (`EntityReplication`) spawns an entity from its row at the
  tracker's base, forwards each later frame's packets for the ids it tracks,
  and resyncs (absolute position, motion, metadata) an entity seen under
  another owner or behind the ring, never respawning it. A departing entity
  stays published, frozen, until its handoff clears; readers keep the newer
  owner's view while both publish it, so a border crossing looks like a move.
  Orbs are no longer resent every pass. Peer players keep their own path until
  VMC-077i; the tracker takes any entity with a position, motion and metadata.

Deferred:

- Players join the owner trackers with VMC-077i, and with them the head
  rotation and ground flag of player-connection E5 (no player packet is on
  this path; `move_entity_pos_rot` for players still sends a constant flag).
- Player-sourced transfers (drops, pickups, mining drops, placement,
  container clicks, XP pickup) still cross from the connection on their own
  protocols until VMC-077i; the XP request's consumed-units field is now
  always 0 and unchecked.
- Orbs still rest where they spawn: vanilla's launch velocity, gravity,
  following the nearest player and merging of nearby orbs are not live
  (`Physics.OrbMotion` keeps the launch).
- A cross-region merge never splits a donor: stacks above 64 that vanilla
  would merge partly stay apart across a region border.
- A withdrawal whose orbs land in another region waits while the furnace
  region's one outgoing handoff is in flight (a retry, not a queue).
- Observers still copy every changed chunk row, and moving items change
  theirs every tick (their current position is in the row for pickups); a
  separate position row would cut the reads.
- Handoff digests hash the transfer's deterministic external term: an OTP
  upgrade that changed that encoding while an intent is in flight would show
  as a conflict on its retry.

Measurements (`bench/entity_store.exs`, raw results kept, untracked, in
`bench/results/entity-store-*.json`):

| | Before (b8646a33) | After |
|---|---|---|
| Items one region accepts | 256, then `:item_count_limit` | 2,000 of 2,000 tried, no refusal |
| Log bytes per create / replace / remove | 255 / 430 / 41 | 269 / 444 / 43 (records name their kind) |
| Packet encodes per tick, 200 moving items | 455 | 65 |
| Encodes per tick with 16 observers | 488 | 60 (observers encode nothing) |
| Observer time per tick (16 observers) | 4.2 ms | 3.6 ms |

Encodes are calls into `Valimc.Protocol.EntityPackets` over 40 ticks of
items moving with drag; an item now sends its motion, a relative move and a
re-encoded spawn once per update interval instead of a spawn, a position and
a motion packet every step.

Deleted lines: the store core removed the caps and the per-region encode
validation; the handoff and merge change deleted the `ItemLedger` codec and
the merge escrow, inbox, permits, transfer, query protocol and owner receipts
(1,821 lines deleted, net −1,132); orbs as entities deleted the orb ledger
family (2,593 deleted, net −2,107).

Awaiting client (the next client run): items moving and settling look smooth
from the relative moves; an item crossing a region border stays one entity
without flicker; a furnace withdrawal spawns its XP orbs at the player, who
collects them (also standing in the neighbouring region); items at a region
border merge.

Checks: `mix test.fast` and the full `mix test` (one run, since every
connection runs the new replication; its one failure, a test comparing
records without their kind, is fixed), the changed vanilla stages
(`check_vanilla.py --changed`, including `anvil_content`, `experience_orb`,
`cooking_experience`, `item_void`, `cooking_tick` and `tcp`), the audit, and
`bench/entity_store.exs`, `bench/item_steps.exs` and `bench/item_handoffs.exs`
under `MIX_ENV=bench`.
