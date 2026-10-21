# VMC-077m — One block-rule engine

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan), [VMC-077d](VMC-077d.md)
(the block fact table), [VMC-077b](VMC-077b.md) (the NIF convention).

Before: two survival engines. Decoration's rules lived in worldgen
(`feature.rs` and its fire, chorus, wire, connection, vine and speleothem
modules); live play had its own Elixir engine, `Valimc.Block.Support`, which
checked each neighbour of a commit on its own, broke blocks through scheduled
ticks and knew no neighbour-update order. Tick callbacks were declared twice
(`TickBehaviours` and each behaviour), corals had their own Elixir shape
update, the region border was implicit and redstone wire carried no power.

Scope: one Rust rule engine shared by decoration and live play; vanilla's
update order and chain limit; redstone wire power as an M3 foundation (signal
sources as placed, not their own reactions); one border function. Not here:
repeaters, comparators, pistons, observers, torch burnout and the other blocks
that react to signals (M3); physics (VMC-077l); placement states.

Acceptance:

- `valimc_core::rules` holds every block rule both sides use, over one
  `BlockAccess` trait: the code rules (fire, chorus, connections, wire shape,
  vines, speleothems, mossy carpets, corals), the survival facts
  (`support.rs` reads decoration's `worldgen/survival.json` and live play's
  `physics/support.json` with its reactions) and the shape facts. Decoration's
  `Decoration::update_shape` and the live engine call the same `Rules`. The
  two survival files stay: their partitions differ (decoration reads survival
  before placement under unlit light, live play after it, with reactions).
- `rules::updater` runs what `Level.setBlock` starts, as vanilla's
  `CollectingNeighborUpdater` runs it: `LevelChunk.setBlockState`'s hooks
  (`affectNeighborsAfterRemoval` when the block changed, then `onPlace` unless
  that replaced it), `updateNeighborsAt` in `UPDATE_ORDER`, then the old and new
  states' indirect shape updates around `updateNeighbourShapes` in
  `UPDATE_SHAPE_ORDER` (flags without 1 and 32, limit one less);
  `executeShapeUpdate` with the wire flag (128), `updateOrDestroy` and
  `destroyBlock` (which leaves the state's fluid). Updates added while one runs
  run depth first, siblings in order; past 1,000,000 chained updates the rest
  are skipped, and shape updates recurse at most 512 deep.
- Live play (`rules::live`): after a commit, the region hands the changed cells
  (with their old states) and its due dependent ticks to one run over its store
  (`block_updates`, with a dirty twin chosen by `Native.dispatch/3`). The run
  writes to an overlay and returns the final changes, the destroyed blocks and
  the ticks; the owner commits the changes as one batch with the loot of the
  destroyed blocks and the break events of those that break with particles,
  and maps ticks onto its state-keyed scheduled ticks. While a write is busy a
  run with drops waits, whole, for the next tick.
- A cascade's cost is not bounded by its input: a run with more than 500
  changes goes dirty, and a normal-scheduler run past 2,048 updates stops,
  drops its work and runs again dirty (`{:error, :too_large}`, as light
  updates do).
- The border is one function, `Live::owns`: the region's generated chunks
  within the build height. An update at a cell it does not own, or whose rule
  reads one, is dropped and counted (`stopped`); what that rule scheduled is
  dropped with it.
- Redstone wire power (`rules::wire`): `DefaultRedstoneWireEvaluator`'s target
  strength (the best neighbour signal while no wire signals, else the
  strongest wire beside, above or below less one) and its notifications in Java
  `HashSet` order; wire's `onPlace`, `affectNeighborsAfterRemoval` (with the
  corner wires), `neighborChanged` (wire without a floor pops off with its loot
  and no particles) and `updateIndirectNeighbourShapes`. Live wire reads the
  level and only its floor from the update, as vanilla's does. The sources'
  hooks: redstone torches notify around them on every placement and removal,
  powered levers and buttons their own cell and the block they hang on, powered
  pressure plates their cell and the block below.
- Signals come from the fact table: `BlockFactsOracle` gains a `signal` column
  (`getSignal` and `getDirectSignal` toward each direction through a level that
  fails on any read; powered wire, comparators, trapped chests, jukeboxes and
  test blocks read the level and are `context`), installed with the other
  columns.
- The `redstone_wire` stage: `RedstoneWireOracle` runs vanilla's
  `CollectingNeighborUpdater`, `RedstoneWireBlock` and the sources over a probe
  `ServerLevel` (cells in a map, `Level.setBlock` with the chunk's hooks) on
  240 random scenes of 48 block changes over a stone floor: wire as a player
  places it, stone, glass, slabs, redstone blocks, torches, levers, buttons,
  pressure plates and air. `check_wire.exs` replays each scene on the engine
  (`rules_scene`, a parity NIF) and compares every write in order, the blocks
  broken with particles and the ticks scheduled (torch ticks are M3).
- `test/block_support_test.exs` covers the owner's side: wire beside a redstone
  block carries 15 and 14, loses it with the block, and pops off with its drop
  when its floor goes.

Removed: `Valimc.Block.Support` (214 lines), Coral's Elixir shape update, the
callback declarations of `TickBehaviours` (each behaviour declares its own),
`RegionData`'s support scheduling (`support_updates`, `support_breaks`,
`support_delay`), worldgen's copies of the rule modules and
`bench/block_support.exs`. Lines: `lib` −102 in the engine commit and +23 for
wire; the engine is +1,076 and +498 lines of Rust (with the scene NIF).

