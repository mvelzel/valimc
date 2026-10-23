# VMC-041b — Pathfinding and navigation

Status: Planned
Milestone: M3
Depends on: [VMC-041a](VMC-041a.md).

Vanilla's `PathFinder` with its node evaluators (walk, swim, fly, amphibious)
and path types from block facts (doors, fences, fluids, danger), then
`PathNavigation` following, stuck detection and recomputation.

- Run the search in Rust as a bounded job over published chunk snapshots, so
  it never runs inside the owner.
- The owner rejects a result made from snapshots older than its fence.
- Node types come from one generated source (`ai_facts.json`'s path type of
  every state, VMC-041a1), so 029d's states path correctly.
- Replace VMC-041a1's straight one-node path (`Valimc.AI.Navigation`, and
  `MobAiOracle`'s matching path finder) with the search; the following,
  stuck detection and timeouts there stay.

Acceptance:

- Mobs path around walls, through doors where vanilla lets them, across
  section and group lines and into water.
- Paths match the oracle's fixtures for the four evaluators.
- No owner waits on a search.
