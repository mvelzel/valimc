//! The live side of the block-update engine (VMC-077m): one run over the
//! stores of a group's sections (VMC-077j), after a batch of block changes in
//! one of them, at its due ticks, or for a player's bucket or a generated
//! chunk's post-processing. Writes go to an overlay the group commits, each
//! section its own cells; ticks, destroyed blocks, level events and stops at
//! the group's edge are returned beside it.

use std::collections::{HashMap, HashSet};

use super::fluid::{Emptied, Options};
use super::updater::{Engine, Report, World, ALL, UPDATE_LIMIT};
use super::{BlockAccess, Rules};
use crate::column::{ColumnStore, HEIGHT, MIN_Y};
use crate::worldgen::random::Random;

/// A block change the owner already made: the position and its old state.
pub type Change = ([i32; 3], u16);

/// What one run decided.
#[derive(Debug, Default)]
pub struct Outcome {
    /// Cells whose state the run changed, with their final state, in the
    /// order they first changed.
    pub changes: Vec<([i32; 3], u16)>,
    /// Block ticks scheduled: position, block, delay.
    pub block_ticks: Vec<([i32; 3], u16, i32)>,
    /// Fluid ticks scheduled: position, fluid, delay.
    pub fluid_ticks: Vec<([i32; 3], u8, i32)>,
    /// Per action, its result: a bucket's `Emptied` (0 failed, 1 placed, 2
    /// evaporated), a pickup's item index + 1 (0: none), a post-processing
    /// mark's 1 (done) or 0 (it read past the owner: keep it).
    pub results: Vec<i32>,
    pub report: Report,
}

/// What a run does besides updates and ticks.
#[derive(Clone, Copy, Debug)]
pub enum Action {
    /// `BucketItem.emptyContents` of a bucket of fluid `kind` (a source) at
    /// `pos`, then at `retry` (the clicked face's neighbour), sneaking or not.
    Empty {
        pos: [i32; 3],
        kind: u8,
        retry: Option<[i32; 3]>,
        secondary: bool,
    },
    /// `BucketPickup.pickupBlock` at `pos`.
    Pickup { pos: [i32; 3] },
    /// A generated chunk's post-processing mark.
    PostProcess { pos: [i32; 3] },
    /// A random tick of a lava cell; `fire`: a player is near enough for its
    /// fire to spread.
    RandomTick { pos: [i32; 3], fire: bool },
}

/// One run's input.
#[derive(Clone, Copy, Debug, Default)]
pub struct Input<'a> {
    /// Cells the owner changed, with their old states.
    pub changes: &'a [Change],
    pub actions: &'a [Action],
    /// Due block ticks: position and the state they were scheduled for.
    pub ticks: &'a [([i32; 3], u16)],
    /// Due fluid ticks: position and fluid.
    pub fluid_ticks: &'a [([i32; 3], u8)],
    pub options: Options,
}

struct Live<'s> {
    /// The section the run starts in, then the group's other sections.
    stores: &'s [&'s ColumnStore],
    /// Chunks of those sections not generated yet: like a neighbour group's,
    /// not held.
    absent: &'s HashSet<(i32, i32)>,
    air: u16,
    overlay: HashMap<[i32; 3], u16>,
    order: Vec<[i32; 3]>,
    block_ticks: Vec<([i32; 3], u16, i32)>,
    fluid_ticks: Vec<([i32; 3], u8, i32)>,
    /// The run's due fluid ticks while they still wait for the fluid phase:
    /// a tick scheduled meanwhile for one of them is dropped, as vanilla's
    /// fluid `LevelTicks` still holds it then.
    held: HashSet<([i32; 3], u8)>,
    crossed: bool,
    random: &'s mut Random,
}

