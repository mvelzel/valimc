//! The live side of the block-update engine (VMC-077m): one run over the
//! stores of a group's sections (VMC-077j), after a batch of block changes in
//! one of them, at its due ticks, or for a player's bucket or a generated
//! chunk's post-processing. Writes go to an overlay the group commits, each
//! section its own cells; ticks, destroyed blocks, level events and stops at
//! the group's edge are returned beside it.

use std::collections::{HashMap, HashSet};

use super::components::{EntityBox, Used};
use super::fluid::{Emptied, Options};
use super::piston::Event;
use super::updater::{Engine, Report, World, ALL, UPDATE_LIMIT};
use super::{BlockAccess, Rules};
use crate::column::{ColumnStore, HEIGHT, MIN_Y};
use crate::piston::Moving;
use crate::worldgen::random::Random;

/// A block change the owner already made: the position and its old state.
pub type Change = ([i32; 3], u16);

/// What one run decided.
#[derive(Debug, Default)]
pub struct Outcome {
    /// Cells whose state the run changed, with their final state, in the
    /// order they first changed.
    pub changes: Vec<([i32; 3], u16)>,
    /// Block ticks scheduled: position, block, delay, `TickPriority`.
    pub block_ticks: Vec<([i32; 3], u16, i32, i32)>,
    /// Fluid ticks scheduled: position, fluid, delay.
    pub fluid_ticks: Vec<([i32; 3], u8, i32)>,
    /// Per action, its result: a bucket's `Emptied` (0 failed, 1 placed, 2
    /// evaporated), a pickup's item index + 1 (0: none), a post-processing
    /// mark's 1 (done) or 0 (it read past the owner: keep it), a use's 1
    /// (used) or 0 (passed on), a random tick's or bone meal's `growth`
    /// result, a transform's entry index + 1 (0: none applied), a trample's
    /// 1 (trampled) or 0; 0 for the others.
    pub results: Vec<i32>,
    /// The redstone torches' recent toggles after the run.
    pub toggles: Vec<([i32; 3], i64)>,
    /// Comparators' outputs the run changed (VMC-048a), in the order they
    /// first changed: the new output, or `None` for a comparator gone.
    pub outputs: Vec<([i32; 3], Option<i32>)>,
    /// Moving pistons' block entities the run changed (VMC-048b), in the
    /// order they first changed: the new one, or `None` for one gone.
    pub pistons: Vec<([i32; 3], Option<Moving>)>,
    /// The pending block events after the run: the input's and those it
    /// raised, less those it ran.
    pub events: Vec<Event>,
    /// Changed cells no write told clients of (VMC-048b: a moving piston's
    /// cells, which a client's own piston makes).
    pub hidden: Vec<[i32; 3]>,
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
    /// A random tick of a lava cell or a growing plant (VMC-039a); `fire`: a
    /// player is near enough for lava's fire to spread; `rain`: it rains at
    /// the cell above (farmland).
    RandomTick {
        pos: [i32; 3],
        fire: bool,
        rain: bool,
    },
    /// Bone meal used on the block at `pos` (VMC-039a), clicked on face
    /// `face` (`STEP` index, none for a dispenser's), `corals` whether the
    /// biome beside that face grows corals from it (VMC-039b).
    BoneMeal {
        pos: [i32; 3],
        face: Option<usize>,
        corals: bool,
    },
    /// A tool's block transformer `tool` used on `pos` from face `face`
    /// (VMC-039a).
    Transform {
        pos: [i32; 3],
        tool: usize,
        face: usize,
    },
    /// An entity trampling the farmland at `pos` (VMC-039a).
    Trample { pos: [i32; 3] },
    /// Berries picked at `pos` (VMC-039b).
    Harvest { pos: [i32; 3] },
    /// Shears used on `pos` by a player facing `facing` (`STEP` index) from
    /// the click (VMC-039c).
    Shear { pos: [i32; 3], facing: usize },
    /// A player's use of the block at `pos` (`useWithoutItem`, VMC-047a),
    /// facing horizontal direction `facing`, allowed to build or not.
    Use {
        pos: [i32; 3],
        facing: usize,
        may_build: bool,
    },
    /// The run's entities' contacts with the plates, buttons and tripwire
    /// they touch (`entityInside`).
    Contacts,
    /// A daylight detector's update.
    Daylight { pos: [i32; 3] },
    /// A lectern's page turned.
    Page { pos: [i32; 3] },
    /// A projectile's hit on a target block, of `power`, an arrow's or not.
    Hit {
        pos: [i32; 3],
        power: i32,
        arrow: bool,
    },
    /// A player placed the tripwire hook or diode at `pos` (`setPlacedBy`).
    Placed { pos: [i32; 3] },
    /// The block entity at `pos` changed (`setChanged`: a container's
    /// contents), which comparators reading it hear.
    OutputChanged { pos: [i32; 3] },
    /// A player with shears is breaking the tripwire at `pos`.
    Disarm { pos: [i32; 3] },
    /// A mob eats the block at `pos` while it still holds `from`
    /// (VMC-043c): it becomes `to` (`Level.setBlock(.., 2)`, a grazed
    /// grass block's dirt, a raided carrot's younger stage), or with no
    /// `to` it is destroyed without drops (`destroyBlock(pos, false)`);
    /// `event` is the block-break event's data shown first, if any. With
    /// `updates` the change updates its neighbours (`setBlockAndUpdate`, an
    /// enderman's), and with `survives` only a state that survives there is
    /// set (an enderman putting down its block, VMC-043b5).
    Edit {
        pos: [i32; 3],
        from: u16,
        to: Option<u16>,
        event: Option<i32>,
        updates: bool,
        survives: bool,
    },
    /// The moving piston's block entity at `pos` ticks (VMC-048b).
    Moving { pos: [i32; 3] },
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
    /// The owner's pending block ticks the run may ask about (position,
    /// block), beside those it schedules.
    pub pending: &'a [([i32; 3], u16)],
    /// The entities redstone's contacts and checks see.
    pub entities: &'a [EntityBox],
    /// The game time, and the torches' recent toggles.
    pub time: i64,
    pub toggles: &'a [([i32; 3], i64)],
    /// `skyDarken` and `SUN_ANGLE` (degrees) for daylight detectors.
    pub sky_darken: i32,
    pub sun_angle: f32,
    /// One sky light for every cell instead of the stores' (parity scenes,
    /// whose stores hold no light).
    pub sky: Option<i32>,
    /// The comparators' outputs (their block entities') the run may read,
    /// and the analog signals of the owner's block entities (containers).
    pub outputs: &'a [([i32; 3], i32)],
    pub containers: &'a [([i32; 3], i32)],
    /// The owner's pending block events (VMC-048b), and whether this run
    /// runs them (the tick's block event phase), after the rest.
    pub events: &'a [Event],
    pub run_events: bool,
    /// Whether the run is in the tick's first part (`isHandlingTick`).
    pub handling_tick: bool,
    /// The first tick order a block entity made by the run takes.
    pub order: i64,
    /// The world border (min x, min z, max x, max z) and the level's lowest
    /// and highest block y, which pistons cannot push past.
    pub border: Option<[f64; 4]>,
    pub build: Option<(i32, i32)>,
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
    block_ticks: Vec<([i32; 3], u16, i32, i32)>,
    fluid_ticks: Vec<([i32; 3], u8, i32)>,
    /// Comparators' outputs: the owner's, then the run's.
    outputs: HashMap<[i32; 3], i32>,
    written_outputs: HashMap<[i32; 3], Option<i32>>,
    output_order: Vec<[i32; 3]>,
    containers: &'s [([i32; 3], i32)],
    /// The run's due fluid ticks while they still wait for the fluid phase:
    /// a tick scheduled meanwhile for one of them is dropped, as vanilla's
    /// fluid `LevelTicks` still holds it then.
    held: HashSet<([i32; 3], u8)>,
    pending: &'s [([i32; 3], u16)],
    sky: Option<i32>,
    crossed: bool,
    random: &'s mut Random,
    /// Moving pistons' block entities the run wrote (VMC-048b).
    moving: HashMap<[i32; 3], Option<Moving>>,
    moving_order: Vec<[i32; 3]>,
    next_order: i64,
}

