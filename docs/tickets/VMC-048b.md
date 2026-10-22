# VMC-048b — Pistons and moving blocks

Status: Planned
Milestone: M3
Depends on: [VMC-047a](VMC-047a.md), [VMC-015i](VMC-015i.md) (entities
are pushed).

Pistons and sticky pistons, as vanilla's `PistonBaseBlock` and
`PistonMovingBlockEntity`:

- **Pushing and pulling:** the push limit of 12, which blocks move or
  break, slime and honey groups, and immovable blocks, including blocks
  with block entities.
- **Moving blocks:** `moving_piston` block entities, which persist and hand
  off. Their collision geometry is in the physics kernel, replacing today's
  empty shape (the old VMC-014b5).
- **Entities:** players, mobs and items riding or pushed by moving blocks.
- **Timing:** zero-tick and pulse behaviour as vanilla times it.

Acceptance:

- Push and pull fixtures, including slime contraptions, match the oracle's
  block states and entity positions.
- A piston door works on the real client, and a player rides a moving
  block.
