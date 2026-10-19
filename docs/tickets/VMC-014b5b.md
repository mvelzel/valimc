# VMC-014b5b — Moving-piston collision snapshots

Status: Done
Note: Done — geometry and actual client contacts verified. October 14, 2026. Depends on VMC-014b5a.

Resolve moving-piston geometry from explicit state/direction/progress/source
observations and a caller-owned movement exclusion. This replaces native thread
local state with immutable query data; it adds no piston process or coordinator.
Animation ticking, redstone, pushing and persistence remain separate work.

Acceptance:

- Extract all 12 moving states, native head variants and extended-base mappings.
  Match source/ordinary movement, extension/retraction, float displacement,
  short-head boundary and stationary-base unions.
- Match the progress<1 movement-direction exclusion. Unavailable observations stay
  unresolved; confirmed absent/wrong entities are empty. Reject unknown or
  recursive moved states and malformed observations; propagate work-limit failure.
- Compare actual Mojang block/entity methods, geometry and exact clipping over
  all moving states, directions, flag branches and progress/exclusion boundaries.
  Include ordinary cached grids and dynamic moved-block native defaults.
- Pass format, full tests/native suite, release, diff and public-tree audit.
- Actual 26.3/CUA: native-encoded private piston event fixtures, displaced
  block/source contacts during extension and retraction, commands and reconnect.
  Record fixture limitations; no claim of server ticking/pushing implementation.

Pinned reference: 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`,
`MovingPistonBlock.getCollisionShape`, `PistonMovingBlockEntity.getCollisionShape`,
`getMovementDirection/getExtendedProgress` and `Shapes.or`. Private bytecode:
`research/disassembly/VMC014b4-world-contexts.txt`.

Implementation: immutable validated piston snapshots and a query-local exclusion
direction. Native float32 progress/displacement, source-head selection and bounded
voxel unions resolve all 12 moving states. Unavailable observations remain explicit;
confirmed absent/wrong block entities match native empty geometry. Moved dynamic
states use native empty/entity-type defaults. Recursive moved pistons reject.

Verification, October 14:

- Format, 382 tests, production release and full native suite pass. The oracle
  compares 19,981 native snapshots and 119,886 exact axis clips across all moving
  states, directions, source/extension flags, progress/exclusion boundaries,
  24 base states, 330 cached grids and 187 dynamic moved states. Existing collision
  facts are unchanged; only the piston catalog was added. Exact diff/audit pass.
- Actual 26.3/CUA, `ValiMC computer-use test`: static setups at y63–65, native
  piston extend/retract events, world freeze and one tick step create native BEs
  at progress 0.5. From centered flight at y67, held Shift+Tab descends onto each
  fixture. Ordinary extending/retracting stone both stop at y65.5; extending source
  head and retracting source head/base union both stop at y64.5. All four Elixir
  clipping predictions match exactly; client reports flight off at contact.
  `/stats`, cleanup to grass/air and ordinary unseeded reconnect pass at y64.
- Private evidence: `.local/vmc014b5b-*`,
  `.local/client-tests/VMC-014b5b/latest.log`, and
  `/tmp/valimc-014b5b-fixture.exs`. Fresh 23:28–23:47 client sessions show no new
  localhost protocol errors. CUA coordinate input returned `noWindowsAvailable`;
  keyboard navigation worked. Initial BE-data-only fixtures were discarded:
  native moving blocks do not create their own BE on ordinary block updates.
  Client block events correctly create it. An early private checker field typo
  was fixed before recording successful observations.

These are collision observations and private client fixtures. Server movement
remains client-controlled; piston animation, pushing, redstone, block-entity
persistence and authoritative fenced world queries remain unfinished.
