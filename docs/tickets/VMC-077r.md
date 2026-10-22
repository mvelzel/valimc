# VMC-077r — Domain layout, the layering check and docs of the new model

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) phases 0–5 (on main at 38f8a86a).

Before: `lib/valimc` held 70 flat modules (about 25 of them `player_*`) beside
19 directories whose names followed history rather than ownership
(`registry`, `command` and `commands`, `block`, `portal`, `anvil`, `auth`).
Nothing kept a layer from depending on the ones above it: the protocol module
built packets from player, living, menu and world state, the world and the
command builtins called the connection process, player code wrote to sockets
through `Net.Codec`, and the text codec called the command parser. Most of
the code was one dependency cycle.

Scope: phase 6 of VMC-077. Moves and function moves only: no gameplay or
protocol behaviour changes. Not here: splitting the hosted session's router
(below).

## What changed

- **Contexts.** Every module is in one of 17 contexts: Data, Protocol, Text,
  Physics, Living, Blocks, Menus, Txn, Entity, World, Player, Admin, Storage,
  Worldgen, Session, Commands and Net. The top of `lib/valimc` keeps the
  application, the root module, the NIF module (its name is fixed in Rust)
  and six context facades (`Valimc.World`, `Valimc.Commands`, `Valimc.Blocks`,
  `Valimc.Living`, `Valimc.Text`, `Valimc.Worldgen`). The `player_*` modules
  are `Player.*` or `Living.*`; `Registry.*` and the type tables are `Data.*`;
  the command engine is `Commands.*` with its parser in `Commands.Parser.*`;
  portals are `World.Portal.*`; Anvil is `Storage.Anvil.*`; authentication is
  `Net.Auth.*`; the entity store, views, publication, trackers, handoffs and
  item physics are `Entity.*`.
- **Layering check.** `scripts/check_layers.py` ranks the contexts (Data <
  Protocol, Text < Physics, Living, Blocks, Menus, Txn < Entity < World,
  Player, Admin, Storage, Worldgen < Session, Commands < Net) and fails on any
  `mix xref` edge to a higher rank, and on a known exception that no longer
  occurs; the publication audit runs it. `--report` prints the edges between
  contexts and the largest cycle.
- **Upward edges removed** (function moves, behaviour unchanged):
  - Packets that need player, living, menu, world or command state moved out
    of `Protocol.Packets` into `Player.Packets`, `Living.Packets`,
    `Menus.Packets`, `Commands.packet/1`, the clock and the light halo.
  - The codec is `Protocol.Codec` and owns the hosted session's outbox and
    disconnect reason, which `Player.Host` and `Player.Presence` held.
  - `Connection.deliver/2` is `Player.PlayerList.deliver/2`,
    `offline_uuid/1` is `Data.UUID.offline/1`, `guard_connection/2` is
    `Session.Messages.guard/2`; `Player.Level` queues its view reset itself.
  - `Data.Grid` holds the grid arithmetic (`chunk_key`, `region_key`,
    `section`, the levels, the build height); `region_size` is a constant,
    not configuration.
  - The physics kernel reads the world through the `Physics.Cells` protocol,
    which `World.View` implements; its player adapter is `Player.Kinetics`'.
  - Selector syntax, `Range` and `Identifier`, with SNBT, the string reader
    and the command error, are `Text.*`; selector matching moved to
    `Commands.Targets`, and `Registries` to Protocol.
  - `ChunkView` (and the regions a view covers) is Player's,
    `ChestBlockEntity` Blocks', the sprint report a private part of
    `World.TickRate`; `/clear` sends its item matcher to the player.
