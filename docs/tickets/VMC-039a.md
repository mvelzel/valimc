# VMC-039a — Crops, plants and saplings grow

Status: In progress
Milestone: M3
Depends on: [VMC-029d](VMC-029d.md), [VMC-066](VMC-066.md) (random ticks).

What a survival farm needs, by random ticks:

- crops (wheat, carrots, potatoes, beetroot) with light and farmland
  hydration;
- pumpkin and melon stems growing their fruit;
- sugar cane and cactus (their placement survival from VMC-066 first);
- saplings growing into trees, reusing generation's tree code;
- bone meal, farmland drying and trampling (mobs too, after VMC-015i),
  and the seeds and crops these drop.

Acceptance:

- Growth chances and outcomes match the oracle at the same random ticks.
- A farm grows on the real client.

Slices:

- **039a1 Growth by random ticks** (done): `valimc_core::rules::growth` runs
  the random ticks of crops (`CropBlock`, beetroot's skipped third),
  pumpkin and melon stems and their fruit, sugar cane, cactus (and its
  flower), farmland (water within 4, rain above, drying to dirt unless a crop
  keeps it) and saplings' and propagules' stages on the block-update engine,
  with vanilla's draws. Light is the stores' raw brightness (sky minus the
  day's darkening for saplings). Farmland and dirt paths that cannot
  survive turn to dirt at their tick. The owner's sampler hands the growing
  blocks' randomly ticking states to the rules with lava's
  (`Valimc.World.Growth`); rain above a farmland comes from the owner's
  published heights and biomes while the weather is wet.
- **039a2 Saplings' trees and bone meal** (done): a sapling's tick (or bone
  meal) that grows its tree answers 2; the tree grows in a task as
  `/place feature` places one (`Placement::Sapling`, `TreeGrower.growTree`:
  mega trees over a 2 × 2, flower trees beside flowers, saplings restored
  when the tree does not fit), then commits in one box edit fenced on the
  states it replaced. Decoration now parses every tree feature, placed by a
  biome or not. Bone meal (`BoneMealItem.useOn` on what this slice grows)
  runs in the rules: crops, stems (a grown stem ticks at once), saplings
  (`canGrow`'s draws, the build height, 45 %) and propagules; the level
  event 1505; one used up in survival.
- **039a3 Tilling and trampling** (planned): the hoe's block transformer
  (with the shovel's and axe's, one mechanism), and farmland trampled by
  falling players and mobs.

Reference: pinned 26.3 `CropBlock`, `BeetrootBlock`, `StemBlock`,
`AttachedStemBlock`, `SugarCaneBlock`, `CactusBlock`, `FarmlandBlock`,
`SaplingBlock`, `MangrovePropaguleBlock`, `TreeGrower`, `BoneMealItem`,
`BlockScanUtils` (decompiled privately). Seeds and produce drop through the
loot tables VMC-029e runs.

Not modelled: bone meal on blocks this slice does not grow (grass, flowers,
water plants and the rest); a grass block's own random tick; entities
pushed up when farmland turns to dirt; bees in a grown tree's hive.

Checks: stage `growth`: GrowthOracle `facts` (11 tree growers, 10
saplings, `priv/physics/growth.json`); 120 scenes of 400 ticks match tick by
tick (cells, level events, results; 2,283 crop and 614 stem writes, 135
fruits, 90 cactus flowers, 183 farmland dried, 1,224 sapling stages, 1,563
trees decided, 2,022 bone meals taken); 600 trees (372 grown, 207 over a
2 × 2) equal vanilla's `growTree` block for block. `test/growth_test.exs`:
crops, cane and drying in a stepped owner, a sapling's tree, bone meal.
