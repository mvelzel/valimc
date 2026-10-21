# VMC-077e — Chunk tickets, region unload and World.View

Status: In progress
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
fact table (VMC-077d), supervision and commands (VMC-077a).

Acceptance:

- Tickets (`Valimc.World.Tickets`, vanilla 26.3's `TicketType`): player
  loading (view), player simulation, forced, portal (300 ticks), post-teleport
  (5), player spawn (20), spawn search (1) and unknown (1, a fresh owner's own
  admission). Untimed tickets end with their holder process. Loading tickets
  drive generation nearest first (they replace VMC-075's wants); scheduled and
  random block ticks and item motion run only in chunks a simulation ticket
  covers, cooking and orb ageing while any chunk of the region does; due ticks
  elsewhere wait. A view's simulation ticket covers its chunks within
  `min(simulation_distance, view distance)` (Chebyshev) of the player.
- A region without tickets and work in flight for `region_unload_delay_ms`
  (10 s) retires its route, saves its volatile state and stops; worlds without a
  path and `/save-off` keep their regions. A walk across twelve regions with the
  cap at three more than the owners already running never fails admission, and
  the regions left behind are gone with their tables and stores; an edit made
  before the unload is there after reloading (`region_lifecycle_test.exs`).
- On a dimension change or a restart, an owner told before that is no longer
  the one of its key is told to withdraw (by pid, not by region key).
- Portal and spawn readers await generation through the region's defer
  mechanism instead of polling for absent chunks.
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
presentation, decorated-world and pickup socket files (23 passed).