- **Mechanical leftovers.**
  - One `Data.Float32` (`round/1`, `round_or_infinity/1`) replaces 22
    private f32 helpers, three public copies and `Reader.to_float32`; mining
    keeps its own cast, which carries its infinity arithmetic.
  - One login job pool, `Net.LoginJobs`, with a `:key` and a `:session`
    instance, replaces `KeyExchange` and `Auth.SessionJobs` (two copies).
    It stays a pool process rather than a `Task.Supervisor`: its owner
    monitor kills a job mid-work when the socket goes, and its admission is
    a call bounded by `:admission_call_ms`.
  - Test-only code left production: `Connection.teleport`, `set_velocity`,
    `fall_damage` and `add_effect` with their `Player.Calls` clauses (tests
    run them through one `{:debug_call, fun}` hook in `Valimc.TestConn`),
    and the predicates `Drops.at_source?`, `MiningAttempt.current?`,
    `ScheduledTicks.scheduled?` and `Food.enough?`. Twenty unused public
    functions were deleted (among them `Kernel.footing`, `any_liquid?`,
    `inside_shape?` and `new_collision?`, `Reader.read_quoted_string`,
    `Receipts.reserve`, `Dimension.address?` and `of_code`), as were the
    unused placement and mining pool and `Workers`.
  - Every `priv` fact file already had one decoding module through
    `Data.Facts`; the remaining JSON readers read world and data-pack
    directories at run time.
- **Docs.** Architecture gains contexts and layering and the new names;
  compatibility, the README and `AGENTS.md` describe real vanilla worlds
  instead of a creative flat-world preview; development describes the check.

## Measurements

| | Before (38f8a86a) | After |
|---|---|---|
| Files under `lib` | 330 | 334 |
| Lines under `lib` | 56,214 | 56,211 |
| Flat modules in `lib/valimc` | 70 | 8 (the application, the NIF module, 6 context facades) |
| Largest dependency cycle (`mix xref graph --format cycles`) | 230 files (41 compile, 51 export edges) | 76 files (1 compile, 6 export) |
| Upward edges under the ranking | 73 | 7, all known exceptions |
| protocol → player, world | 14 | 0 |
| protocol → living, menus, storage, commands, admin | 12 | 0 |
| world → connection | 2 | 0 |
| player → net | 5 | 0 |
| commands → connection | 7 | 0 |

The "before" edges are the graph at 38f8a86a with every file where it is
now; the moves alone would have left those 73, the function moves removed 66.
Without the seven exceptions the largest cycle would be 41 files.

## Known exceptions

- The hosted session's router (`Session.Messages`, run by `Player.Host` in a
  group) still carries the connection's login, authentication and socket
  clauses: `Player.Host` → `Session.Messages` → five `Net` modules. Splitting
  it into the connection's half and the hosted session's half removes six
  edges and most of the remaining cycle.
- `Blocks.NetherPortal` reads its level's build height from the owner's
  dimension context (`World.Dimension.bounds/0`); passing the level to block
  callbacks removes it.

Acceptance:

- No module stays at the top of `lib/valimc` but the entry points and context
  facades; `scripts/check_layers.py` passes in the audit.
- Commands packet, chunk, entity and login bytes unchanged: the vanilla
  stages compare them (results below).

Checks (October 22, 2026): `mix test.fast` after each step (399 of 399);
the full `mix test` through `scripts/heavy.py` on the layering commit (574 of
574) and on the leftovers commit (572 of 574: the portal test still sent the
removed teleport call; it uses `TestConn.teleport/2` now and passes);
`check_vanilla.py --changed 38f8a86a` once at the end: 209 of 209 stages
(every stage; the moves reach them all).

Storage: worlds and player files written before this change hold the old
struct names (an item's motion, a player's motion, food, experience,
abilities and game mode); their checkpoints read as invalid and their log
frames do not decode, so test worlds are made anew (D4, no migration). The
final client run's world belongs to its frozen release.

Next / deferred:

- Split `Session.Messages` (the first known exception).
- Pass the level to block behaviour callbacks (the second).
- The parity NIFs behind the deleted kernel wrappers
  (`physics_any_liquid`, `physics_footing`, `physics_inside_shape`,
  `physics_new_collision`) have no caller; remove them from
  `physics_checks.rs` with the kernel's next change.
- `region_size` and the build height are constants in `Data.Grid`; the Rust
  side keeps its own.
- Registered process names (`Valimc.Auth.DiscoveryWaiters`, ...) keep their
  old atoms; they name processes, not modules.
