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

- A region whose owner dies while loading is refused for a doubling backoff
  (50 ms first); after five failures in a row it is poisoned with one error log
  line and probed every five minutes. Admission errors are values; no caller
  matches `{:ok, pid} =`.

Checks: `mix test test/region_loading_test.exs test/region_directory_test.exs
test/directory_recovery_test.exs test/item_store_test.exs test/world_test.exs`
(18 passed).
