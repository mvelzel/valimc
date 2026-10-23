# VMC-047a — Power sources, consumers and update order

Status: Awaiting client
Milestone: M3
Depends on: [VMC-077m](VMC-077m.md) (wire power and the update engine),
[VMC-029d](VMC-029d.md) (redstone items place in their vanilla states).

Redstone wire power and vanilla's neighbour-update order already ran in the
Rust block-update engine. This slice adds:

- **Sources:** levers, buttons and pressure plates (wood and stone, with
  their timing and entity checks), redstone torches with burnout, redstone
  blocks, daylight detectors, target blocks, tripwire hooks and tripwires,
  and lecterns' pulses.
- **Consumers:** redstone lamps, doors, trapdoors and fence gates opened by
  power, note blocks, and TNT ignited by power (with VMC-050a).
- **Rules:** strong and weak power, quasi-connectivity where vanilla has it,
  and the update order of its experimental-off evaluator, with no
  simplified fast redstone. Placement uses the oracle and power uses its
  fixtures.

Acceptance:

- Circuit fixtures from a redstone oracle match vanilla's states tick by
  tick, including across section and group lines.
- On the real client, a button-operated iron door and a lever-lit lamp work.

## What is live

- **Facts.** `RedstoneOracle facts` → `priv/physics/redstone.json`: every
  block that gives or takes power, by class (100 blocks: levers, 15
  buttons, 15 plates, 2 weighted plates, torches, lamps, 22 doors, 22
  trapdoors, 13 fence gates, note blocks, TNT, targets, daylight detectors,
  hooks, tripwire, lecterns) with its parameters (a button's pressed ticks
  and whether arrows press it, a plate's sensitivity, a weighted plate's
  maximum, whether a hand opens a door or trapdoor) and sounds; the outline
  bounds of buttons and tripwire (their entity checks); the note block
  instruments; every sound's registry id; and the overworld's day cycle
  (`SKY_LIGHT_LEVEL`: the dimension's value, the day timeline's multiplier
  keyframes and the weather's alpha blends; `SUN_ANGLE`: its keyframes and
  cubic Bézier easing). No other timeline moves the sky.
- **Signals** (`valimc_core::rules::power`): `SignalGetter` as vanilla reads
  it, wire signalling with its connections from the level (power down and
  to the sides it connects to, never up; its direct signal is its signal),
  conductors passing on the strongest direct signal into them. Wire's own
  evaluation still reads with wire silent (`shouldSignal`). Quasi-
  connectivity is vanilla's: a door listens at both halves.
