# VMC-048a — Repeaters, comparators and observers

Status: Awaiting client
Milestone: M3
Depends on: [VMC-047a](VMC-047a.md).

The components that time and measure power:

- **Repeaters:** delay, locking and orientation.
- **Comparators:** compare and subtract modes. They read container
  fullness (chests, furnaces, hoppers once VMC-049a lands), cake, cauldrons,
  composters, lecterns, item frames and end portal frames.
- **Observers:** pulses on the shape changes VMC-029d models.

Their scheduled ticks use vanilla's priorities, in the tick pipeline's
per-chunk containers.

Acceptance:

- Timing fixtures (repeater chains, comparator clocks, observer pulses)
  match the oracle tick by tick.
- A comparator reading a chest's fullness matches vanilla on the real
  client.

## What is live

- **Facts.** `RedstoneOracle facts` adds the `repeater`, `comparator` (its
  click sound) and `observer` kinds, and `analog`: every block with an
  analog output (103), its signal per state where the state alone gives it
  (cakes, cauldrons, composters, end portal frames, respawn anchors, bee
  nests, copper bulbs and golem statues), else `entity` (containers,
  lecterns, jukeboxes, shelves and the rest that read a block entity,
  neighbours or entities), and whether its removal tells comparators
  (`Containers.updateNeighboursAfterDestroy`).
- **Engine** (`rules::components`, `power`, `updater`), as the classes do
  it with the experimental redstone off:
  - Repeaters: `neighborChanged` (a repeater without a rigid floor pops off;
    else unless locked it schedules its tick when its input disagrees,
    `willTickThisTick` first), the tick (off, or on and off again after its
    delay), the lock from a powered diode beside it in `updateShape` (any
    update across its axis), and `onPlace`/`affectNeighborsAfterRemoval`
    telling the cell in front and its neighbours but the repeater.
  - Comparators: input from behind with wire's power, an analog output
    behind or behind a conductor (`getInputSignal`), side inputs
    (`getControlInputSignal`), compare and subtract, `checkTickOnNeighbor`
    against the block entity's output, `refreshOutputState` at the tick and
    after a mode change (its sound at 0.5 or 0.55). A comparator's signal is
    its block entity's output wherever signals are read (wire, conductors,
    consumers, placement).
  - Observers: `updateShape` toward their face starts a 2-tick pulse unless
    one is pending; the tick, `onPlace` (a powered one placed without a tick
    turns off) and removal.
  - Tick priorities: repeaters extremely high when the diode in front does
    not face them, very high turning off, else high; comparators high or
    normal; everything else normal. `BlockAccess::schedule_block_tick_priority`
    carries them to the owner's `ScheduledTicks`, whose containers order by
    trigger tick, priority and scheduling order.
  - `Level.setBlock` of a state with an analog output, a container's
    removal and a block entity's change tell the comparators beside it, or
    behind a conductor beside it, with the state they hold
    (`FullNeighborUpdate`). A chest under a conductor reads 0.
  - `setPlacedBy`: a placed diode whose input is on ticks after 1.
- **Placement.** `PlacementOracle` no longer excludes repeaters and
  comparators: a repeater's facts read no diodes beside it and its lock is
  a post step (`post` 3, `Rules::repeater_locked`), which reads the
  comparators' outputs too. The oracle checks vanilla's placement against
  facts and lock on random neighbourhoods; 1,140 block items and 110,424
  matrix cases match (`placement`).