impl Live<'_> {
    /// The store holding chunk `chunk`.
    fn store(&self, chunk: (i32, i32)) -> Option<&ColumnStore> {
        self.stores.iter().copied().find(|store| {
            let (min, size) = (store.chunk_min, store.chunk_size);
            (min.0..min.0 + size).contains(&chunk.0) && (min.1..min.1 + size).contains(&chunk.1)
        })
    }

    fn base(&self, pos: [i32; 3]) -> u16 {
        self.store((pos[0] >> 4, pos[2] >> 4))
            .and_then(|store| store.get(pos[0], pos[1], pos[2]).ok())
            .unwrap_or(self.air)
    }
}

impl BlockAccess for Live<'_> {
    fn get(&mut self, pos: [i32; 3]) -> u16 {
        if !self.owns(pos) {
            self.crossed = true;
            return self.air;
        }
        match self.overlay.get(&pos) {
            Some(&state) => state,
            None => self.base(pos),
        }
    }

    fn schedule_block_tick(&mut self, pos: [i32; 3], block: u16, delay: i32) {
        self.block_ticks.push((pos, block, delay));
    }

    fn schedule_fluid_tick(&mut self, pos: [i32; 3], fluid: u8, delay: i32) {
        if self.held.contains(&(pos, fluid)) {
            return;
        }
        self.fluid_ticks.push((pos, fluid, delay));
    }

    /// Ticks this run scheduled; the owner's earlier ticks are not visible.
    fn has_block_tick(&mut self, pos: [i32; 3], block: u16) -> bool {
        self.block_ticks
            .iter()
            .any(|&(p, b, _)| p == pos && b == block)
    }

    /// The level random's (a legacy random, as `RandomSource.create`'s).
    fn next_int(&mut self, bound: i32) -> i32 {
        self.random.next_int_bounded(bound)
    }
}

impl World for Live<'_> {
    /// The group's edge, in one place: its sections' chunks that are
    /// generated, within the build height.
    fn owns(&self, pos: [i32; 3]) -> bool {
        let chunk = (pos[0] >> 4, pos[2] >> 4);
        (MIN_Y..MIN_Y + HEIGHT as i32).contains(&pos[1])
            && self.store(chunk).is_some()
            && !self.absent.contains(&chunk)
    }

    fn set(&mut self, pos: [i32; 3], state: u16) {
        if self.overlay.insert(pos, state).is_none() {
            self.order.push(pos);
        }
    }

    fn begin(&mut self) -> usize {
        self.crossed = false;
        self.block_ticks.len() << 32 | self.fluid_ticks.len()
    }

    fn crossed(&mut self, mark: usize) -> bool {
        if self.crossed {
            self.block_ticks.truncate(mark >> 32);
            self.fluid_ticks.truncate(mark & 0xffff_ffff);
        }
        self.crossed
    }
}

/// Run the updates the owner's `changes` start (as `Level.setBlock` with
/// `UPDATE_ALL` does), its actions, then the dependent blocks' due ticks and
/// the due fluid ticks, over `stores` (the section's, then its group's
/// others), drawing from `random`, within `budget` updates if given (`None`
/// past it, nothing to commit).
pub fn run(
    rules: &Rules,
    stores: &[&ColumnStore],
    absent: &HashSet<(i32, i32)>,
    input: &Input,
    random: &mut Random,
    budget: Option<u64>,
) -> Result<Option<Outcome>, String> {
    let world = Live {
        stores,
        absent,
        air: rules.table.default_state("air")?,
        overlay: HashMap::new(),
        order: Vec::new(),
        block_ticks: Vec::new(),
        fluid_ticks: Vec::new(),
        held: input.fluid_ticks.iter().copied().collect(),
        crossed: false,
        random,
    };
    let mut engine = Engine::new(rules, world)
        .with_budget(budget.unwrap_or(u64::MAX))
        .with_options(input.options);
    for &(pos, old) in input.changes {
        engine.changed(pos, old, ALL, UPDATE_LIMIT);
    }
    let fluids = rules.fluids.is_some();
    let mut results = Vec::with_capacity(input.actions.len());
    for action in input.actions {
        results.push(match *action {
            _ if !fluids => 0,
            Action::Empty {
                pos,
                kind,
                retry,
                secondary,
            } => match engine.empty_bucket(pos, kind, retry, secondary) {
                Emptied::Failed => 0,
                Emptied::Placed => 1,
                Emptied::Evaporated => 2,
            },
            Action::Pickup { pos } => engine.pickup(pos).map_or(0, |item| item as i32 + 1),
            Action::PostProcess { pos } => i32::from(engine.post_process(pos)),
            Action::RandomTick { pos, fire } => {
                engine.lava_random_tick(pos, fire);
                0
            }
        });
    }
    for &(pos, state) in input.ticks {
        engine.tick(pos, state);
    }
    if fluids {
        engine.world.held.clear();
        for &(pos, kind) in input.fluid_ticks {
            engine.fluid_tick(pos, kind);
        }
    }
    if engine.report.over_budget {
        return Ok(None);
    }
    let Engine { world, report, .. } = engine;
    let changes = world
        .order
        .iter()
        .map(|&pos| (pos, world.overlay[&pos]))
        .filter(|&(pos, state)| state != world.base(pos))
        .collect();
    Ok(Some(Outcome {
        changes,
        block_ticks: world.block_ticks,
        fluid_ticks: world.fluid_ticks,
        results,
        report,
    }))
}

