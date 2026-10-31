# VMC-034o — Brewing and potions

Status: In progress
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
