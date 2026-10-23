# Ownership and architecture

Processes define state ownership and failure boundaries. Parallel schedulers do
not make coupled gameplay independent; published observations never grant
authority. The foundations below are in place; later milestones on the
[roadmap](roadmap.md) build gameplay on them.

## Contexts and layering

Every module belongs to one domain context, a directory under `lib/valimc`
(with a facade module of the same name where the context has one, such as
`Valimc.World` or `Valimc.Commands`); only the application, the root module
and the NIF module sit at the top. The contexts are ranked, and a module
depends only on its own rank and the ranks below it:

| Rank | Contexts | Holds |
|---|---|---|
| 1 | Data | Generated facts and their loader (`Data.Facts`, `Data.Version`), the block registry and fact table, entity, effect and potion types, NBT, UUIDs, Java floats, the world grid (`Data.Grid`), metrics |
| 2 | Protocol, Text | Wire formats, packets, item stacks and their data components, the codec and the hosted session's outbox; text components, SNBT, the string reader and selector syntax |
| 3 | Physics, Living, Blocks, Menus, Txn | The physics kernel (it reads the world through `Physics.Cells`), living entities' rules, block behaviours, cooking and mining, menus and inventories, transfer permits and receipts |
| 4 | Entity, AI | The entity store, views, publication, trackers, handoffs and item physics; mob AI (goal selectors, brains, sensing, navigation, the goal library) |
| 5 | World, Player, Admin, Storage, Worldgen | Groups and sections, chunk lifecycle, portals and the environment; players and their hosted sessions; admin lists and permissions; the log, checkpoints and Anvil; generation |
| 6 | Session, Commands | The connection's view, streaming and replication; the command catalog, parser and builtins |
| 7 | Net | The connection shell, login, authentication, the listener, the console and RCON |

`scripts/check_layers.py`, run by the publication audit, fails on any `mix
xref` edge to a higher rank. Its one known exception names the change that
removes it: a block behaviour reads its level's height from its owner's
dimension context. A lower layer that must run code of a higher one takes it
as a value: a hosted session carries its router module, whose callbacks
`Player.Host` defines (`Session.Messages` implements them), and the physics
kernel reads the world through `Physics.Cells`, which `World.View`
implements.

## Owners

| State/work | Owner and access |
|---|---|
| Socket, framing, AES stream, compression, login and configuration, keepalive, chunk view and streaming, replication of what owners publish | One connection process per player, the player's stable address (`Net.Link`) |
| A playing player's body, inventory, living state, open menus, movement checks, mining and item use | The group process that owns the section the player stands in (`Player.Host`); each move packet is validated there by the physics kernel |
| Admission, names, lifecycle | `Player.PlayerList`; never on movement or chat hot paths |
| Nearby-player observations | Spatial index for routing events; players replicate through their group's trackers like entities |
| Blocks (Rust paletted sections), block entities, entities (items, XP orbs) | The group process (`World.Region`) of their 8×8-chunk section while chunk tickets hold it; immutable chunk snapshots and chunk packets in the section's ETS table for readers |
| Which sections share a group | Regionizer per dimension (`World.Regionizer`); routes in the Directory's ETS table |
| Generated chunks before they are full | Generation scheduler per dimension (`Worldgen.Scheduler`): statuses, proto chunks as native cells, structure starts; terrain, decoration and full chunks as jobs on the generation pool |
| Entity observations | Region-owned protected ETS: per-chunk views and per-tick frames encoded once by the owner's trackers |
| World clock, weather, difficulty, who sleeps | Environment owner; immutable publications; sessions report only sleep changes |
| What the world generates per dimension | `World.Spec`, read once from `world.json` at start; a read failure stops the start |
| World spawn (with dimension and pitch), default game mode, admin switches | Settings owner; writes `settings.json` crash-safely, then publishes |
| Commands and suggestions | A job per command (`Session.Commands`), or the console's or RCON client's process, over a `Commands.Source` value; blocks change through region owners, players through the groups hosting them |
| Encoding, transfers, command jobs, key exchange and session verification | Bounded worker pools; the login jobs in `Net.LoginJobs` |
| Region and player checkpoints, the write-ahead log | Log stripes (`Storage.Log`) and checkpoint tasks; disk outside sensitive owners |

