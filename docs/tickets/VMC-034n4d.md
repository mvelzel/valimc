# VMC-034n4d — Items and orbs burn

Status: Awaiting client
Milestone: M3
Depends on: [VMC-034n4c](VMC-034n4c.md) (orbs in lava), [VMC-077l](VMC-077l.md)
(items in the kernel).

Dropped items and experience orbs take vanilla's fire, lava and cactus damage
and burn up, as `ItemEntity` and `ExperienceOrb` do in 26.3:

- **Health.** Both have 5 (`Health`, saved and imported as a short).
  `hurtServer` takes the damage off it as an integer, truncated; at 0 or
  below the entity is gone and later hurts in the tick miss it.
- **Burning.** `Entity.baseTick` hurts a burning entity 1 every 20 ticks
  unless it is in lava, counting down (`remainingFireTicks`, saved as `Fire`).
- **Block effects.** `applyEffectsFromBlocks` after the move: fire and soul
  fire ignite for eight seconds and hurt 1 or 2 a tick, lava ignites for 15
  seconds and hurts 4, water puts it out, and a cactus hurts any entity 1.
- **Fire immunity.** A stack whose `damage_resistant` lists fire (netherite)
  takes no fire, lava or burning damage and stops burning; a cactus still
  destroys it. Orbs have none.

Acceptance: an item and an orb die in lava, fire, soul fire and on a cactus,
and burn out after passing through fire, on vanilla's tick; netherite
survives fire; the real client sees them vanish.

## Design

- **Kernel.** `item::step` and `orb::step` return whether the body began the
  tick in lava (`isInLava` for the burn) and the contacts of its move: the
  mob's `contacts::touched` over the recorded path for the body's size, with
  only cactus kept among the immediate hazards (magma, campfires and berry
  bushes hurt living entities only). A resting item's effects come from its
  last movement, which ValiMC takes as standing still.
- **Rules.** `Entity.ItemBurning.tick/4` applies `Burning.tick`, then the
  ordered operations of `Burning.plan/1`. Fire ignition is `fireIgnite` for
  an entity that is not a player: a negative counter steps toward zero, then
  eight seconds at least, with no random step. After the effects a counter
  that is not burning goes back to 0, and an entity gone in `baseTick` skips
  them. Any hurt that leaves 0 or less removes it (an imported item saved at 0
  lives until hurt). Health and fire ticks live in
  `ItemMotionState`; `ItemStep` runs the rules after each kernel step and
  marks a step `dead`.
- **Removal.** The region owner removes dead steps in the same tick, before
  routing the rest, wherever their move led; the next frame drops their
  records. A busy store skips the tick's motion and burning alike. Fire ticks
  are counters for storage: a change to them alone waits, as an age does.
- **Explosions** destroy an item or orb whose health the damage uses up,
  rather than assuming 5.

## Evidence

- `ItemBurnOracle` / `check_item_burn.exs` (stage `item_burn`), on 26.3 jar
  `33680f5f`: 2,662 actual `ItemEntity.tick` and `ExperienceOrb.tick` calls
  with the full `baseTick` and `applyEffectsFromBlocks`, through
  `hurtServer` with vanilla's damage-type tags. Stone, netherite and an orb;
  lava, fire, soul fire, a cactus wall, fire then water, and fire to pass
  through; three starts and three velocities, up to 200 ticks or until gone
  or at rest. Every live tick is bit-exact in position and velocity and
  exact in health, burning and age through `ItemStep`; 80 burn up on the
  same tick (stone and orbs in every layout, netherite only on the cactus),
  two are put out by water.
- `ItemTravelOracle` and `OrbTravelOracle` still leave burning out; their
  checks ignore health and fire ticks.
- `test/item_step_test.exs`: an item in lava is gone on its second tick; a
  fire-immune one keeps its health.

Not covered here: rain, the on-fire flag and a sub-lethal explosion's damage
came in [VMC-034n4e](VMC-034n4e.md); a destroyed shulker box or bundle
dropping its contents waits for those components (VMC-004b). Items the
kernel cannot step (inside a block) do not burn.

## Client gate

Drop a stack into lava and into a fire: it vanishes. Throw one through a
fire onto stone: it burns out after a few seconds. Drop a netherite ingot
into lava: it floats. Drop items against a cactus and orbs into lava.
