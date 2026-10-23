//! Block updates inside one owner (VMC-077m): what `Level.setBlock` starts
//! after a block changes, run as vanilla's `CollectingNeighborUpdater` runs
//! it. A change first runs the blocks' own hooks (`affectNeighborsAfterRemoval`,
//! `onPlace`: redstone wire's and the signal sources', `wire.rs`), then
//! notifies its neighbours
//! (`updateNeighborsAt`, in `NeighborUpdater.UPDATE_ORDER`) and updates their
//! shapes (`updateNeighbourShapes`, in `UPDATE_SHAPE_ORDER`, and wire's
//! `updateIndirectNeighbourShapes`); a shape that becomes air destroys its
//! block (`destroyBlock`, which leaves the block's fluid and drops its loot),
//! any other change is set and updates its own neighbours.
//! Updates produced while one runs are collected and run before it continues
//! (depth first, siblings in order); after `MAX_CHAINED` updates the rest are
//! skipped, as vanilla's `max-chained-neighbor-updates` does, and shape updates
//! recurse at most 512 deep.
//!
//! A run may have a budget of updates (a normal scheduler's); past it the
//! engine stops and reports `over_budget`, and its writes are to be dropped.
//!
//! The engine reads and writes a `World`: the owner's cells (`World::owns`).
//! An update at a cell the owner does not own, or whose rule reads one, is
//! dropped: updates stop at owner borders until owners hold everything that
//! can interact (VMC-077j).

use super::{at, BlockAccess, Rules};
use crate::worldgen::blocks::LIQUID_BLOCK;

/// `NeighborUpdater.UPDATE_ORDER`: west, east, down, up, north, south.
pub const UPDATE_ORDER: [usize; 6] = [4, 5, 0, 1, 2, 3];
/// `BlockBehaviour.UPDATE_SHAPE_ORDER`: west, east, north, south, down, up.
pub const UPDATE_SHAPE_ORDER: [usize; 6] = [4, 5, 2, 3, 0, 1];
/// `Block.UPDATE_NEIGHBORS`.
pub const NEIGHBORS: i32 = 1;
/// `Block.UPDATE_CLIENTS`.
pub const CLIENTS: i32 = 2;
/// `Block.UPDATE_KNOWN_SHAPE`.
pub const KNOWN_SHAPE: i32 = 16;
/// `Block.UPDATE_SUPPRESS_DROPS`.
pub const SUPPRESS_DROPS: i32 = 32;
/// `Block.UPDATE_SKIP_SHAPE_UPDATE_ON_WIRE`.
pub const SKIP_WIRE_SHAPES: i32 = 128;
/// `Block.UPDATE_ALL`.
pub const ALL: i32 = NEIGHBORS | CLIENTS;
/// `Block.UPDATE_LIMIT`.
pub const UPDATE_LIMIT: i32 = 512;
/// The `max_chained_neighbor_updates` game rule's default.
pub const MAX_CHAINED: u64 = 1_000_000;

/// The cells an engine run reads and writes.
pub trait World: BlockAccess {
    /// Whether the owner holds `pos`; nothing else is read or written.
    fn owns(&self, pos: [i32; 3]) -> bool;
    fn set(&mut self, pos: [i32; 3], state: u16);
    /// Start a rule call: returns a mark for `crossed`.
    fn begin(&mut self) -> usize;
    /// Whether the call since `mark` read a cell the owner does not hold; if
    /// so, what it scheduled since is dropped.
    fn crossed(&mut self, mark: usize) -> bool;
    /// The sky light at `pos` (daylight detectors).
    fn sky_light(&mut self, _pos: [i32; 3]) -> i32 {
        15
    }
    /// The block light at `pos` (growing plants, VMC-039a).
    fn block_light(&mut self, _pos: [i32; 3]) -> i32 {
        0
    }
    /// Keep the output of the comparator at `pos` (its block entity's), or
    /// drop it with its block entity (`None`).
    fn set_comparator_output(&mut self, _pos: [i32; 3], _output: Option<i32>) {}
    /// The analog signal of the owner's block entity at `pos` (a container's
    /// fullness), 0 where it keeps none.
    fn container_signal(&mut self, _pos: [i32; 3]) -> i32 {
        0
    }
}

