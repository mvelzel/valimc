# VMC-029d — Survival block states and shape updates

Status: Awaiting client
Milestone: M3
Depends on: [VMC-029b](VMC-029b.md) (placement), [VMC-077m](VMC-077m.md)
(the block-update engine).

Every block a survival player can obtain places in its vanilla state and
updates as vanilla does:

- **Two-part blocks:** doors, beds and tall plants.
- **Attached blocks:** wall torches, ladders, buttons, levers, signs and
  banners.
- **Oriented blocks:** stairs (with their shapes), slabs (top, bottom,
  double), logs by axis, trapdoors, fence gates and the rest that read the
  click face and the player's facing.
- **Excluded shape updates.** The ones `ShapeOracle` excluded:
  - attached pumpkin and melon stems toward their fruit (a woodland
    mansion's pumpkin room fails its chunks);
  - observers;
  - kelp, weeping, twisting and cave vine plants.
- **Coverage matrix.** A placement oracle drives one coverage matrix of
  every item's placed states, which VMC-030 later grows.

Acceptance:

- The placement matrix matches the oracle for every survival-obtainable
  block.
- `ShapeOracle` reports no excluded state.
- The mansion seed that failed generates whole.

## Design

### Shape updates

`ShapeOracle` now answers what the excluded updates asked for:

- the registries (an attached stem names the stem it becomes by registry
  key): the built-in ones;
- whether a block tick is scheduled (an observer schedules its pulse only if
  none is): none. That is exact, because levels and proto chunks keep one tick
  per position and type, so scheduling it again changes nothing;
- one `nextInt(bound)` draw (a vine or kelp plant whose head was removed
  becomes a head of random age): the outcome lists the new state per drawn
  value, and the rule engine draws from the level's random after the rule's
  reads (`Shapes::update`, `Rules::table_update`).

### Placement facts

`PlacementOracle` tabulates what vanilla's `BlockItem.useOn` does with every
block item: it runs `BlockItem.place` (`canPlace`, `updatePlacementContext`,
`getPlacementState` with obstruction left to ValiMC, `placeBlock`,
`setPlacedBy`) in a probe level whose cells and click are inputs. The
outcome is every cell written, relative to the target: the placed block, a
door's upper half, a bed's head, the water or air above a tall plant, or a
refusal. Randoms drawn (a kelp's age) make an outcome of alternatives.

A placement's inputs, each with a small domain:

- the clicked face and whether the clicked block is replaced
  (`replaceClicked`);
- the player's view: `Direction.orderedByNearest` (48 orders), the vertical
  and horizontal direction, and the rotation (its 16 segments split at the
  horizontal direction's boundaries, 20 classes);
- the cursor (below, at or above the middle on each axis) and sneaking;
- the target's raw brightness and whether it sees the sky (crops,
  mushrooms), and whether the target and the cell above it receive redstone
  power (doors, trapdoors, fence gates, heads, lamps);
- the cells around the target within two blocks, each through a partition of
  all states found as `ShapeOracle` finds them.

Per item the oracle tabulates an outcome for every combination and writes
the result as one decision diagram shared by all items: a node tests an input
or a cell's class, equal nodes are shared and a test whose branches agree is
left out. Partitions factor the state's fluid out, since waterlogged states
alternate with dry ones. Whether a click replaces the clicked block is a rule
per state over the held item (its block's own or not), the face, the cursor
and sneaking.

Stairs, fences, bars and panes, walls and redstone wire read their neighbours
as air in the facts and leaves read no distance. ValiMC applies their shape
updates (`connect.rs`, `redstone.rs`) and leaf distance afterwards, and the
oracle checks on random neighbourhoods that vanilla's placement equals that
composition. Two outcomes are code: scaffolding clicked on scaffolding walks
along the column to the first free cell (`ScaffoldingBlockItem`), and a pale
moss carpet places with the carpet code decoration uses (its sides and the
topper it draws). The matrix covers them with real clicks like the rest.

### Live placement

`Valimc.Blocks.Placement` picks the target (the clicked block when the held
item replaces it, else the cell beside the clicked face) and the click's
inputs. The player's group then evaluates the rules (`Region.placement/4`,
`Rules::place`), which add the target's light and redstone power and read the
cells across the group's sections. The plan checks that every write lies in
the target's section, refuses a chest that would join a double chest
(VMC-032b), and checks the main block against the bodies there. The commit
(`Region.place_block/4`) takes up to three writes under the section's fence.
A survival player's stack shrinks by one; a powder snow bucket leaves a
bucket. Operator blocks place only for creative operators. Lily pads and
frogspawn place by use, not by a click on a block: the player's ray through
water sources (VMC-031a's) finds the source looked at, and the item places as a
click on the cell above it (`PlaceOnWaterBlockItem.use`).

Signs, hanging signs, banners, mob heads, decorated pots and bells place as
block entities without data (a blank sign, a plain banner). Stacks with
component changes for a block with a block entity (a named or patterned
banner) are corrected, as are blocks whose block entity has no owned record
yet (barrels, hoppers and the other containers, VMC-032).

The per-class placement callbacks (`Slab`, `Pillar`, the chest's and
furnaces') and the creative fallback that placed default states are gone,
with the facts they read.

## Not modelled here

- Repeaters and comparators ([VMC-048a](VMC-048a.md)) and creaking hearts (awake by
  the time of day, with the creaking).
- Redstone power as a placement input comes from the block facts' signals and
  powered wire; comparators', trapped chests' and other block entity signals
  read 0, as for wire.
- `onPlace` reactions: rails connecting, sponges absorbing, falling blocks,
  TNT lit by power.
- Sign editing after placement, banner patterns and other block entity data
  (VMC-032).
- A door's or bed's other half across a section line is refused.
- Live shape updates of placed blocks that worldgen never places
  (`ShapeOracle` analyses the blocks worldgen names; breaking updates come
  from live survival facts, connections and doors from code).

## Evidence

October 23, 2026, on the host's ten cores.

- `ShapeOracle`: 4,572 states analysed, 4,041 with rules (5,531 rules, 2,557
  outcomes), excluded none; stage `worldgen_shapes` regenerates
  `priv/worldgen/shapes.json` byte-equal. `test/shape_updates_test.exs` (an
  attached stem whose pumpkin goes, a kelp plant whose head goes, an observer
  before a change) fails on the old facts and passes on the new ones; the old
  facts failed exactly these updates in decoration, which is how a mansion's
  pumpkin room (`woodland_mansion/1x2_a8`, the only template with attached
  stems) lost its chunks. The failing mansion (seed -779151933078932174,
  default settings, chunks -1241..-1237 by 1303..1305): with the old facts
  regions (-155, 162) and (-155, 163) fail decorating chunk (-1239, 1304) on
  state 10068 toward north, as the dev server logged; with the new facts all
  four regions around it generate.
- `PlacementOracle` (3,800 s, stage `placement`): 1,138 block items in one
  diagram of 36,008 nodes over 284 partitions and 343 outcomes, 9 replacement
  rules; `priv/physics/placement.json` is 2.3 MB. Excluded: repeaters,
  comparators, creaking hearts. The coverage matrix, 110,232 random clicks
  from real yaw and pitch, matches vanilla case by case; 11,370 consumption
  cases match.
- `check_vanilla.py --changed --regen`: 94 of 94 stages pass (every
  decoration, structure and live generation stage among them), and `tcp`.
- Affected tests: 56 pass, among them the door's two halves at the owner, a
  lily pad used on water and refused on a click, and the existing placement,
  chest, cooking and bucket connection tests.

## Client scenario (phase-end handoff)

Survival, fresh flat world: place and look at

1. an oak door from each side (lower and upper half, hinge beside another
   door), a bed (foot and head), a sunflower, and a small dripleaf;
2. a wall torch, ladder, lever on a wall and a floor, a stone button on a
   ceiling, an oak sign on a wall and standing (16 directions), a white
   banner on a wall and standing;
3. oak stairs (top and bottom halves, a corner where two meet), a top, bottom
   and double slab, a log on each axis, an oak trapdoor on the upper half of a
   wall, a fence gate between walls, a fence beside a fence, a glass pane;
4. a candle stacked to four, a sea pickle in water, snow layers, a waterlogged
   slab, scaffolding built up and out along a column, a lily pad used on water
   (a click on the water's block places none);
5. reconnect: everything is unchanged.

Mining what was placed belongs to [VMC-029e](VMC-029e.md); survival mining still
corrects most of these blocks.
