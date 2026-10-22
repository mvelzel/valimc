# VMC-015i — Living-entity travel in the kernel

Status: Planned
Milestone: M3
Depends on: [VMC-043a](VMC-043a.md), [VMC-077l2](VMC-077l2.md) (the player
kernel).

The physics kernel already runs the player's travel rules (gravity, jumps,
fluids, climbing, step-up, slowing blocks, knockback inputs) and a whole item
tick. Mobs need vanilla's `LivingEntity.travel`, `Mob` movement control and
entity pushing (`pushEntities`, collision between mobs and with players).

- Generalize the kernel's travel to any living body (the player's becomes one
  case), with per-type dimensions, step height, gravity and fluid rules from
  the entity facts.
- The owner runs every mob of a section in one NIF call per tick: movement
  control inputs in, positions, velocities, contacts and landings out.
- Fall damage, drowning, burning and lava contact reuse the player's living
  rules.

Acceptance:

- A summoned mob falls, swims, climbs, steps up, is pushed and takes fall
  damage as the oracle's fixtures do.
- A short tick bench shows several hundred mobs in one group within the
  tick budget.
