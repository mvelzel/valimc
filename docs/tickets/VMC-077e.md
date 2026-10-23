# VMC-077e — Chunk tickets, region unload and World.View

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan), [VMC-070](VMC-070.md)
(view distance and chunk batches), [VMC-075](VMC-075.md) (per-chunk generation).

Before: region owners never unloaded, so memory and tick CPU grew with explored
area until `max_regions` refused admission for everyone; every loaded chunk
ticked; a region whose load always failed was started again on every access;
the connection waited up to 15 s for chunk frames; and physics read blocks five
ways, fenced on the region-wide revision, so any block change in a region (or a
rain check during a save) corrected a moving player.

Scope: tickets drive load, simulation and unload as in vanilla; the Directory
backs off and poisons failing keys; chunk frames are published and requested
asynchronously; one lazy read view over published snapshots serves every
physics, rain, portal and spawn reader. Not here: light (VMC-077c), the block
fact table (VMC-077d), supervision and commands (VMC-077a), synchronous
movement validation (physics kernel, VMC-077l).

Limits: ticket types carry flags (loads, simulates) rather than vanilla's
numeric levels, so the ring of loaded but non-ticking border chunks is not
modelled: a chunk ticks exactly when a simulation ticket names it. Item motion
is gated per chunk; item ageing, cooking and orb ageing per region (any chunk
simulated) until the entity store (VMC-077h). Nothing places `post_teleport`
or `player_spawn` tickets yet: a teleport sends the player's view and
simulation tickets in the same step.

Acceptance:

