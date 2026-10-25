# VMC-080d — Sparse native spawn reads

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).

The user's mixed exploring/standing capture `valimc-profile(5).json` remains
unplayable: trailing-minute simulation 5.74 TPS; final MSPT ring median 88.9 ms,
p95 243.0 ms. Connection reductions fall from 251.3M to 118.2M against capture 4,
but owner work dominates. The captures are different gameplay workloads, so
these are observations, not a controlled before/after claim.

The native spawn call rebuilds all 256 heights of a chunk when it needs one
column, per call, and each block/light/biome read linearly searches all section
stores. Compute and cache only requested heights and memoize chunk routing for
one immutable call. Preserve absent/unloaded reads, negative coordinates, store
precedence, heightmap predicates, RNG consumption, caps and all spawn results.
No cross-tick native state or authority change is needed.

Validate exact results and native read parity, retain matched full-profile
measurements, run the affected Rust and Elixir/vanilla checks, and deploy to the
existing world/settings for the user's next profile. No graphical client driver
or flight benchmark.

Implemented call-local sparse height and chunk-route caches in the existing Rust
spawn kernel. The call already holds immutable store guards, so cached hits and
misses cannot outlive the state they describe. There is no new NIF, worker,
resource or cross-tick invalidation scheme.

Matched full-profile fixture: 441 simulated chunks around one player, nine or
77 loaded stores, materialized columns with identical edits, environment and RNG
states; seven samples of five calls. Median per-call time falls from 0.998 to
0.342 ms with nine stores, and 0.985 to 0.321 ms with 77. The complete result
(including RNG states) has the same SHA-256 in both revisions and both layouts.
This is a sparse materialized-column fixture, not a production TPS prediction.
Raw inputs/results are `.local/wide-view-perf/profile5/spawn-*`.
The two added Rust tests cover sparse heights for every column, both predicates,
negative coordinates, flat fallback, absent/missing chunks and store precedence.
All 126 crate tests and the affected Elixir/vanilla checks pass; shared
verification evidence is in the parent ticket.