/// The first of `states` that can survive at `pos` (placement's
/// `canSurvive`, `Rules::live_survives`) over `stores` (as `run`). A rule
/// that reads past the group's edge is not refused: the neighbour group
/// holds that cell.
pub fn first_surviving(
    rules: &Rules,
    stores: &[&ColumnStore],
    absent: &HashSet<(i32, i32)>,
    pos: [i32; 3],
    states: &[u16],
) -> Result<Option<u16>, String> {
    let mut random = Random::legacy(1);
    let mut world = Live {
        stores,
        absent,
        air: rules.table.default_state("air")?,
        overlay: HashMap::new(),
        order: Vec::new(),
        block_ticks: Vec::new(),
        fluid_ticks: Vec::new(),
        held: HashSet::new(),
        crossed: false,
        random: &mut random,
    };
    Ok(states.iter().copied().find(|&state| {
        world.crossed = false;
        rules.live_survives(&mut world, state, pos) || world.crossed
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_group_owns_its_generated_chunks_within_the_build_height() {
        let store = ColumnStore::new((8, -8), 8, Box::new([0; HEIGHT]), 1 << 20);
        let sibling = ColumnStore::new((16, -8), 8, Box::new([7; HEIGHT]), 1 << 20);
        let absent = HashSet::from([(9, -8)]);
        let stores = [&store, &sibling];
        let mut random = Random::legacy(1);
        let mut live = Live {
            stores: &stores,
            absent: &absent,
            air: 0,
            overlay: HashMap::new(),
            order: Vec::new(),
            block_ticks: Vec::new(),
            fluid_ticks: Vec::new(),
            held: HashSet::new(),
            crossed: false,
            random: &mut random,
        };
        assert!(live.owns([128, 64, -128]));
        assert!(live.owns([255, 319, -1]));
        assert!(!live.owns([127, 64, -128]), "west of the region");
        assert!(!live.owns([128, 64, -129]), "north of the region");
        assert!(live.owns([256, 64, -1]), "a sibling section east of it");
        assert_eq!(live.get([256, 64, -1]), 7);
        assert!(!live.owns([384, 64, -1]), "east of the group");
        assert!(!live.owns([128, 320, -128]), "above the build height");
        assert!(!live.owns([144, 64, -128]), "a chunk not generated yet");
        // Reading outside marks the rule call, which then drops what it scheduled.
        let mark = live.begin();
        live.schedule_block_tick([128, 64, -128], 1, 2);
        assert_eq!(live.get([127, 64, -128]), 0);
        assert!(live.crossed(mark));
        assert!(live.block_ticks.is_empty());
    }
}