impl Live<'_> {
    fn base_moving(&self, pos: [i32; 3]) -> Option<Moving> {
        self.store((pos[0] >> 4, pos[2] >> 4))
            .and_then(|store| store.piston(pos))
    }

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
        self.block_ticks.push((pos, block, delay, 0));
    }

    fn schedule_block_tick_priority(
        &mut self,
        pos: [i32; 3],
        block: u16,
        delay: i32,
        priority: i32,
    ) {
        self.block_ticks.push((pos, block, delay, priority));
    }

    fn comparator_output(&mut self, pos: [i32; 3]) -> i32 {
        match self.written_outputs.get(&pos) {
            Some(output) => output.unwrap_or(0),
            None => self.outputs.get(&pos).copied().unwrap_or(0),
        }
    }

    fn schedule_fluid_tick(&mut self, pos: [i32; 3], fluid: u8, delay: i32) {
        if self.held.contains(&(pos, fluid)) {
            return;
        }
        self.fluid_ticks.push((pos, fluid, delay));
    }

    /// Ticks this run scheduled, and those of the owner's it was given.
    fn has_block_tick(&mut self, pos: [i32; 3], block: u16) -> bool {
        self.pending.contains(&(pos, block))
            || self
                .block_ticks
                .iter()
                .any(|&(p, b, _, _)| p == pos && b == block)
    }

    /// The level random's (a legacy random, as `RandomSource.create`'s).
    fn next_int(&mut self, bound: i32) -> i32 {
        self.random.next_int_bounded(bound)
    }

    fn next_float(&mut self) -> f32 {
        self.random.next_float()
    }

    fn next_double(&mut self) -> f64 {
        self.random.next_double()
    }

    fn next_long(&mut self) -> i64 {
        self.random.next_long()
    }

    fn moving_at(&mut self, pos: [i32; 3]) -> Option<Moving> {
        if !self.owns(pos) {
            return None;
        }
        World::moving(self, pos)
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

    fn sky_light(&mut self, pos: [i32; 3]) -> i32 {
        if let Some(sky) = self.sky {
            return sky;
        }
        self.store((pos[0] >> 4, pos[2] >> 4))
            .and_then(|store| store.light_at(pos[0], pos[1], pos[2]))
            .map_or(0, |(sky, _)| sky as i32)
    }

    fn block_light(&mut self, pos: [i32; 3]) -> i32 {
        if self.sky.is_some() {
            return 0;
        }
        self.store((pos[0] >> 4, pos[2] >> 4))
            .and_then(|store| store.light_at(pos[0], pos[1], pos[2]))
            .map_or(0, |(_, block)| block as i32)
    }

    fn set_comparator_output(&mut self, pos: [i32; 3], output: Option<i32>) {
        if self.written_outputs.insert(pos, output).is_none() {
            self.output_order.push(pos);
        }
    }

    fn container_signal(&mut self, pos: [i32; 3]) -> i32 {
        self.containers
            .iter()
            .find(|&&(p, _)| p == pos)
            .map_or(0, |&(_, signal)| signal)
    }

    fn moving(&mut self, pos: [i32; 3]) -> Option<Moving> {
        match self.moving.get(&pos) {
            Some(written) => *written,
            None => self.base_moving(pos),
        }
    }

    fn set_moving(&mut self, pos: [i32; 3], moving: Option<Moving>) {
        if self.moving.insert(pos, moving).is_none() {
            self.moving_order.push(pos);
        }
    }

    fn next_order(&mut self) -> i64 {
        self.next_order += 1;
        self.next_order - 1
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
        outputs: input.outputs.iter().copied().collect(),
        written_outputs: HashMap::new(),
        output_order: Vec::new(),
        containers: input.containers,
        held: input.fluid_ticks.iter().copied().collect(),
        pending: input.pending,
        sky: input.sky,
        crossed: false,
        random,
        moving: HashMap::new(),
        moving_order: Vec::new(),
        next_order: input.order,
    };
    let mut engine = Engine::new(rules, world)
        .with_budget(budget.unwrap_or(u64::MAX))
        .with_options(input.options);
    engine.redstone.time = input.time;
    engine.redstone.toggles = input.toggles.to_vec();
    engine.redstone.entities = input.entities.to_vec();
    engine.redstone.sky_darken = input.sky_darken;
    engine.redstone.sun_angle = input.sun_angle;
    engine.redstone.tnt_explodes = input.options.tnt_explodes;
    engine.pistons.events = input.events.iter().copied().collect();
    engine.pistons.handling_tick = input.handling_tick;
    if let Some(border) = input.border {
        engine.pistons.border = border;
    }
    if let Some((min_y, max_y)) = input.build {
        engine.pistons.min_y = min_y;
        engine.pistons.max_y = max_y;
    }
    for &(pos, old) in input.changes {
        engine.changed(pos, old, ALL, UPDATE_LIMIT);
    }
    let fluids = rules.fluids.is_some();
    let mut results = Vec::with_capacity(input.actions.len());
    for action in input.actions {
        results.push(match *action {
            Action::Use {
                pos,
                facing,
                may_build,
            } => i32::from(engine.use_block(pos, facing, may_build) == Used::Used),
            Action::Contacts => {
                engine.contacts();
                0
            }
            Action::Daylight { pos } => {
                engine.daylight_tick(pos);
                0
            }
            Action::Page { pos } => {
                engine.page_turned(pos);
                0
            }
            Action::Hit { pos, power, arrow } => {
                engine.target_hit(pos, power, arrow);
                0
            }
            Action::Placed { pos } => {
                engine.placed_by(pos);
                0
            }
            Action::OutputChanged { pos } => {
                engine.output_changed(pos);
                0
            }
            Action::Disarm { pos } => {
                engine.disarm(pos);
                0
            }
            Action::BoneMeal { pos, face, corals } => engine.bone_meal(pos, face, corals),
            Action::Moving { pos } => {
                engine.moving_tick(pos);
                0
            }
            Action::Transform { pos, tool, face } => engine.transform(pos, tool, face),
            Action::Trample { pos } => engine.trample(pos),
            Action::Harvest { pos } => engine.harvest(pos),
            Action::Edit {
                pos,
                from,
                to,
                event,
                updates,
                survives,
            } => engine.mob_edit(pos, from, to, event, updates, survives),
            Action::Shear { pos, facing } => engine.shear(pos, facing),
            Action::RandomTick { pos, rain, .. } if engine.growing(pos) => {
                engine.growth_random_tick(pos, rain)
            }
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
            Action::RandomTick { pos, fire, .. } => {
                engine.lava_random_tick(pos, fire);
                0
            }
        });
    }
    let table = rules.table.as_ref();
    engine.redstone.due = input
        .ticks
        .iter()
        .map(|&(pos, state)| (pos, table.block_of(state)))
        .collect();
    for &(pos, state) in input.ticks {
        engine.tick(pos, state);
    }
    if fluids {
        engine.world.held.clear();
        for &(pos, kind) in input.fluid_ticks {
            engine.fluid_tick(pos, kind);
        }
    }
    if input.run_events {
        engine.run_block_events();
    }
    if engine.report.over_budget {
        return Ok(None);
    }
    let Engine {
        world,
        report,
        redstone,
        pistons,
        ..
    } = engine;
    let changes = world
        .order
        .iter()
        .map(|&pos| (pos, world.overlay[&pos]))
        .filter(|&(pos, state)| state != world.base(pos))
        .collect();
    let outputs = world
        .output_order
        .iter()
        .map(|&pos| (pos, world.written_outputs[&pos]))
        .filter(|&(pos, output)| output != world.outputs.get(&pos).copied())
        .collect();
    let hidden = changes_hidden(&world, &report.sent);
    let moved = world
        .moving_order
        .iter()
        .map(|&pos| (pos, world.moving[&pos]))
        .filter(|&(pos, moving)| moving != world.base_moving(pos))
        .collect();
    Ok(Some(Outcome {
        changes,
        block_ticks: world.block_ticks,
        fluid_ticks: world.fluid_ticks,
        results,
        toggles: redstone.toggles,
        outputs,
        pistons: moved,
        events: pistons.events.into_iter().collect(),
        hidden,
        report,
    }))
}

