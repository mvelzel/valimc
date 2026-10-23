# VMC-037n — Melee combat, mob death, loot and XP

Status: Awaiting client
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

## Implementation (October 23, 2026)

- **Facts.** `CombatOracle facts` (stage `combat_facts`) writes
  `priv/registry/combat_facts.json`: 94 items' default `attribute_modifiers`,
  `weapon`, `blocks_attacks`, `damage_type` and `minimum_attack_charge`; the
  player's base attributes; the zombie's experience reward (5), hurt and
  death sounds and sound source; the sound event, sound source and particle
  ids combat sends; and every damage type's death message id and difficulty
  scaling. `Living.Weapons` reads it. The loot facts hold
  `minecraft:entities/zombie`.
- **Loot.** `Loot.entity_drops/5` over the native evaluator's death context
  (`valimc_core::loot::Death`): `killed_by_player`,
  `random_chance_with_enchanted_bonus`, the `entity_properties` predicates
  the table uses (flags, vehicle type, an attacker's main-hand enchantment
  tag), `enchanted_count_increase` and `furnace_smelt` (furnace results from
  the cooking recipes).
- **One hurt path.** `Entity.Combat.hurt_body/3` (`Mob.hurt/3` underneath):
  invulnerabilities, the hurt window and cooldown, armor and toughness from
  the mob's attributes (its type's natural armor plus its equipment's
  modifiers), Resistance, protection and absorption; for a fresh hit the
  damage event naming the attacker, knockback away from the source unless
  the type is `no_knockback`, and the hurt sound; on death the death sound
  and event. Melee (`Region.hurt_entity/3`), explosions and falling blocks
  (`Body.hurt/3`, VMC-050a), a mob's own falls, fire and drowning
  (`Combat.hurt_mob/4`, VMC-015i) and `/kill` all go through it. A dying mob
  carries its drops (`Mob.death`); its owner drops them when it stores its
  entities (`Store.take_deaths/1`): the loot table's items (unless
  `mob_drops` is off; the owner's random stands in for the world's per-table
  random sequence) and, within 100 ticks of a player's hit, its experience
  orbs.
- **Player attacks.** `attack` and `punch` run in the hosting group
  (`Player.Attack`): the strength ticker (reset by a swing and a new
  main-hand item), reach (`isWithinAttackRange`), weapon attack damage and
  speed, sharpness, smite and bane damage and knockback enchantments,
  criticals, sprint knockback, the sword sweep with Sweeping Edge's ratio,
  weapon wear, 0.1 exhaustion, and vanilla's sounds, critical hit
  animations, sweep and damage indicator particles. Items and orbs are
  invalid targets (vanilla disconnects).
- **Mob attacks.** `RegionData.mob_attack/3` (`Mob.doHurtTarget`) for
  VMC-041a's melee goal: `Entity.Combat.mob_hit/3` builds the hit, and the
  player's session runs `Player.Hurt`: difficulty scaling, a raised shield
  (an item use now: `use_item` with a `blocks_attacks` item) blocking its
  share after the block delay and wearing, armor wear of `max(1, damage /
  4)` a piece, knockback sent as the client's velocity, the death message
  naming the zombie, and the player's hurt or death sound.

Not modelled yet: PvP (attacking another player), Strength, Weakness, Haste
and Mining Fatigue on attacks, post-attack enchantment effects (Fire
Aspect's ignition, Bane of Arthropods' slowness, Thorns), shields disabled
by axes, helmet wear from falling blocks, piercing and spear attacks, mob
equipment drop chances (VMC-043b's zombie equipment), the zombie's fire
spreading to its target, and the world's per-table loot random sequences.

Reference: 26.3 `Player.attack` (`getAttackStrengthScale`,
`canCriticalAttack`, `isSweepAttack`, `doSweepAttack`, `causeExtraKnockback`,
`attackVisualEffects`, `damageStatsAndHearts`),
`ServerGamePacketListenerImpl.handleAttack`/`handlePunch`,
`LivingEntity.hurtServer`/`knockback`/`applyItemBlocking`/`die`/
`dropAllDeathLoot`/`dropExperience`, `Player.hurtServer`,
`Mob.doHurtTarget`/`getBaseExperienceReward`, `BlocksAttacks`,
`EnchantedCountIncreaseFunction`,
`LootItemRandomChanceWithEnchantedBonusCondition`, `SmeltItemFunction`,
`ExperienceOrb.award`.

Checks: `check_vanilla.py --only combat_facts,combat_packets,combat,loot
--regen` (facts equal the oracle; 33 combat packets byte-equal vanilla's;
400 player attacks and 240 zombie hits equal vanilla's health, motion,
sweep, sounds, particles, animations and wear; 1500 zombie deaths' drops
equal vanilla's); `mix test test/combat_test.exs
test/combat_connection_test.exs --include tcp` (the store's hurt path and
deaths, a player's sword kill over a connection with its damage event, drops
and experience, a zombie's hit through armor and a raised shield's block);
the explosion, falling block, mob travel, entity body, loot and player
health suites; `mix test.fast` 437/437; `check_vanilla.py --changed`
156/156 (`anvil_content` once after a network timeout in its oracle's
server boot).

Client scenario (phase-end handoff): survival, normal difficulty, a diamond
sword. `/summon zombie ~3 ~ ~`. Hit it at once and again after the cooldown
bar fills: the first hit is weak (weak sound, little knockback), a full one
strong; a jump-hit while falling shows crit particles; a sprint-hit
knocks it further. Three full hits kill it: it falls over, poofs, drops
rotten flesh (or nothing) and 5 experience. With a second zombie beside the
first, a full standing hit sweeps both. The zombie's hits on an armored
player and on a raised shield wait for VMC-041a's melee goal.

Next: VMC-041a drives `mob_attack/3`; VMC-037 adds the remaining effects and
enchantments; PvP follows the player-target path.
