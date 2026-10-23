# VMC-029e — Survival mining of every block

Status: Done
Milestone: M3
Depends on: [VMC-029a4](VMC-029a4.md) (block loot), [VMC-029d](VMC-029d.md)
(placed states), [VMC-072](VMC-072.md) (the loot evaluator).

Survival mining admitted only some states:

- about 359 cube and pillar states;
- slabs;
- blocks with block entities;
- four random-loot profiles.

`Player.Mining.supported?` corrected every other block back to the client.
That included leaves, flowers, plants, torches, doors, beds and ores whose
drops depend on Fortune.

The survival run needs them all:

- every block's hardness, tool and harvest rules from the block facts;
- its loot table, with every vanilla loot function and condition the
  survival blocks use (Fortune, shears and Silk Touch already work);
- what breaking two-part and attached blocks also breaks, as vanilla does.

Acceptance:

- Every survival-obtainable block mines with the oracle's break time and
  drops.
- No survival block is refused.

## Design

### Every block's loot through one evaluator

The deterministic catalog (`physics/mining_loot.json`) and the four random
profiles (`physics/random_mining_loot.json`) are gone, with their oracles,
their stages and the chest and cooking self-loot stages they made redundant.
Every block's loot table now runs through the native evaluator VMC-072 built
(`valimc_core::loot`), which gained a block break context
(`LootContextParamSets.BLOCK`):

- the block state, the tool (its item and enchantments), whether an entity
  broke it, an explosion's radius, and the blocks above and below it;
- conditions: `survives_explosion`, `match_block`, `match_tool` (items, item
  tags and enchantment levels), `table_bonus`, `location_check` with a block
  predicate, `entity_properties` on the breaker, and the named predicates
  `tool/can_silk_touch` and `tool/can_shear` refer to;
- functions: `apply_bonus` (ore drops, uniform and binomial bonus counts),
  `explosion_decay`, `limit_count`, `copy_state`, and `copy_components` from
  the block entity;
- the `binomial` number provider and `dynamic` entries (a cracked pot's
  sherds).

`LootOracle facts` now writes every block's table into `priv/loot/tables.json`
(1,271 tables), the named predicates into `registries.json`, and
`priv/loot/blocks.json`: each block's table in registry order and the
experience a harvest pops.

Block entities ValiMC places carry their item's defaults, so `copy_components`
copies nothing a patch would keep, and a decorated pot's sherds are four
bricks. Items gain the `minecraft:block_state` component (`copy_state`: a
beehive's honey level, a copper golem statue's pose), and the item defaults
record it.

`Blocks.MiningLoot` is the one entry: `drops/3` (the state, its position, the
tool, breaker, radius and neighbours) and `experience/2`. Vanilla draws a
block table from the world's random sequence for that table; a fresh seed per
break gives the same distribution, as VMC-037n does for mob loot.

### The break

`Player.Mining` no longer filters states: every block but air starts an
attempt, and hardness, tool speed and harvest permission already came from the
block facts for every state (stages `mining`, `mining_tool`, `player_mining`).
A completed attempt reads the blocks above and below and commits the plan of
`Blocks.Breaking`, which follows `ServerPlayerGameMode.destroyBlock`:

- `playerWillDestroy`:
  - a tall plant (`DoublePlantBlock` and its subclasses) drops its loot with
    the player's tool, harvested or not;
  - a door's upper half broken without its tool takes the lower half without
    drops;
  - a tool in `#breaks_decorated_pots` without Silk Touch cracks a decorated
    pot, which then drops its sherds.
- The cell becomes its fluid.
- `playerDestroy`, with the right tool:
  - the loot of the state with the original tool and the player as breaker;
  - the experience `spawnAfterBreak` pops (ores, sculk, spawners; none with
    Silk Touch, except a spawner's);
  - food exhaustion;
  - ice melting into water above a melting block or a liquid (not with Silk
    Touch, not where water evaporates);
  - a turtle egg cluster losing one egg.

`Region.mine_block/4` takes the plan's writes (expected and new state per
cell) with the drops and orbs, and commits them in one call. Drops pop like
`Block.popResource`.

