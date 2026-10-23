# VMC-043d — Nether mobs

Status: In progress
Milestone: M3
Depends on: [VMC-041b](VMC-041b.md), [VMC-037o](VMC-037o.md).

The Nether's mobs: zombified piglins (group anger), piglins (brain,
bartering, admiring gold, hostility rules), hoglins, blazes (fireballs,
flight), ghasts (large fireballs), magma cubes, wither skeletons and striders
(walking on lava). Their loot gives blaze rods and pearls by barter.

Acceptance:

- Behaviour fixtures and barter loot match the oracle.
- On the real client, a fortress run yields blaze rods.

## Slices

1. **043d1 — blazes** (done): goals, attack, flight and loot below.
2. **043d2 — zombified piglins** (done): NeutralMob anger, group alerts,
   spawn gear.
3. **043d3 — ghasts** (done): flying travel, wandering, large fireballs.
4. **043d4a — bartering** (done): a piglin's admired gold ingot becomes
   the bartering table's items, thrown toward the player it sees.
5. **043d4b — piglins and hoglins**: the piglin brain's fight, avoid and
   celebrate activities, hostility rules, inventory; hoglins' brain.
6. **043d5 — wither skeletons and magma cubes**: on VMC-043b's skeleton and
   slime parts.
7. **043d6 — striders**: walking on lava, shivering, warped fungus.

## Oracle

`scripts/NetherMobOracle.java` (stage `nether_mobs`) ticks whole vanilla
mobs in `MobAiOracle`'s probe level (`MobAiOracle.run`); `check_mob_ai.exs`
replays each scene through the owner's mob tick. The probe now records what a
mob adds to the level (`addFreshEntity`: fireballs, thrown items) and its
level events, per mob tick, and `MobAiOracle.mob/2` makes any type by its own
factory, so other families' oracles reuse it the same way.

## 043d1 — blazes