- Tickets (`Valimc.World.Tickets`, vanilla 26.3's `TicketType`): player
  loading (view), player simulation, forced, portal (300 ticks), post-teleport
  (5), player spawn (20), spawn search (1) and unknown (1, a fresh owner's own
  admission). Untimed tickets end with their holder process. Loading tickets
  drive generation nearest first (they replace VMC-075's wants); scheduled and
  random block ticks and item motion run only in chunks a simulation ticket
  covers, cooking and orb ageing while any chunk of the region does; due ticks
  elsewhere wait. A player's simulation ticket covers the chunks within the
  simulation distance (Chebyshev, at most the server's view distance) of
  the player whatever its client renders, and its loading ticket covers
  them as well as the view ([VMC-077e1](VMC-077e1.md)).
- A region without tickets and work in flight for `region_unload_delay_ms`
  (10 s) retires its route, saves its volatile state and stops; worlds without a
  path and `/save-off` keep their regions. A walk across twelve regions with the
  cap at three more than the owners already running never fails admission, and
  the regions left behind are gone with their tables and stores; an edit made
  before the unload is there after reloading (`region_lifecycle_test.exs`).
- On a dimension change or a restart, an owner told before that is no longer
  the one of its key is told to withdraw (by pid, not by region key).
- Chunk batches stay vanilla's (VMC-070: 9 per tick until the first ack, then the
  client's rate, at most 10 batches in flight). The connection never waits for a
  chunk: an owner publishes a chunk's packet next to its snapshot once encoded
  from durable blocks and withdraws it in the step that adopts a change of that
  chunk (blocks, light, biomes); `World.sendable/2` returns published packets or
  the owner to ask, requests go out with `send_request` (at most 64 in flight)
  and replies arrive as messages. A reply kept for a later batch is dropped when
  a change of its chunk arrives, or on a dimension change.
- Portal and spawn readers await generation through the region's defer
  mechanism instead of polling for absent chunks.
- `World.View` is the one block read path for collision, pose, fluid,
  climbing, landing, rain, portal and spawn code: rows of published snapshots,
  loaded per chunk (a box's chunks up front, any other chunk on first read),
  with no fence and no owner call; an unreadable chunk fails closed. `await/4`
  holds a timed ticket and awaits generation through the owner's defer queue.
  Deleted: the observation frames (`BlockCollisions.Frame`, `prepare`, the
  128-block observation split and per-cell re-validation, fence verification
  after the computation), `BlockSnapshot.read/chunk/current?` and the
  region-wide `:block_fence` row, `World.item_frame_current?`, the
  `Portal.Access` and `PlayerSpawn` polling loops, `Region.observe_columns`
  and `ColumnIndex`/`ColumnHeight`. Movement and pose results carry the owners
  they read (to recheck a pose when one dies), not revisions; item simulation
  commits without a region fence, and a resting item is simulated again when a
  section around it changes.
- Rain reads the column's MOTION_BLOCKING height and lowest sky source and the
  biome at each point from the snapshot row: the owner publishes Rust's
  `column_facts` (heights interleaved per column, stored biomes) beside the
  sections; `World.Climate` takes the biome's base temperature and `frozen`
  modifier from `priv/worldgen/biomes.json` and the native
  `Biome.getTemperature`; the biome at a block uses the native fuzzed zoom.
  `FlatClimate` and its facts file are deleted; generated worlds rain by biome
  (no rain in deserts, snow in cold biomes). Parity: the `sky_column`,
  `flat_climate` (now the native temperature) and `heightmap` stages, and a
  test that published heights and biomes equal the owner's blocks and
  `region_biome`.
- Movement, pose, item motion and rain stop correcting on unrelated block
  changes: a collision job whose region changes elsewhere while it computes
  still answers (`collision_query_test.exs`), and a rain answer is neither
  staled by an unrelated change nor delayed by a busy owner
  (`player_rain_query_test.exs`).
- A region whose owner dies while loading is refused for a doubling backoff
  (50 ms first); after five failures in a row it is poisoned with one error log
  line and probed every five minutes. Admission errors are values; no caller
  matches `{:ok, pid} =`.

Checks: Directory slice: `mix test test/region_loading_test.exs
test/region_directory_test.exs test/directory_recovery_test.exs
test/item_store_test.exs test/world_test.exs` (18 passed). Ticket slice: the
generation, tick, block-tick, support, item, cooking, spawn, view-distance,
console, weather, portal, lifecycle, loading and directory files (43 passed),
then the dimension-travel, portal, connection, lid, entity-replication, command
presentation, decorated-world and pickup socket files (23 passed). Chunk slice:
world, view-distance, light, block-batch, group-commit and imported block
entity files (21 passed), then the socket files above. View slice:
`check_vanilla.py --changed` (49 stages: collision, motion, fluid, climb, stuck,
pose, kinetics, item travel, sky column, heightmap, chunk sections, live
generation and the TCP sessions) all pass; `mix test.fast` and the player,
portal, dimension-travel and flight socket files.
`portal_connection_test.exs` sometimes fails its cleanup (`File.rm_rf!` while
a late write lands); it does the same on the commit before this slice (2 of 5
runs), so it is not caused here. The late writers were the stores of the world
spawn's regions, which the credits' respawn loads and the teardown left running;
it now stops them (`TestScope.stop_neighbourhood(key, spawn: true)`), and ten
runs in a row pass. Rain slice: `cargo test -p valimc_core column`,
`cargo clippy --all-targets`, `mix test.fast` (490 passed) and
`check_vanilla.py --changed` (63 stages, including sky column, flat climate,
heightmap, rain contact, light and TCP) pass.

Size over the five commits (b06e324, 032e275, 2bb6221, d8d4a36, c1594f0):
lib and native +1,680 / −1,390 lines (the read-path commit alone +585 /
−965), tests +380 / −550, scripts +100 / −140; deleted `ColumnIndex`,
`ColumnHeight`, `FlatClimate` and its facts file, `BlockCollisions.Frame` and
the observation pipeline. The lifecycle (tickets, unload, backoff, published
packets) is new code.

Client: the milestone handoff covers a long walk and flight (no missing chunks,
regions unload behind), rain by biome (none in deserts, snow in cold biomes)
and movement beside lit furnaces and other block changes without corrections.
Next: the client run; vanilla's level rings and per-chunk entity ticking with
the entity store; the remaining owner calls (`Portal.Access` commit retries,
`World.chunk/1` for tests) with VMC-077g's error taxonomy.

Client: interim VMC-077 run on the frozen release of b8646a33 (October 22, 2026; evidence in ignored `.local/client-tests/VMC-077-interim/`): chunk streaming at view distance 12, a 3,000-block teleport (whole view in about 8–12 s), and unload and return after a 20,000-block hop. PASS.
