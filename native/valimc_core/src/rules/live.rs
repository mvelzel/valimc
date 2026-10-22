//! The live region's side of the block-update engine (VMC-077m): one run
//! over the region's store, after a batch of block changes or at due ticks.
//! Writes go to an overlay the owner commits as one batch; ticks, destroyed
//! blocks and border stops are returned beside it.

use std::collections::{HashMap, HashSet};

use super::updater::{Engine, Report, World, ALL, UPDATE_LIMIT};
use super::{BlockAccess, Rules};
use crate::column::{ColumnStore, HEIGHT, MIN_Y};

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
    /// Fluid ticks scheduled: position, fluid, delay (live fluids do not flow
    /// yet).
    pub fluid_ticks: Vec<([i32; 3], u8, i32)>,
    pub report: Report,
}

struct Live<'s> {
    store: &'s ColumnStore,
    /// Chunks of the region not generated yet: like a neighbour's, not held.
    absent: &'s HashSet<(i32, i32)>,
    air: u16,
    overlay: HashMap<[i32; 3], u16>,
    order: Vec<[i32; 3]>,
    block_ticks: Vec<([i32; 3], u16, i32)>,
    fluid_ticks: Vec<([i32; 3], u8, i32)>,
    crossed: bool,
    rng: u64,
}

impl Live<'_> {
    fn base(&self, pos: [i32; 3]) -> u16 {
        self.store.get(pos[0], pos[1], pos[2]).unwrap_or(self.air)
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
        self.fluid_ticks.push((pos, fluid, delay));
    }

    /// Ticks this run scheduled; the owner's earlier ticks are not visible.
    fn has_block_tick(&mut self, pos: [i32; 3], block: u16) -> bool {
        self.block_ticks
            .iter()
            .any(|&(p, b, _)| p == pos && b == block)
    }

    fn next_int(&mut self, bound: i32) -> i32 {
        // xorshift64; any random will do for the delays rules draw.
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        (self.rng % bound as u64) as i32
    }
}

impl World for Live<'_> {
    /// The owner's border, in one place: the region's chunks that are
    /// generated, within the build height.
    fn owns(&self, pos: [i32; 3]) -> bool {
        let chunk = (pos[0] >> 4, pos[2] >> 4);
        let (min, size) = (self.store.chunk_min, self.store.chunk_size);
        (MIN_Y..MIN_Y + HEIGHT as i32).contains(&pos[1])
            && (min.0..min.0 + size).contains(&chunk.0)
            && (min.1..min.1 + size).contains(&chunk.1)
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
/// `UPDATE_ALL` does), then the dependent blocks' due `ticks`, within
/// `budget` updates if given (`None` past it, nothing to commit).
pub fn run(
    rules: &Rules,
    store: &ColumnStore,
    absent: &HashSet<(i32, i32)>,
    changes: &[Change],
    ticks: &[([i32; 3], u16)],
    seed: u64,
    budget: Option<u64>,
) -> Result<Option<Outcome>, String> {
    let world = Live {
        store,
        absent,
        air: rules.table.default_state("air")?,
        overlay: HashMap::new(),
        order: Vec::new(),
        block_ticks: Vec::new(),
        fluid_ticks: Vec::new(),
        crossed: false,
        rng: seed.max(1),
    };
    let mut engine = Engine::new(rules, world).with_budget(budget.unwrap_or(u64::MAX));
    for &(pos, old) in changes {
        engine.changed(pos, old, ALL, UPDATE_LIMIT);
    }
    for &(pos, state) in ticks {
        engine.tick(pos, state);
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
        report,
    }))
}

/// The first of `states` that can survive at `pos` (placement's
/// `canSurvive`, `Rules::live_survives`). A rule that reads past the
/// region's border is not refused: the neighbour region holds that cell.
pub fn first_surviving(
    rules: &Rules,
    store: &ColumnStore,
    absent: &HashSet<(i32, i32)>,
    pos: [i32; 3],
    states: &[u16],
) -> Result<Option<u16>, String> {
    let mut world = Live {
        store,
        absent,
        air: rules.table.default_state("air")?,
        overlay: HashMap::new(),
        order: Vec::new(),
        block_ticks: Vec::new(),
        fluid_ticks: Vec::new(),
        crossed: false,
        rng: 1,
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
    fn the_region_owns_its_generated_chunks_within_the_build_height() {
        let store = ColumnStore::new((8, -8), 8, Box::new([0; HEIGHT]), 1 << 20);
        let absent = HashSet::from([(9, -8)]);
        let mut live = Live {
            store: &store,
            absent: &absent,
            air: 0,
            overlay: HashMap::new(),
            order: Vec::new(),
            block_ticks: Vec::new(),
            fluid_ticks: Vec::new(),
            crossed: false,
            rng: 1,
        };
        assert!(live.owns([128, 64, -128]));
        assert!(live.owns([255, 319, -1]));
        assert!(!live.owns([127, 64, -128]), "west of the region");
        assert!(!live.owns([128, 64, -129]), "north of the region");
        assert!(!live.owns([256, 64, -1]), "east of the region");
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