- **Owner** (`World.RegionData`):
  - A comparator's block entity is a plain block entity (placeable, listed
    in chunk packets); its output lives in the section's `comparators`
    (`position => output`), persisted as `{:comparator, position}` records.
    The rules start a new comparator at 0, drop a gone one's and return the
    outputs they change; every run reads the group's outputs (`peers` carry
    each section's). An imported comparator starts from 0 (its preserved
    entry no longer protects its block).
  - A run reads the analog signals of owned containers (single chests, the
    furnace family) one or two cells beside a comparator
    (`Redstone.entry_signal/1`, `container_signal/2`: vanilla's float
    arithmetic over each stack's count and maximum stack size).
  - A container whose signal changed tells the comparators at the next
    block phase (`{:output_changed, position}`).
  - Repeaters and comparators are used like levers (a player who may build;
    a repeater cycles its delay); placing one runs `setPlacedBy`
    (`{:placed, position}`, as hooks).
  - A run's pending ticks include those at the cells its changes name, so
    an observer placed or removed knows its own.

## Facts and fixtures

`RedstoneOracle` scenes (pinned 26.3, stage `redstone`) now also set
repeaters, comparators and observers in any state, single chests, furnaces,
cakes and composters (not at 7, which ticks itself); place diodes
(`setPlacedBy`); use them; and fill chests and furnaces (`fill`: new
contents as one `setChanged`, with vanilla's signal, which
`check_redstone.exs` checks against `container_signal/2`). The probe keeps
comparators', chests' and furnaces' block entities as `LevelChunk` does and
tells comparators of analog outputs as `Level.setBlock` does. Per tick the
scenes also record the comparators whose output changed. Scripted fixtures:
a lever-driven line of repeaters with random delays across x 128 into a
lamp, with a lever-driven repeater locking one; a subtract-mode comparator
clock; a comparator reading a chest through a stone block, refilled every
few ticks; two observers facing each other until one is broken; and a race
in which a repeater turning off (very high) and one turning on (high,
scheduled first) are due the same tick and the second's wire feeds the
first.

- 120 scenes (seed 47001: 33,646 writes, 889 repeaters powered, 300
  locked, 435 comparators powered, 338 output changes, 845 observers
  powered, 839 fills) and 400 scenes (seed 9117: 118,035 writes, 2,832
  repeaters powered, 1,720 output changes, 2,842 fills) match tick by tick,
  with the 047a components; so do 400 scenes of seed 48001 without the
  race fixture.
- Ignoring priorities fails 4 of those 400; the race fixture alone catches
  a very-high tick run as high (5 of 120), which 800 random scenes did not.

`test/redstone_region_test.exs`: a comparator reads a chest's fullness
(ten stacks of 64: 6) into a lamp and goes to 0 when it empties; a repeater's
use cycles its delay and an adventurer's passes; a broken comparator's
output goes with it.

## Not here

- Item frames do not exist yet, so comparators read none.
- A trapped chest's signal (its viewers) and a jukebox's read 0: neither
  owns a block entity yet; nor do double chests (preserved block entities),
  hoppers, barrels and the other containers, or a lectern's book.
- A container's change reaches comparators at the next block phase, a tick
  later at most than vanilla's `setChanged`; vanilla tells them once per
  slot changed, ValiMC once per changed signal.
- A group's sections run their due ticks one section after another, so
  priorities order ticks within a section; the scenes run a group's as one
  level's.

Reference: Minecraft 26.3 (`DiodeBlock`, `RepeaterBlock`, `ComparatorBlock`,
`ComparatorBlockEntity`, `ObserverBlock`, `SignalGetter`,
`Level.setBlock`, `Level.updateNeighbourForOutputSignal`, `Containers`,
`LevelChunk.setBlockState`, `AbstractContainerMenu.getRedstoneSignalFromContainer`,
`Mth.lerpDiscrete`, `ChestBlock`, `LevelTicks`, `ScheduledTick`,
`TickPriority`, `CollectingNeighborUpdater`), decompiled privately under
`research/decompiled/vmc-048a`.

Checks: `cargo test -p valimc_core` (112), `cargo clippy --all-targets`
with `parity` (no new findings), `cargo fmt`; the affected tests
(`redstone_region_test`, storage, placement, chests, containers, block
support, fluids, ticks, falling blocks, explosions, mining, portals, clock,
menus and the connection tests for buckets, chests, explosions, mining,
placement and projectiles: 85 passed); `check_vanilla.py --changed` passed
all 93 selected stages (`redstone`, `redstone_wire`, `placement`,
`anvil_content`, `chest_block_entity` and `tcp` among them; `placement` and
`tcp` again after the shared oracle builds lost their classes mid-run), and
`--regen --only redstone` verified the facts.

Client gate: on the real client, a comparator reading a chest lights a lamp
that goes out when the chest empties; a repeater line delays and a side
repeater locks it; two observers facing each other pulse.
