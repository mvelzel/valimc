# VMC-080a — Incremental entity publication and observer replication

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).

Reuse section publication revisions and populated chunk rows. Stop scanning
empty chunks and rebuilding unchanged visibility maps every 50 ms. Preserve
chunk/id ordering, entity limits, visibility changes, empty/nonempty transitions,
ownership generations and recovery when a publication disappears or changes.
Cache only immutable published observations; never gameplay authority.

Acceptance: unchanged publications reuse cached results; a changed or removed
entity updates the observer on the next pass; new readers and replaced tables
refresh correctly. Publication skips unchanged grouping/hashing while retaining
frame and collider semantics. Targeted publication/replication/socket tests and
matched wide-view measurements pass before the slice is committed.

Implemented section incarnation/revision checks, caches of populated chunk rows
and the aggregate view, and candidate-chunk reuse while position, range and sent
chunks stay unchanged. Deleting a publication row advances the section revision.
The publisher retains its previous immutable views and touches only changed
chunks, skips unchanged source copies and still publishes tracking frames.

Matched local `MIX_ENV=bench` observer fixture: 3,725 requested chunks across 79
sections, four sparse entities per section, existing 64-section/1,024-entity
limits, five samples of 40 passes. Median stationary work falls from 25.187 to
0.748 ms (7,523,436 to 72,007 reductions); changing one section per pass falls
from 25.595 to 3.443 ms (7,588,647 to 632,056 reductions). Every sample retains
the same 7,920 entity-count checksum. Raw script, before/after JSON and logs are
in ignored `.local/wide-view-perf/observer*`; baseline `4049cd01`. This measures
observer lookup/publication, not whole connection time or production TPS.