pub(super) enum Update {
    /// `ShapeUpdate`: `pos` learns that its neighbour at `neighbor_pos`
    /// (toward `direction`) became `neighbor_state`.
    Shape {
        direction: usize,
        neighbor_state: u16,
        pos: [i32; 3],
        neighbor_pos: [i32; 3],
        flags: i32,
        limit: i32,
    },
    /// `SimpleNeighborUpdate`: `pos` hears that a neighbour of kind `block`
    /// changed (a diode's or observer's front).
    Neighbor { pos: [i32; 3], block: u16 },
    /// `FullNeighborUpdate`: the same with the state it is told it holds (a
    /// comparator an analog output tells, `updateNeighbourForOutputSignal`).
    Full {
        pos: [i32; 3],
        state: u16,
        block: u16,
    },
    /// `MultiNeighborUpdate`: the neighbours of `source` in update order.
    Neighbors {
        source: [i32; 3],
        block: u16,
        skip: Option<usize>,
        index: usize,
    },
}

/// A block a run destroyed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Destroyed {
    pub pos: [i32; 3],
    pub state: u16,
    /// Whether its loot drops.
    pub drops: bool,
    /// Whether it breaks with particles and sound (`destroyBlock`), not
    /// silently (`removeBlock`).
    pub effects: bool,
}

/// What a run did besides its writes.
#[derive(Debug, Default)]
pub struct Report {
    /// Blocks destroyed, in order.
    pub destroyed: Vec<Destroyed>,
    /// Updates dropped at the owner's border.
    pub stopped: u64,
    /// Updates past the chain limit.
    pub skipped: u64,
    /// Updates run: neighbour and shape updates, each once.
    pub updates: u64,
    /// Whether the run stopped at its budget, incomplete.
    pub over_budget: bool,
    /// Level events: position, event type and data (a fizz, a broken block).
    pub events: Vec<([i32; 3], i32, i32)>,
    /// Sounds played (VMC-047a).
    pub sounds: Vec<super::components::Sound>,
    /// Block events (`Level.blockEvent`): position, block and its two values.
    pub block_events: Vec<([i32; 3], u16, i32, i32)>,
    /// Cells whose TNT primed.
    pub primed: Vec<[i32; 3]>,
}

pub struct Engine<'r, W: World> {
    pub(super) rules: &'r Rules,
    pub world: W,
    stack: Vec<Update>,
    added: Vec<Update>,
    count: u64,
    max_chained: u64,
    budget: u64,
    pub options: super::fluid::Options,
    /// What redstone reads beyond the cells (VMC-047a).
    pub redstone: super::components::Redstone,
    pub report: Report,
}

impl<'r, W: World> Engine<'r, W> {
    pub fn new(rules: &'r Rules, world: W) -> Self {
        Engine {
            rules,
            world,
            stack: Vec::new(),
            added: Vec::new(),
            count: 0,
            max_chained: MAX_CHAINED,
            budget: u64::MAX,
            options: super::fluid::Options::default(),
            redstone: super::components::Redstone::default(),
            report: Report::default(),
        }
    }

    /// The level's fluid settings.
    pub fn with_options(mut self, options: super::fluid::Options) -> Self {
        self.options = options;
        self
    }

    /// Stop after `updates` updates (`Report::over_budget`).
    pub fn with_budget(mut self, updates: u64) -> Self {
        self.budget = updates;
        self
    }