/// The run's changed cells that no write sent to clients.
fn changes_hidden(world: &Live, sent: &HashSet<[i32; 3]>) -> Vec<[i32; 3]> {
    world
        .order
        .iter()
        .copied()
        .filter(|pos| !sent.contains(pos) && world.overlay[pos] != world.base(*pos))
        .collect()
}

/// What placing `item` at `target` writes (`Rules::place`, VMC-029d) over
/// `stores` (as `run`) and the comparators' `outputs`, the click's inputs
/// `values` by `placement::VARS`.
/// The light and power inputs are filled in here from the target's light and
/// its neighbours' signals; `seed` seeds the level random a placement draws
/// from. A placement that reads past the group's edge is refused.
#[allow(clippy::too_many_arguments)]
pub fn place(
    rules: &Rules,
    stores: &[&ColumnStore],
    absent: &HashSet<(i32, i32)>,
    item: u16,
    mut values: [u8; 13],
    target: [i32; 3],
    seed: i64,
    outputs: &[([i32; 3], i32)],
) -> Result<Option<Vec<([i32; 3], u16)>>, String> {
    let mut random = Random::legacy(seed);
    let mut world = Live {
        stores,
        absent,
        air: rules.table.default_state("air")?,
        overlay: HashMap::new(),
        order: Vec::new(),
        block_ticks: Vec::new(),
        fluid_ticks: Vec::new(),
        outputs: outputs.iter().copied().collect(),
        written_outputs: HashMap::new(),
        output_order: Vec::new(),
        containers: &[],
        held: HashSet::new(),
        pending: &[],
        sky: None,
        crossed: false,
        random: &mut random,
        moving: HashMap::new(),
        moving_order: Vec::new(),
        next_order: 0,
    };
    let (sky, block) = world
        .store((target[0] >> 4, target[2] >> 4))
        .and_then(|store| store.light_at(target[0], target[1], target[2]))
        .unwrap_or((0, 0));
    // `getRawBrightness(pos, 0)` and `canSeeSky` (sky light at its maximum),
    // and `hasNeighborSignal` at the target and above it.
    values[8] = sky.max(block);
    values[9] = u8::from(sky == 15);
    values[10] = u8::from(rules.has_neighbor_signal(&mut world, target));
    values[11] =
        u8::from(rules.has_neighbor_signal(&mut world, [target[0], target[1] + 1, target[2]]));
    let writes = rules.place(&mut world, item, &values, target)?;
    Ok(if world.crossed { None } else { writes })
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
            outputs: HashMap::new(),
            written_outputs: HashMap::new(),
            output_order: Vec::new(),
            containers: &[],
            held: HashSet::new(),
            pending: &[],
            sky: None,
            crossed: false,
            random: &mut random,
            moving: HashMap::new(),
            moving_order: Vec::new(),
            next_order: 0,
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
