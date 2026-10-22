# VMC-077h — One entity store per owner

Status: In progress
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

Measurements (`bench/entity_store.exs`, raw results kept, untracked, in
`bench/results/entity-store-*.json`):

| | Before (b8646a33) | After |
|---|---|---|
| Items one region accepts | 256, then `:item_count_limit` | |
| Log bytes per create / replace / remove | 255 / 430 / 41 | |
| Packet encodes per tick, 200 moving items | 455 | |
| Encodes per tick with 16 observers pulling | 488 | |
| Observer time per tick (16 observers) | 4.2 ms | |

Checks: in progress.
