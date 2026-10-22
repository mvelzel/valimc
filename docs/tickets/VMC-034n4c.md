# VMC-034n4c — Experience orb gaps

Status: Planned
Milestone: M3
Depends on: [VMC-077i](VMC-077i.md) (orbs move in the Rust kernel),
[VMC-077h](VMC-077h.md) (one entity store).

Orbs already move live. The kernel's `orb.rs` applies currents, gravity, the
pull toward the nearest player, collision and the bounce, and `Entity.Store`
ages and expires orbs. This ticket closes the gaps against vanilla's
`ExperienceOrb`:

- **Merging:** nearby orbs merge (count and value), as vanilla's
  `scanForMerges` does.
- **Lava:** an orb in lava gets vanilla's random jump.
- **Furnace orbs:** they start at rest today (`ExperienceOrbs.award`);
  vanilla gives every new orb a random velocity.
- **Oracle check:** the live kernel matches oracle fixtures across falls,
  walls, slabs, ice, slime, honey, water and lava.

This used to be the supplied-kernel plan of VMC-034n4; VMC-077i replaced that
plan, so this ticket now lists only what remains.

Acceptance: merging, the lava jump and launch velocity match the oracle's
fixtures; furnace orbs scatter as in vanilla on the real client.
