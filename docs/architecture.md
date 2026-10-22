# Ownership and architecture

Processes define state ownership and failure boundaries. Parallel schedulers do
not make coupled gameplay independent; published observations never grant
authority. The M1 foundations below are in place; later milestones on the
[roadmap](roadmap.md) build gameplay on them.

## Owners

| State/work | Owner and access |
|---|---|
| Socket, framing, AES stream, compression, login and configuration, keepalive, chunk view and streaming, replication of what owners publish | One connection process per player, the player's stable address (`Session.Link`) |
| A playing player's body, inventory, living state, open menus, movement checks, mining and item use | The group process that owns the section the player stands in (`Session.Host`); each move packet is validated there by the physics kernel |
| Admission, names, lifecycle | Players service; never on movement or chat hot paths |
| Nearby-player observations | Spatial index for routing events; players replicate through their group's trackers like entities |
| Blocks (Rust paletted sections), block entities, entities (items, XP orbs) | The group process (`World.Region`) of their 8×8-chunk section while chunk tickets hold it; immutable chunk snapshots and chunk packets in the section's ETS table for readers |
| Which sections share a group | Regionizer per dimension (`World.Regionizer`); routes in the Directory's ETS table |
| Generated chunks before they are full | Generation scheduler per dimension (`Worldgen.Scheduler`): statuses, proto chunks as native cells, structure starts; terrain, decoration and full chunks as jobs on the generation pool |
| Entity observations | Region-owned protected ETS: per-chunk views and per-tick frames encoded once by the owner's trackers |
| World clock, weather, difficulty | Environment owner; immutable publications |
| What the world generates per dimension | `World.Spec`, read once from `world.json` at start; a read failure stops the start |
| World spawn (with dimension and pitch), default game mode, admin switches | Settings owner; writes `settings.json` crash-safely, then publishes |
| Commands and suggestions | A job per command (`Session.Commands`), or the console's or RCON client's process, over a `Command.Source` value; blocks change through region owners, players through the groups hosting them |
| Encoding, placement and mining jobs, auth/crypto | Bounded worker pools (the placement and mining pool partitioned per caller) |
| Region and player checkpoints, the write-ahead log | Log stripes (`Storage.Log`) and checkpoint tasks; disk outside sensitive owners |

Ingress is bounded by `active: :once`, packet/byte rate windows, per-phase
frame and receive-buffer caps (small before configuration), a connection heap
limit and mailbox checks. Overloaded connections are shut down with
`{:shutdown, :overloaded}`, so their sessions still end and save. Chat follows
the vanilla spam throttle. Runtime caps live in `config/config.exs`. A
connection calls another owner only to hand its session to a group and to end
it; commands and suggestions run as jobs (`Session.Jobs`) and their results
arrive as messages (VMC-077a).

Supervision is five domain supervisors under a `rest_for_one` root, each with
its own restart intensity: infrastructure (settings, clock, tick rate, admin
lists, worker pools), storage, world, players and network. A crash loop stays
in its domain; only a domain's restart restarts the domains after it. Tables
that hold no owned state belong to the application itself. Acceptors back off
on accept errors (VMC-077a).

A section's state is its key and epoch (its incarnation: handles and
messages of an older one are stale), its publication table, its blocks and
block entities, its entities (`RegionEntities`: the entity store, its
replication trackers and the entity work it schedules), its commit state (`RegionStorage`) and its job table
(`Jobs`), held by its group as a `RegionData`. Every piece of background work
runs on that table: at most one job
per kind under a bounded pool, each with a token, a monitor and a deadline,
reported, overrun and lost through one path; a crashed worker is a failed job.
Owner processes are found or started through one helper (`Owners.ensure/4`).
Errors are `{:error, {:retry | :reject | :conflict | :invalid, detail}}`,
classified where they are made (`Valimc.Error`): a caller retries
`{:retry, _}` without a list of atoms (VMC-077g).

## Groups and the regionizer

