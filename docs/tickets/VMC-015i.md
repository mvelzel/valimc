# VMC-015i — Living-entity travel in the kernel

Status: Awaiting client
Milestone: M3
Depends on: [VMC-043a](VMC-043a.md), [VMC-077l2](VMC-077l2.md) (the player
kernel).

The physics kernel already runs the player's travel rules (gravity, jumps,
fluids, climbing, step-up, slowing blocks, knockback inputs) and a whole item
tick. Mobs need vanilla's `LivingEntity.travel`, `Mob` movement control and
entity pushing (`pushEntities`, collision between mobs and with players).

- Generalize the kernel's travel to any living body (the player's becomes one
  case), with per-type dimensions, step height, gravity and fluid rules from
  the entity facts.
- The owner runs every mob of a section in one NIF call per tick: movement
  control inputs in, positions, velocities, contacts and landings out.
- Fall damage, drowning, burning and lava contact reuse the player's living
  rules.

Acceptance:

- A summoned mob falls, swims, climbs, steps up, is pushed and takes fall
  damage as the oracle's fixtures do.
- A short tick bench shows several hundred mobs in one group within the
  tick budget.

## Implementation (October 23, 2026)

- **Kernel.** `valimc_core::physics::mob` is vanilla's server tick for a
  living body that is not a player: `Entity.baseTick`'s fluid state and
  currents (water resets the fall, lava halves it), then
  `LivingEntity.aiStep` — the 0.003 dead zone, input decay, `MoveControl`
  (wait, move to, jumping; `Mth.atan2`'s table, `rotlerp`) and
  `JumpControl`, ground and fluid jumps, `travel` with `moveRelative` and
  `getFrictionInfluencedSpeed` (dry, water with its efficiency, lava),
  climbing, `Entity.move` with the type's step height, slowing blocks, the
  fluid re-sample of `checkFallDamage`, the fall and its landing block,
  restitution and block speed. Sizes, step height, gravity, jump strength,
  movement speed and the drag and friction modifiers come from the entity
  facts and the mob's attribute overrides. The player's pure rules and
  contacts are reused (a mob is a one-pose catalog). `StrictMath.asin` is
  ported beside `sin` and `cos` for `Mth.atan2`'s table.
- **Pushing.** `tick_all` runs a section's mobs in id order; each one's
  `pushEntities` pushes the mobs it touches and is pushed by them, and
  players' boxes push the mobs they touch (from both sides, as vanilla's
  server does). Mobs meet only within neighbouring grid cells.
- **Owner.** The entity phase runs every simulated mob of a section in one
  `physics_mobs` call (a dirty twin past the budget), then each mob's living
  rules (`Entity.MobVitals`: landing damage through `Living.Landing` and
  `Living.FallDamage`, fire and lava contacts through `Burning.plan/1`,
  burning, air and drowning for types outside `can_breathe_under_water`),
  hurting through `Mob.hurt/3` so a mob that dies plays the death of
  VMC-043a. A step lands in the section, in a sibling in the same commit or
  in another group by the handoff, as items do. A body's motion-only record
  changes wait for the motion pass. Item auto-merging counts items only.
- **Control input.** `MobMotion.control` is what the AI sets each tick
  (`MobMotion.move_to/3` is `setWantedPosition`, which keeps a jump going);
  until VMC-041a mobs wait. Look and body rotation controls are VMC-041a's:
  the head follows the yaw. Strafing, entity cramming damage and the
  long-move fall reset by clipping are left for later slices.

Reference: 26.3 `Entity.baseTick`/`move`/`collide`/`checkFallDamage`/`push`,
`LivingEntity.aiStep`/`travel`/`travelInAir`/`travelInWater`/`travelInLava`/
`jumpFromGround`/`getFrictionInfluencedSpeed`/`pushEntities`,
`EntityFluidInteraction`, `Mob.serverAiStep`, `MoveControl`, `JumpControl`,
`Mth.atan2` (javac folds `180.0F / (float)Math.PI` to 57.2957763671875).

Checks: stage `mob_travel` (`MobTravelOracle`: whole vanilla zombie ticks
in a probe level over block scenes — falls of 2 to 11.25 blocks, walking on
stone, ice and soul sand, a slab step, a `MoveControl` jump, a wall, water
sinking and crossing, lava, a ladder, a cobweb, two zombies pushing):
830 mob ticks equal bit for bit in position, velocity, ground, fall
distance, yaw and horizontal collision, with landings and their fall damage
and lava contact. `cargo test -p valimc_core` (`atan2`, `rotlerp`, input,
pushes, move control, `StrictMath.asin`).
`test/mob_travel_region_test.exs`: in a region owner a zombie falls six
blocks and loses three health, two overlapping zombies push apart, a zombie
walks toward its target, and one walks across a section line into the next
owner. `check_vanilla.py --changed` 84/84; `mix test.fast` 426/426.

Bench (`bench/mob_ticks.exs`, `MIX_ENV=bench`, October 23 at host load
about 40 on 10 cores; medians of 60 ticks): zombies a block apart walking
across a stone floor and pushing each other, the whole mob phase (kernel
call, living rules, store steps; trackers excluded) takes 3.0 ms a tick for
100, 8.3 ms for 300 (17% of a 50 ms tick) and 17.2 ms for 600 (34%), about
28 µs a mob (a test-build sample put the kernel call alone at about 8 µs a
mob).

Client scenario (phase-end handoff): in creative, `/summon zombie ~ ~8 ~`:
it falls, flashes red on landing and stands. Summon one at the edge of a
pool: it sinks and walks the bottom; one beside lava: in lava it burns. Two
summoned at the same spot push apart; walking into a zombie pushes it.
