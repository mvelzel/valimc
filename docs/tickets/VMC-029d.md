# VMC-029d — Survival block states and shape updates

Status: Planned
Milestone: M3
Depends on: [VMC-029b](VMC-029b.md) (placement), [VMC-077m](VMC-077m.md)
(the block-update engine).

Every block a survival player can obtain places in its vanilla state and
updates as vanilla does:

- **Two-part blocks:** doors, beds and tall plants.
- **Attached blocks:** wall torches, ladders, buttons, levers, signs and
  banners.
- **Oriented blocks:** stairs (with their shapes), slabs (top, bottom,
  double), logs by axis, trapdoors, fence gates and the rest that read the
  click face and the player's facing.
- **Excluded shape updates.** The ones `ShapeOracle` excludes today:
  - attached pumpkin and melon stems toward their fruit (a woodland
    mansion's pumpkin room fails its chunks);
  - observers;
  - kelp, weeping, twisting and cave vine plants.
- **Coverage matrix.** A placement oracle drives one coverage matrix of
  every item's placed states, which VMC-030 later grows.

Acceptance:

- The placement matrix matches the oracle for every survival-obtainable
  block.
- `ShapeOracle` reports no excluded state.
- The mansion seed that failed generates whole.
