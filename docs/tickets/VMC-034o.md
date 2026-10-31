# VMC-034o — Brewing and potions

Status: Awaiting client
Milestone: M4
Depends on: [VMC-037p](VMC-037p.md) (every effect), [VMC-034n4](VMC-034n4.md)
(furnaces, the model for a ticking container),
[VMC-037o](VMC-037o.md) (splash potions and arrows).

Brewing as 26.3 has it, and every way a potion reaches the world.

26.3's brewing is data-driven:
- 279 `minecraft:brewing` recipes, each an input (item and potion), a
  reagent item and an output stack;
- the `brewing_reagents` and `brewing_inputs` property sets, plus the
  `brewing_potion_inputs` item tag;
- the `brewing_fuel` item component (blaze powder: `brewing/uses_default`
  20 uses, `brewing/speed_default` 1.0).

Every one of these is generated from the jar.

The work comes in three slices:

| Slice | Scope |
|---|---|
| 034o1 | Brewing facts and the stand's tick |
| 034o2 | The brewing stand block, its menu and hoppers |
| 034o3 | Lingering potions and clouds, tipped arrows, cauldrons |

## 034o1 — Facts and the tick

Acceptance:
- **`BrewingOracle facts`** writes `priv/crafting/brewing.json`: the recipes
  in recipe-manager order, the reagent and input sets, and the fuel items'
  uses and speed. A `same` stage holds it equal.
- **`Valimc.Blocks.Brewing`** is `BrewingStandBlockEntity.serverTick` as a
  pure step over the five slots and the brew time, fuel, totals, speed and
  remembered ingredient. It covers:
  - refuelling, and a fuel's remainder;
  - starting a brew (`ceil(400 / speed)`);
  - stopping when the ingredient changes or nothing is brewable;
  - brewing every bottle, and the ingredient's remainder or drop;
  - the `has_bottle_*` states, and level event 1035.
- **`brewing_tick`** runs vanilla's `serverTick` over scripted slot changes
  and ticks, and ours equals it after every tick.

## 034o2 — The stand

Acceptance:
- **The block.** Placing a brewing stand makes its owned five-slot entry.
  It ticks only while brewing, holding fuel or holding bottles; it keeps its
  times across a restart; breaking it spills its contents.
- **The menu.** The `brewing_stand` menu has vanilla's slots and rules:
  - bottles stack to 1 and must be potion inputs;
  - the ingredient slot takes reagents and the fuel slot fuel;
  - shift-clicks route by `quickMoveStack`;
  - the four data slots show brew time and fuel.

  Each click is a durable transaction as a furnace's is. The menu oracle
  stages compare clicks with vanilla.
- **Hoppers.** They feed the ingredient from above and fuel and bottles
  from the sides, and take bottles (and a glass-bottle ingredient) from
  below (`getSlotsForFace`, `canPlaceItem`, `canTakeItemThroughFace`).

## 034o3 — Potions in the world

Acceptance:
- A thrown lingering potion makes an area effect cloud as vanilla does,
  checked against the projectile oracle.
- A tipped arrow gives every effect of its potion at an eighth of its
  duration, and arrows dipped in a lingering potion are crafted
  (`TippedArrowRecipe`).
- A water bottle fills a cauldron a level and an empty bottle takes one
  back, matching `CauldronInteraction`.

## Results

### 034o1

- **Facts.** `BrewingOracle facts` → `priv/crafting/brewing.json`
  (`brewing_facts`). It holds:
  - 279 recipes, each of one input item and potion, one reagent item and one
    output item and potion, no two matching one input;
  - 21 reagents;
  - 4 potion inputs (`glass_bottle`, `potion`, `splash_potion`,
    `lingering_potion`);
  - blaze powder (20 uses, speed 1.0);
  - dragon's breath's glass bottle.

  The extractor checks every one of these shapes.
- **The tick.** `Valimc.Blocks.Brewing.tick/2` is `serverTick` over the
  slots. A fresh stand's totals are 0; a saved one without them reads 400
  and 20.
- **Oracle.** `brewing_tick` runs vanilla's `serverTick` over 10 scripts.
  They cover:
  - water to awkward;
  - splash to lingering with dragon's breath (its bottle replacing the last
    one, or dropping beside a stack);
  - a changed ingredient;
  - waiting for fuel;
  - bottles taken mid-brew;
  - glass bottles;
  - stone's infestation;
  - mixed bottles.

  Ours equals vanilla after every step.

### 034o2

- **The block.** `BrewingStandBlock` → `Valimc.Blocks.BrewingStand`,
  block-entity kind `:brewing_stand`.
