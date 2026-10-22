# VMC-037o — Projectiles

Status: Planned
Milestone: M3
Depends on: [VMC-043a](VMC-043a.md), [VMC-037n](VMC-037n.md).

A projectile kernel (vanilla's `Projectile` and `AbstractArrow` motion, the
ray and entity hit tests, block hits) and the projectiles the survival run
needs:

- **Bows and crossbows:** arrows, their charge, pickup and stuck arrows.
- **Thrown items:** snowballs, eggs (chickens hatch), ender pearls
  (teleport and endermite chance) and splash potions already brewed.
- **Fireballs:** small (blaze), large (ghast, deflectable) and the dragon's.
- **Eyes of ender:** the entity's flight, which VMC-026c uses.

Acceptance:

- Each projectile's flight and hit matches the oracle's fixtures.
- A skeleton (VMC-043b) and a player shoot each other.
- An ender pearl teleports across a group line.