    /// What `Level.setBlock` does after the block at `pos` changed from `old`
    /// to the state the world now holds there, which the owner placed.
    pub fn changed(&mut self, pos: [i32; 3], old: u16, flags: i32, limit: i32) {
        let new = self.world.get(pos);
        if new == old || !self.world.owns(pos) {
            return;
        }
        let mark = self.world.begin();
        self.rules.placed(&mut self.world, new, pos);
        if self.world.crossed(mark) {
            self.report.stopped += 1;
        }
        if self.hooks(pos, old, new, flags) && self.world.get(pos) == new {
            self.after_set(pos, old, new, flags, limit);
        }
    }

    /// A block's scheduled tick for the block of `state`, which runs with
    /// the cell's state if it still holds that block: a redstone
    /// component's, a bubble column's, or a dependent block's (it breaks if
    /// it cannot survive).
    pub fn tick(&mut self, pos: [i32; 3], state: u16) {
        let table = self.rules.table.as_ref();
        let block = table.block_of(state);
        if let Some(i) = self
            .redstone
            .due
            .iter()
            .position(|&due| due == (pos, block))
        {
            self.redstone.due.remove(i);
        }
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        if table.block_of(state) != block {
            return;
        }
        if self.component_tick(pos, state)
            || self.bubble_tick(pos, state)
            || self.growth_tick(pos, state)
            || self.coral_tick(pos, state)
        {
            return;
        }
        let mark = self.world.begin();
        let breaks = self.rules.live_breaks(&mut self.world, state, pos);
        if self.world.crossed(mark) {
            self.report.stopped += 1;
        } else if breaks {
            self.destroy(pos, true, UPDATE_LIMIT);
        }
    }

    /// `Level.setBlock`.
    pub fn set_block(&mut self, pos: [i32; 3], state: u16, flags: i32, limit: i32) -> bool {
        if !self.world.owns(pos) {
            self.report.stopped += 1;
            return false;
        }
        let old = self.world.get(pos);
        if old == state {
            return false;
        }
        self.world.set(pos, state);
        if !self.hooks(pos, old, state, flags) {
            return false;
        }
        // A hook that changed the cell again ends this change.
        if self.world.get(pos) == state {
            self.after_set(pos, old, state, flags, limit);
        }
        true
    }

    /// `LevelChunk.setBlockState`'s hooks: when the block changed, the old
    /// block's `affectNeighborsAfterRemoval`; then, unless that replaced the
    /// new block, the new state's `onPlace`. Only redstone wire and the signal
    /// sources have them yet (`wire.rs`).
    fn hooks(&mut self, pos: [i32; 3], old: u16, new: u16, flags: i32) -> bool {
        let table = self.rules.table.as_ref();
        let block = table.block_of(new);
        // A comparator's block entity goes with its block, before the
        // removal's updates (`LevelChunk.setBlockState`).
        let comparator = self.rules.redstone.comparator;
        if table.block_of(old) != block && table.block_of(old) == comparator {
            self.world.set_comparator_output(pos, None);
        }
        if table.block_of(old) != block && flags & NEIGHBORS != 0 {
            self.removed(pos, old);
        }
        if self.rules.table.block_of(self.world.get(pos)) != block {
            return false;
        }
        // A new comparator's block entity starts at 0 (it is made after
        // `onPlace`, which reads 0 without it alike).
        if block == comparator && self.rules.table.block_of(old) != comparator {
            self.world.set_comparator_output(pos, Some(0));
        }
        self.placed(pos, old, new);
        if self.rules.fluids.is_some() && self.world.get(pos) == new {
            if self.rules.table.flag(new, LIQUID_BLOCK) {
                self.liquid_changed(pos, new);
            } else {
                self.fire_placed(pos, old, new);
            }
        }
        true
    }

    fn after_set(&mut self, pos: [i32; 3], old: u16, new: u16, flags: i32, limit: i32) {
        let table = self.rules.table.as_ref();
        if flags & NEIGHBORS != 0 {
            self.update_neighbors_at(pos, table.block_of(old), None);
            if self.has_analog(new) {
                self.update_neighbour_for_output_signal(pos, table.block_of(new));
            }
        }
        if flags & KNOWN_SHAPE == 0 && limit > 0 {
            let flags = flags & !(NEIGHBORS | SUPPRESS_DROPS);
            self.indirect_shapes(old, pos, flags, limit - 1);
            self.update_neighbour_shapes(new, pos, flags, limit - 1);
            self.indirect_shapes(new, pos, flags, limit - 1);
        }
    }

