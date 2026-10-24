# VMC-049a — Hoppers, droppers and dispensers

Status: Done
Milestone: M3
Depends on: [VMC-047a](VMC-047a.md), [VMC-037o](VMC-037o.md) (dispensers
shoot projectiles), [VMC-032](VMC-032a.md) (containers).

Item machines, as vanilla's `HopperBlockEntity`, `DispenserBlock` and
`DropperBlock`:

- **Hoppers:** cooldowns, pulling items from containers and item entities
  above them, pushing into containers including furnaces by side, and
  locking by power.
- **Droppers:** they drop items.
- **Dispensers:** each item's dispense behaviour, which includes
  projectiles, buckets with VMC-031a, bone meal with VMC-039a, armour,
  boats deferred, TNT and fire charges.
- **Menus:** each block's menu.

Transfers are ordered and atomic in the group's commit and never duplicate
items. Transfers reach sibling sections of the same owning group; an
unloaded target outside that group is unavailable.

Acceptance:

- Transfer-order fixtures (hopper chains, furnace feeding, item pickup)
  match the oracle.
- No item duplicates or vanishes under concurrent group ticks or a crash.
- A hopper-fed furnace works on the real client.

## What is live

- **Blocks** (`Blocks.Machine`): hoppers, droppers and dispensers own a
  container entry (`Containers.create_machine/4`: 5 or 9 slots, a hopper's
  `TransferCooldown`, and the revision it was created at, the order block
  entities tick in), persisted as tagged records of the containers part. A
  block set without a container plan (a command, a raw write) gets its
  empty entry at once, as vanilla's block entity comes with the block;
  placement plans it; a break spills it in the same commit. A state change
  that keeps the container (a hopper's `enabled`, a dispenser's
  `triggered`, a chest's facing) keeps the entry with its contents.
  Anvil import and export carry them (`Items`, `TransferCooldown`);
  generated ones with loot stay preserved.
- **Rules** (`rules::components`, RedstoneOracle's `hopper` and `dispenser`
  kinds): `HopperBlock.checkPoweredState` on placement and neighbour
  changes; `DispenserBlock.neighborChanged` (power at the cell or above)
  sets `triggered` and schedules the tick 4 later, whose run reports the
  cell (`dispensed`) for the owner to dispense.
- **Hoppers** (`World.Hoppers` over `Blocks.ItemTransfer`, `RegionData.
  hoppers/1` after moving pistons in `TickPipeline`): per tick, first each
  item entity in a hopper's bowl (`entityInside`, in entity order), then
  each hopper in tick order (`pushItemsTick`): cooldown, push one item of
  the first slot that fits into what it faces (`ejectItems`, a furnace by
  face: input from above, fuel from the sides with the bucket rule),
  pull one item from the container above (a furnace gives its result and,
  below, buckets) or take item entities at and above it unless a full
  block covers it (`does_not_block_hoppers` aside), whole or in part; a
  move sets 8, and an empty hopper that receives waits 8, or 7 when it
  already ticked (`tickedGameTime`, kept by the owner in memory).
  Comparators read hoppers, droppers and dispensers (`entry_signal`).
  Double chests expose both physical halves through the shared logical
  container view ([VMC-032b](VMC-032b.md)).
- **Droppers and dispensers** (`Blocks.Dispensing` from DispenserOracle's
  facts, `RegionData.dispense/2`): a random filled slot
  (`getRandomSlot`), else event 1001. A dropper puts one item into the
  container in front, else drops it. A dispenser drops plain items
  (`spawnItem`: 0.7 out, the random push, events 1000 and 2000 with the
  facing); shoots arrows (pickup allowed) and tipped arrows, snowballs,
  eggs, splash potions and fire charges with each item's power, spread,
  event and start; pours water and lava buckets and fills an empty bucket
  through the block rules (`consumeWithRemainder`: the bucket goes into
  the dispenser or drops); uses bone meal (event 1505, the generator's
  growth in a task, a flower's copy); primes TNT (its sound, fails with
  `tnt_explodes` off); and puts dispensable equipment on the first mob in
  front that picks up loot and can wear it (a guaranteed drop, persistent),
  else drops it.
- **Menus**: a hopper opens `minecraft:hopper` (5 slots), a dropper or
  dispenser `generic_3x3` (titled by kind), on the chest click engine and
  `quickMoveStack` routes; viewers refresh when transfers move items.
- **Commits.** A tick's transfers change the section's containers and item
  store in one owner state, so the group's next cut holds all of them or
  none: a crash loses whole ticks. An insert into a container of a sibling
  section is that section's effect, applied before the cut (what no longer
  fits drops there, never lost). Nothing a hopper or dropper reaches lies in
  another group: the regionizer keeps different groups' loaded chunks at
  least 25 chunks apart, and a target outside the group reads as not
  loaded. While a plan holds the item store, hoppers see no item entities
  and dispensers wait for the next block phase. A cooldown alone waits for
  the counters pass, like a furnace burning on.

## Facts and fixtures

