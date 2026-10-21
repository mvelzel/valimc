# Ownership and architecture

Processes define state ownership and failure boundaries. Parallel schedulers do
not make coupled gameplay independent; published observations never grant
authority. The M1 foundations below are in place; later milestones on the
[roadmap](roadmap.md) build gameplay on them.

## Owners

| State/work | Owner and access |
|---|---|
| Socket, protocol, AES stream, session inventory/input/pose, move validation | One connection process per player; each move packet is validated synchronously by the physics kernel |
| Admission, names, lifecycle | Players service; never on movement or chat hot paths |
| Nearby-player observations | Published ETS rows plus a spatial index; paced replication |
| Blocks (Rust paletted sections), block entities, stationary items | Region owner (8×8 chunks) while chunk tickets hold it; immutable chunk snapshots and chunk packets in its ETS table for readers |
| Generated chunks before they are full (decorated worlds) | Proto owner per region (`Worldgen.Proto`): encoded proto chunks, statuses, finalize transactions; terrain and decoration on dirty schedulers |
| Item and orb observations | Region-owned protected ETS; cached immutable packet binaries |
| World clock, weather, difficulty | Environment owner; immutable publications |
| What the world generates per dimension | `World.Spec`, read once from `world.json` at start; a read failure stops the start |
| World spawn (with dimension and pitch), default game mode, admin switches | Settings owner; writes `settings.json` crash-safely, then publishes |
| Commands and suggestions | A job per command (`Session.Commands`), or the console's or RCON client's process, over a `Command.Source` value; blocks change through region owners, players through their own connections |
| Encoding, placement and mining jobs, auth/crypto, transfer recovery | Bounded worker pools (the placement and mining pool partitioned per caller) |
| Region files and player snapshots | Leased writers; disk outside sensitive owners |

Ingress is bounded by `active: :once`, packet/byte rate windows, per-phase
frame and receive-buffer caps (small before configuration), a connection heap
limit and mailbox checks. Overloaded connections are shut down with
`{:shutdown, :overloaded}`, so their final save still runs. Chat follows the
vanilla spam throttle. Runtime caps live in `config/config.exs`. A connection
never calls another owner synchronously: commands, suggestions and block
interactions run as its jobs (`Session.Jobs`) and their results arrive as
messages (VMC-077a).

Supervision is five domain supervisors under a `rest_for_one` root, each with
its own restart intensity: infrastructure (settings, clock, tick rate, admin
lists, worker pools), storage, world, players and network. A crash loop stays
in its domain; only a domain's restart restarts the domains after it. Tables
that hold no owned state belong to the application itself. Acceptors back off
on accept errors (VMC-077a).

## Foundations (M1)

- **Sections, not edit maps.** Each region owns its chunk columns as paletted
  sections in a Rust resource (VMC-062): single-value or packed palette storage
  with block entities and heightmaps beside it. Chunk packets are encoded from the
  sections. The Elixir encoder remains as the parity oracle.
- **Published reads.** After each block change, and before any client hears of
  it, the owner publishes immutable chunk snapshots (VMC-065) with the
  MOTION_BLOCKING heightmap, lowest sky sources and biomes Rust computes beside
  them, so a client's next move is checked against what it was shown. Every physics, rain, portal and
  spawn reader reads them through `World.View`, one lazy per-chunk view: no
  owner call, no envelope to plan and no fence, since observations are not
  transactions; a chunk not loaded or generated fails closed (VMC-077e). Only commits are fenced: block
  observations for placement, mining and commands carry section revisions, so
  they stale only when the sections they read change (VMC-064).
- **Shared write-ahead log (D2).** Every owner commits to one striped log per
  world (`Valimc.Storage.Log`, VMC-077f): eight stripes, region frames on six
  and player files on two, each written by one process that drains its queue
  into one append with one `datasync` (plus `F_FULLFSYNC` on macOS). An owner
  adopts, publishes and answers every change at once and cuts one frame of
  keyed records every 50 ms (cells, items by UUID, receipts, container entries
  by position, scheduled ticks, block entities); only a cross-owner transfer's
  reply (its receipt, the proof the other owner acts on) waits for its frame. A
  crash loses at most a suffix of an owner's frames, never one half of a
  transfer. A region's checkpoint file folds its cells into column images
  relit alone, so a load replays nothing older; the log then drops the frames
  it holds. Simulation never waits for the disk.
- **One transaction engine.** Cross-owner effects (pickup, mining drops, container
  exchanges, merges, handoffs, XP) are idempotent operations keyed by source,
  sequence and digest. Shared primitives: `Txn.Permits` (one owner permit table),
  `Txn.Receipts` (one idempotency classifier over the per-sequence-space receipt
  tables), `Txn.Delivery` (bounded attempts) and `Txn.Operation` (the per-kind
  source half: request, apply, receipt, proof, resolve) (VMC-064).
