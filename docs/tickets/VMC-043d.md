# VMC-043d — Nether mobs

Status: Done
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
5. **043d4b — piglins and hoglins** (done; crossbow piglins are a gap,
   below): the piglin brain's fight, avoid and celebrate
   activities, hostility rules; hoglins' brain.
6. **043d5 — magma cubes and wither skeletons** (done): the shared cube
   (`AbstractCubeMob`) and magma cubes; wither skeletons on VMC-043b3's
   skeletons.
7. **043d6 — striders** (done): walking on lava, shivering, warped fungus.

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

## 043d4b — piglins fight

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

## 043d4c — hoglins

- `Valimc.AI.Mobs.Hoglin` and its brain `Valimc.AI.Brains.Hoglin`
  (`HoglinAi`): core, idle, fight and retreat activities in vanilla's
  order; pacified by warped fungus and other repellents (and walking away
  from them), attacking the nearest player it may attack, an adult
  walking away from adult piglins, a baby following an adult; melee every
  40 ticks (a baby's 15); retreat while piglins outnumber them. Hurt, it
  retaliates with the adult hoglins it sees, a baby flees. Its hit
  (`doHurtTarget`): event 4 and the attack sound, the brain's reaction,
  then half its attack damage plus up to as much again and a throw
  (`HoglinBase.throwTarget`, the player's `push`). A baby one time in five
  (age, its attack damage), growing up.
- Shared: `Behaviors.become_passive/2`, `look_sometimes/3`
  (`SetEntityLookTargetSometimes`'s ticker), `baby_follow_adult/2`;
  `Sensors.NearestAdult`, `Sensors.repellent/2`; `Fight.much_farther?/3`;
  a brain's melee runs the family's `hit/2`; Kind `young?/1`.
- Evidence: `nether_mobs` passes 6980 ticks of 23 scenes (hoglin attack, repellent, baby hit,
  idle among them); `loot` 45000 deaths; `hostile_spawns` 14040 spawns;
  `mob_ai_connection_test` has a hoglin charge and hit a logged-in player.
- Gaps: breeding with crimson fungus (`AnimalMakeLove` inert), zombifying
  outside the Nether (the oracle's hoglin does not convert), piglins
  hunting hoglins, leads.

## 043d5 — magma cubes

- `Valimc.AI.Mobs.Cube` is vanilla's `AbstractCubeMob`, shared with slimes
  (VMC-043b6): its goals (float, random direction, keep jumping, attack;
  players within four blocks up or down, iron golems), its move control as
  a family `move_control/1` (turn, hop when the jump delay runs out, the
  jump sound), size (entity data `cube_size`; box, health, speed),
  `finalizeSpawn`'s size from the level's random, landing (the particle
  draws and squish), touch damage and splitting. `Valimc.AI.Mobs.MagmaCube`
  adds its own: four times the delay, attack and armor by size, a bigger
  jump and a lava leap (the kernel's `cube` jump), its sounds, experience
  its size, always lit.
- Shared: Kind `volume/1`, `jump/1`, `loot_properties/1`, `experience/1`,
  `split/2`; a `Monster`'s idle time in light now follows the facts'
  `monster` (a ghast or cube is not one); a player's hurt can carry the
  attacker's `taken_sound`; the loot engine reads `type_specific/cube_mob`
  sizes and a damage source entity's components (none modelled yet: a
  frog's variant).
- Owner: `{:touch, player, amount, sound}` hurts a player (`playerTouch`;
  the oracle's players touch cubes after the mobs tick); a dead cube's
  removal creates its halves (`AbstractCubeMob.remove`, `split/2`).
- Loot: a stack a function set below one counts as none
  (`ItemStack.getCount`), so Looting can still lift a cube's cream above it.
- Evidence: `nether_mobs` passes 5880 ticks of 19 scenes (hop, attack with
  touches, lava leaps among them); `loot` 39000 deaths (magma cubes of
  sizes one to four among them); `hostile_spawns` 9720 spawns with magma
  cube sizes; `mob_ai_connection_test` has a size-two cube hurt a
  logged-in player and split into halves when killed.
- Gaps: touching iron golems (`push`), slimes' own module (VMC-043b6),
  spawn rules beyond the existing natural spawning, magma cream from frogs.

## 043d5b — wither skeletons

- `Valimc.AI.Mobs.WitherSkeleton` over VMC-043b3's skeleton goals and
  weapon goal: piglins as targets too, a stone sword (no armour or
  enchantments), attack damage 4, Wither for ten seconds on what it hits
  (`doHurtTarget`), never withered itself (Kind `affected?/1`, read where
  an effect reaches a mob), weapons it dislikes not held. Its loot (coal,
  bones, the skull by Looting) and sounds are generated facts.
- Evidence: `nether_mobs`' wither skeleton scene (chase, hits
  carrying Wither) bit for bit; `hostile_spawns` 15120 spawns; `loot`
  46500 deaths.
- Gaps: its arrows' fire (it holds a bow only if it picks one up), Wither
  on mobs it hits (piglins).

## 043d6 — striders

- `Valimc.Entity.Animals.Strider` on VMC-043c's animals: its goals (panic,
  breeding and temptation by warped fungus, `StriderGoToLavaGoal` toward
  the lava block itself, following its parent, strolling, looks), lava
  worth 10 to its walks and every other place nothing once in lava
  (`RandomPos` skips `:neg_infinity`), shivering (entity data and a third
  less speed) away from warm blocks and lava, its happy and retreat
  sounds, water's hurt, and `finalizeSpawn`'s jockey draws.
- Kernel: a lava walker (`motion` `lava_walker`) stands on lava sources
  (`LiquidBlock`'s stable half block when above it with no lava over it),
  travels as in air in lava, keeps its base tick's lava instead of the
  fall check's re-sample, and floats up (`floatStrider`). A mob's footing
  after a move is its supporting block only when grounded, found with the
  move (`setOnGroundWithMovement`); the kernel reports the block it stands
  on (`getBlockStateOnLegacy`) to the AI.
- Evidence: `nether_mobs` passes the strider's lava, to-lava and tempt
  scenes bit for bit; `loot` 55500 deaths.
- Gaps: riding (saddles, warped fungus on a stick) and its jockeys wait
  for vehicles (VMC-046); a strider's path starting inside a lava column
  (`getStart`'s fluid branch).

Client gate (pending, batched with the milestone's run): in a Nether
fortress, blazes from a spawner shoot volleys at the player, rise to a player
above them, and a blaze killed by the player drops blaze rods; zombified
piglins ignore the player until it hits one, then the group attacks; a
piglin given a dropped gold ingot admires it and throws barter items (over
several barters, ender pearls); piglins attack a player without gold armour;
a ghast shoots fireballs that the player can hit back to kill it; a hoglin
charges the player and throws it, and keeps away from warped fungus; a magma
cube hops at the player, hurts it at a touch and splits when killed; a
strider walks on a lava lake and shivers off it.

## Handoff (October 2026)

- Done and verified: every slice above is on main (last commit 4ade4963).
  `nether_mobs`, `mob_ai`, `loot`, `hostile_spawns` and the 123 stages
  that `check_vanilla.py --changed` selected passed; `mob_ai_connection_test`
  passes. Nothing is in progress and there is no open branch.
- Remains: the client gate above (batched with the M3 client run); the
  gaps listed in the slice sections: crossbow piglins (`CrossbowAttack`,
  `BackUpIfTooClose`), hoglin breeding and zombification, riding and
  jockeys (VMC-046), a strider's path start inside a lava column, and
  Wither on the mobs a wither skeleton hits.
- Gotchas: the probe level is overworld-like, so the oracle's piglins and
  hoglins are subclasses that never convert. Regenerate `ai_facts`,
  `combat_facts`, `animal_facts` and `priv/loot/tables.json` with
  `scripts/java_tool.py` after every rebase that touches the oracles'
  lists. `mix format` also reformats other sessions' unformatted files:
  keep those out of commits.

Closed with M3 (October 31, 2026): its client observations passed in the [gate run](VMC-078.md#gate-run-on-the-native-mob-core-october-30-2026) and the [VMC-083 run](VMC-083.md#client-run-october-31-release-67a9072e).