Ingress is bounded by `active: :once`, packet/byte rate windows, per-phase
frame and receive-buffer caps (small before configuration), a connection heap
limit and mailbox checks. Overloaded connections are shut down with
`{:shutdown, :overloaded}`, so their sessions still end and save. Chat follows
the vanilla spam throttle. Runtime caps live in `config/config.exs`. A
connection calls another owner only to hand its session to a group and to end
it; commands and suggestions run as jobs (`Player.Jobs`) and their results
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
Owner processes are found or started through one helper (`World.Owners.ensure/4`).
Errors are `{:error, {:retry | :reject | :conflict | :invalid, detail}}`,
classified where they are made (`Valimc.Data.Error`): a caller retries
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
change that spans sections is durable whole or not at all; it cuts only the
sections changed since its last cut, so a group's cost follows what changes
in it, not how many sections it holds. Inside a group the block rules read
and write across section borders and stop only at its edge, light crosses by
the group's own mailbox (generated columns as sibling effects before the next
cut), and an entity crossing a section
line is withdrawn and adopted in the same group commit; between groups it
goes by the durable entity handoff, whose ends and receipts are section keys.
A group that crashes takes its sections down; each is admitted again from its
log, in a group of its own.

A group also hosts the session of each player standing in one of its sections
(`Player.Host`, VMC-077i3). The player's connection stays its address: it
forwards play input and what else is meant for the session as `{:player,
uuid, message}` and writes the packets the session sends back after each
callback. A pickup, a drop, a placement, a container or table click, an XP
pickup and a death's drops are plain calls inside the group, so the inventory
and the world change in one callback and are durable in one record. A player
is registered under its uuid exactly while a group hosts it or saves its last
frame; a login waits until no group does. A group that crashes disconnects its
players, whose clients hold state newer than what is durable; their next login
loads every durable frame.

One regionizer per dimension applies Folia's rule at section size (grid
exponent 3, create and merge radius 1): a loaded section joins every group with
a loaded section within three sections of it, so separate groups keep their
loaded chunks at least 25 chunks apart. A group whose sections fall into
pieces splits once a sixth of the sections it had at its last recalculation
have unloaded. The regionizer only decides; groups move sections at their
tick boundaries, one change at a time. The regionizer also alone retires
groups: a group left with nothing (no sections, players, saves of leaving
players or transfers) asks, and is told to stop only when the regionizer's own
record of it holds no section, so a group about to adopt is never stopped and
a retiring one is never chosen as a target. A group ticks while it has
sections or players.

One transfer moves sections and players between groups (VMC-077y), the way
Folia moves a region's state: adopt, held, release. The giving group waits
until every frame it sent is durable, sending nothing more meanwhile (frames
cut meanwhile go along), so no log acknowledgement ever follows a section or
player elsewhere. It then sends the sections and the players standing in them
in one message: each section's Rust store changes owner (`region_give`: the
NIF's owner check follows it), its table moves with `:ets.give_away/3`, its
route moves to the target and it keeps its epoch; the target watches its
ticket holders, viewers and workers again and hosts the players, telling their
connections. The giving group keeps the players until the target says held:
what arrives for them meanwhile goes on and is copied, and if the target stops
first (taking the sections' routes; their log holds every frame) the players
resume where they were and run the copies in order. A player crossing into
another group's section, teleported or carried by a portal moves alone through
the same transfer, once no session job runs; a target that does not hold the
player's section refuses it, and it stays.

Nothing is forwarded by table. A message for a section a group does not hold
goes on by the Directory's current route (by key, chunk or epoch); a worker
reports to its section's current group, and its monitor's message carries
the section's epoch. One for a player goes to the group that hosts it. A call
is relayed: the group that received it, which its caller watches, stays until
the answer passed through. A call that reaches a group after it stopped never
ran: one that names an epoch goes to that section's current route
(`Region.call/3`); other callers get the usual retry. The adopting group arms a section's timers again, since the group it
left may stop before they fire there. A connection watches the
groups it told its view's tickets to and tells the view again when one
stops. A delivery of generated chunks for a section that moved goes on with
its credit, and the group that installs it acknowledges it for the group it
was sent to.

## Foundations

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
  entries by position, scheduled ticks by chunk, block entities), a group all its
  sections' and hosted players' frames as one record on its own stripe; only
  an entity handoff's reply between groups (its receipt, the proof the other
  owner acts on) waits for its frame. A crash loses at most a suffix of an
  owner's frames, never one half of a handoff or of a player's interaction
  with the world. A region's checkpoint file folds its cells into column images
  relit alone, so a load replays nothing older; the log then drops the frames
  it holds. The log is a section's only frame source: a stripe indexes where
  each owner's uncovered frames are, and a load or checkpoint reads exactly
  those bytes itself (one with none reads nothing), so a stripe never reads
  for anyone. Every checkpoint is written by a task holding the file's lock:
  it waits until the log holds the section's frames, folds the last
  checkpoint with them, writes the file and tells the log what it covers.
  The commit tick's task reports back; a flush or shutdown waits for it; an
  unloading section waits only until the task holds the lock, and a section
  loading again waits for that task to end. A frame holds the records a
  part's keyed entries changed into, found by identity (a chunk's scheduled
  ticks, an entity, a container), so it costs what changed. Simulation never
  waits for the disk.