Everything that can interact has one owner (VMC-077j). The 8 × 8-chunk section
stays the unit of storage, generation and light; a **group process** owns a
connected set of sections of one dimension and is the unit of ownership, time
and durability. A section's routing key names its dimension, `{dimension, sx,
sz}`, in every dimension: the Directory's route table, the registries, topics
and the spatial index use it, and no route reads a process's dimension
context. Callers hold `{group pid, epoch}` per section from the route table;
the group runs each call on the section it names by epoch, chunk or key. One tick runs all of a
group's sections in key order under one tick number, the world clock's game
time (`World.GameTick`), so groups merge without offsets. The group cuts all
its sections' changes at once into one record of the write-ahead log, so a
change that spans sections is durable whole or not at all. Inside a group the
block rules read and write across section borders and stop only at its edge,
light crosses by the group's own mailbox, and an entity crossing a section
line is withdrawn and adopted in the same group commit; between groups it
goes by the durable entity handoff, whose ends and receipts are section keys.
A group that crashes takes its sections down; each is admitted again from its
log, in a group of its own.

A group also hosts the session of each player standing in one of its sections
(`Session.Host`, VMC-077i3). The player's connection stays its address: it
forwards play input and what else is meant for the session as `{:player,
uuid, message}` and writes the packets the session sends back after each
callback. A pickup, a drop, a placement, a container or table click, an XP
pickup and a death's drops are plain calls inside the group, so the inventory
and the world change in one callback and are durable in one record. A player
crossing into another group's section is handed over, with its storage, once
its frames are sent; one whose section moves goes along. A group that crashes
disconnects its players, whose clients hold state newer than what is durable;
their next login loads every durable frame.

One regionizer per dimension applies Folia's rule at section size (grid
exponent 3, create and merge radius 1): a loaded section joins every group with
a loaded section within three sections of it, so separate groups keep their
loaded chunks at least 25 chunks apart. A group whose sections fall into
pieces splits once a sixth of the sections it had at its last recalculation
have unloaded. The regionizer only decides; groups move sections at their
tick boundaries, one change at a time. A handoff passes the section's Rust
store to the new owner (`region_give`: the NIF's owner check follows it), its
table with `:ets.give_away/3` and its state in one message; the adopting group
takes the route and the section keeps its epoch. The group it left forwards
what still arrives for the section for two minutes; one left without sections
then stops.

## Foundations (M1)

- **Sections, not edit maps.** Each region owns its chunk columns as paletted
  sections in a Rust resource (VMC-062): single-value or packed palette storage
  with block entities and heightmaps beside it. Chunk packets are encoded from the
  sections. The Elixir encoder remains as the parity oracle.
- **Published reads.** After each block change, and before any client hears of
  it, the owner publishes an immutable snapshot of each changed chunk (VMC-065,
  VMC-077p), so a client's next move is checked against what it was shown. A
  snapshot is a Rust handle in the section's table that shares the chunk's
  sections and biomes with the owner's store: the store clones a section only
  when it writes one a snapshot still holds, so republishing a chunk copies 24
  pointers, block memory is held once except for sections written since the
  last publication, and each section carries the revision of the publication
  that last changed it. Handles move with the table when a section changes
  group. Every physics, rain, portal and spawn reader reads them through
  `World.View`, one lazy per-chunk view: no owner call, no copy, no lock, no
  envelope to plan and no fence, since observations are not transactions. The
  kernel and the view's batch calls read the handles in place; heights, sky
  sources and biomes are computed from the snapshot when asked. A chunk not
  loaded or generated fails closed (VMC-077e). Only commits are fenced: block
  observations for placement, mining and commands carry section revisions, so
  they stale only when the sections they read change (VMC-064).
- **Shared write-ahead log (D2).** Every owner commits to one striped log per
  world (`Valimc.Storage.Log`, VMC-077f): eight stripes, each written by one
  process that drains its queue into one append with one `datasync` (plus
  `F_FULLFSYNC` on macOS). An owner
  adopts, publishes and answers every change at once and cuts one frame of
  keyed records every 50 ms (cells, entities by UUID, receipts, container
  entries by position, scheduled ticks, block entities), a group all its
  sections' and hosted players' frames as one record on its own stripe; only
  an entity handoff's reply between groups (its receipt, the proof the other
  owner acts on) waits for its frame. A crash loses at most a suffix of an
  owner's frames, never one half of a handoff or of a player's interaction
  with the world. A region's checkpoint file folds its cells into column images
  relit alone, so a load replays nothing older; the log then drops the frames
  it holds. Simulation never waits for the disk.
- **Cross-owner effects.** Entity handoffs between groups and box edits use
  shared primitives: `Txn.Permits` (one owner permit table) and `Txn.Receipts`
  (one idempotency classifier over the receipt tables) (VMC-064). A player's
  interactions need neither: they are calls inside the group hosting the
  player (VMC-077i3).
- **Tick pipeline.** Each group tick runs `TickPipeline` phases on each of its
  sections at the group's game tick: scheduled block ticks, random ticks (a
  native per-section sampler), entities, cooking. Block ticks and item motion
  run only in chunks a simulation ticket covers; cooking while any chunk of
  the section does (VMC-077e). What a commit starts (neighbour and shape updates,
  survival, redstone wire power) and dependent blocks' due ticks run in the Rust
  block-update engine in one call per commit, over the group's section stores
  (VMC-077m, VMC-077j); blocks with effects of
  their own (portals, containers, cooking) keep `Valimc.Block.Behaviour`
  callbacks. `Region.step/2` drives ticks deterministically in tests (VMC-066).
- **Entities.** Each region owner holds one entity store (`Entities`,
  VMC-077h): every entity it owns, items and XP orbs now, mobs and
  projectiles later, by network id with a uuid index, persisted one record per
  entity with no count or size cap. Network ids come from one `:atomics`
  counter (`EntityIds`) for players and every kind, and an entity keeps its id
  across handoffs within a VM. Entities move between owners through one
  handoff (`EntityHandoffs`): the source withdraws a cohort into one durable
  outgoing intent, the destination adopts it and records its receipt in the
  same frame, and the source clears the intent once that receipt is durable. A
  cross-region item merge is the donor handed over with its target, merged on
  arrival or returned. A furnace withdrawal spawns its XP orbs in the same
  commit, or hands them to the owner of their position.
- **Replication.** The owner keeps one tracker per entity (`EntityTracker`,
  vanilla's `ServerEntity`): each tick it encodes, once for every observer,
  the packets of what changed (relative moves, motion, metadata, absolute
  syncs) at the kind's update interval into a frame, and rewrites only the
  chunk rows whose views changed (`EntityPublication`). A connection's tracker
  (`EntityReplication`) spawns entities from their rows, at the position the
  owner's tracker last sent, forwards the frames for the ids it tracks, and
  resyncs one seen under another owner or behind the frame ring, never
  respawning it. A departing entity stays published until its handoff clears.
  A hosted player has a tracker in its group (`PlayerTracker`, VMC-077i4):
  relative moves with its rotation and ground flag, head rotation, entity
  data and equipment, published in the row and frame of the section it
  stands in. The tab list holds every online player, near or far.
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
  In play `Session.Link` is the connection's half and `Session.Host` runs the
  session at its group. Broadcast packets are framed once and shared as
  binaries (VMC-069).
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
(VMC-077e). A section holds the tickets of its chunks
(`World.Tickets`): a connection's view (`player_loading`) and simulation
(`player_simulation`, the chunks within `min(simulation distance, view
distance)` of the player), `forced` from `/forceload`, timed `portal`,
`post_teleport`, `player_spawn` and `spawn_search` tickets of readers that need
chunks loaded, and a fresh owner's one-tick `unknown` ticket of its own
admission. Untimed tickets end with their holder process. An owner without
tickets and work in flight (writes, jobs, outboxes, deferred calls, open
containers, permits) for `region_unload_delay_ms` retires its route, saves its
volatile state and leaves its group; a world without a path and `/save-off` keep
their sections. The Directory admits sections; one whose group dies while loading backs
off per key and is poisoned, with one error line, after five failures in a row.
Admission errors are values.

Chunks stream as vanilla's acknowledged batches (VMC-070). The connection never
waits for a chunk: an owner publishes each chunk's packet beside its snapshot
once encoded and withdraws it in the step that adopts a
change; the connection reads published packets directly, asks for the others
with `send_request` and sends replies when they arrive. A dimension change
withdraws the old dimension's tickets and abandons pending requests.

## Generation (M2)

A section of a generated world loads without generating: the chunks its log has
no column for are absent (VMC-075). Loading tickets say which of its chunks are
wanted and how far from their center; the section tells its dimension's
generation scheduler which absent chunks it wants (as `{group, key}`, so
sections of one group keep separate wants), each at its distance to the
nearest player that wants it, whenever that changes, and never generates on
itself. It installs each full chunk as it arrives; its column image joins the
next frame, and the scheduler forgets the chunk only once that frame is
durable. Until then an absent chunk is like a chunk of an unloaded neighbour
group: block reads in the group see nothing there, edits and observations are
refused, published snapshots fail closed and the chunk stream skips it.

One scheduler per dimension owns every chunk's generation (VMC-077n): its
status (terrain, decorated, final once its 3 × 3 is decorated, handed over
once its section made it durable), its proto chunk as a native cell, and the
dimension's structure starts, which placement changes as vanilla changes its
saved starts. Work runs on `Valimc.Worldgen.Pool` with explicit write areas:
terrain holds its chunk, a decoration its 3 × 3, a full chunk its own cell.
Decorations conflict within two chunks; each gets a number when a request
first needs it (the request's chunks within one, Z outer and X inner), and
conflicting decorations run in number order, so a chunk depends only on the
order of requests. Work waits in priority queues (wanted final chunks,
decorations that can run, needed terrain) whose priorities the work inherits
from the wanted chunks; a finished job updates them around its chunk, and
they are rebuilt only when wants change. Nothing answers busy or polls; a full
pool wakes the scheduler when a job ends. Terrain-only worlds are final after
terrain; flat-layer worlds are full at once.

Proto chunks and starts are not durable (D3): a graceful stop snapshots them
(`generation.snapshot`), the next start reads and deletes it, and after a
crash chunks that were not yet full generate again. A deterministic generation
error leaves its chunk failed (`worldgen_errors`) and fails the wanted chunks
that need it. A chunk wanted again after it was handed over is made alone over
fresh terrain, as vanilla regenerates a chunk missing from its region file. A
new world's spawn search runs the same scheduler inline and leaves its state
as the snapshot.

Proto chunks in memory are bounded per dimension (`worldgen_proto_cells`,
VMC-077q). Past the cap, the cells no wanted chunk or needed decoration is
near go, least recently used first: terrain no decoration wrote into is
dropped and made again when needed (terrain reads only the starts' beards,
which placement never changes), and every other cell spills to the
dimension's scratch file (`generation.scratch`), never durable state, from
which the job that needs it decodes it. A snapshot's chunks are restored into
the scratch file, not into memory.

## Elixir and Rust

Elixir owns sockets, sessions, ownership, scheduling, transactions, persistence
orchestration and gameplay rules. Rust (via a NIF crate, `native/valimc_nif`,
over a pure `valimc_core` crate) owns dense data and CPU-heavy pure work:

| Rust | Why |
|---|---|
| Section/column storage, published chunk snapshots and chunk packet encoding | Mutable 4096-entry arrays and bit packing; large memory win; snapshots share copy-on-write sections with the store (VMC-077p) |
| World generation (M2) | The most CPU per chunk; pure; runs on dirty CPU schedulers behind a bounded pool |
| Lighting (M2) | Per chunk (VMC-077c): each chunk lit alone where it is generated and stored in its column image; a region adopts that light, propagates only across chunk faces and then updates incrementally within a work budget, over nibble arrays on the section resource |
| Disk NBT reading (VMC-020) | 3.5–4× the Elixir reader on vanilla chunks; values are sub-binaries of the input |
| Anvil import and export (VMC-021) | LZ4 chunk streams; packed palette indices into sections; compact column images for region checkpoints; vanilla palette packing for export (5.7× the Elixir reference) |
| Block updates (VMC-077m) | `updateShape`, survival, neighbour updates in vanilla's collecting order and redstone wire power over the owner's store, one call per commit; the same rule modules serve decoration. Effects that leave the owner (drops, events) return to Elixir |
| Entity physics (VMC-077l, VMC-077l2) | One kernel (`valimc_core::physics`) for players and items: block scans over published chunk snapshots, read in place, with per-section special-collider checks, shapes from the installed fact table, `Entity.collide` with step-up, body sweeps, fluids, flow and currents, the supporting block, a whole item tick, and the player's travel rules (jumps, air and fluid travel, climbing, swimming, sneaking at edges, slowing blocks, poses, contacts). A move packet or a resting player's tick is one call from the player's session; a region owner's items one call per tick. Effects on living state (burning, landing damage, air, rain) come back as observations |

Kept in Elixir: packet and file compression (`:zlib`), AES-CFB8
(`:crypto`/OpenSSL), network item/text NBT, NBT writing (zlib deflate costs more
per chunk), region file headers and palette-name mapping (VMC-021, about 80 µs
per chunk; not yet compared with Rust). `Valimc.NBT` is the one
NBT codec: network and disk framing, explicit limits, and an Elixir reader that
is the native reader's parity reference.

NIF rules ([VMC-077b](tickets/VMC-077b.md)):

- The shim has one module per domain (`facts`, `region`, `snapshot`, `rules`,
  `light`, `climate`, `codec`, `sys`, `worldgen`, `loot`, `physics`, `player`); oracle
  and benchmark NIFs live in `parity` (the physics kernel's pieces in
  `physics_checks` and `player_parity`), built only with the `parity` cargo
  feature (dev, test and bench builds, not releases). One arity per NIF.
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
- Mutable state is a `ResourceArc` owned by one process: the Region resource
  refuses changes from any other (`{:error, :not_owner}`) and changes owner
  only by a handoff its owner makes (`region_give`).
  Shared Rust state is immutable and shared through an `Arc` (a seed's
  generation context, with bounded caches of pure values), or lent to one
  job at a time by its owner (the scheduler's proto cells and start table,
  locked while a call uses them); readers get immutable binaries or
  immutable handles (chunk snapshots), which a NIF borrows from its argument
  for the call.
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
yet is preserved for export in a side file. A player's file is the checkpoint
of its state's keyed records (`Player.State`, one schema and codec); its
changes ride as frames in the record of the group hosting it
(`Player.Storage`), records that move every tick at most once a second and
every other change at once. The file is replaced after 1200 frames, on
`/save-all` and when the player leaves; a login waits until no group holds
the player, then folds the frames into the file. The log holds
no file descriptor between operations, so descriptors are bounded by its
stripes; an append that cannot open its segment wrote nothing and is retried
for 30 seconds. Worlds stored before the shared log are refused with a clear
error, never migrated (D4). A crash loses at most the last frames (about 50 ms
of changes); item motion reaches a frame at most once a second, and tick
counters (entity ages and delays, furnace burn and progress) are saved by
checkpoints, at the latest five minutes after they move, as vanilla's autosave.
An entity record carries its kind, uuid, position and hops, never its
network id; an outgoing handoff intent is stored without network ids, so one
recovered after a restart delivers records that get fresh ones.
Handoff receipts are durable before they are sent, and a source clears its
intent only on the destination's durable receipt. Owner incarnations and
revisions fence stale operations. Never fabricate recovery evidence or roll
back one side of a committed handoff. Receipt tables are keyed records with no
source cap.
Contracts and tests: [VMC-019b1](tickets/VMC-019b1.md), [019b2](tickets/VMC-019b2.md),
[019b3a](tickets/VMC-019b3a.md) and [disconnect cleanup](tickets/VMC-005b2d2b.md).

Online login runs verified HTTPS in bounded workers before admission; each
connection owns its cipher. See the [authentication tickets](tickets/VMC-007c3.md).
