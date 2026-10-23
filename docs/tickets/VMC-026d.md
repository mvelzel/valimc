# VMC-026d — Eyes of ender; mobs and orbs through portals

Status: Done
Milestone: M3
Depends on: [VMC-037o](VMC-037o.md), [VMC-015i](VMC-015i.md),
[VMC-034n4c](VMC-034n4c.md) (orb gaps),
[VMC-026](VMC-026.md) (its M3 carry-overs).

- **Eyes of ender.** Using one throws an `EyeOfEnder` toward the nearest
  stronghold's start (generation's structure starts, as `/locate` finds
  them). It drops or breaks with vanilla's chance.
- **Portal travel for every entity.** Items already travel
  ([VMC-026c](VMC-026c.md)). Mobs and experience orbs now travel through
  Nether and End portals and gateways too, by the same path. Each keeps its records across
  the dimension change, and the cooldowns match vanilla's.

Acceptance:

- An eye leads to the same stronghold as vanilla on fixed seeds.
- A zombie and an orb pass a Nether portal and arrive with their state.

## Design

- **Eyes of ender.** `Player.Projectiles` handles an ender eye's use in the
  air as `EnderEyeItem.use` does. Nothing happens when the player looks at an
  end portal frame (`Buckets.aim`); the use on the block fills it instead
  (`Portal.Items`). Otherwise a session job (`:eye`) finds the nearest
  `#eye_of_ender_located` start from the player's block in the player's
  dimension (`Worldgen.Locate.nearest/3`, which `/locate structure` now
  shares). The tag's members come from the loot facts
  (`Blocks.Loot.structure_tag/1`), since the command facts sit a rank above
  players. When the job returns (`eyed/3`), an eye still held flies from the
  player's middle. `Projectile.signal_to/3` is `signalTo`: it heads for the
  start's corner, or past 12 blocks across for 12 toward it and 8 up, and
  survives four times in five. The launch sound plays at `lerp(f, 0.33F,
  0.5F)`, and one eye is used unless the player has infinite materials. With
  no stronghold (the Nether, the End, a world without structures) nothing is
  thrown, as vanilla's `CONSUME`.
- **Portal travel.** `World.ItemPortals` became `World.EntityPortals`, with
  one path for items, orbs and mobs. Each entity's size comes from its kind:
  items 0.25, orbs 0.5, a mob its type's width and height. Its cooldown
  lives in its motion (items, orbs) or its body (`Body.portal_cooldown`,
  saved while above zero). The orb's runs down in `Store.age`, the body's in
  `Body.tick`. Mob steps meet portals in the entity phase before they route,
  so a standing mob travels too. Dead mobs and the bosses (dragon, wither)
  stay. On arrival a body takes the target's motion and rotation; its mind
  starts afresh, as after any handoff, which matches vanilla's new entity
  per dimension change. Through an end portal, any non-player arrives as an
  item does (`EndPortal.destination`). One entity per owner travels at a
  time.

## Evidence

- `locate` stage (LocateOracle): every structure tag, including
  `eye_of_ender_located`, gives vanilla's start on fixed seeds. The loot and
  command facts agree on the tag (`minecraft:stronghold`).
- `test/projectile_test.exs`: `signalTo` near (the start itself) and far
  (12 along, 8 up).
- `test/item_portal_region_test.exs`: an orb (value 7, count 3) and a hurt
  zombie (13 health) fall into a Nether portal between live owners. Both
  arrive in the Nether with their state and a fresh cooldown.

Not covered: projectiles, primed TNT and falling blocks in portals; a baby
mob's smaller size; the used-ender-eye advancement and statistic.

## Client gate

Throw an eye of ender in the overworld: it flies toward the stronghold, then
drops or shatters. A zombie walking into a Nether portal and orbs thrown into
one appear on the Nether side.

## Client run (October 23, 2026; M3 client run 3, frozen `e13509dd` (origin/main `df9441ec` and the mob-sound fix) release, fresh worlds; `.local/client-tests/M3-run-3/run-04` and `run-06`)

Passed on seed 20261023:

- Five thrown eyes of ender each flew about 12 blocks toward the stronghold
  `/locate` named (about 40° west of south) and dropped as items.
- A zombie walked into a lit Nether portal toward the survival player
  behind it and stood beside the Nether-side portal when the player came
  through.
- Two orbs resting in a frame's opening when it was filled with portal
  blocks appeared about 3 seconds later, with the same ids, beside the new
  portal in the Nether near the overworld position over 8 (seen in the
  server's entities only).