What the change does to its neighbours (a door's or bed's other half, a tall
plant's, a torch or flower losing its support) stays with the block rules
(VMC-077m): the commit starts their updates, and each block they destroy drops
its tool-less loot. Those drops now read the blocks around them as vanilla
destroys them in order, with the ones destroyed before already gone, so a
tall plant whose support goes drops once. Explosions pass their radius and
source, so `survives_explosion` and `explosion_decay` come from the tables.

Reference: the pinned 26.3 jar (Vineflower 1.12.0, ignored
`research/decompiled/vmc-029e`): `ServerPlayerGameMode.destroyBlock`,
`Block.playerWillDestroy`/`playerDestroy`/`dropResources`/`popExperience`,
`BlockBehaviour.getDrops`/`spawnAfterBreak`, `DoublePlantBlock`, `DoorBlock`,
`IceBlock`, `TurtleEggBlock`, `DecoratedPotBlock`, `DropExperienceBlock`,
`RedStoneOreBlock`, the sculk blocks, `SpawnerBlock`, `LootContext`,
`ApplyBonusCount`, `ApplyExplosionDecay`, `ExplosionCondition`,
`BonusLevelTableCondition`, `MatchTool`, `LocationCheck`,
`LootItemEntityPropertyCondition`, `CopyBlockState`, `CopyComponentsFunction`,
`LimitCount`, `BinomialDistributionGenerator`, `PotDecorations`.

## Not modelled here

- Imported block entities holding data (a generated bee nest with bees, a
  decorated pot with sherds or loot) keep their block (VMC-021e1): releasing
  bees needs the bee entity (VMC-043c).
- Infested blocks drop as vanilla but spawn no silverfish (VMC-043b), and an
  unstable TNT is not primed when mined.
- Piglins angered by mining gold-guarded blocks (VMC-043d), the
  `BLOCK_MINED` statistic and game events.
- Shears disarming a tripwire before it breaks (VMC-048a).

## Evidence

October 23, 2026.

- `LootOracle facts` (stage `loot`): 1,271 loot tables (69 named by
  containers), 43 enchantments, 1,658 items; 18 blocks pop experience, each
  checked against `spawnAfterBreak` over 400 seeds with and without Silk Touch.
- `LootOracle blocks` and `check_block_loot.exs` (stage `block_loot`): 54,507
  vanilla breaks over all 35,547 states with a loot table: every context for a
  block's default state, one random context for each other state. Contexts:
  an empty hand, pickaxes with Fortune I–III, 255 and Silk Touch, shears,
  axes, hoes, swords, shovels, enchantments stored instead of applied, no
  breaker, explosions of radius 1 to 8, random blocks above and below, block
  entities as placing their plain item makes them. All 47,797 stacks equal
  vanilla's.
- `ItemMetadata` (stage `item_metadata`): 12 items carry a default
  `block_state`.
- Tests: `mining_test.exs` (loot and experience, harvest, a tall plant read
  through its other half, a door's lower half taken without drops, ice
  melting, turtle eggs, pots cracking), `player_mining_connection_test.exs`
  (a door mined from its lower half breaks whole with one drop; a diamond ore
  drops a diamond and experience), and the region, placement, chest spill,
  explosion, loot, item and support suites.
- `check_vanilla.py --changed --regen`: 177 of 177 stages pass (`loot`,
  `block_loot`, `item_metadata`, `explosion` and `tcp` among them).

## Client scenario (phase-end handoff)

Survival, fresh default world, with an iron pickaxe, a Fortune III pickaxe,
a Silk Touch pickaxe, shears and an axe:

1. Mine oak leaves by hand (sometimes a sapling or stick) and with shears
   (the leaves); grass and a tall grass with shears and by hand.
2. Mine coal, iron, diamond and redstone ores with the iron pickaxe and the
   Fortune pickaxe (more drops, experience orbs) and with Silk Touch (the ore,
   no experience).
3. Place and mine an oak door from each half, a bed from its foot, a
   sunflower from its top, a wall torch, and the block under a standing torch:
   each drops one item (and the block its own).
4. Mine ice over stone (water appears), snow layers with a shovel
   (snowballs), a decorated pot with the pickaxe (four bricks) and by hand
   (the pot).
5. Reconnect: the drops and the broken blocks are unchanged.

## Client runs (October 23, 2026; flat world; `.local/client-tests/M3-phase2/`)

Run 1 (frozen `cab65365`, `run-05`, `run-06`): leaves by hand (sticks,
saplings, an apple) and with shears, grass and tall grass with shears and by
hand, the four ores with an iron pickaxe (and experience), Fortune III (more)
and Silk Touch (the ore, no experience), ice melting over stone, snow layers
with a shovel, a decorated pot with a pickaxe (four bricks) and by hand (the
pot), a door from its lower half, a bed from its foot and a wall torch all
dropped as vanilla's, and the broken area and its drops were unchanged after
a reconnect. A door mined from its upper half, a sunflower from its top and
the block under a standing torch dropped nothing for the block the rules
removed: `mine_block` replaced the section's item store with the spill
plan's after the rules had added their drops. Fixed in `0b70277e` (the
spill's store goes first), with the door test now mining the upper half.

Run 2 (frozen `0b70277e`, `run-07`): the upper door half, the sunflower's
top and dirt and stone under a torch each dropped the door, sunflower and
torch once, and the controls still dropped one item each.
