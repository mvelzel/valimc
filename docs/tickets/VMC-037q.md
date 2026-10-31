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
  `Valimc.Protocol.EnchantmentEffects`, the older Elixir reader, still
  answers players' melee damage, knockback, protection and Unbreaking under
  their stages; each moves onto the engine when its path changes.
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
  (`smash_damage_per_fallen_block`), Breach (`armor_effectiveness` in the
  armour reduction) and Wind Burst (`post_attack` explode: the wind burst
  that launches the attacker).
- The spear's charge and jab (`KineticWeapon`, `PiercingWeapon`) where
  players use them, with Lunge (`post_piercing_attack`: the impulse, the
  exhaustion and the wear).

Acceptance: the oracle's mace and spear cases pass; a Density mace's smash,
Wind Burst's launch and Lunge's dash behave as vanilla.

### Not in this ticket

Luck of the Sea and Lure need fishing, which ValiMC does not have yet; their
value hooks are in the engine and its oracle cases, and act when fishing
lands.

## Implementation

### q1a — The engine, attributes, Silk Touch and Mending (October 31, 2026)

- **Engine.** `valimc_core::mobs::living::enchant` (`mod.rs` types,
  `parse.rs`, `eval.rs`): every effect component of the pinned pack parses
  into typed effects, and its forms are those listed above; the hooks fold
  values in Java floats and answer actions. It lives in `LivingFacts`
  (`enchant`), so mobs reach it in Rust; players reach it through
  `valimc_nif::enchant` and `Valimc.Living.Enchant`. The `armor` slot group
  now holds the body slot, as `EquipmentSlotGroup.ARMOR` does.
- **Oracle.** `EnchantmentEffectOracle` runs vanilla's `EnchantmentHelper`
  on enchanted stacks against real entities and damage sources in a probe
  level with the data pack's entity and damage type tags: every
  enchantment's attribute modifiers in every slot, Unbreaking's draws by
  seed, block experience, Mending's repair, ammunition use and piercing by
  ammunition, Multishot, Loyalty, the fishing values, Quick Charge, Riptide,
  attack damage, knockback, Breach and Density against eight victims and
  five sources, Looting's drop chance, and protection and immunity. Stage
  `enchantment_effects`: 3,533 cases, all equal.
- **Players' attributes.** `Living.Armor.attributes/1` adds the modifiers
  the equipment's enchantments give (`enchanted`) and sends each attribute
  with its base and modifiers when it changes: burning time, oxygen bonus,
  mining efficiency, submerged mining speed, sneaking speed, sweeping
  damage ratio, water movement efficiency and explosion knockback
  resistance. Mining speed, air, burning, Blast Protection's knockback and
  the player kinetics' water drag (Depth Strider) read them; the
  hand-written Efficiency and Aqua Affinity formulas and the Fire
  Protection table are gone.
- **Silk Touch.** A harvest's experience goes through the tool's
  `block_experience` where the block drops it by `tryDropExperience`.
- **Mending.** An orb a player touches is taken at once; its experience
  repairs a random damaged item with Mending first
  (`ExperienceOrb.repairPlayerItems`), and only the rest is given.

Tests: `enchantment_effects_test.exs` (attributes, Silk Touch, Mending); the
stages `enchantment_effects`, `player_mining`, `player_armor`, `player_air`,
`damage_protection`, `fluid_travel`, `swim_steering`, `explosion`,
`player_kinetics`, `server_movement`, `block_loot`, `combat`,
`hostile_ai`, `mob_ai`, `enchantments` and `equipment` pass.

Left in q1: Frost Walker's ice (needs frosted ice's aging), Soul Speed and
the Curse of Binding.

### q2 — Melee and Thorns (October 31, 2026)

- **Mobs hurt.** A hit carrying `post_attack` (a player's hit and each
  sweep, a mob's melee from `mob_hit`) runs `combat::post_attack` after it
  hurts a mob: the mob's equipment's effects (Thorns), then the attacker's
  weapon's (Fire Aspect, Bane's slowness), from the mob's own random, and
  only when there is an enchantment to run, so an unenchanted fight draws
  nothing. Effects on the mob apply there (fire by its burning time, effects,
  a worn piece's wear); those on the attacker come back in the hurt's
  outcome (`post_attack`) to the player's session.
- **Players hurt.** `Player.Enchantments.struck/3`, from `Player.Hurt`, runs
  the worn pieces' effects (Thorns hurts the mob through its owner's hurt
  path, caused by the player, and wears the piece) and a melee attacker's
  weapon's on the player. Thorns' own hurt carries no post-attack, so it
  never answers itself.
