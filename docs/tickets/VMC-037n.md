# VMC-037n — Melee combat, mob death, loot and XP

Status: Planned
Milestone: M3
Depends on: [VMC-043a](VMC-043a.md), [VMC-017a](VMC-017a.md) (damage and
death of players).

Both directions of melee, as vanilla's `Player.attack` and
`Mob.doHurtTarget`:

- **Player attacks:** attack strength and cooldown, criticals, sweeping
  edge, knockback and sprint knockback.
- **Damage taken:** damage sources and types, armor, toughness and
  protection, shields and blocking, invulnerability ticks.
- **Mob death:** the death animation, its loot table (entity loot from the
  generated loot facts, looting excluded until enchanting) and its XP orbs.

Acceptance:

- A player kills a summoned zombie with a sword. Hits, cooldown, criticals
  and knockback look as in vanilla.
- The zombie's drops and XP match the oracle.
- A zombie's hits on an armoured player deal the oracle's damage.
- A raised shield blocks them.
