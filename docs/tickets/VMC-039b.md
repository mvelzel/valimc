# VMC-039b — The rest of a farm's growth

Status: Awaiting client
Milestone: M3
Depends on: [VMC-039a](VMC-039a.md).

What else random ticks and bone meal touch on a survival farm:

- grass blocks and mycelium spreading onto dirt and dying under cover;
  nylium dying;
- torchflowers, pitcher crops, nether wart, cocoa, sweet berries, kelp and
  the vines growing;
- bone meal on the remaining `BonemealableBlock`s a survival run meets,
  and on water;
- what a block interaction drops (sweet berries and glow berries picked,
  rooted dirt tilled).

Acceptance:

- Growth chances and outcomes match the oracle at the same random ticks.
- Picking berries drops what vanilla's interaction loot tables give.

Slices:

- **039b1 Random ticks and bone meal in the rules** (done):
  `valimc_core::rules::plants` on `growth`'s kinds and plans. Random ticks:
  grass blocks and mycelium (`SpreadingSnowyBlock`: dirt under a state they
  die under, else four tries to spread onto dirt at light 9, snowy under
  snow), nylium (netherrack), torchflower crops (crops whose last age is the
  torchflower, a third of ticks skipped), pitcher crops (`PitcherCropBlock`,
  the upper half from age 3), nether wart, cocoa, sweet berries and the
  heads of kelp, weeping, twisting and cave vines (`GrowingPlantHeadBlock`,
  berries by chance). Which states smother grass and nylium are GrowthOracle
  facts (`smothers`, from `canStayAlive` and `canBeNylium`). Bone meal
  (`BoneMealItem.useOn`): torchflowers, pitcher crops, cocoa, sweet
  berries, kelp and the Nether's vines from head or body (cave vines: their
  berries), short grass and ferns (their tall halves), tall flowers and full
  flower beds (a copy pops: result 3, the owner drops the block's item),
  flower beds' amount, seagrass, bushes, firefly bushes and dry grass
  (`findSpreadableNeighbourPos`), sea pickles on coral, mangrove leaves (a
  hanging propagule), rooted dirt (hanging roots) and azaleas (their tree,
  as a sapling's, from the facts' `azaleas`); and, when the clicked block
  takes none, the water beside a sturdy clicked face (`growWaterPlant`:
  seagrass, and corals from the `wall_corals` and `underwater_bonemeals`
  tags where the biome beside the face grows them). Live corals out of water
  die at their scheduled tick (`CoralBlock.tick` and the plants'), which no
  rule ran before.
- **039b2 Bone meal that places features** (done): on a grass block with
  air above, nylium, moss or a mushroom (`MushroomBlock`'s 40 % first) the
  rules answer 2, as a sapling's tree, and the owner grows it in a task
  through the generator with the task's own random
  (`Growth::generated` → `Placement::grown`): a grass block's 128 tries
  (`GrassBlock.performBonemeal`: the `grass_bonemeal` placed feature, short
  grass grown tall, one in eight a feature of the biome's bone meal
  features, a GrowthOracle fact), nylium's and moss's feature above them
  (`/place feature`'s), a mushroom's huge mushroom (`growMushroom`: the
  mushroom back when it does not fit). Every configured feature now parses
  in a decoration. The box edit that commits it runs its cells' shape
  updates in the owners, as vanilla's live writes run them.
- **039b3 Interaction loot** (done): `LootOracle facts` adds every
  `block_interact` table (`harvest/sweet_berry_bush`, `harvest/cave_vine`,
  `till/rooted_dirt`, `harvest/beehive`, `carve/pumpkin`) to
  `priv/loot/tables.json`. A player's use of a sweet berry bush past age 1
  (not a growing one with bone meal in hand: that is bone meal's) or cave
  vines with berries picks them (`Valimc.Blocks.Harvest`, the rules'
  `{:harvest, position}` before redstone's uses and menus): the owner rolls
  the table for the berried state, pops each stack and plays the pick sound
  to everyone near. A transformer entry with loot (a hoe on rooted dirt)
  rolls it for the tilled block and pops it from the clicked face
  (`ItemDrop.pop_from_face`) or the middle, in the owner.

Reference: pinned 26.3 `SpreadingSnowyBlock`, `SnowyBlock`, `GrassBlock`,
`NyliumBlock`, `TorchflowerCropBlock`, `PitcherCropBlock`, `NetherWartBlock`,
`CocoaBlock`, `SweetBerryBushBlock`, `GrowingPlantHeadBlock`,
`GrowingPlantBodyBlock`, `KelpBlock`, `WeepingVinesBlock`,
`TwistingVinesBlock`, `CaveVinesBlock`, `NetherVines`, `TallGrassBlock`,
`TallFlowerBlock`, `FlowerBedBlock`, `SeagrassBlock`, `BushBlock`,
`FireflyBushBlock`, `ShortDryGrassBlock`, `TallDryGrassBlock`,
`SeaPickleBlock`, `MangroveLeavesBlock`, `RootedDirtBlock`, `AzaleaBlock`,
`BoneMealItem`, `BonemealableBlock`, `BlockUtil`, `CoralBlock`,
`CoralPlantBlock`, `CoralFanBlock`, `CoralWallFanBlock` (decompiled
privately).

Not modelled: a corals biome is the clicked water's for every cell vanilla
tries; a grass block's draws before the generator are the task's, not the
level's; the sweet berry bush's game events. Bone meal on netherrack,
fungi, bamboo, glow lichen, dripleaves, hanging moss and pale moss carpets,
and shears on hives and pumpkins, are [VMC-039c](VMC-039c.md)'s.

Checks: stage `growth`: GrowthOracle `facts` (11 tree growers, 10
saplings, 2 azaleas; grass dies under 7,123 runs of states, nylium 574; 43
biomes with bone meal features, 2 mushrooms, 4 feature placers); 120
scenes of 400 ticks (farms with torchflowers and pitcher crops, cane and
cactus beds, saplings, meadows, sea beds three deep, Nether plants, cocoa,
vines and what hangs from a ceiling; a warm-ocean biome in a third) match
tick by tick: 622 grass and 115 mycelium spreads, 363 nylium deaths, 97
torchflowers, 382 pitcher, 258 wart, 297 cocoa and 241 berry writes, 546
kelp and 2,243 vine head writes, 298 tall grass, 2,036 tall seagrass, 105
corals, 30 coral blocks dead, 3,476 bone meals used, 244 with a copy
dropped and 482 handed to the generator; 600 trees, azaleas among them,
equal vanilla's `growTree`; `features`: 400 bone meal placements (grass
blocks in ten biomes, moss, nylium, mushrooms: 379 grown, 21 mushrooms that
did not fit) equal vanilla's block for block on plots whose covers stand
(pale moss is left out: its carpets' sides settle by shape updates, which
the owner runs after the commit). Stages `loot` (1,279 tables) and
`block_loot`: 864 block interactions (every state of the blocks each table
serves, eight seeds each, an empty hand or a tool) drop what vanilla's
tables give. `test/growth_test.exs`: a sunflower's copy, seagrass from
water and a grass block's growth through the generator; berries picked from
a bush and cave vines (a growing bush gives way to bone meal) and rooted
dirt's hanging roots, through the owner; grass spreads in its owner.

Client (pending, for the milestone's batched run): grass spreads onto a
dirt patch in daylight and dies under a placed stone; bone meal on grass
grows grass and flowers, on short grass a tall plant, on a sunflower a
dropped sunflower; on water in a
river seagrass; a sweet berry bush grows and picking it drops berries;
cocoa on a jungle log ripens; kelp grows up to the surface.