- `Valimc.AI.Mobs.Blaze`: registered goals (vanilla's, `ai_facts`),
  `customServerAiStep` (height offset every 100 ticks, lift toward a
  target's eyes above it) through the new `Mobs.custom/1` hook, and
  `BlazeAttackGoal` (melee within two blocks, a charged volley of three small
  fireballs, follow when unseen). Its own mind fields live in `Mind.own`.
- Kernel (`physics::mob`): `fall_scale` (a falling blaze's motion × 0.6
  before the dead zone) and `rise` (`(0.3F − y) × 0.3F` after it), in
  vanilla's `aiStep` order.
- Owner: `{:projectile, …}` effects become owned fireball bodies,
  `{:level_event, …}` (1018) goes to viewers. A blaze is always lit for its
  idle time, water hurts it (`MobVitals`; rain is not read yet), its
  charged flag is its entity data (`blaze_flags`) and its loot table
  (`entities/blaze`: a blaze rod, killed by a player) and hurt and death
  sounds are generated facts.
- Evidence: `nether_mobs` passes 1040 mob ticks of 4 scenes (burst, rise,
  melee, alert) bit for bit; `mob_ai_connection_test` has a blaze's
  fireballs set a logged-in player on fire.

## 043d2 — zombified piglins

- `Valimc.AI.Neutral` is vanilla's `NeutralMob` for every neutral mob
  (anger end time and target in `Mind.own`, `updatePersistentAnger`,
  `isAngryAt`, `stopBeingAngry`) with `ResetUniversalAngerTargetGoal`.
- `Valimc.AI.Mobs.ZombifiedPiglin`: a zombie's goals with its own behaviour
  goals; `customServerAiStep` (the `attacking` speed modifier while angry,
  the first growl, anger kept up, alerts every four to six seconds) and its
  `setTarget` override through the new `Mobs.on_target/1` hook, which other
  mobs' alerts go through too. A selector may read the mob (`isAngryAt`).
  Travel reads attribute modifiers now (`MobMotion.travel/2`).
- The kernel pushes a mob by the players it touches before by other mobs,
  as the level lists players first.
- Evidence: `nether_mobs` passes 2240 ticks of 6 scenes (a neutral one; a
  hit one whose kind joins it, angry and faster, leaving the other player
  alone); `mob_ai` still passes; `mob_ai_connection_test` has zombified
  piglins turn on the player who hits one.
- Spawning: a family of `Valimc.AI.Mobs` (VMC-043b1's `finalizeSpawn`):
  a zombie's spawn (`Zombie.zombie/3`) with a golden sword, one time in
  twenty a golden spear, no armour and no reinforcements; a zombie's data,
  values and baby dimensions. `hostile_spawns` adds zombified piglins: 4320
  results equal vanilla's.
- Gaps: anger is not saved with the mob; universal anger does not yet reach
  the mob's kind around it.

## 043d3 — ghasts

- Kernel (`physics::mob`): `flying` (`travelFlying`: input at 0.02, no
  gravity, drag 0.91F in air, 0.8F in water, 0.5 in lava, no fall) and
  `float`, vanilla's `GhastMoveControl`: every 2 to 6 ticks (drawn from the
  mob's random, which the kernel takes and returns) a push of
  `flying_speed × 5/3` toward the wanted place, unless a block on the way
  (`forEachBlockIntersectedBetween`, `collidedAlongVector`) collides, which
  ends the want; an unreadable cell is in the way. The sweep's visit cap
  grew to 32768 for a ghast's box.
- `Valimc.AI.Mobs.Ghast`: `RandomFloatAroundGoal` (a place within 16 blocks
  on each axis), `GhastLookGoal` (facing its drift, motion's dead zone
  applied, or its target), `GhastShootFireballGoal` (events 1015 and 1016,
  a large fireball four blocks along its view, which follows its head),
  targets within four blocks up or down; its charging flag is entity data.
  A large fireball a player sent back kills it (`Kind.taken/2`, a hit that
  passes its fire immunity); another ghast's only burns, which it ignores.
- Loot: `damage_source_properties` in the native loot engine (the killing
  damage's type tags, direct and source entity types, `is_direct`), passed
  from the killing hit (`Combat`); `LootOracle` kills one death in four
  with the attacker's large fireball: the ghast's music disc drops as
  vanilla's. 21000 deaths and 3000 barters equal vanilla.
- Evidence: `nether_mobs` passes 4980 ticks of 16 scenes (a ghast floating,
  shooting twice at a player on a pillar, walled in);
  `mob_ai_connection_test` has a ghast's fireball hurt a logged-in player;
  `nether_mobs_test` the reflected fireball.

## 043d4a — bartering

- Loot: `LootOracle` adds `gameplay/piglin_bartering` to the facts and 3000
  barter cases (`table.getRandomItems(params, seed)`); `check_loot.exs`
  replays them through `Blocks.Loot.barter/2`: all equal vanilla.
- The piglin brain rolls the table when admiring a gold ingot ends
  (`stopHoldingOffHandItem`) with a seed from `World.loot_seed/1` (vanilla
  draws the world's random sequence for the table; the owner draws a fresh
  seed), swings its off hand and throws each stack as
  `BehaviorUtils.throwItem` does: from 0.3 below its eyes, at 0.3 toward a
  block above the nearest visible player or a spot near itself. The owner
  makes the `{:throw, …}` effects items with the default pickup delay.
- Oracle: the probe's fighters are `ServerPlayer`s now (a `Fighter`'s state
  copied into a `ServerPlayer` shell), so player sensors see them; the
  probe's server serves the bartering table and hands out recorded random
  sequence seeds (`loot_seed` rows); rows carry a brain's memories and its
  idle `RunOne` randoms (`gate_seeds`, compared each tick). The oracle had
  seeded the celebrate `RunOne` instead of the idle one at priority 15 (a
  `HashMap`'s order), which left piglin traces flaky; it now picks the idle
  activity's.
- Evidence: `nether_mobs` passes 2760 ticks of 8 scenes, with two barter
  scenes (toward a player in a golden helmet, and alone); `loot` passes
  3000 barters; `mob_brain_region_test` has a summoned piglin barter.
- Gaps: a baby's or a non-ingot loved item's handling (inventory, wearing),
  `mobInteract` (a player giving an ingot by hand), piglins' anger at
  players without gold armour: 043d4b.

## 043d4b — piglins fight (melee done; crossbows next)

- Spawning: `Valimc.AI.Mobs.Piglin` joins the mob families: one time in
  five a baby (smaller, faster), else a crossbow or a golden sword (a
  golden spear one time in ten), gold armour piece by piece one time in
  ten, enchantments, the wait before its first hunt, loot pickup; a
  structure's piglin is neither baby nor armed. Its entity data (baby,
  immune, charging, dancing). `hostile_spawns` adds piglins (natural,
  spawner and structure): 5400 results equal vanilla's.
- Brain (`Valimc.AI.Brains.Piglin`): vanilla's fight, celebrate, avoid and
  ride activities beside core, idle and admire, in vanilla's priorities:
  attacking the nearest player wearing no gold, a nemesis or whom it is
  angry at (`findNearestValidAttackTarget`), melee every 20 ticks, dropping
  a target that is no longer the nearest valid one, fleeing zombified
  piglins and soul fire, celebrating a kill where it fell. Its sensor is
  vanilla's `PiglinSpecificSensor` (the soul fire search in Manhattan
  order). Shared behaviours live in `Valimc.AI.Behaviors.Fight`
  (`StartAttacking`, `StopAttackingIfTargetInvalid`,
  `SetWalkTargetFromAttackTargetIfTargetOutOfReach`, `MeleeAttack`,
  `CopyMemoryWithExpiry`, `EraseMemoryIf`, `SetWalkTargetAwayFrom`,
  `GoToTargetLocation`, celebrating and forgetting a dead target).
- Reactions: a brain mob's hurts by entities wait in `Mind.pending` and run
  before its section thinks (`AI.react`, as vanilla's `wasHurtBy` runs at
  the hurt), with what they change in other mobs' brains: a hurt piglin
  drops what it holds, stops admiring, retaliates and the adults around
  take up its anger; a baby flees. Opening a chest or barrel
  (`Player.Menus`) and mining a block piglins guard (`Player.Mining`) send
  `{:anger, player, seen}` to the section (`Region.mob_event/2`,
  `AI.World.events`): idle piglins near the player get angry.
- A baby's voice is higher (hurt, death and its own sounds).
- Oracle: per-mob setup (a weapon, a baby) in `MobAiOracle.Spawn` data,
  all five piglin `RunOne`s seeded and reported, `getEntity(UUID)` in the
  probe, sensors' first scans drawn from a seeded random (a case is the
  same every run), and block scans that read the scene (its sections had
  claimed to hold nothing, so no piglin ever saw soul fire). A mob reads
  the others where they stood as its section's tick began (VMC-041a), not
  where the mobs before it moved this tick: scenes order a mob that looks
  at a moving one before it. Evidence: `nether_mobs` passes 4280 ticks of 13 scenes (attack,
  retaliate, baby hit, avoid, repellent among them);
  `mob_ai_connection_test` has a piglin spare a player in a golden helmet
  until it hits it.
- Gaps: crossbow piglins (`CrossbowAttack`, `BackUpIfTooClose` needs the
  move control's strafe), spears, doors, hunting hoglins, riding, a
  piglin's inventory, food and equipping what it picks up, creative
  breaking's anger, zombification outside the Nether.

Client gate (pending, batched with the milestone's run): in a Nether
fortress, blazes from a spawner shoot volleys at the player, rise to a player
above them, and a blaze killed by the player drops blaze rods; zombified
piglins ignore the player until it hits one, then the group attacks; a
piglin given a dropped gold ingot admires it and throws barter items (over
several barters, ender pearls); piglins attack a player without gold armour;
a ghast shoots fireballs that the player can hit back to kill it.