- Not run: effects on a mob that attacks another mob (its Thorns), and the
  Thorns of a mob hit by a sweep.
- **Oracle.** 240 `doPostAttackEffectsWithItemSource` cases: Fire Aspect I–III,
  Bane I–V and both, against Thorns I, III and X on a zombie, a spider and a
  player, melee and by arrow, each from one seeded random shared by the
  level and both bodies; what each party took and the chestplate's wear
  equal vanilla's.

Tests: the connection test "a Fire Aspect sword sets a zombie alight; Thorns
hurts the zombie hitting back"; stages `enchantment_effects` (3,773
cases), `combat`, `guardian_hurt`, `dragon_damage`, `mob_ai`, `hostile_ai`,
`nether_mobs`, `animals`, `village` and `projectiles`. The shulker lid
reach test fails now and then on `main` too.

### q3 — Bows and crossbows (October 31, 2026)

- **Drawing ammunition** (`ProjectileWeaponItem.draw` and `useAmmo`): a
  shot takes as many arrows as the weapon's `projectile_count` (Multishot's
  three), the first from the ammunition by its `ammo_use` (Infinity takes
  none and shoots an intangible copy), the others intangible copies. A
  crossbow loads them all into `charged_projectiles`.
- **Shooting** (`ProjectileWeaponItem.shoot`): each arrow at its angle in
  the weapon's `projectile_spread` (Multishot's 10 degrees each side): a
  bow turns the yaw, a crossbow turns the view about the player's up
  vector, with a shot sound and pitch per arrow; the weapon wears a point
  each and stops when it breaks.
- **Charging**: the charge time is the crossbow's `crossbow_charge_time`
  (Quick Charge's quarter second off per level) and its sounds the
  highest-levelled `crossbow_charging_sounds`.
- **Arrows** (`Entity.Projectile.arm/3`, for players' shots and skeletons'):
  an arrow keeps its weapon, pierces what the weapon's `projectile_piercing`
  gives for its ammunition, and takes `projectile_spawned` (Flame: 100
  seconds of fire). On a hit its base damage goes through the weapon's
  `damage` effects (Power) before the speed and critical bonus; the
  weapon's `knockback` (Punch) pushes along the arrow's horizontal motion,
  less the target's knockback resistance (`doKnockback`, players and mobs);
  the post-attack effects run. A piercing arrow passes what it pierced (the
  kernel skips those ids), flies on after a hurt, is gone after its count,
  and stops piercing when it hits a block. The pierce level is sent.

Tests: the connection tests "a Multishot, Quick Charge III crossbow loads
three arrows from one in ten ticks" and "an Infinity, Flame, Power V bow
keeps its arrow and shoots it burning"; stages `projectiles`,
`shulker_bullets`, `shulker_bullet_hurt`, `shulker_body_box`,
`enchantment_effects`, `hostile_ai` and `combat`.

Not shot yet: firework rockets from crossbows, and pillagers' and piglins'
crossbows (VMC-044d's illagers).

## Awaiting client

- **Efficiency and Mending** (q1a): an Efficiency V diamond pickaxe breaks
  stone without the crack lagging behind; a damaged Mending pickaxe in the
  hand mends from orbs, and the experience bar fills only once it is whole.
- **Depth Strider** (q1a): Depth Strider III boots walk on a pool's floor at
  land speed.
- **Bows and crossbows** (q3): a Multishot crossbow shoots three arrows in
  a fan; Quick Charge III charges in half a second with its own sounds; a
  Flame bow's arrows burn; Infinity keeps the last arrow; a Piercing IV
  crossbow's arrow passes through a line of zombies; Punch II knocks one
  back further.
- **Fire Aspect and Thorns** (q2): a Fire Aspect sword sets a zombie
  burning; a zombie hitting a player in Thorns III armour is hurt now and
  then, with the thorns sound and the armour wearing.
