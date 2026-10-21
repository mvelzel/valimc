# Ownership and architecture

Processes define state ownership and failure boundaries. Parallel schedulers do
not make coupled gameplay independent; published observations never grant
authority. The M1 foundations below are in place; later milestones on the
[roadmap](roadmap.md) build gameplay on them.

## Owners

| State/work | Owner and access |
|---|---|
| Socket, protocol, AES stream, session inventory/input/pose | One connection process per player |
| Admission, names, lifecycle | Players service; never on movement or chat hot paths |
| Nearby-player observations | Published ETS rows plus a spatial index; paced replication |
| Blocks (Rust paletted sections), block entities, stationary items | Region owner (8×8 chunks); immutable chunk snapshots in its ETS table for readers |
| Generated chunks before they are full (decorated worlds) | Proto owner per region (`Worldgen.Proto`): encoded proto chunks, statuses, finalize transactions; terrain and decoration on dirty schedulers |
| Item and orb observations | Region-owned protected ETS; cached immutable packet binaries |
| World clock, weather, difficulty | Environment owner; immutable publications |
| Encoding, collision queries, auth/crypto, transfer recovery | Bounded worker pools (collision pool partitioned per caller) |
| Region files and player snapshots | Leased writers; disk outside sensitive owners |

Ingress is bounded by `active: :once`, packet/byte rate windows, a receive-buffer
cap and mailbox checks. Overloaded connections are shut down with
`{:shutdown, :overloaded}`, so their final save still runs. Chat follows the
vanilla spam throttle. Runtime caps live in `config/config.exs`.

## Foundations (M1)

- **Sections, not edit maps.** Each region owns its chunk columns as paletted
  sections in a Rust resource (VMC-062): single-value or packed palette storage
  with block entities and heightmaps beside it. Chunk packets are encoded from the
  sections. The Elixir encoder remains as the parity oracle.
- **Published reads.** After each committed batch the owner publishes immutable
  chunk snapshots with revisions (VMC-065). Collision workers and other readers
  read them directly. Block observations carry section fences, so placement and
  destruction stale only when the sections they read change (VMC-064).
- **Group commit.** Owners adopt every durable change in memory at once and queue
  its frame (at most 64); replies, publications and client updates wait until the
  frame is durable. The region writer drains all queued frames into one log append
  with one `datasync` (plus `F_FULLFSYNC` on macOS), then acknowledges them in
  order; checkpoints run beside it (VMC-063). Simulation keeps ticking.
- **One transaction engine.** Cross-owner effects (pickup, mining drops, container
  exchanges, merges, handoffs, XP) are idempotent operations keyed by source,
  sequence and digest. Shared primitives: `Txn.Permits` (one owner permit table),
  `Txn.Receipts` (one idempotency classifier over the per-sequence-space receipt
  tables), `Txn.Delivery` (bounded attempts) and `Txn.Operation` (the per-kind
  source half: request, apply, receipt, proof, resolve) (VMC-064).
- **Tick pipeline.** Each region tick runs `TickPipeline` phases on the owner's
  game tick: scheduled block ticks, random ticks (a native per-section sampler),
  items, cooking, orb lifetime, orbs. Block reactions are `Valimc.Block.Behaviour`
  callbacks; `Region.step/2` drives ticks deterministically in tests (VMC-066).
- **Entities.** Items and orbs share one view (`EntityView`), one per-chunk
  publication with revision stamps (`EntityPublication`; observers copy only
  changed chunks) and one replication tracker per connection (VMC-067).
- **Data.** One generated fact source per concept and a single version module
  (`Valimc.Version`). `Valimc.Registry.Blocks` owns block identity (state runs,
  defaults, properties, vanilla classes); per-state physics facts keep their own
  dense tables. Block behaviours are `Valimc.Block.Behaviour` callbacks chosen by
  the generated class (VMC-068).
- **Connection.** `Valimc.Connection` is a thin GenServer shell; `Net.*` holds
  the codec, login flow and serverbound dispatch, `Session.*` message routing,
  jobs, events, replication and commands, and `Player.*` each gameplay domain.
  Broadcast packets are framed once and shared as binaries (VMC-069).

## Generation (M2)

A region of a generated world loads without generating: the chunks its log has
no column for are absent (VMC-075). Views and forced chunks tell each region
which of its chunks they want and how far from the player; the owner generates
the wanted absent chunks nearest first, in bounded batches and never on itself
(terrain worlds on the worldgen workers, decorated worlds through their proto
owner), persists each batch as one frame and installs it once durable, relit
once. Until then an absent chunk is like a chunk of an unloaded neighbour
region: block reads in the owner see nothing there, edits and observations are
refused, published snapshots fail closed and the chunk stream skips it.