    /// `Level.destroyBlock`: the block leaves its fluid.
    pub fn destroy(&mut self, pos: [i32; 3], drop: bool, limit: i32) -> bool {
        let state = self.world.get(pos);
        let table = self.rules.table.as_ref();
        if table.is_air(state) {
            return false;
        }
        // Fire goes without its break particles and sound.
        let block = table.block_of(state);
        let fire =
            block == self.rules.fire.fire_block() || block == self.rules.fire.soul_fire_block();
        self.report.destroyed.push(Destroyed {
            pos,
            state,
            drops: drop,
            effects: !fire,
        });
        self.set_block(pos, table.remains[state as usize], ALL, limit)
    }

    /// `updateNeighborsAt` (`updateNeighborsAtExceptFromFacing` with `skip`).
    pub fn update_neighbors_at(&mut self, source: [i32; 3], block: u16, skip: Option<usize>) {
        let index = usize::from(Some(UPDATE_ORDER[0]) == skip);
        self.add(Update::Neighbors {
            source,
            block,
            skip,
            index,
        });
    }

    /// `Level.updateNeighbourForOutputSignal`: the comparators beside `pos`,
    /// or behind a conductor beside it, hear that its analog output changed.
    pub fn update_neighbour_for_output_signal(&mut self, pos: [i32; 3], block: u16) {
        let comparator = self.rules.redstone.comparator;
        for d in [2, 5, 3, 4] {
            let mut beside = at(pos, d);
            if !self.world.owns(beside) {
                self.report.stopped += 1;
                continue;
            }
            let mut state = self.world.get(beside);
            if self.rules.table.block_of(state) != comparator {
                if !self
                    .rules
                    .table
                    .flag2(state, crate::worldgen::blocks::REDSTONE_CONDUCTOR)
                {
                    continue;
                }
                beside = at(beside, d);
                if !self.world.owns(beside) {
                    self.report.stopped += 1;
                    continue;
                }
                state = self.world.get(beside);
                if self.rules.table.block_of(state) != comparator {
                    continue;
                }
            }
            self.add(Update::Full {
                pos: beside,
                state,
                block,
            });
        }
    }

    /// `Level.neighborChanged(pos, block)`.
    pub(super) fn neighbor_changed_at(&mut self, pos: [i32; 3], block: u16) {
        self.add(Update::Neighbor { pos, block });
    }

    /// `BlockState.updateNeighbourShapes`.
    fn update_neighbour_shapes(&mut self, state: u16, pos: [i32; 3], flags: i32, limit: i32) {
        for d in UPDATE_SHAPE_ORDER {
            self.add(Update::Shape {
                direction: d ^ 1,
                neighbor_state: state,
                pos: at(pos, d),
                neighbor_pos: pos,
                flags,
                limit,
            });
        }
    }

    /// `CollectingNeighborUpdater.addAndRun`.
    pub(super) fn add(&mut self, update: Update) {
        if self.report.over_budget {
            return;
        }
        let running = self.count > 0;
        let too_many = self.count >= self.max_chained;
        self.count += 1;
        if too_many {
            self.report.skipped += 1;
        } else if running {
            self.added.push(update);
        } else {
            self.stack.push(update);
        }
        if !running {
            self.run();
        }
    }

    /// `CollectingNeighborUpdater.runUpdates`.
    fn run(&mut self) {
        loop {
            while let Some(update) = self.added.pop() {
                // `addedThisLayer` is pushed last first, so its first update
                // runs first.
                self.stack.push(update);
            }
            if self.report.updates >= self.budget {
                self.report.over_budget = true;
                self.stack.clear();
                self.added.clear();
            }
            let Some(mut next) = self.stack.pop() else {
                break;
            };
            loop {
                let more = self.run_next(&mut next);
                if !more {
                    break;
                }
                if !self.added.is_empty() {
                    self.stack.push(next);
                    break;
                }
            }
        }
        self.count = 0;
    }

