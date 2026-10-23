# VMC-039c — Bamboo, cave and Nether growth; shears on hives and pumpkins

Status: Awaiting client
Milestone: M3
Depends on: [VMC-039b](VMC-039b.md).

What VMC-039b left of bone meal and block interactions:

- bamboo growing, by random ticks and bone meal;
- bone meal on glow lichen, dripleaves, Nether fungi, netherrack, pale
  hanging moss and pale moss carpets;
- shears on a full beehive and on a pumpkin.

Acceptance:

- Growth chances and outcomes match the oracle at the same random ticks.
- A fungus's huge fungus equals vanilla's block for block.
- Shearing drops what vanilla's interaction loot tables give.

Slices:

- **039c1 Random ticks and bone meal in the rules** (done):
  `valimc_core::rules::plants`. A bamboo sapling grows a stalk with small
  leaves in light 9 (`BambooSaplingBlock`), a growing stalk shorter than 16
  grows one more and bone meal one or two (`BambooStalkBlock.growBamboo`:
  leaves move up, the stalk thickens, a tall one may stop growing); the
  thicker stalk's shape update thickens the stalk below it, which the plan's
  reads see. Bone meal on glow lichen spreads it from a random face toward a
  random direction (`MultifaceSpreader`: same cell, same plane, around the
  corner); on a small dripleaf grows a big dripleaf two to five tall
  (`placeWithRandomHeight`); on a big dripleaf or its stem raises the leaf
  by one; on netherrack beside nylium under a state sky light passes down
  through turns it to that nylium, either one at random beside both
  (`skylight`, a GrowthOracle fact from `propagatesSkylightDown`); on pale
  hanging moss grows its tip down; on a base pale moss carpet grows its
  topper with every side it can have.
- **039c2 Fungi through the generator** (done): bone meal on a fungus over
  its nylium (GrowthOracle's `fungi` facts) answers 2 two times in five, and
  the owner grows the planted huge fungus at the cell in a task
  (`Growth::generated` → `Generated::At` → `Placement::Feature`). A planted
  `HugeFungusFeature` is never huge, ignores the generator's depth and
  destroys what it grows through over a block.
- **039c3 Shears in play** (done): a player's shears on a beehive or bee
  nest with five honey or on a pumpkin (`Valimc.Blocks.Shearing`, in the
  owner before berries and redstone's uses): the owner rolls
  `harvest/beehive` or `carve/pumpkin`, the rules (`{:shear, position,
  facing}`) empty the hive or carve the pumpkin toward the clicked side (the
  player's when clicked from above or below), honeycomb pops from the hive
  and the seeds drop out of the carved face (`ItemDrop.carved/3`), the
  sound plays to everyone near and the player's shears wear by one.

Sweet berry bushes already slow and hurt players and mobs moving through
them (`physics::player::contacts`, which the mob kernel shares since
VMC-015i); foxes and bees, which vanilla spares, come with their families.

Reference: pinned 26.3 `BambooSaplingBlock`, `BambooStalkBlock`,
`GlowLichenBlock`, `MultifaceBlock`, `MultifaceSpreader`,
`SmallDripleafBlock`, `BigDripleafBlock`, `BigDripleafStemBlock`,
`NetherFungusBlock`, `HugeFungusFeature`, `NetherrackBlock`,
`HangingMossBlock`, `MossyCarpetBlock`, `BeehiveBlock`, `PumpkinBlock`,
`SweetBerryBushBlock` (decompiled privately).

Not modelled: what a planted huge fungus destroys drops nothing; a
sheared hive releases and angers no bees (none live in hives yet), a glass
bottle takes no honey, and shearing emits no game event.

Two fact sources were fixed on the way. `SupportOracle` seeded every live
neighbour with air only, so a `canSurvive` needing two neighbours at once
never survived: a big dripleaf stem's rule (a stem or soil below, a stem or
leaf above) was constant-false and any vertical update broke stem columns
in play. Live rules now also start from the block itself; only that rule
changed. `ShapeOracle` now analyses bamboo saplings
(`scripts/shape_blocks.txt`), which the live engine had kept unchanged
when a shoot grew above them.

Checks: stage `growth`: GrowthOracle `facts` (2 fungi, 9,185 runs of
states sky light passes down through); 120 scenes of 400 ticks, now with
bamboo groves and lush, pale and crimson floors, match tick by tick:
11,261 bamboo, 62 glow lichen, 326 big dripleaf and 512 stem, 55 crimson
and 45 warped nylium, 338 pale hanging moss and 28 pale moss carpet
writes, 499 bone meals handed to the generator; `features`: 400 bone meal
placements, 60 planted huge fungi among them, equal vanilla's block for
block. Stages `support` and `worldgen_shapes`: the regenerated facts.
`check_vanilla.py --changed --regen`: 108 of 108 stages. `cargo test -p
valimc_core`; `test/growth_test.exs`: shears carve a pumpkin toward the
click and drop its seeds, and a fungus grows its huge fungus through the
owner, with the other affected owner and placement suites (54 tests).

Client (pending, for the milestone's batched run): bone meal on a bamboo
sapling and stalk grows bamboo; on glow lichen it spreads; on a small
dripleaf a big one grows; on a crimson fungus over crimson nylium a huge
fungus grows; on netherrack beside nylium it turns to nylium; shears on a
pumpkin carve it and drop seeds; shears on a full beehive drop honeycomb.
