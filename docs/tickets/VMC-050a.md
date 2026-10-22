# VMC-050a — Explosions, TNT and falling blocks

Status: Planned
Milestone: M3
Depends on: [VMC-043a](VMC-043a.md), [VMC-077o](VMC-077o.md) (box edits).

What the explosion changes:

- **Explosions.** Vanilla's `ServerExplosion`: ray sampling against block
  resistance, block destruction with drops, fire from fireballs and beds,
  and entity damage and knockback with exposure.
- **Atomicity.** The changed blocks may span sections and groups, so they
  commit as one cross-owner edit with the box-edit primitive, never per
  section.
- **Sources.** Primed TNT (fuse, chain reactions), creepers (VMC-043b), end
  crystals (VMC-045a), and beds and respawn anchors (VMC-040a).
- **Falling blocks.** Sand, gravel, concrete powder and anvils fall as
  entities and land as blocks.

Acceptance:

- TNT craters match the oracle's block sets for the same seed and position,
  including across a group line.
- Damage and knockback match the oracle.
- Sand falls and lands as in vanilla.