- `HopperOracle scenes` (stage `hoppers`, pinned 26.3): a probe level whose
  block entities live and tick as `LevelChunk` and `Level.tickBlockEntities`
  keep them and whose entity lookups list entities by section as
  `EntitySectionStorage` does. Chains of 2 to 6 hoppers in every direction
  but up (half of them created last first) from a chest to a chest, a
  hopper, a dropper, a furnace or nothing, with a second chest over one;
  furnaces fed with inputs (some that do not smelt) from above and fuels,
  buckets and non-fuels from a side, emptied below; hoppers under item
  entities of several sizes, some covered by stone, glass, a slab or a
  chest, some nearly full; redstone blocks locking and freeing hoppers.
  Furnaces are created after the hoppers, so they tick after them as
  ValiMC's cooking phase does. `check_hoppers.exs` replays them through
  `World.Hoppers` and `Cooking.step/2`: 150 scenes of 240 ticks (seed
  49001: 94,760 container changes, 110 item entity changes, 2,059 writes)
  match tick by tick: every slot, hopper cooldown, furnace timer and item
  count.
- `DispenserOracle facts` (`priv/physics/dispensers.json`): the behaviour
  of every item's default stack (588: 82 equipment, 13 projectiles with
  their configs, 493 registered).
- `RedstoneOracle facts`: the `hopper` and `dispenser` components.

`test/hopper_region_test.exs`: a raw-set hopper chain feeds a furnace from
above and a side and takes its ingots below; power locks a hopper that
holds items, which then pushes and takes an item entity above; a broken
hopper spills; a hopper gives across a section line only once both sections
share a group; a chain across the line keeps every item through random
ticks and a crash (killed after a flush, reloaded from its log); menus open;
a dropper fills a chest, else drops; a dispenser shoots arrows, pours and
fills buckets, primes TNT and uses bone meal (and fails on stone).
`test/containers_test.exs`: machine entries round-trip with their
cooldown and order.

## Not here

- Dispensing boats (deferred, as the ticket says), minecarts, shulker
  boxes, armor stands, spawn eggs, carved pumpkins and skulls, glass
  bottles, water bottles, glowstone into anchors, honeycomb, brushes,
  shears, flint and steel, fish, axolotl and powder snow buckets, spectral
  arrows, bottles o' enchanting, lingering potions, fireworks and wind
  charges: they keep their item and fail (event 1001). Equipment does not go
  on players, horses, wolves or armor stands yet: it drops.
- Hopper minecarts and other entity containers; composters and
  other `WorldlyContainerHolder` blocks.
- `entityInside` runs on an item's final box after its move, not along its
  path. A section's hoppers tick in creation order within the section; a
  group's sections run one after another.
- A cooking job planned before a hopper changed a container is discarded
  and retried, as any container change does.

Reference: Minecraft 26.3 (`HopperBlockEntity`, `HopperBlock`, `Hopper`,
`DispenserBlock`, `DropperBlock`, `DispenserBlockEntity`,
`DefaultDispenseItemBehavior`, `OptionalDispenseItemBehavior`,
`ProjectileDispenseBehavior`, `ProjectileItem`, `EquipmentDispenseItemBehavior`,
`DispenseItemBehavior.bootStrap`, `AbstractFurnaceBlockEntity`,
`EntitySectionStorage`, `HopperMenu`, `DispenserMenu`), decompiled privately
under `research/decompiled/vmc-043d`.

Client gate: on the real client, a hopper under a chest of raw iron feeds a
furnace from above while one at its side feeds coal, and a hopper below
takes the iron ingots into a chest; the hopper and furnace menus show the
items move.

Checks: `cargo test -p valimc_core` (124), `cargo fmt`, `cargo clippy` (no
new findings); `test/hopper_region_test.exs`, `test/dispensing_test.exs`,
`test/containers_test.exs`, `test/redstone_region_test.exs` and the
container, chest, cooking, menu, anvil, placement and piston tests;
`check_vanilla.py --regen --only hoppers,redstone` passed.

## Handoff (October 2026)

- The implementation under "What is live" and its checks were rebased
  onto main and pushed; the graphical gate remained pending at handoff.
- Not run (stopped when usage ran out): `mix test.fast` and the full
  `check_vanilla.py --changed` set (118 stages, mostly NIF-dependent).
  Run both before the M3 milestone gate.
- Remaining: the client gate above; the dispense behaviours under "Not
  here" (each now keeps its item and fails); armour onto players.
- Gotchas: `placement_region_test.exs` can fail under load with
  `:invalid_or_expired_placement` (passes alone). A container block set
  without a plan now gets its entry at once (chests and furnaces too).

## Client gate (October 24, 2026)

The dedicated tester passed the hopper-fed furnace scenario in M3 run 4:
actual GUI actions put four raw iron in the input chest and two coal in the
side chest. The hoppers drained them, the furnace lit and its menu showed
input, fuel and cooking; the output chest received four iron ingots. The
hopper menu itself was not opened in this run; its routes remain covered by
the owner/menu checks. Evidence: `.local/client-tests/M3-run-04/report.md`
and the run-02 results. The handoff's missing initial fast and changed checks
were completed before the batch (536 fast checks and 103 selected stages).
VMC-032b also passed its 539-check fast suite and the affected machine stages;
the listed deferred dispense behaviours remain outside this checkpoint.

Parent closure: the fresh fast suite passes 541 checks (9 properties, 532
tests), with 215 socket/slow checks excluded; `.local/m3-client-gates-fast.log`.
