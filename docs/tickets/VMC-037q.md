# VMC-037q — Enchantment effects

Status: In progress
Milestone: M4
Depends on: [VMC-037n](VMC-037n.md) (melee), [VMC-037o](VMC-037o.md)
(projectiles), [VMC-077d](VMC-077d.md) (the enchantment definitions).

Every 26.3 enchantment works on tools, weapons, armour, bows, crossbows,
tridents and maces through the effect components of the pinned data pack
(`priv/registry/enchantments.json`, `EnchantmentMetadata`), checked against
the oracle. Nothing names an enchantment in code: a hook asks the engine for
an effect component, and the engine answers from the definitions.

## What exists

VMC-037n, 037o, 017a3 and the loot work left these live, each reading the
definitions or the loot tables:

- Damage protection and immunity (Protection, its four variants, Feather
  Falling, Frost Walker's hot-floor immunity), for players and mobs.
- Attack damage and knockback (Sharpness, Smite, Bane of Arthropods'
  damage, Knockback); Sweeping Edge's attribute.
- Unbreaking's wear removal; Vanishing's drop; Looting in loot tables and in
  equipment drop chances; Fortune and Silk Touch in block loot.
- Efficiency and Aqua Affinity by formulas written by hand; Respiration by
  name in the air rules.

Missing: every `post_attack` effect (Fire Aspect, Bane's slowness, Thorns,
Channeling, Wind Burst), Mending, Silk Touch's `block_experience`, the bow
and crossbow enchantments, the player's trident and mace with theirs, the
spear's Lunge, Depth Strider, Swift Sneak, Soul Speed, Frost Walker's ice
and the Curse of Binding.

## Design

- **One engine, in Rust.** `valimc_core::enchant` compiles the definitions
  once into typed effects: every `LevelBasedValue` form the pack uses
  (`linear`, `clamped`, `fraction`, `levels_squared`, `lookup`), every value
  effect (`add`, `set`, `multiply`, `remove_binomial`), every entity and
  location effect (`all_of`, `apply_mob_effect`, `ignite`, `damage_entity`,
  `change_item_damage`, `explode`, `summon_entity`, `play_sound`,
  `spawn_particles`, `apply_impulse`, `apply_exhaustion`, `replace_disk`,
  `attribute`) and every requirement (`entity_properties`,
  `damage_source_properties`, `match_tool`, `random_chance`,
  `enchantment_active_check`, `location_check`, `weather_check`,
  `all_of`, `any_of`, `inverted`, block and fluid predicates). A form outside
  these fails the install, so a data change cannot be silently ignored.
  - Value hooks (`modifyDamage`, `getDamageProtection`, `processAmmoUse`,
    `processProjectileCount`...) fold the stack's enchantments in vanilla's
    order and return the value.
  - Entity hooks (`doPostAttack`, `runLocationChangedEffects`, `tick`,
    `doPostPiercingAttack`, `onHitBlock`, `onProjectileSpawned`) return a
    list of **actions** (ignite an entity, apply an effect, damage an item,
    summon lightning, explode, impulse, replace blocks, add or remove an
    attribute modifier, play a sound). The engine never touches the world;
    the owner of the entity applies the actions as its own hurt and effect
    paths do, so the same plan serves a player in Elixir and a mob in Rust.
  - Random draws come from the caller's random (the entity's), so a draw
    lands where vanilla's does.
- **Mobs** call it in Rust (`mobs::living::enchantments` becomes a thin
  adapter over the engine). **Players** call it by NIF
  (`Native.enchant_*`); each call is a short pure fold, well under 1 ms.
  `Valimc.Protocol.EnchantmentEffects` keeps its API and delegates, so the
  Elixir interpreter goes away and one engine remains.
- **Oracle.** `EnchantmentEffectOracle` builds stacks with real
  enchantments and runs vanilla's `EnchantmentHelper` hooks over a matrix of
  levels, items, targets and damage sources: values directly, entity effects
  through a recording level (the actions taken, their order and draws).
  Stage `enchantment_effects` replays it against the engine through the
  NIF. Each slice adds its hooks' cases.