- **Cross-owner effects.** Entity handoffs between groups and box edits use
  shared primitives: `Txn.Permits` (one owner permit table) and `Txn.Receipts`
  (one idempotency classifier over the receipt tables) (VMC-064). A player's
  interactions need neither: they are calls inside the group hosting the
  player (VMC-077i3).
- **Tick pipeline.** Each group tick runs `TickPipeline` phases on each of its
  sections at the group's game tick: scheduled block ticks, random ticks (a
  native per-section sampler), entities, cooking. Block ticks and item motion
  run only in chunks a simulation ticket covers; cooking while any chunk of
  the section does (VMC-077e). Scheduled ticks sit in per-chunk containers, as
  vanilla's `LevelTicks`: a tick visits only the containers of simulated
  chunks, so those of the rest wait untouched, with no cap on how many a
  section holds (VMC-077s), ordered by trigger tick, priority (a diode's,
  VMC-048a) and scheduling order; a block tick runs while its cell holds the
  block it was scheduled for, with the cell's state then. What a commit starts
  (neighbour and shape updates, survival, redstone power and its components'
  reactions, VMC-047a), the rules' due block ticks and due fluid ticks (water
  and lava, VMC-031a; keyed `{:fluid, id}`, run after the block ticks) run in
  the Rust block-update engine in one call per commit, over the group's
  section stores (VMC-077m, VMC-077j); so do a player's buckets and uses of
  redstone components, the entities' contacts with plates, buttons and
  tripwire once a tick, daylight detectors every twentieth tick, a
  container's changed signal for the comparators reading it, and a
  generated chunk's post-processing marks, settled when it first ticks with
  its neighbours present. A fluid tick that would read past its group waits
  its delay and runs again. Blocks with effects of
  their own (portals, containers, cooking) keep `Valimc.Blocks.Behaviour`
  callbacks. `Region.step/2` drives ticks deterministically in tests (VMC-066).
