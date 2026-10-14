# VMC-014b5a — Bounded voxel unions

Status: Done — primitive and actual client contacts verified. October 14, 2026.
Depends on VMC-014b4.

Moving-piston retraction joins a stationary base with a displaced head. Establish
the required pure union/optimization primitive first; VMC-014b5 remains unfinished
until all piston contexts and actual moving fixtures are covered.

Acceptance:

- Match native box construction, epsilon-aware coordinate merging, occupied-cell
  union and optimization. Preserve clipping behavior at internal/boundary faces;
  a list of independently clipped component boxes is insufficient evidence.
- Bound axis/cell/box work and reject invalid geometry before use. No new process
  or global coordinator; later simulation owners decide scheduling and fences.
- Compare actual `Shapes.or`, `VoxelShape.optimize` and axis clipping with every
  cached grid plus compound/displaced/epsilon-boundary fixtures.
- Pass format, full tests/native suite, release, exact diff and public-tree audit.
- Actual 26.3/CUA: touching stone/slab fixtures, full and half-height contacts and
  traversal across their seam; compare the union's predicted heights. Verify
  commands and unseeded reconnect, retain fresh private logs.

Pinned native reference: 26.3 SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, `Shapes.create/findBits/join`,
`IndirectMerger`, `BitSetDiscreteVoxelShape.forAllBoxes`, `VoxelShape.optimize`.
Private bytecode: `research/disassembly/VMC014b5-unions.txt` and
`VMC014b4-aabb.txt`. Implement original functional grid operations; copying Java
object/thread arrangements would add no useful ownership boundary on the BEAM.

Implementation: immutable occupied-cell sets, epsilon-aware axis maps, ordered
box extraction and packed binary results. Limits are 32 cells per axis, 32,768
cells, 64 boxes and block-local coordinates within ±16. Oversized terms reject
before serialization; fragmented or oversized output jobs raise without returning
an approximation. The grid parser's capacity grows to accommodate unions; the
pinned cached facts are unchanged.

Verification, October 14:

- Format, 376 tests, production release and full native suite pass. All 330 cached
  grids participate in 1,959 native construction/optimization/union cases and
  70,524 exact clipping comparisons, including displaced compounds, operand order,
  thin/epsilon boundaries, inside starts and signed/tiny deltas. Final input-bound
  hardening was followed by full ExUnit/release and focused native union checks.
- Actual 26.3/CUA, `ValiMC computer-use test`: stone at {0,64,0} and bottom stone
  slab state 15252 at {0,64,1}. Initial y65; W held 300 ms traverses down to y64.5
  at z2.041990147468919; S held 300 ms steps back to y65 at z0.750491638208988.
  All three union predictions match exactly. `/stats`, ordinary unseeded reconnect
  and graceful restart into the rebuilt release retain the final pose.
- Fresh 22:51–23:05 logs and contact observations are private under
  `.local/client-tests/VMC-014b5a/` and `.local/vmc014b5a-*`. The initial fixture's
  preview-name lookup was corrected to the pinned slab state before joining.
  No new localhost protocol/server errors were observed. Exact diff/audit pass.

This completes the union primitive, not moving pistons or authoritative movement.
Piston snapshot rules, owner queries, animation/pushes and reconciliation remain.