- **Components** (`rules::components`), each as its class does it, every
  write a `Level.setBlock` with its flags so the updates it starts run in
  vanilla's order:
  - `neighborChanged`: redstone torches schedule their 2-tick toggle unless
    it is due this tick (`willTickThisTick`); a lamp lights at once and
    goes out 4 ticks after; doors (both halves' signal, not for their own
    other half), trapdoors and fence gates open and close with their sounds
    (the level random's pitch); a note block plays on a rising edge (a block
    event where its instrument can sound); TNT primes (the primed entity's
    draw from the level random, its sound) and leaves its fluid.
  - Ticks: torch burnout (`RECENT_TOGGLES`: eight toggles within 60 ticks
    burn a torch out with level event 1502 and a 160-tick restart), lamps,
    buttons (20 ticks stone, 30 wood; arrows hold a wooden one), plates
    (20 ticks, weighted 10, sensitivity and weight from the facts), hooks,
    tripwire (rechecks every 10 ticks, releases after 1), targets,
    lecterns.
  - Hooks and tripwire: `calculateState` along up to 41 cells, attaching,
    powering, disarmed wire, the sounds and detach pitch; tripwire's
    `onPlace`, `affectNeighborsAfterRemoval` and placement's
    `setPlacedBy`.
  - Shapes the shape facts leave out: tripwire connects to tripwire and to
    hooks facing it, hooks (and levers and buttons survival does not
    cover) fall off their face, fence gates sink into walls. Torches and
    the components read the level in `updateShape`, never the update's
    neighbour state (a torch on a door just placed survives while the door
    stands open, as vanilla's does).
- **Owner** (`World.RegionData`, `Blocks.Redstone`):
  - A player's use (`Region.menu/4`) of a lever, button, note block,
    daylight detector, or a door, trapdoor or fence gate a hand opens goes
    to the rules when the hand may use it (vanilla's secondary-use rule),
    in reach and not as a spectator; an iron door passes the use on to
    placement; an adventurer cannot invert a detector. A fence gate opens
    away from the player's facing.
  - Scheduled ticks run by block, with the cell's state then (vanilla's
    `LevelTicks`): the rules' ticks are keyed by their block's default
    state, a cell and block pending once; behaviours' ticks also run while
    their block stays.
  - Once a tick after the entities moved, the section's items, orbs, mobs,
    primed TNT, falling blocks and the players standing in it (spectators
    not) touch the plates, buttons and tripwire under their boxes
    (`entityInside`, a box less 1e-5, cells in x, then y, then z order);
    the ticks of plates, buttons and tripwire count the same entities.
  - Daylight detectors update every twentieth game tick in a dimension with
    sky light, in the chunks that tick, from the cell's sky light, the
    overworld clock's day (`Clock.day_ticks/0`) and the weather's levels.
    A detector's block entity holds nothing and places like a plain one.
  - Primed TNT joins the section's entities with vanilla's 80-tick fuse;
    sounds go to the players in range (the acting player's own
    client-predicted sound excluded), note blocks' block events with their
    instrument's sound and pitch.
  - Torch toggles are kept per section in memory, like vanilla's per level:
    a torch only ever counts its own.

## Facts and fixtures

`RedstoneOracle` (pinned 26.3), stage `redstone`:

- `facts` → `priv/physics/redstone.json` (above).
- `day`: `skyDarken` and `SUN_ANGLE` from vanilla's own keyframe samplers,
  modifiers and weather lerps, every tick of a clear day and 4,000 random
  times, rain and thunder levels; `power::Day` matches all 28,000 bit for
  bit (sun angle as float bits).
- `scenes`: circuits over a probe `ServerLevel` whose block ticks are
  vanilla's own `LevelTicks`, over a stone floor straddling the chunk and
  8 × 8 section lines at x 128 and z 0. Each of 200 ticks runs the due
  ticks, every twentieth tick the detectors (random darkness and sun
  angle), then random actions over the first 150: sets of wire, stone,
  glass, redstone blocks, torches, levers, buttons, plates, lamps, doors
  (both halves), trapdoors, gates, note blocks, TNT (some scenes with
  `tnt_explodes` off), targets, detectors, hooks, tripwire and lecterns;
  uses with a player's facing and build right; entities of three kinds
  over plates and tripwire; page turns, target hits, disarmed tripwire;
  then the entities' contacts. Some scenes toggle a lever under a torch
  until it burns out, others build a tripwire line between two hooks.
  Per tick it records the writes, level events, sounds (volume and pitch
  as float bits, whether the player hears its own), block events, primed
  TNT and use results. `check_redstone.exs` replays each scene on the live
  engine over four section stores read as one group's (`redstone_scene`)
  and compares the changed cells, events, sounds, block events, primed TNT
  and results per tick. 120 scenes (seed 47001: 27,238 writes, 309 lamps
  lit, 1,738 door writes powered, 307 plate writes pressed, 82 hooks
  powered, 15 burnouts, 467 note events, 101 TNT primed, 4,861 sounds)
  match; so do 400 scenes with seed 9117 (92,351 writes, 66 burnouts). The
  oracle clears vanilla's static torch toggles between scenes.
- The `redstone_wire` stage now compares the torches' ticks too.

`test/redstone_region_test.exs`: a lever lights a lamp that goes out four
ticks after; a button opens an iron door for 20 ticks (a hand cannot); an
item on a wooden plate lights a lamp; power primes TNT into an entity; a
walled-in, inverted detector gives 15 and, opened to the morning sky,
goes off at its next update; a lever's update past a group's edge stops
there and reaches the lamp after the groups merge.

Group lines: an update at a cell a group does not hold, or whose rule reads
one, is dropped there (VMC-077m); groups keep their loaded chunks at least
25 chunks apart, so no loaded block lies across one, and after a merge the
circuit works as one.

## Not here

- Repeaters, comparators and observers (VMC-048a), pistons (VMC-048b),
  hoppers, droppers and dispensers (VMC-049a); copper bulbs, powered and
  activator rails, bells, crafters and lightning rods react later. A
  comparator's, trapped chest's or jukebox's signal reads its block entity
  and is 0.
- Lecterns pulse and tick in the rules, but a lectern holding a book (a
  block entity) cannot be placed yet, so no page is turned in play.
- Target hits and arrows on wooden buttons wait for projectiles
  (VMC-037o: `{:hit, position, power, arrow?}` and an `:arrow` entity).
- A tripwire broken with shears is disarmed by `{:disarm, position}`, which
  mining's break does not call yet; punching a note block does not play
  it yet (mining's `attack`), and a mob head on one plays nothing (its
  sound is the head's block entity's). A head used on a note block's top
  tunes it instead of passing to placement.
- Contacts are checked once a tick at each entity's position, not along
  its path as it moves; players as standing boxes from their feet. A
  tripwire an entity enters while its one-tick release is pending presses
  a tick early: contacts do not read the owner's pending ticks (a target
  hit does).
- Other blocks than torches and components still read an update's
  neighbour state in their shape rules where vanilla may read the level
  (VMC-077m).

Reference: Minecraft 26.3 (`SignalGetter`, `LeverBlock`, `ButtonBlock`,
`BasePressurePlateBlock`, `PressurePlateBlock`, `WeightedPressurePlateBlock`,
`RedstoneTorchBlock`, `RedstoneWallTorchBlock`, `RedstoneLampBlock`,
`DoorBlock`, `TrapDoorBlock`, `FenceGateBlock`, `NoteBlock`, `TntBlock`,
`PrimedTnt`, `TargetBlock`, `DaylightDetectorBlock`, `TripWireHookBlock`,
`TripWireBlock`, `LecternBlock`, `BlockSetType`, `NoteBlockInstrument`,
`KeyframeTrackSampler`, `EasingType`, `WeatherAttributes`, `Timelines`,
`Level.skyDarken`, `LevelTicks`).

Checks: `cargo test -p valimc_core` (107), `cargo clippy --all-targets` with
and without `parity` (no new findings), `cargo fmt`; the affected tests
(`redstone_region_test`, block support, fluids, ticks, falling blocks,
explosions, placement, chests, menus, portals, clock, connection tests for
uses, chests, buckets and explosions, mining and projectiles: 101 passed
on main after VMC-029e and VMC-037o); `check_vanilla.py --changed` passed
all 141 selected stages (`redstone`, `redstone_wire`, `support`, `fluids`,
`placement` and `tcp` among them), and `--regen --only redstone` verified
the facts.

Client gate: a button-operated iron door and a lever-lit lamp on the real
client.