- **Entities.** Each region owner holds one entity store (`Entity.Store`,
  VMC-077h): every entity it owns, by network id with a uuid index, persisted
  one record per entity with no count or size cap. Items and XP orbs have
  their own records; every other type is a body (`Entity.Body`, VMC-043a), one
  schema for living types (`:mob`, whose `Entity.Mob` holds its
  `Valimc.Living` state, equipment, attribute overrides, AI slot and travel
  state) and the rest (`:object`). Mobs travel in the entity phase, all of a
  section's in one kernel call, and their living rules (`Entity.MobVitals`)
  follow the player's. Before that call the AI context (`Valimc.AI`,
  VMC-041a) runs each living mob's part of vanilla's tick in id order: its
  goal and target selectors, navigation, a brain mob's brain (memories,
  sensors, activities, behaviours) and look control, over what the owner
  hands it (the group's players, the section's mobs and items, published
  blocks, the section's level random); the kernel runs the move and jump
  controls it set, and a looting mob picks items up after the move. Paths
  come from vanilla's search (VMC-041b) in Rust, never in the owner: a
  mob's request leaves its tick as an effect, the section runs its
  requests as one job (`World.MobPaths`, at most one batch at a time)
  over the published snapshots of the chunks the searches' regions cover,
  whichever section or group owns them, and the next tick installs each
  result unless a chunk it read was published again since (stale: the mob
  recomputes). Until then the mob's path is pending and it holds still.
  Each mob draws
  from its own saved random, so it draws what vanilla's would; what it
  decides beyond itself (a melee hit, an alert) comes back as effects. Every hurt of a mob (melee, explosions, falling
  blocks, its own falls, fire and drowning, `/kill`) goes through one path,
  `Entity.Combat` (VMC-037n); a death leaves its loot and experience on the
  mob, and the owner drops them when it stores its entities. A player's
  attack runs in the group hosting the player; a mob's hit on a player goes
  to the player's session (`Player.Hurt`). Projectiles (VMC-037o) are bodies
  too: one kernel call per section moves them and finds their hits
  (`World.Projectiles` plans what each hit does), they hurt through the same
  path and travel between owners as mobs do; what reaches a player (a hit,
  an ender pearl's landing, a splash) goes to its session. Only modelled types are made: their entity data is known
  field by field (every living type of a spawning category is a plain mob,
  its own data at vanilla's defaults, until its family models it), and each
  type's facts (size, attributes, loot, spawning, tracking) come from
  `Data.EntityTypes`. Network ids come from one `:atomics`
  counter (`Entity.Ids`) for players and every kind, and an entity keeps its id
  across handoffs within a VM. Entities move between owners through one
  handoff (`Entity.Handoffs`): the source withdraws a cohort into one durable
  outgoing intent, the destination adopts it and records its receipt in the
  same frame, and the source clears the intent once that receipt is durable. A
  cross-region item merge is the donor handed over with its target, merged on
  arrival or returned. A furnace withdrawal spawns its XP orbs in the same
  commit, or hands them to the owner of their position.
- **Natural spawning.** Each group runs vanilla's `NaturalSpawner` and
  `Mob.checkDespawn` once a tick, before its sections' entities tick
  (`World.Spawning`, VMC-042a): one call of the spawn kernel
  (`valimc_core::spawning`, a normal NIF or its dirty twin by the chunks it
  covers) reads the group's stores (blocks, light, heightmaps, biomes) and
  returns the mobs that spawn in its simulated chunks, those that despawn and
  those whose idle time restarts; the sections adopt and drop them in the
  group's next commit. The caps count what the group holds: every mob that
  is not persistent toward its category, a mob near a player toward that
  player's local cap, and the global cap scales with the chunks near the
  group's players. Groups keep their loaded chunks 24 chunks apart, so a
  player's spawning chunks and nearby mobs are its own group's and no process
  counts across groups. The group's level random and its mobs' random are its
  own; a generated chunk's creatures come with its install, from the chunk's
  decoration seed. The spawn facts (biome spawn lists and costs, the
  dimensions' light rules and timelines, per-state block tests) are one
  generated table (`Data.SpawnFacts`).
- **Replication.** The owner keeps one tracker per entity (`Entity.Tracker`,
  vanilla's `ServerEntity`): each tick it encodes, once for every observer,
  the packets of what changed (relative moves, motion, metadata, absolute
  syncs; for a body also its rotation, head yaw, attributes, equipment and
  entity events) at the type's update interval into a frame, and rewrites only the
  chunk rows whose views changed (`Entity.Publication`). A connection's tracker
  (`Entity.Observer`) spawns entities from their rows, at the position the
  owner's tracker last sent, forwards the frames for the ids it tracks, and
  resyncs one seen under another owner or behind the frame ring, never
  respawning it. A departing entity stays published until its handoff clears.
  A hosted player has a tracker in its group (`PlayerTracker`, VMC-077i4):
  relative moves with its rotation and ground flag, head rotation, entity
  data and equipment, published in the row and frame of the section it
  stands in. The tab list holds every online player, near or far.
- **Data.** One generated fact source per concept and a single version module
  (`Valimc.Data.Version`). Each `priv` file has one decoding module: it reads the
  file with `use Valimc.Data.Facts`, which loads it once at compile time and checks
  every release stamp it carries, and every other reader asks that module.
  Files too large to keep as terms (loot tables, translations, the command
  tree) and the files Rust parses itself (worldgen, survival, shapes) are read
  at run time by their owner through `Valimc.Data.Facts.read!/1`;
  `Valimc.Worldgen.Facts` keeps the few worldgen terms Elixir needs (biome
  names and climates, the ids commands name). `Valimc.Data.Blocks` owns block identity (state
  runs, defaults, properties, vanilla classes) and `Valimc.Data.BlockFacts`
  every per-state fact, as one columnar table from one oracle (VMC-077d): flags,
  collision shape, motion, fluid, climbing, inside behaviour, hazard, landing,
  mining, replaceability, heightmaps, sky, light and redstone signals. Survival
  keeps two tables, read by one Rust module: decoration checks survival before
  placement under unlit light, live updates after it with their reactions.
  What water and lava read beyond the table (containers' fluids, waterlogging,
  bucket pickups, dimension attributes) is `physics/fluids.json`
  (`Valimc.Blocks.Fluids`, VMC-031a); a bucket's ray reads outline shapes
  (`physics/outlines.json`, `Valimc.Physics.Clip`). Placement is one decision
  diagram over every block item (VMC-029d): the click's inputs and the cells
  around the target decide what `BlockItem.useOn` writes; Elixir picks the
  target and the inputs, the owner's Rust rules read the cells. Every loot
  table (containers, mobs, every block's) runs through one native evaluator
  over the loot facts (`priv/loot`, `Valimc.Blocks.Loot`); a survival break
  is a plan of writes, drops and experience (`Valimc.Blocks.Breaking`,
  VMC-029e) its owner commits in one call. Block
  behaviours are `Valimc.Blocks.Behaviour` callbacks chosen by the generated
  class (VMC-068).
- **Connection.** `Valimc.Net.Connection` is a thin GenServer shell. `Net.*`
  holds the login flow, the pre-play packets and the connection's own
  messages (`Net.Messages`: socket data, login jobs, keepalives, the chunk
  stream); `Protocol.Codec` the framing, cipher and socket writes;
  `Session.*` the session's router (`Session.Messages`), its play packets
  (`Session.Play`), events, replication and chat commands; and `Player.*`
  each gameplay domain. Before play the connection runs both routers on its
  whole state; in play `Net.Link` is the connection's half and `Player.Host`
  runs the session at its group, whose client output queues in the codec's
  outbox. Broadcast packets are framed once and shared as binaries
  (VMC-069).
- **Commands.** `Valimc.Commands.registry/0` maps each top-level command to
  one handler function, which receives the parsed literals; the
  Brigadier tree is built from `tree.json` at start, so the command
  packet needs no compile-time handler table (nodes keep redirects and a
  modifier slot for `execute`). A command runs in layers: parse
  (pure), resolve over published snapshots (`Commands.Targets` selects
  over the player projections and the spatial index), execute through owner
  operations, and feedback through the source's sink (a connection, the
  log or an RCON reply). `Commands.Source` is a plain value: entity,
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
admission. Untimed tickets end with their holder process. A view's tickets
reach each group as one message for all its sections, and a connection
re-sends them to a section's new owner whenever that owner changed. An owner
without
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
no column for are absent (VMC-075). The section tells its dimension's generation
scheduler which absent chunks its loading tickets want, and which of them calls
wait for (urgent), as `{group, key}` whenever that set changes, and never
generates on itself. Demand is membership: tickets carry no center, and a
player's tickets change only where the chunks of a section they cover change,
not with every chunk the player enters (at view distance 32 a view spans about
80 sections). Full chunks come in deliveries with credit: a group has at most
two unacknowledged, and what finishes meanwhile waits in the scheduler for the
next, the players' own and nearest chunks first, so the group's mailbox stays
bounded however fast generation runs. One record per group holds its sections'
epochs, the chunks ready for it (each with the epoch it was made for) and its
unacknowledged deliveries; a chunk on its way to a section at its epoch is not
made again. A group installs a delivery per section in one pass (an unusable
chunk fails alone) and gives its sibling sections their halo images at once;
the column images join the next frame, and the scheduler forgets a chunk only
once that frame is durable. Until then an absent chunk is like a chunk of an
unloaded neighbour group: block reads in the group see nothing there, edits
and observations are refused, published snapshots fail closed and the chunk
stream skips it.

One scheduler per dimension owns every chunk's generation (VMC-077n): its
status (terrain, decorated, final once its 3 × 3 is decorated, handed over
once its section made it durable), its proto chunk as a native cell, and the
dimension's structure starts, which placement changes as vanilla changes its
saved starts. Work runs on `Valimc.Worldgen.Pool` with explicit write areas:
terrain holds its chunk, a decoration its 3 × 3, a full chunk its own cell.
Decorations conflict within two chunks; each gets a number when a request
first needs it (the request's chunks within one, Z outer and X inner), and
conflicting decorations run in number order, so a chunk depends only on the
order of requests.

What is made in which order is one model (VMC-077x1, `Worldgen.Frontier`). The
wanted chunks not sent yet are goals, kept in one ordered set: urgent ones
first, then by their score from the nearest player, else by key. Each
player's connection tells the scheduler which chunk the player entered and
which way they move (`Scheduler.focus/5`), straight, not through the
sections' tickets; the player's own chunk scores first, then the chunks ahead
of them before those beside and behind, and a chunk crossed re-scores the
goals once. Nothing else stores a priority. Each numbered decoration knows
what it still waits for (earlier decorations within two, chunks of its 3 × 3
without terrain) and how many goals reach it; a result updates only what it
touches. Jobs start from the goals in order: final chunks and chunks made
alone, then, walking each goal's dependencies (its decorations, the earlier
ones they wait for, the terrain they lack), the decorations that can start and
the terrain, until the pool's room is filled. Terrain never takes the pool's
last slot. Nothing answers busy or polls: a job's result starts the next job
at once, and while work is left out for want of a slot, the next job to end
anywhere in the pool wakes the scheduler. Terrain-only worlds are final after
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
VMC-077q). Past the cap, the cells no goal or needed decoration is near go,
least recently used first (an index by last use; a pass after a job ends looks
at a bounded number and moves the cells it keeps to the recent end): terrain
no decoration wrote into is
dropped and made again when needed (terrain reads only the starts' beards,
which placement never changes), and every other cell spills to the
dimension's scratch file (`generation.scratch`), never durable state, from
which the job that needs it decodes it. A job of its own encodes and writes
the spills, holding their chunks meanwhile, so the scheduler never waits for
them (VMC-077x). A snapshot's chunks are restored into the scratch file, not
into memory.

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
| Block updates (VMC-077m) | `updateShape`, survival, neighbour updates in vanilla's collecting order and redstone wire power over the owner's store, one call per commit; the same rule modules serve decoration. What a placement writes (VMC-029d), from the placement facts and the cells around it. Redstone's sources and consumers (VMC-047a), repeaters, comparators and observers (VMC-048a): their signals, reactions, prioritised ticks and the uses, entity contacts and detector updates that start them; comparators' outputs and containers' signals come from the owner and their changes go back to it. Effects that leave the owner (drops, events, sounds, primed TNT) return to Elixir |
| Entity physics (VMC-077l, VMC-077l2, VMC-015i) | One kernel (`valimc_core::physics`) for players, items and mobs: block scans over published chunk snapshots, read in place, with per-section special-collider checks, shapes from the installed fact table, `Entity.collide` with step-up, body sweeps, fluids, flow and currents, the supporting block, a whole item or orb tick with its fire, lava and cactus contacts, and the player's travel rules (jumps, air and fluid travel, climbing, swimming, sneaking at edges, slowing blocks, poses, contacts). A move packet or a resting player's tick is one call from the player's session; a region owner's items one call per tick, and its mobs another: `LivingEntity.aiStep` with `MoveControl` and `JumpControl`, `travel` with relative input, the type's size and step height, and pushing among the mobs and by players; its projectiles another (VMC-037o): arrows, thrown items, fireballs and eyes of ender with the collider ray, its border stop and the entity hit tests. Effects on living state (burning, landing damage, air, rain) come back as observations |
| Path search (VMC-041b) | Vanilla's `PathFinder` with the walk, amphibious, swim and fly node evaluators (`valimc_core::path`) over published chunk snapshots read as `PathNavigation`'s region reads a level, with path types from `ai_facts.json` and shapes from the kernel's facts: a section's batch of searches is one call in its path job, each search bounded by the mob's visited-node limit (a zombie's 560 nodes take at most about 0.9 ms) |
| Natural spawning (VMC-042a) | A tick's spawn attempts read blocks, light, heightmaps and biomes at every position of every pack and run each type's rules and a collision test: one call over the group's stores, about 0.3 ms a tick for a player's nine sections; the caps, despawn bookkeeping and the records stay in Elixir |

Kept in Elixir: packet and file compression (`:zlib`), AES-CFB8
(`:crypto`/OpenSSL), network item/text NBT, NBT writing (zlib deflate costs more
per chunk), region file headers and palette-name mapping (VMC-021, about 80 µs
per chunk; not yet compared with Rust). `Valimc.Data.NBT` is the one
NBT codec: network and disk framing, explicit limits, and an Elixir reader that
is the native reader's parity reference.

NIF rules ([VMC-077b](tickets/VMC-077b.md)):

- The shim has one module per domain (`facts`, `region`, `snapshot`, `rules`,
  `light`, `climate`, `codec`, `sys`, `worldgen`, `loot`, `physics`, `player`,
  `path`); oracle
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