- **The entry.** Placing a stand creates `%{kind: :brewing_stand, brewing:
  %Brewing{}}` (container tag 5: times, speed, ingredient, shown bottles, five
  slots).
  - Breaking it spills the slots (`ContainerSpills`).
  - Comparators read its five slots.
  - Anvil import and export carry `Items`, `BrewTime`, `total_brew_time`,
    `Fuel`, `total_fuel` and `speed_multiplier`.
  - A generated stand that holds potions stays preserved, as a filled
    generated furnace does.
- **The tick.** Stands tick in the furnaces' worker pass
  (`CookingRuntime`/`CookingBatch`). The steps:
  - the bottle states commit as a furnace's `lit` does;
  - remainders drop as a furnace's do;
  - level event 1035 is published with the commit;
  - viewers get `container_progress` for the data slots.

  Timer-only changes wait for a checkpoint, as a furnace's do.
- **The menu.** `Menu.brewing/0` (window type 11) with vanilla's slot rules,
  bottle limit 1 and `quickMoveStack` routes; the four data slots are brew
  time, fuel and their totals. Clicks go through `ContainerClicks`, fenced
  on the entry's revision as a furnace's are.
- **Hoppers** (`ItemTransfer`) use its faces:
  - from above, the ingredient;
  - from the sides, empty bottle slots and the fuel;
  - from below, the bottles, and the ingredient only as a glass bottle.
- **Oracle.** `brewing_click` (`BrewingClickOracle`): 5,760 vanilla
  `BrewingStandMenu.clicked` cases (pickups, shift-clicks and swaps over two
  layouts) and every stock item's shift route equal ours; the window type is
  vanilla's.
- **Tests.**
  - `brewing_region_test`: a brew through the owner, the block's bottles,
    the times across a restart, clicks and hopper faces.
  - `brewing_connection_test`: a player opens a stand, sees its 41 slots and
    4 data values, and shift-clicks fuel in.

### 034o3

- **Lingering potions.**
  - Thrown by players and dispensers, a lingering potion flies as a splash
    potion does. Where it breaks it leaves `EffectCloud.lingering/3`:
    - radius 3, shrinking by `-3/600` a tick and by half a block on each touch;
    - 10 ticks' wait and 600 ticks' duration;
    - its potion at the item's `potion_duration_scale` (0.25), instant
      effects at half strength;
    - a particle of the potion's opaque colour.
  - A potion without effects leaves no cloud. The splash level event (2002
    or 2007) goes out either way.
  - Players and mobs take the cloud's effects through the splash paths.
- **Potion colours.** `PotionContents.color/1` (`PotionContents.getColor`:
  a custom colour, else the visible effects mixed by amplifier, else water's
  blue) now colours splash events, clouds and tipped arrows. The
  `potion_colors` stage checks 246 vanilla colours.
- **Tipped arrows.**
  - A tipped arrow carries every effect of its potion at its duration scale
    (0.125) and shows its colour (`arrow_color`).
  - A hit adds them all, to players and to mobs (the native `Hit.effects`
    list).
  - Eight arrows around a lingering potion craft eight tipped arrows of its
    potion (`TippedArrowRecipe`).
- **Cauldrons.** `Valimc.Blocks.Cauldron`:
  - a water bottle pours a level into an empty or not yet full water
    cauldron and leaves a glass bottle;
  - a glass bottle takes a level back as a water bottle;
  - each plays `item.bottle.empty` or `item.bottle.fill`.

  The owner edits the block through the rule run; the hand's item changes
  as a bucket's does. A sneaking player uses the item instead.
- **Tests.** `potions_in_world_test`: the cloud's wait, quarter durations and
  shrinking; a tipped arrow's effects, colour and recipe; the cauldron's
  levels.

## Left for later

- A splash or lingering potion's water effects (hurting water-sensitive
  mobs, putting out fire, rehydrating axolotls) and fire dousing.
- Filling a glass bottle from water, and buckets on cauldrons.
- A cloud's touch on an entity that refuses all its effects still counts.
- Wind charges trigger blocks; see [VMC-037p](VMC-037p.md).

## Awaiting client

In M4's batched run:
- **Brewing:** a stand placed and opened shows its screen; with blaze powder
  and water bottles it brews nether wart into awkward potions. The bubbles and
  progress arrow run for 20 seconds, the bottles show on the block, and the
  brew ends with its sound. Splash and lingering upgrades work, as does a
  hopper feeding the stand from above and the side and taking from below.
- **A thrown lingering potion** leaves a cloud of its colour that gives its
  effect and shrinks.
- **Tipped arrows** crafted in a table and shot give their effect.
- **Cauldrons:** a water bottle fills a cauldron and a glass bottle empties it.
