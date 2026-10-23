# VMC-034n4e — Burning items: rain, flames and explosions

Status: Done
Milestone: M3
Depends on: [VMC-034n4d](VMC-034n4d.md) (items and orbs burn).

Closes three of the gaps VMC-034n4d left in burning items and orbs, as
`Entity`, `ItemEntity` and `ExperienceOrb` do them in 26.3:

- **Rain.** `applyEffectsFromBlocks` calls `clearFire` when `isInRain`,
  after the block effects and before a counter that is not burning resets.
  `isInRain` asks `isRainingAt` at the block it stands in and at the top of
  its box in the same column, where its move ended.
- **Flames.** `baseTick` sets the on-fire shared flag (entity data 0, bit
  0x01) to `remainingFireTicks > 0` after its countdown, before the move and
  its block effects: a client sees an item catch fire a tick after it does
  and go out a tick after it does.
- **Explosions.** `ServerExplosion.hurtEntities` calls `hurtServer` with the
  damage: an item's or orb's health loses it as a float, truncated, and it
  is gone at 0 or below; a nether star resists.

Acceptance: an item or orb burning in the rain goes out on vanilla's tick, a
client sees flames on a burning one, and an explosion that leaves it alive
leaves it the health vanilla's does.

## Design

- **Rain.** `World.RainQuery` (moved from `Player`, now any body's) samples
  rain at a body's feet and top from the step's view. `Entity.ItemBurning`
  asks it only of an entity still burning after the effects (one they just
  destroyed included, as vanilla's), through a function `ItemStep` passes
  in; a column that cannot be read counts as dry. The weather's `wet` gate
  stays in `RainQuery`.
- **Flames.** `ItemBurning.tick` returns `Burning.tick`'s `on_fire`, and
  `ItemStep` puts it on the step. The store keeps it on the entry and adds
  `shared_flags` to the item's or orb's metadata packet once it first burns
  (a fresh one's packets stay as before), so a burning one shows flames to
  observers and a later 0 puts them out; a step without the flag (a push, a
  teleport) keeps it, and a handoff's record carries it to the next owner.
  Like vanilla's flag, it is not saved.
- **Explosions.** `Explosion.hits` takes the damage off with
  `ItemBurning.hurt` (`Float32` subtraction, truncated): `:destroy` at 0 or
  below, otherwise `{:push, impulse, health}`, which pushes it and keeps the
  new health.

## Evidence

- `ItemBurnOracle` / `check_item_burn.exs` (stage `item_burn`), on 26.3 jar
  `33680f5f`: a seventh layout puts a fire strip at x 0 and rain from x 1
  on (`isRainingAt` by block), and every row now compares the on-fire flag
  (`getSharedFlag(0)`) too. 3,023 ticks, all bit-exact with health, burning,
  age and the flag; 88 burn up on the same tick (stone and orbs in all seven
  layouts), six are put out, four of them by rain, and 159 ticks end with the
  flag set. A second part calls `hurtServer` alone with
  `damageSources().explosion` for stone, a nether star and an orb at health
  5, 3, 1 and 0 over eleven damages, boundary floats among them: 132 cases,
  health and removal exact.
- `test/world_items_test.exs`: a burning item's metadata carries the flag,
  a handoff and a push keep it, and going out sends 0.
- `check_vanilla.py --changed`: the 18 stages the change reaches pass
  (`item_travel` and `orb_travel` now pass a dry rain function).

Not covered: a destroyed shulker box or bundle dropping its contents
(`Item.onDestroyed` → `ItemUtils.onContainerDestroyed`). ValiMC's stacks
cannot hold `minecraft:container` or `minecraft:bundle_contents` yet, so no
such item exists to destroy; it belongs with those components in VMC-004b.
Creepers' explosions, whose `mobGriefing` check can spare items, do not
exist yet.

## Client gate

Throw an item through a fire: it shows flames until it burns out. Throw one
through a fire into the rain: the flames go out. Blow up TNT a few blocks
from dropped items: the near ones vanish, the far ones fly.

## Client run (October 23, 2026; M3 client run 3, frozen `dff984cb` (origin/main `abc89857` and the stand-up fix) release, fresh worlds; `.local/client-tests/M3-run-3/run-01`)

Passed on a superflat world:

- A plank thrown through a fire showed flames on the stone until it burned
  out.
- In `/weather rain` two planks thrown through the fire landed without
  flames, survived more than 10 seconds and merged.
- Primed TNT destroyed cobblestone beside it and a stack about 6.6 blocks
  away (vanilla's damage there exceeds an item's 5 health), while planks
  7.5 blocks away survived and moved slightly, as vanilla's exposure gives.