- **Tick pipeline.** Each region tick runs `TickPipeline` phases on the owner's
  game tick: scheduled block ticks, random ticks (a native per-section sampler),
  items, cooking, orb lifetime, orbs. Block ticks and item motion run only in
  chunks a simulation ticket covers; cooking and orb ageing while any chunk of
  the region does (VMC-077e). What a commit starts (neighbour and shape updates,
  survival, redstone wire power) and dependent blocks' due ticks run in the Rust
  block-update engine in one call per commit (VMC-077m); blocks with effects of
  their own (portals, containers, cooking) keep `Valimc.Block.Behaviour`
  callbacks. `Region.step/2` drives ticks deterministically in tests (VMC-066).
- **Entities.** Items and orbs share one view (`EntityView`), one per-chunk
  publication with revision stamps (`EntityPublication`; observers copy only
  changed chunks) and one replication tracker per connection (VMC-067).
- **Data.** One generated fact source per concept and a single version module
  (`Valimc.Version`). Each `priv` file has one decoding module: it reads the
  file with `use Valimc.Facts`, which loads it once at compile time and checks
  every release stamp it carries, and every other reader asks that module.
  Files too large to keep as terms (loot tables, translations, the command
  tree) and the files Rust parses itself (worldgen, survival, shapes) are read
  at run time by their owner through `Valimc.Facts.read!/1`;
  `Valimc.Worldgen.Facts` keeps the few worldgen terms Elixir needs (biome
  names and climates, the ids commands name). `Valimc.Registry.Blocks` owns block identity (state
  runs, defaults, properties, vanilla classes) and `Valimc.Registry.BlockFacts`
  every per-state fact, as one columnar table from one oracle (VMC-077d): flags,
  collision shape, motion, fluid, climbing, inside behaviour, hazard, landing,
  mining, replaceability, heightmaps, sky, light and redstone signals. Survival
  keeps two tables, read by one Rust module: decoration checks survival before
  placement under unlit light, live updates after it with their reactions.
  Block behaviours are `Valimc.Block.Behaviour` callbacks chosen by the
  generated class (VMC-068).
- **Connection.** `Valimc.Connection` is a thin GenServer shell; `Net.*` holds
  the codec, login flow and serverbound dispatch, `Session.*` message routing,
  jobs, events, replication and commands, and `Player.*` each gameplay domain.
  Broadcast packets are framed once and shared as binaries (VMC-069).
- **Commands.** `Valimc.Commands.registry/0` maps each top-level command to
  one handler function, which receives the parsed literals; the
  Brigadier tree is built from `tree.json` at start, so the command
  packet needs no compile-time handler table (nodes keep redirects and a
  modifier slot for `execute`). A command runs in layers: parse
  (pure), resolve over published snapshots (`Command.Targets` selects
  over the player projections and the spatial index), execute through owner
  operations, and feedback through the source's sink (a connection, the
  log or an RCON reply). `Command.Source` is a plain value: entity,
  dimension, position, rotation, anchor, level, sink and silent flag.
  `/fill`, `/clone` and `/place` are box edits (`World.BoxEdit`): each
  region owner locks its cells (`Txn.Permits` `:box_edit`) and checks
  them, then all commit or all abort; an unloaded region fails with
  `argument.pos.unloaded` (VMC-077o).
- **Text.** `Valimc.Text` builds components, `Text.Render` renders them as
  English strings and `Text.Codec` converts the command and item-component
  forms (one colour table, item identity bytes unchanged). Gameplay
  depends on `Valimc.Text`, not on the command layer.

## Chunk lifecycle

Chunk tickets drive load, simulation and unload, as vanilla's `TicketType`s do
(VMC-077e). A region owner holds the tickets of its chunks
(`World.Tickets`): a connection's view (`player_loading`) and simulation
(`player_simulation`, the chunks within `min(simulation distance, view
distance)` of the player), `forced` from `/forceload`, timed `portal`,
`post_teleport`, `player_spawn` and `spawn_search` tickets of readers that need
chunks loaded, and a fresh owner's one-tick `unknown` ticket of its own
admission. Untimed tickets end with their holder process. An owner without
tickets and work in flight (writes, jobs, outboxes, deferred calls, open
containers, permits) for `region_unload_delay_ms` retires its route, saves its
volatile state and stops; a world without a path and `/save-off` keep their
regions. The Directory admits regions; one whose owner dies while loading backs
off per key and is poisoned, with one error line, after five failures in a row.
Admission errors are values.

Chunks stream as vanilla's acknowledged batches (VMC-070). The connection never
waits for a chunk: an owner publishes each chunk's packet beside its snapshot
once encoded and withdraws it in the step that adopts a
change; the connection reads published packets directly, asks for the others
with `send_request` and sends replies when they arrive. A dimension change
withdraws the old dimension's tickets and abandons pending requests.

## Generation (M2)