## Slices

Each slice is one commit series, landed on `main` when its cases pass.

### q1 — The engine, armour and tools

- The engine with every form above; the oracle and its stage.
- Existing hooks move onto it: protection, immunity, damage, knockback,
  attributes, item damage, equipment drops.
- Attributes from enchantments on players' armour and tools as vanilla's
  `forEachModifier` adds them: Efficiency, Aqua Affinity, Respiration, Depth
  Strider, Swift Sneak, Sweeping Edge, Blast and Fire Protection's
  attributes; the hand-written formulas go.
- Silk Touch's `block_experience`; Mending (`repair_with_xp`: an orb repairs
  a random damaged Mending item first, `ExperienceOrb.repairPlayerItems`).
- Frost Walker's ice and Soul Speed's speed, wear and particles
  (`location_changed`, `tick`); Curse of Binding (`prevent_armor_change`) in
  inventory clicks.

Acceptance: the oracle's cases for these hooks pass; an Efficiency V
pickaxe, Silk Touch on an ore, Mending repairing from orbs, Frost Walker on
water and Soul Speed on soul sand behave as vanilla in a connection test.

### q2 — Melee and Thorns

- `post_attack` for players' and mobs' melee: Fire Aspect, Bane of
  Arthropods' slowness, Thorns (from the victim's armour on the attacker,
  with its armour wear), as `doPostAttackEffectsWithItemSource` runs them,
  for both sweeps and direct hits.
- Breach's `armor_effectiveness` in the armour reduction.

Acceptance: the oracle's post-attack cases pass; a Fire Aspect sword sets a
zombie alight, Thorns hurts a zombie hitting a player and wears the armour,
a zombie's Fire Aspect sword sets a player alight.

### q3 — Bows and crossbows

- Power (arrow damage), Punch (arrow knockback), Flame (`projectile_spawned`
  ignites the arrow), Infinity (`ammo_use`), for players and skeletons.
- Multishot (`projectile_count`, `projectile_spread`), Piercing
  (`projectile_piercing`: the arrow passes through that many bodies, never
  the same twice), Quick Charge (`crossbow_charge_time` and its sounds), for
  players, pillagers and piglins.

Acceptance: the oracle's cases for these hooks pass; the projectile fixtures
gain shots from enchanted bows and crossbows and match.

### q4 — Tridents

- The player's trident: its charge and throw (`TridentItem.releaseUsing`),
  its flight and hit (`ThrownTrident`: 8 damage, Impaling against
  `#sensitive_to_impaling`), its pickup, and its wear.
- Loyalty (`trident_return_acceleration`: the return), Riptide
  (`trident_spin_attack_strength`: the spin launch in water or rain and its
  attack), Channeling (`hit_block` and `post_attack`: lightning in a
  thunderstorm).

Acceptance: the oracle's trident cases pass; a thrown Loyalty trident
returns, Riptide launches in rain, Channeling calls lightning on a zombie
in a thunderstorm.

### q5 — Maces and spears

- The mace's smash attack (`MaceItem`: the bonus by fall distance, the
  landing knockback, the fall reset) with Density
  (`smash_damage_per_fallen_block`), Breach and Wind Burst (`post_attack`
  explode: the wind burst that launches the attacker).
- The spear's charge and jab (`KineticWeapon`, `PiercingWeapon`) where
  players use them, with Lunge (`post_piercing_attack`: the impulse, the
  exhaustion and the wear).

Acceptance: the oracle's mace and spear cases pass; a Density mace's smash,
Wind Burst's launch and Lunge's dash behave as vanilla.

### Not in this ticket

Luck of the Sea and Lure need fishing, which ValiMC does not have yet; their
value hooks are in the engine and its oracle cases, and act when fishing
lands.

## Awaiting client

Added per slice as each lands.
