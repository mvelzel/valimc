# VMC-037o — Projectiles

Status: Awaiting client
Milestone: M3
Depends on: [VMC-043a](VMC-043a.md), [VMC-037n](VMC-037n.md),
[VMC-050a1](VMC-050a1.md) (fireball explosions).

A projectile kernel (vanilla's `Projectile` and `AbstractArrow` motion, the
ray and entity hit tests, block hits) and the projectiles the survival run
needs:

- **Bows and crossbows:** arrows, their charge, pickup and stuck arrows.
- **Thrown items:** snowballs, eggs (chickens hatch), ender pearls
  (teleport and endermite chance) and splash potions already brewed.
- **Fireballs:** small (blaze), large (ghast, deflectable) and the dragon's.
- **Eyes of ender:** the entity's flight, which VMC-026d uses.

Acceptance:

- Each projectile's flight and hit matches the oracle's fixtures.
- A skeleton (VMC-043b) and a player shoot each other.
- An ender pearl teleports across a group line.

## Design

- **Kernel.** `valimc_core::physics::projectile` ticks a projectile as its
  class does: `AbstractArrow.tick` (the stuck test, water drag, the ray,
  `findHitEntities` nearest by position, `onHitBlock`'s back-off and stick,
  drag and gravity, coming loose when its block goes), `ThrowableProjectile`
  (gravity, then drag), `AbstractHurtingProjectile` (acceleration along its
  motion, `rotateTowardsMovement`) and `EyeOfEnder` (`updateDeltaMovement`
  toward its target), with `checkLeftOwner` and the base tick's fluid push
  and water state. `physics::ray` is `clipIncludingBorder` with collider
  shapes: `traverseBlocks`, `VoxelShape.clip` (inside a filled voxel, else
  the boxes' nearest entered face) and the border stop. Targets are the
  entities' boxes with the owner marked. One call per section per tick
  (`Native.physics_projectiles`, a dirty twin by cost).
- **Owner.** Projectiles are object bodies (`Entity.Projectile`: owner,
  ticks lived, water and owner flags, fire, the type's fields). A section's
  entity phase runs the kernel over its projectiles against its living mobs
  and the group's players (`Player.Host.bodies/1`); `World.Projectiles`
  plans each step as the type's `onHit` does, and the owner applies it:
  hits through VMC-037n's hurt path (this section's mobs at once, players
  by their sessions with the projectile as the direct entity, knockback
  along its motion), sounds, entity and level events, spawned entities,
  explosions (VMC-050a1), fire, potion splashes. Moves go where mobs' go:
  this section, a sibling in the same commit, another group by the entity
  handoff. A shot, a stick or a deflection forces the tracker's update
  (vanilla's `needsSync`).
- **Players.** `Player.Projectiles` runs the item uses in the hosting group:
  throws (`shootFromRotation` with the player's motion), the bow's draw and
  release (`getPowerForTime`), the crossbow's charge with its loading
  sounds and `charged_projectiles` (a new item component codec), arrow
  ammunition as `useAmmo` draws it, the ender pearl's cooldown, the pickup
  of stuck arrows, a pearl's landing (teleport, 5 damage, the endermite
  chance), splash and cloud effects. A player's attack on a fireball turns
  it back (`deflectProjectile`).
- **Mobs.** `RegionData.mob_shoot/4` is `AbstractSkeleton.performRangedAttack`
  for VMC-043b's ranged goal: aim at a third of the target's height raised
  for the distance, power 1.6, the difficulty's spread and damage.

## Implementation (October 23, 2026)

- **Kernel and oracle.** `physics::projectile`, `physics::ray`;
  `Physics.Kernel.projectiles/5`. `ProjectileOracle` ticks real `Arrow`,
  `Snowball`, `ThrownSplashPotion`, `SmallFireball`, `LargeFireball`,
  `DragonFireball` and `EyeOfEnder` over block scenes (a floor, a wall, a
  slab row, a pool, a current, a 16-block border) with standing zombies and
  the shooter at the start, recording every tick and the hits `onHit`
  receives; `check_projectiles.exs` replays them (stage `projectiles`).
- **Bodies.** `Entity.Projectile` (data, kernel input, entity data, spawn
  data, `shoot` and `from_rotation`), `Entity.EffectCloud` (the dragon's
  breath, `AreaEffectCloud.serverTick`), chickens and endermites as bodies;
  entity data fields for arrows, thrown items, eyes, clouds and a baby flag
  (`EntityOracle facts`); sounds, the chicken and endermite and the
  dragon's breath particle in `combat_facts` (`CombatOracle facts`); their
  loot tables (`LootOracle`). Babies drop neither loot nor experience; an
  adult chicken gives one to three.
- **Owner.** `World.Projectiles` (plans, splash, item drops),
  `RegionData.tick_projectiles/1` and the effects, `{:hurt, uuid, hit}`
  sibling effects, `{:take_arrow, ...}` and `{:deflect_projectile, ...}`
  calls, `mob_shoot/4`. `Explosion` gained `fire` (`createFire` over the
  crater, soul fire on soul sand and soil); `GameRules` defaults for
  `mob_griefing` and `spawn_monsters`. `Combat` and `Player.Hurt` take a hit's
  `direction` (a projectile's knockback), its `ignite` and the projectile
  as the damage event's direct entity.
- **Player.** `Player.Projectiles`, `Use.drawing/3`, `ItemUse` and the
  release action, the session's `{:ender_pearl, position}`, `{:splash, ...}`
  and `:arrow_hit_player` messages.

## Results

- `projectiles` stage: 157 vanilla flights, 6,974 ticks and 110 hits
  (blocks, entities and a border deflection) equal the kernel's position,
  velocity, rotation, water, ground and owner flags bit for bit, and each
  hit's cell, face, point and flags or entity and point.
- `test/projectile_test.exs`: arrow damage and the bounce of a hit that
  does not take; a stuck arrow's sound and despawn; a snowball's break, eggs
  hatching (1 in 8, four in 1 in 32 of those), a pearl calling its owner;
  fireballs lighting, exploding and breathing; an eye dropping or
  shattering; a splash's distance scaling and undead healing; the dragon's
  breath timing; in a section, an arrow hurting a zombie and another
  sticking in stone, a mob's arrow hitting a zombie, a ghast's fireball
  blowing its crater.
- `test/projectile_connection_test.exs` (tcp): a fully drawn bow's arrow
  hurts a zombie, using an arrow and wearing the bow; a mob's arrow
  (`mob_shoot`) hurts the player; an ender pearl landing in a section of
  another group brings the player there with 5 damage.

Checks: `check_vanilla.py --changed --regen` 161/162 before the rebase onto
029e (`loot` then expected 1,500 deaths; it holds three tables' 4,500 now),
then `--only loot,projectiles,combat_facts,entity_facts,combat_packets,combat,explosion,block_loot,entity,tnt_travel,falling_block,mob_travel`
12/12; `mix test.fast` 454/454; the projectile, combat and explosion socket
suites.

Not modelled: bow and crossbow enchantments (Power, Punch, Flame, Infinity,
Multishot, Piercing, Quick Charge: VMC-037), tipped arrows' effects,
spectral arrows, firework rockets from crossbows, an arrow bouncing off a
player's shield or a creative player (a player hit is taken to land), more
than the first entity on one tick's path, projectiles hitting mobs of a
sibling section (a section is 128 blocks across), arrows hitting fireballs,
`state.onProjectileHit` (targets, bells, TNT lit by a burning arrow),
block effects inside the path, bubble columns and portals, water potions
dousing fire, potion colours from their effects (the splash particle uses
the potion's custom colour or water's), an arrow's count stuck in a mob,
chickens growing up (VMC-043d) and the eye of ender's use (VMC-026d throws
it at the nearest stronghold).

Client scenario (phase-end handoff): survival, normal difficulty. `/give
@s bow`, `/give @s crossbow`, `/give @s arrow 16`, `/give @s snowball 4`,
`/give @s egg 16`, `/give @s ender_pearl 2`, `/give @s splash_potion[potion_contents={potion:"minecraft:harming"}]`.
`/summon zombie ~6 ~ ~`. Draw the bow fully and shoot it: the arrow flies,
hits with the hit sound, the zombie flashes and is knocked back. Shoot one
at the ground: it sticks and shakes; walk over it to pick it up. Charge the
crossbow (three loading sounds), shoot it. Throw snowballs (they break in
puffs), eggs at the ground (now and then a chick hatches), the splash
potion at the zombie (it is healed: zombies are undead). Throw an ender
pearl 20 blocks away: the player lands where it hit, hurt a little.
`/summon fireball ~ ~2 ~4`: punch it; it flies off the way the player
looks and explodes where it lands. `/summon dragon_fireball ~ ~3 ~4` stays;
`/summon small_fireball` likewise (no motion from `/summon`).

Next: VMC-043b's skeletons call `mob_shoot/4` from their ranged goal; 043c's
blazes and ghasts shoot `small_fireball` and `fireball`; VMC-026d throws
the eye at a stronghold; VMC-045a's dragon its fireballs; VMC-037 adds the
bow and crossbow enchantments.
