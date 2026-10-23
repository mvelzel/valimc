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
2. **043d2 — zombified piglins** (done but spawn gear): NeutralMob anger,
   group alerts.
3. **043d3 — ghasts**: flying travel, wandering, large fireballs.
4. **043d4 — piglins and hoglins**: the piglin brain's fight, avoid,
   celebrate and barter activities, hostility rules; hoglins' brain.
5. **043d5 — wither skeletons and magma cubes**: on VMC-043b's skeleton and
   slime parts.
6. **043d6 — striders**: walking on lava, shivering, warped fungus.

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
- Gaps: spawn gear (a golden sword or spear) and babies wait on VMC-043b's
  shared `finalizeSpawn`; anger is not saved with the mob; universal anger
  does not yet reach the mob's kind around it.

Client gate (pending, batched with the milestone's run): in a Nether
fortress, blazes from a spawner shoot volleys at the player, rise to a player
above them, and a blaze killed by the player drops blaze rods; zombified
piglins ignore the player until it hits one, then the group attacks.