A decorated world's chunks become full through proto owners (VMC-025d). A
chunk is decorated once its 3 × 3 has terrain and is full once its 3 × 3 is
decorated; decoration reads and writes only that 3 × 3, so a full chunk is
never touched again. Finalizing chunks `T` of a region (the chunks its live
region asked for; the whole region for `full_chunks/1`) is one transaction
over the proto owners within two chunks of `T`: their terrain first, then all
their locks at once (`Txn.Permits`), each granted at once or refused as busy,
so a transaction never waits while it holds locks and transactions with
disjoint areas run together (a refused one gives its locks back and retries);
foreign locks are made durable while one decoration call over the chunks
within one of `T` runs, then one commit frame with an outbox, then idempotent
parts (`Txn.Receipts`, `Txn.Delivery`). A participant left with a durable lock
asks the coordinator, a lock not yet durable dies with its coordinator, and
anything not committed is aborted. The live region persists the full chunks
with their block entities and ticks in one frame and the proto owner drops
them.

## Elixir and Rust

Elixir owns sockets, sessions, ownership, scheduling, transactions, persistence
orchestration and gameplay rules. Rust (via a NIF crate, `native/valimc_nif`,
over a pure `valimc_core` crate) owns dense data and CPU-heavy pure work:

| Rust | Why |
|---|---|
| Section/column storage and chunk packet encoding | Mutable 4096-entry arrays and bit packing; large memory win |
| World generation (M2) | The most CPU per chunk; pure; runs on dirty CPU schedulers behind a bounded pool |
| Lighting (M2) | Breadth-first propagation over nibble arrays on the section resource |
| Disk NBT reading (VMC-020) | 3.5–4× the Elixir reader on vanilla chunks; values are sub-binaries of the input |
| Anvil import and export (VMC-021) | LZ4 chunk streams; packed palette indices into sections; compact column images for the region log; vanilla palette packing for export (5.7× the Elixir reference) |

Kept in Elixir: packet and file compression (`:zlib`), AES-CFB8
(`:crypto`/OpenSSL), network item/text NBT, NBT writing (zlib deflate costs more
per chunk), region file headers and palette-name mapping (VMC-021, about 80 µs
per chunk; not yet compared with Rust), player physics, redstone (until profiled). `Valimc.NBT` is the one
NBT codec: network and disk framing, explicit limits, and an Elixir reader that
is the native reader's parity reference.

NIF rules: a regular NIF call stays under about 1 ms (batch operations); longer
work runs on dirty schedulers behind a bounded Elixir pool. Mutable state is a
`ResourceArc` held by exactly one owner process; readers get immutable binaries.
Wire and disk input is validated with bounded lengths and no panicking unwraps;
panics surface as Elixir errors. Every NIF has ExUnit parity tests against the
Elixir reference or vanilla dumps, plus `cargo test` in the core crate.

Pumpkin (GPL-3.0) is a design inspiration only; ValiMC's Rust is clean-room from
pinned vanilla behavior. See [research](research.md).

## Durability and failure

Region state lives in a per-region log of checksummed frames plus checkpoints, not
Anvil: vanilla worlds are imported into it and exported from it offline
(`mix valimc.import`, `mix valimc.export`, VMC-021; 26.2 chunks upgraded as vanilla's
data fixers upgrade them, VMC-028d), and what ValiMC does not model
yet is preserved for export. Player snapshots are files group-committed through partitioned
player logs (`Valimc.PlayerLog`). Logs hold no file descriptor between operations; what
they open at once is bounded by `Valimc.FileBudget`, and running out of descriptors is
retried, never fatal (VMC-074). Acknowledged writes survive a
crash; volatile state (item motion, cooking progress, raw creative edits) is saved
periodically and at clean shutdown, so a hard crash can lose its recent tail. Item transfers
journal a reduced source inventory plus one outbox before delivery; the region
commits records and retry receipts before publication. Source clearing requires
destination receipt proof. UUID writer leases, owner incarnations and revisions
fence stale operations. Never fabricate recovery evidence or roll back one side of
a committed transfer; receipt/counter limits are explicit admission failures.
Contracts and tests: [VMC-019b1](tickets/VMC-019b1.md), [019b2](tickets/VMC-019b2.md),
[019b3a](tickets/VMC-019b3a.md) and [disconnect cleanup](tickets/VMC-005b2d2b.md).

Online login runs verified HTTPS in bounded workers before admission; each
connection owns its cipher. See the [authentication tickets](tickets/VMC-007c3.md).