    /// One step of an update; whether it has more.
    fn run_next(&mut self, update: &mut Update) -> bool {
        self.report.updates += 1;
        match *update {
            Update::Shape {
                direction,
                neighbor_state,
                pos,
                neighbor_pos,
                flags,
                limit,
            } => {
                self.shape_update(direction, pos, neighbor_pos, neighbor_state, flags, limit);
                false
            }
            Update::Neighbor { pos, block } => {
                self.neighbor_changed(pos, block, None);
                false
            }
            Update::Full { pos, state, block } => {
                self.neighbor_changed(pos, block, Some(state));
                false
            }
            Update::Neighbors {
                source,
                block,
                skip,
                ref mut index,
            } => {
                let d = UPDATE_ORDER[*index];
                *index += 1;
                if *index < UPDATE_ORDER.len() && Some(UPDATE_ORDER[*index]) == skip {
                    *index += 1;
                }
                let more = *index < UPDATE_ORDER.len();
                self.neighbor_changed(at(source, d), block, None);
                more
            }
        }
    }

    /// `NeighborUpdater.executeShapeUpdate`.
    fn shape_update(
        &mut self,
        direction: usize,
        pos: [i32; 3],
        neighbor_pos: [i32; 3],
        neighbor_state: u16,
        flags: i32,
        limit: i32,
    ) {
        if !self.world.owns(pos) {
            self.report.stopped += 1;
            return;
        }
        let current = self.world.get(pos);
        let table = self.rules.table.as_ref();
        if flags & SKIP_WIRE_SHAPES != 0 && table.block_of(current) == self.rules.redstone.wire {
            return;
        }
        if let Some(fluids) = &self.rules.fluids {
            if table.flag(current, LIQUID_BLOCK) {
                self.liquid_shape(pos, current, direction, neighbor_state);
                return;
            }
            if fluids.bubbles.is_column(table, current) {
                self.column_shape(pos, direction, neighbor_state);
                return;
            }
        }
        let mark = self.world.begin();
        let new = self.rules.live_update_shape(
            &mut self.world,
            current,
            pos,
            direction,
            Some((neighbor_pos, neighbor_state)),
        );
        if self.world.crossed(mark) {
            self.report.stopped += 1;
            return;
        }
        // A rule that cannot run keeps the state, as before VMC-077m.
        let Ok(new) = new else {
            return;
        };
        self.update_or_destroy(current, new, pos, flags, limit);
    }

    /// `Block.updateOrDestroy`.
    fn update_or_destroy(&mut self, old: u16, new: u16, pos: [i32; 3], flags: i32, limit: i32) {
        if new == old {
            return;
        }
        if self.rules.table.is_air(new) {
            self.destroy(pos, flags & SUPPRESS_DROPS == 0, limit);
        } else {
            self.set_block(pos, new, flags & !SUPPRESS_DROPS, limit);
        }
    }

    /// `NeighborUpdater.executeUpdate`: the block at `pos` (holding `given`,
    /// else the cell's state) hears that a neighbour of kind `block` changed.
    /// Redstone wire, liquids and the redstone components react.
    fn neighbor_changed(&mut self, pos: [i32; 3], block: u16, given: Option<u16>) {
        if !self.world.owns(pos) {
            self.report.stopped += 1;
            return;
        }
        let state = given.unwrap_or_else(|| self.world.get(pos));
        if self.is_wire(state) {
            self.wire_neighbor_changed(pos, state);
        } else if self.rules.table.flag(state, LIQUID_BLOCK) {
            self.liquid_changed(pos, state);
        } else {
            self.component_neighbor_changed(pos, state, block);
        }
    }
}
