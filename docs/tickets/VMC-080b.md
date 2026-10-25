# VMC-080b — Owner-local entity spatial queries

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).

Maintain chunk membership beside authoritative entity stores, use bounded nearby
queries instead of repeated whole-group flattening, and reuse typed spawning
preparation where safe. Preserve current values after same-tick moves, transfers,
body changes, worker adoption and rollback. No published view authorizes a write.
Keep vanilla spawn caps and mob tick order unchanged. Validate index parity with
the authoritative store and existing entity/spawn/transfer checks.

Implemented authoritative store chunk membership and exact solid collider boxes.
Creation, worker additions, movement, body changes, removal and recovery maintain
them; queries fetch current entries, so counters and same-tick state never come
from a cached entity. Mob selection reads simulated chunks; external collision
setup collects only intersecting solids, keeping mob tick order unchanged.

AI sensing uses an 8-block grid of bounding boxes for populations of at least 32,
with ordinals preserving query order and updates as mobs move during the tick.
Very broad queries retain the linear path. Spawning caches per-section inputs
only while the authoritative entries and simulation tickets are identical;
mob caps still include the whole group. Discards/resets route once by entity id.

Alternating local full-profile measurements, seven samples of ten passes, with
identical result checksums: 600 sensed cows, 600 box queries and 600 same-tick
moves including grid construction take a median 26.396 ms versus 35.871 ms for
the linear path (2,996,300 versus 3,437,821 reductions). Nine collider queries
over 79 stores/1,264 mobs take 0.077 versus 2.178 ms; unchanged spawn preparation
for those stores takes 0.394 versus 0.794 ms. Collider measurements exclude index
maintenance, spawning is the unchanged-input case, and none establish whole-tick
or production capacity. Raw fixtures/results, the rejected 16-block grid's
regression and final alternating results remain in `.local/wide-view-perf/`.