Measurements (`bench/block_updates.exs`, `MIX_ENV=bench`, 200 repetitions,
median; the host ran other sessions' checks at load 23–35 on 10 cores, so the
figures are indicative; raw samples in `.local/077m/bench-block-updates.json`):

| Workload | One run per batch | One run per change |
|---|---|---|
| 16 × 16 stone layer (256 changes, 3,072 updates) | 191 µs, 0.75 µs a change | 218 µs, 0.85 µs a change |
| 64-wire line beside a redstone block (65 changes) | 1,575 µs, 7,932 updates | 6,367 µs, 35,352 updates |

Independent changes cost about the same either way (16 million updates a
second batched, 14 million one NIF call per change). Changes that share a
cascade cost four times less batched: run one at a time, each change runs the
shared power propagation again. The batched wire line includes a normal-
scheduler attempt that stops at its budget (2,048 updates; the run then goes
dirty), measured alone at about 1.5 ms for 4,096 updates at load 32, which set
the budget. For scale, VMC-029c measured the deleted Elixir check at 0.09–0.37
µs per neighbour check in isolation, without storage reads or the update order.

Deviations (kept for M3 or later):

- A commit's changes are all in storage before their updates run; vanilla runs
  each `setBlock`'s updates before the next block changes.
- `has_block_tick` sees only ticks the run scheduled, not the owner's earlier
  ones; fluid ticks are dropped (live fluids do not flow yet).
- Only wire, the signal sources and corals have placement and removal hooks,
  and only wire reacts to `neighborChanged`. Doors, rails, TNT, lamps, note
  blocks, observers, torch burnout, repeaters, comparators and pistons are M3;
  a comparator's, trapped chest's or jukebox's signal reads its block entity and
  is 0.
- Rules other than wire read the updating neighbour's cell as the update gives
  it, even if it changed again before the update ran; vanilla's blocks differ in
  which they read.
- Live rules use vanilla's tags, not a data pack's.
- Players cannot place redstone items yet (placement has no facts for them);
  wire power is reached through `/setblock`, `/fill`, `/clone` and `/place`,
  whose box edits run their changes with `UPDATE_ALL` where vanilla's commands
  use their own flags (VMC-077o).

Reference: Minecraft 26.3 (`Level.setBlock`, `destroyBlock` and `removeBlock`,
`LevelChunk.setBlockState`, `CollectingNeighborUpdater`, `NeighborUpdater`,
`SignalGetter`, `RedstoneWireBlock`, `RedstoneWireEvaluator`,
`DefaultRedstoneWireEvaluator`, `RedstoneTorchBlock`, `LeverBlock`,
`ButtonBlock`, `BasePressurePlateBlock`, `ServerLevel.updateNeighborsAt`).

Checks: `cargo test -p valimc_core` (82), `cargo clippy --all-targets` with and
without `parity`, `cargo fmt --check`. The engine commit: `mix test.fast` and
`check_vanilla.py --changed` (78 stages; `tcp` failed under load, see below).
The wire commit, on VMC-077f's write-ahead log: `mix test.fast` 487 passed and
`check_vanilla.py --changed --regen` passed all 81 selected stages
(`block_facts`, `support`, `redstone_wire` and `tcp` among them); the
`redstone_wire` oracle also on 1,500 scenes of 64 changes (seed 991). Under
host load the `tcp` sessions sometimes failed at `VanillaOracle.java:706`:
after the creative stone placement the client steps into the stone and the
wall-entry correction never comes. With this ticket's hook switched off they
failed the same way (1 of 5 loaded runs), so it predates VMC-077m. Cause:
before VMC-077f an owner held a commit's release (client updates and the chunk
snapshots movement reads) behind earlier durable writes (`release_when_durable`,
about 590 ms here), while the placement's correction read the owner's blocks
and showed the stone at once; the move was checked against the old snapshot
(air) and accepted. VMC-077f releases at once, and an owner now writes a
change's snapshots before any client hears of it (`release_blocks` and the
creative destroy's single-block set). On c3cdcbaa `tcp` passed 10 of 10 runs
beside 12 `yes` processes (load 25–56), and 10 of 10 with the ordering change
(load 34–50).

Next: M3's components react through the same hooks (`placed`, `removed`,
`neighbor_changed`) and read signals through `signal`; an owner that holds a
cell's neighbours across regions (VMC-077j) lifts the border stops.