A region of a generated world loads without generating: the chunks its log has
no column for are absent (VMC-075). Loading tickets say which of its chunks are
wanted and how far from their center; the owner generates
the wanted absent chunks nearest first, in bounded batches and never on itself
(terrain worlds on the worldgen workers, decorated worlds through their proto
owner) and installs each batch at once, relit once; its column images join the
next frame, and a proto owner forgets the chunks only once that frame is
durable. Until then an absent chunk is like a chunk of an unloaded neighbour
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
| Lighting (M2) | Per chunk (VMC-077c): each chunk lit alone where it is generated and stored in its column image; a region adopts that light, propagates only across chunk faces and then updates incrementally within a work budget, over nibble arrays on the section resource |
| Disk NBT reading (VMC-020) | 3.5–4× the Elixir reader on vanilla chunks; values are sub-binaries of the input |
| Anvil import and export (VMC-021) | LZ4 chunk streams; packed palette indices into sections; compact column images for region checkpoints; vanilla palette packing for export (5.7× the Elixir reference) |
| Block updates (VMC-077m) | `updateShape`, survival, neighbour updates in vanilla's collecting order and redstone wire power over the owner's store, one call per commit; the same rule modules serve decoration. Effects that leave the owner (drops, events) return to Elixir |
| Entity physics (VMC-077l) | One kernel (`valimc_core::physics`) for players and items: block scans over published section rows with per-section special-collider checks, shapes from the installed fact table, `Entity.collide` with step-up, body sweeps, fluids, flow and currents, the supporting block and a whole item tick. Players call it per move packet from their connection; region owners once per tick for all their items |

Kept in Elixir: packet and file compression (`:zlib`), AES-CFB8
(`:crypto`/OpenSSL), network item/text NBT, NBT writing (zlib deflate costs more
per chunk), region file headers and palette-name mapping (VMC-021, about 80 µs
per chunk; not yet compared with Rust), the player's travel rules around the kernel's geometry (jump, fluid and climbing controls, sneak edges). `Valimc.NBT` is the one
NBT codec: network and disk framing, explicit limits, and an Elixir reader that
is the native reader's parity reference.

NIF rules ([VMC-077b](tickets/VMC-077b.md)):

- The shim has one module per domain (`facts`, `region`, `rules`, `light`,
  `climate`, `codec`, `sys`, `worldgen`, `loot`, `physics`); oracle and benchmark
  NIFs live in `parity`, built only
  with the `parity` cargo feature (dev, test and bench builds, not releases).
  One arity per NIF.
- Scheduling by bounded worst-case cost. A NIF on a normal scheduler stays under
  about 1 ms for any input its callers can pass (batch, never one call per
  position). A NIF whose cost grows with its input has a dirty twin, and
  `Valimc.Native.dispatch/3` picks one of the two from measured nanoseconds per
  unit. Long pure work (generation, `/locate`, `/place`) runs only as a job in
  `Valimc.Worldgen.Pool`, which runs two jobs fewer than the VM has dirty CPU
  schedulers, so an owner's own dirty call never waits behind generation.
- Results: `{:ok, value}`, `:ok` without one, or `{:error, atom}` from the
  domain's closed set for an expected failure; a broken invariant raises. No
  string errors for machine use.
- Mutable state is a `ResourceArc` owned by the process that created it: the
  Region resource refuses changes from any other (`{:error, :not_owner}`).
  Shared Rust state is only a pure memoization cache (the worldgen state pool,
  as many states as the generation pool runs jobs); readers get immutable
  binaries.
- Positions cross as packed big-endian binaries; outputs are written straight
  into binaries, and large ones point into the Rust buffer without a copy.
- Wire and disk input is validated with bounded lengths and no panicking
  unwraps. Every NIF has ExUnit parity tests against the Elixir reference or
  vanilla dumps, plus `cargo test` in the core crate.

Pumpkin (GPL-3.0) is a design inspiration only; ValiMC's Rust is clean-room from
pinned vanilla behavior. See [research](research.md).

## Durability and failure

Region state lives in per-region checkpoint files and the world's write-ahead log
of checksummed frames, not Anvil: vanilla worlds are imported into checkpoints
and exported from them offline
(`mix valimc.import`, `mix valimc.export`, VMC-021; 26.2 chunks upgraded as vanilla's
data fixers upgrade them, VMC-028d), and what ValiMC does not model
yet is preserved for export in a side file. Player snapshots are files whose
bytes are logged on the player stripes before the file is written. The log holds
no file descriptor between operations, so descriptors are bounded by its
stripes; an append that cannot open its segment wrote nothing and is retried
for 30 seconds. Worlds stored before the shared log are refused with a clear
error, never migrated (D4). A crash loses at most the last frames (about 50 ms
of changes); item motion reaches a frame at most once a second, and tick
counters (item age and delays, furnace burn and progress) are saved by
checkpoints, at the latest five minutes after they move, as vanilla's autosave.
Transfer proofs are always durable before they are sent. Item transfers
journal a reduced source inventory plus one outbox before delivery; the region
commits records and retry receipts before publication. Source clearing requires
destination receipt proof. UUID writer leases, owner incarnations and revisions
fence stale operations. Never fabricate recovery evidence or roll back one side of
a committed transfer; receipt/counter limits are explicit admission failures.
Contracts and tests: [VMC-019b1](tickets/VMC-019b1.md), [019b2](tickets/VMC-019b2.md),
[019b3a](tickets/VMC-019b3a.md) and [disconnect cleanup](tickets/VMC-005b2d2b.md).

Online login runs verified HTTPS in bounded workers before admission; each
connection owns its cipher. See the [authentication tickets](tickets/VMC-007c3.md).
