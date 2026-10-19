# Ownership and architecture

Processes define state ownership and failure boundaries. Parallel schedulers do
not make coupled gameplay independent; published observations never grant
authority. The M1 tickets on the [roadmap](roadmap.md) move the preview from its
current shape to the target below.

## Owners

| State/work | Owner and access |
|---|---|
| Socket, protocol, AES stream, session inventory/input/pose | One connection process per player |
| Admission, names, lifecycle | Players service; never on movement or chat hot paths |
| Nearby-player observations | Published ETS rows plus a spatial index; paced replication |
| Blocks, chunk sections, block entities, stationary items | Region owner (8×8 chunks) |
| Item and orb observations | Region-owned protected ETS; cached immutable packet binaries |
| World clock, weather, difficulty | Environment owner; immutable publications |
| Encoding, collision queries, auth/crypto, transfer recovery | Bounded worker pools |
| Region files and player snapshots | Leased writers; disk outside sensitive owners |

Ingress is bounded by `active: :once`, packet/byte rate windows, a receive-buffer
cap and mailbox checks. Overloaded connections are shut down with
`{:shutdown, :overloaded}`, so their final save still runs. Chat follows the
vanilla spam throttle. Runtime caps live in `config/config.exs`.

## Target design (M1)

- **Sections, not edit maps.** Each region owns its chunk columns as paletted
  sections in a Rust resource (VMC-062): single-value or packed palette storage
  with block entities and heightmaps beside it. Chunk packets are encoded from the
  sections. The Elixir encoder remains as the parity oracle.
- **Published reads.** After each committed batch the owner publishes immutable
  section snapshots with revisions (VMC-065). Collision workers and other readers
  read them directly; fences compare section revisions instead of a region-wide one.
- **Group commit.** Owner operations queue durable effects; one writer batch per
  tick persists dirty sections and journals, fsyncs file and directory, and then
  acknowledges every operation in the batch (VMC-063). Simulation keeps ticking.
- **One transaction engine.** Cross-owner effects (pickup, mining drops, container
  exchanges, merges, handoffs, XP) are idempotent operations keyed by source,
  sequence and digest with one permit table and one outbox (VMC-064).
- **Tick pipeline.** Region ticks follow world game time in fixed phases
  (scheduled ticks, random ticks, entities, block updates, replication). Tests step
  the clock instead of sleeping (VMC-066). Border effects queue to the neighbour
  and apply at the start of its next tick.
- **Entities.** One entity model (identity, body, motion, lifetime, replication)
  carries items, orbs and later mobs (VMC-067).
- **Data.** One generated registry module per fact family and a single version
  module; block behaviours are callbacks keyed by generated behaviour classes
  (VMC-068).
- **Connection.** Transport, codec (persistent compression streams), login flow,
  job registry and replication become separate modules; broadcast packets are
  framed once and shared as binaries (VMC-069).

## Elixir and Rust

Elixir owns sockets, sessions, ownership, scheduling, transactions, persistence
orchestration and gameplay rules. Rust (via a NIF crate, `native/valimc_nif`,
over a pure `valimc_core` crate) owns dense data and CPU-heavy pure work:

| Rust | Why |
|---|---|
| Section/column storage and chunk packet encoding | Mutable 4096-entry arrays and bit packing; large memory win |
| World generation (M2) | The most CPU per chunk; pure; runs on dirty CPU schedulers behind a bounded pool |
| Lighting (M2) | Breadth-first propagation over nibble arrays on the section resource |
| Anvil chunk read/write (M2) | Parses chunk NBT straight into the section resource |

Kept in Elixir: packet compression (`:zlib`, reusing streams), AES-CFB8
(`:crypto`/OpenSSL), item/text NBT, player physics, redstone (until profiled).

NIF rules: a regular NIF call stays under about 1 ms (batch operations); longer
work runs on dirty schedulers behind a bounded Elixir pool. Mutable state is a
`ResourceArc` held by exactly one owner process; readers get immutable binaries.
Wire and disk input is validated with bounded lengths and no panicking unwraps;
panics surface as Elixir errors. Every NIF has ExUnit parity tests against the
Elixir reference or vanilla dumps, plus `cargo test` in the core crate.

Pumpkin (GPL-3.0) is a design inspiration only; ValiMC's Rust is clean-room from
pinned vanilla behavior. See [research](research.md).

## Durability and failure

Block and player state use custom snapshots, not Anvil/player NBT (until M2).
Periodic saves can lose recent uncheckpointed state on a hard crash. Item transfers
journal a reduced source inventory plus one outbox before delivery; the region
commits records and retry receipts before publication. Source clearing requires
destination receipt proof. UUID writer leases, owner incarnations and revisions
fence stale operations. Never fabricate recovery evidence or roll back one side of
a committed transfer; receipt/counter limits are explicit admission failures.
Contracts and tests: [VMC-019b1](tickets/VMC-019b1.md), [019b2](tickets/VMC-019b2.md),
[019b3a](tickets/VMC-019b3a.md) and [disconnect cleanup](tickets/VMC-005b2d2b.md).

Online login runs verified HTTPS in bounded workers before admission; each
connection owns its cipher. See the [authentication tickets](tickets/VMC-007c3.md).
