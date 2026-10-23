# VMC-037n — Melee combat, mob death, loot and XP

Status: In progress
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

## Design

- **Facts.** `CombatOracle facts` writes `priv/registry/combat_facts.json`:
  each item's default `attribute_modifiers`, `weapon`, `blocks_attacks`,
  `damage_type` and `minimum_attack_charge` components (vanilla codec JSON),
  the `#minecraft:swords` tag, the player's base attributes and each
  modelled mob's base experience reward. `LootOracle` also exports the
  modelled mobs' entity loot tables and the smelting results its
  `furnace_smelt` entries need.
- **Loot.** The native evaluator takes an entity context: the victim's
  flags (on fire, baby, vehicle type), whether a player killed it, and the
  attacker's main-hand enchantments. It adds `killed_by_player`,
  `random_chance_with_enchanted_bonus`, the `entity_properties` predicates
  the tables use, `enchanted_count_increase` and `furnace_smelt`. Vanilla
  draws entity loot from a world-persisted random sequence per table; that
  sequence is shared mutable state across groups, so the owner's random
  drives it here (the same distribution), and the evaluator is checked
  against vanilla with an explicit random source.
- **One hurt path for mobs.** `Entity.Combat.hurt/5` runs
  `LivingEntity.hurtServer` on a mob body: hurt window and invulnerability
  ticks, armor and toughness (equipment and the type's `armor` attribute),
  protection, absorption, knockback from the source position, the damage
  event, and death with its loot, equipment drops and experience orbs.
  Melee, explosions (VMC-050a) and projectiles (VMC-037o) all call it.
- **Player attacks.** The serverbound `attack` and `punch` packets run in the
  group hosting the player: attack strength from a per-player ticker (reset
  by a swing and a main-hand item change, as `Player.tick`), weapon damage
  from the attribute modifiers, sharpness-style damage and knockback
  enchantments, criticals, sprint knockback, sweeping, weapon wear and food
  exhaustion, the crit animations and the attack sounds.
- **Mob attacks.** `Entity.Combat.mob_attack/3` is `Mob.doHurtTarget` on a
  player in the same group, for VMC-041a's melee goal: the mob's attack
  damage, difficulty scaling, shield blocking (`blocks_attacks`, the block
  delay and angle, shield wear), armor through `Player.Vitals`, and
  knockback sent to the player's client.
