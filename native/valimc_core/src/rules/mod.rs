//! Block rules shared by decoration and live play (VMC-077m): vanilla's
//! `canSurvive` and `updateShape`, from the generated facts and, for the
//! blocks whose rules read too much to tabulate, from code (fire, chorus,
//! connections, redstone wire, vines, speleothems, mossy carpets, corals).
//! Rules see the world through `BlockAccess`, which decoration's region and
//! the live region's store both implement. Live play's water and lava are
//! `fluid`'s, run by the block-update engine; live play's block placement is
//! `placement`'s (VMC-029d).

pub mod bubble;
pub mod components;
pub mod connect;
pub mod fire;
pub mod fluid;
pub mod live;
pub mod placement;
pub mod power;
pub mod redstone;
pub mod shapes;
pub mod support;
pub mod updater;
mod wire;

use std::sync::Arc;

use crate::facts::StateFacts;
use crate::worldgen::blocks::{
    BlockSet, BlockTable, FALLING, FLUID_FLOWING_WATER, FLUID_WATER, MOSSY_CARPET,
    REDSTONE_CONDUCTOR, REPLACEABLE, STURDY,
};
use crate::worldgen::end::Chorus;
use crate::worldgen::json::Json;
use connect::Connections;
use fire::Fire;
use placement::{Placed, Placement, Post};
use redstone::RedstoneWire;
use shapes::Shapes;
use support::Support;

/// The delay of a falling block's fall check (`getDelayAfterPlace`), VMC-050a2.
const FALL_DELAY: i32 = 2;

/// Water's tick delay (`WaterFluid.getTickDelay`).
pub const WATER_DELAY: i32 = 5;

/// What a rule may read and schedule: block states, scheduled ticks and the
/// level's random. Delays are vanilla's; decoration's proto chunks keep none.
pub trait BlockAccess {
    fn get(&mut self, pos: [i32; 3]) -> u16;
    fn schedule_block_tick(&mut self, pos: [i32; 3], block: u16, delay: i32);
    fn schedule_fluid_tick(&mut self, pos: [i32; 3], fluid: u8, delay: i32);
    fn has_block_tick(&mut self, pos: [i32; 3], block: u16) -> bool;
    /// The level random's `nextInt(bound)`.
    fn next_int(&mut self, bound: i32) -> i32;
    /// The level random's `nextFloat()` (a door's sound).
    fn next_float(&mut self) -> f32 {
        0.0
    }
    /// The level random's `nextDouble()` (a primed TNT's hop).
    fn next_double(&mut self) -> f64 {
        0.0
    }
}

/// `Direction` steps in vanilla order: down, up, north, south, west, east.
pub const STEP: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

pub fn at(pos: [i32; 3], d: usize) -> [i32; 3] {
    [
        pos[0] + STEP[d][0],
        pos[1] + STEP[d][1],
        pos[2] + STEP[d][2],
    ]
}

pub struct Rules {
    pub table: Arc<BlockTable>,
    pub support: Arc<Support>,
    pub shapes: Option<Arc<Shapes>>,
    /// Live play's survival facts, when given (`priv/physics/support.json`).
    pub live: Option<Support>,
    /// Live play's placement facts, when given (`priv/physics/placement.json`).
    pub placement: Option<Placement>,
    pub fire: Fire,
    pub chorus: Chorus,
    pub redstone: RedstoneWire,
    pub connections: Connections,
    /// Live play's fluid facts (`priv/physics/fluids.json`), when given.
    pub fluids: Option<fluid::FluidFacts>,
    /// Live play's redstone facts (`priv/physics/redstone.json`), when given.
    pub power: Option<power::PowerFacts>,
    vine_block: u16,
    speleothems: BlockSet,
    /// Blocks that hold leaves at distance 0 (`prevents_nearby_leaf_decay`).
    leaf_anchors: BlockSet,
}

impl std::fmt::Debug for Rules {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Rules")
    }
}

impl Rules {
    pub fn new(
        table: Arc<BlockTable>,
        support: Arc<Support>,
        shapes: Option<Arc<Shapes>>,
        live: Option<Support>,
    ) -> Result<Rules, String> {
        Ok(Rules {
            fire: Fire::new(&table)?,
            chorus: Chorus::new(&table)?,
            redstone: RedstoneWire::new(&table)?,
            connections: Connections::new(&table)?,
            vine_block: table.block("vine")?,
            speleothems: table.tag("minecraft:speleothems")?.clone(),
            leaf_anchors: table.tag("minecraft:prevents_nearby_leaf_decay")?.clone(),
            table,
            support,
            shapes,
            live,
            fluids: None,
            power: None,
            placement: None,
        })
    }

    /// The rules from their facts alone (live play, VMC-077m): the block
    /// registry with its tags (`block_registry`, `block_facts`), decoration's
    /// survival and shape facts (`support`, `shapes`), live play's survival
    /// facts (`live_support`) and its fluid facts (`fluids`, which read the
    /// collision shapes of `physics`).
    pub fn parse(
        json: &Json,
        states: &StateFacts,
        physics: Option<&'static crate::physics::facts::Facts>,
    ) -> Result<Rules, String> {
        let table = Arc::new(BlockTable::parse(
            json.field("block_registry")?,
            json.field("block_facts")?,
            states,
        )?);
        let support = Arc::new(Support::parse(json.field("support")?)?);
        let shapes = json
            .get("shapes")
            .map(Shapes::parse)
            .transpose()?
            .map(Arc::new);
        let live = json.get("live_support").map(Support::parse).transpose()?;
        let fluids = json
            .get("fluids")
            .map(|f| fluid::FluidFacts::parse(f, &table, physics))
            .transpose()?;
        let power = json
            .get("redstone")
            .map(|r| power::PowerFacts::parse(r, &table))
            .transpose()?;
        let mut rules = Rules::new(table, support, shapes, live)?;
        rules.fluids = fluids;
        rules.power = power;
        rules.placement = json.get("placement").map(Placement::parse).transpose()?;
        Ok(rules)
    }

    /// What placing `item` at `target` writes in live play (VMC-029d), the
    /// inputs `values` by `placement::VARS`: the placement facts' outcome,
    /// then a connecting block's or redstone wire's shape updates or a
    /// leaf's distance; `None`
    /// when vanilla refuses it. Obstruction by bodies is the caller's.
    pub fn place(
        &self,
        access: &mut dyn BlockAccess,
        item: u16,
        values: &[u8; 13],
        target: [i32; 3],
    ) -> Result<Option<Vec<([i32; 3], u16)>>, String> {
        let placement = self.placement.as_ref().ok_or("no placement facts")?;
        let fluid = |s: u16| self.table.fluid(s);
        let mut draws = Vec::new();
        let placed = {
            // Draws come after the reads; take them from the access afterwards.
            let mut read = |p: [i32; 3]| access.get(p);
            let mut draw = |bound: i32| {
                draws.push(bound);
                0
            };
            placement.place(item, values, target, &mut read, &fluid, &mut draw)?
        };
        let placed = if draws.is_empty() {
            placed
        } else {
            let drawn: Vec<i32> = draws.iter().map(|&b| access.next_int(b)).collect();
            let mut next = drawn.into_iter();
            let mut read = |p: [i32; 3]| access.get(p);
            let mut draw = |_bound: i32| next.next().unwrap_or(0);
            placement.place(item, values, target, &mut read, &fluid, &mut draw)?
        };
        let mut writes = match placed {
            Placed::Refused => return Ok(None),
            Placed::Walk => return self.walk(access, values, target),
            Placed::MossyCarpet => return self.place_mossy_carpet(access, target),
            Placed::Writes(writes) => writes,
        };
        let post = placement.post(item);
        if post != Post::None {
            let table = self.table.as_ref();
            for (pos, state) in writes.iter_mut().filter(|(pos, _)| *pos == target) {
                let mut read = |p: [i32; 3]| access.get(p);
                *state = match post {
                    Post::Shape => (0..6).fold(*state, |s, d| {
                        if table.block_of(s) == self.redstone.wire {
                            self.redstone.update_shape(table, &mut read, s, *pos, d)
                        } else if self.connections.handles(table, s) {
                            self.connections
                                .update_shape(table, &mut read, s, *pos, d)
                                .0
                        } else {
                            s
                        }
                    }),
                    Post::Leaves => self.leaf_distance(&mut read, *state, *pos),
                    Post::None => *state,
                };
            }
        }
        Ok(Some(writes))
    }

    /// `ScaffoldingBlock.getStateForPlacement`: waterlogged in water, its
    /// distance (`getDistance`: the one below it, 0 on a sturdy top, else one
    /// more than the nearest beside it, at most 7) and whether it is a bottom.
    fn scaffolding_state(
        &self,
        access: &mut dyn BlockAccess,
        pos: [i32; 3],
        scaffolding: u16,
    ) -> Result<u16, String> {
        let table = self.table.as_ref();
        let distance_of = |s: u16| {
            table
                .value(s, "distance")
                .and_then(|v| v.parse::<i32>().ok())
                .unwrap_or(7)
        };
        let below = access.get(at(pos, 0));
        let mut distance = 7;
        if table.block_of(below) == scaffolding {
            distance = distance_of(below);
        } else if table.flag(below, STURDY << 1) {
            distance = 0;
        }
        if distance != 0 {
            // `Direction.Plane.HORIZONTAL`: north, east, south, west.
            for d in [2, 5, 3, 4] {
                let beside = access.get(at(pos, d));
                if table.block_of(beside) == scaffolding {
                    distance = distance.min(distance_of(beside) + 1);
                    if distance == 1 {
                        break;
                    }
                }
            }
        }
        let water = table.fluid(access.get(pos)) == FLUID_WATER
            || table.fluid(access.get(pos)) == FLUID_FLOWING_WATER;
        let bottom = distance > 0 && table.block_of(below) != scaffolding;
        let state = table.default_state_of(scaffolding);
        let state = table.with(state, "waterlogged", if water { "true" } else { "false" });
        let state = state.and_then(|s| table.with(s, "distance", &distance.to_string()));
        let state =
            state.and_then(|s| table.with(s, "bottom", if bottom { "true" } else { "false" }));
        state.ok_or_else(|| "scaffolding state".to_string())
    }

    /// A pale moss carpet (`MossyCarpetBlock`): the carpet if it can survive
    /// (`BlockItem.canPlace`), and its topper.
    fn place_mossy_carpet(
        &self,
        access: &mut dyn BlockAccess,
        target: [i32; 3],
    ) -> Result<Option<Vec<([i32; 3], u16)>>, String> {
        // `canSurvive`: a base carpet stands on anything but air.
        if self.table.is_air(access.get(at(target, 0))) {
            return Ok(None);
        }
        let carpet = crate::worldgen::multiface::MossyCarpet::new(&self.table)?;
        let mut draws = 0;
        carpet.place(&mut |p| access.get(p), target, &mut || {
            draws += 1;
            false
        });
        let drawn: Vec<bool> = (0..draws).map(|_| access.next_int(2) == 1).collect();
        let mut next = drawn.into_iter();
        // Again with the level random's draws, which follow the reads.
        let (base, topper) = {
            let mut read = |p: [i32; 3]| access.get(p);
            carpet.place(&mut read, target, &mut || next.next().unwrap_or(false))
        };
        let mut writes = vec![(target, base)];
        if let Some(topper) = topper {
            writes.push((at(target, 1), topper));
        }
        Ok(Some(writes))
    }

    /// `ScaffoldingBlockItem.updatePlacementContext` on scaffolding: along
    /// the click's face when sneaking (into the block if the click was
    /// inside it), else up, or along the player's facing on a top face; past
    /// scaffolding, at most seven blocks sideways, to the first cell that
    /// yields, which takes scaffolding as a click on it along that direction
    /// would (`BlockPlaceContext.at`). A cell that does not yield or the
    /// world's edge ends it.
    fn walk(
        &self,
        access: &mut dyn BlockAccess,
        values: &[u8; 13],
        target: [i32; 3],
    ) -> Result<Option<Vec<([i32; 3], u16)>>, String> {
        const HORIZONTAL_3D: [usize; 4] = [3, 4, 2, 5];
        let table = self.table.as_ref();
        let face = values[6] as usize;
        let d = if values[5] == 1 {
            if values[12] == 1 {
                face ^ 1
            } else {
                face
            }
        } else if face == 1 {
            HORIZONTAL_3D[values[2] as usize & 3]
        } else {
            1
        };
        let scaffolding = table.block_of(access.get(target));
        let mut pos = at(target, d);
        let mut sideways = 0;
        while sideways < 7 {
            if !(-64..320).contains(&pos[1]) {
                break;
            }
            let state = access.get(pos);
            if table.block_of(state) != scaffolding {
                if !table.flag(state, REPLACEABLE) {
                    break;
                }
                // `ScaffoldingBlock.getStateForPlacement` there, which no
                // distance check precedes (`mustSurvive` is false).
                return Ok(Some(vec![(
                    pos,
                    self.scaffolding_state(access, pos, scaffolding)?,
                )]));
            }
            pos = at(pos, d);
            if d >= 2 {
                sideways += 1;
            }
        }
        Ok(None)
    }

    /// `Level.hasNeighborSignal`: whether a neighbour gives `pos` a signal,
    /// a conductor also the strongest direct signal into it. Wire gives its
    /// power where it connects (its stored connections); a comparator's,
    /// trapped chest's or jukebox's signal reads its block entity and is 0
    /// here, as for wire (`wire.rs`).
    pub fn has_neighbor_signal(&self, access: &mut dyn BlockAccess, pos: [i32; 3]) -> bool {
        let table = self.table.as_ref();
        (0..6).any(|d| {
            let neighbour = at(pos, d);
            let state = access.get(neighbour);
            let signal = if table.block_of(state) == self.redstone.wire {
                let power = table
                    .value(state, "power")
                    .and_then(|p| p.parse::<i32>().ok())
                    .unwrap_or(0);
                let connected = d == 1 || RedstoneWire::connected(table, state, d ^ 1);
                if d == 0 || !connected {
                    0
                } else {
                    power
                }
            } else {
                table.signal(state, d)
            };
            signal > 0
                || table.flag2(state, REDSTONE_CONDUCTOR)
                    && (0..6).any(|e| table.direct_signal(access.get(at(neighbour, e)), e) > 0)
        })
    }

    /// `LeavesBlock.updateDistance`: one more than the nearest neighbour's
    /// distance (0 for the blocks that hold leaves, a leaf's own, else 7),
    /// at most 7.
    fn leaf_distance(
        &self,
        read: &mut dyn FnMut([i32; 3]) -> u16,
        state: u16,
        pos: [i32; 3],
    ) -> u16 {
        let table = self.table.as_ref();
        let mut distance = 7;
        for d in 0..6 {
            let neighbour = read(at(pos, d));
            // Only leaves' own distance counts (scaffolding's is another property).
            let at_neighbour = if table.in_tag(neighbour, &self.leaf_anchors) {
                0
            } else if !table.class_name(neighbour).ends_with("LeavesBlock") {
                7
            } else {
                table
                    .value(neighbour, "distance")
                    .and_then(|v| v.parse::<i32>().ok())
                    .unwrap_or(7)
            };
            distance = distance.min(at_neighbour + 1);
            if distance == 1 {
                break;
            }
        }
        table
            .with(state, "distance", &distance.to_string())
            .unwrap_or(state)
    }

    /// `state.canSurvive(level, pos)`, as decoration checks it.
    pub fn survives(&self, access: &mut dyn BlockAccess, state: u16, pos: [i32; 3]) -> bool {
        self.support.survives(state, pos, &mut |p| access.get(p))
    }

    /// `state.updateShape(level, level, pos, d, …)` as decoration calls it
    /// (the cell at `replaced` reads as its given state): the new state;
    /// ticks go to `access`. A state whose update has no facts fails.
    pub fn update_shape(
        &self,
        access: &mut dyn BlockAccess,
        state: u16,
        pos: [i32; 3],
        d: usize,
        replaced: Option<([i32; 3], u16)>,
    ) -> Result<u16, String> {
        if let Some(result) = self.code_update(access, state, pos, d, replaced, false) {
            return result;
        }
        self.table_update(access, state, pos, d, replaced)
    }

    /// `updateShape` in live play, `replaced` being the update's neighbour
    /// (`neighbourState`, which may since have changed again): the rules in
    /// code, then live play's survival facts (they hold under any light), then
    /// the shape facts; a state none of them models keeps its state. Wire
    /// reads the level and only its floor from the update, as vanilla's does;
    /// torches and the redstone components read the level too; the other
    /// rules read the neighbour's cell as the update gives it.
    pub fn live_update_shape(
        &self,
        access: &mut dyn BlockAccess,
        state: u16,
        pos: [i32; 3],
        d: usize,
        replaced: Option<([i32; 3], u16)>,
    ) -> Result<u16, String> {
        // A block holding water (waterlogged, kelp, seagrass) schedules its
        // water in `updateShape`.
        if self.fluids.is_some()
            && !self
                .table
                .flag(state, crate::worldgen::blocks::LIQUID_BLOCK)
            && self.table.fluid(state) == FLUID_WATER
        {
            access.schedule_fluid_tick(pos, FLUID_WATER, WATER_DELAY);
        }
        if self.falls(state) {
            return Ok(self.falling_update(access, state, pos, replaced));
        }
        if let Some(result) = self.code_update(access, state, pos, d, replaced, true) {
            return result;
        }
        // Torches and the redstone components read the level in
        // `updateShape` (`canSurvive`, a note block's instrument), never the
        // update's neighbour state (VMC-047a).
        let reads_level = matches!(
            self.table.class_name(state),
            "TorchBlock" | "WallTorchBlock"
        ) || self
            .power
            .as_ref()
            .is_some_and(|p| p.component(&self.table, state).is_some());
        let replaced = if reads_level { None } else { replaced };
        let mut read = |p: [i32; 3]| match replaced {
            Some((at, s)) if at == p => s,
            _ => access.get(p),
        };
        if let Some(live) = self.live.as_ref().filter(|l| l.dependent(state)) {
            return Ok(match live.update(state, pos, d, &mut read) {
                // A block that stays may still change shape (a kelp plant
                // whose head went becomes a head, VMC-029d).
                support::Reaction::Keep => match &self.shapes {
                    Some(shapes) if shapes.models(state, d) => {
                        return self.table_update(access, state, pos, d, replaced)
                    }
                    _ => state,
                },
                support::Reaction::Break => self.table.default_state("air")?,
                support::Reaction::Tick(delay) => {
                    access.schedule_block_tick(pos, self.table.block_of(state), delay);
                    state
                }
            });
        }
        match &self.shapes {
            Some(shapes) if shapes.models(state, d) => {
                self.table_update(access, state, pos, d, replaced)
            }
            _ => Ok(state),
        }
    }

    /// What placing `state` at `pos` schedules: a falling block its check
    /// (`FallingBlock.onPlace`, VMC-050a2), a coral block away from water its
    /// death (`CoralBlock.getStateForPlacement`).
    pub fn placed(&self, access: &mut dyn BlockAccess, state: u16, pos: [i32; 3]) {
        let table = self.table.as_ref();
        if self.falls(state) {
            access.schedule_block_tick(pos, table.block_of(state), FALL_DELAY);
            return;
        }
        if table.class_name(state) != "CoralBlock" {
            return;
        }
        let water = (0..6).any(|d| {
            let fluid = table.fluid(access.get(at(pos, d)));
            fluid == FLUID_WATER || fluid == FLUID_FLOWING_WATER
        });
        if !water {
            let delay = 60 + access.next_int(40);
            access.schedule_block_tick(pos, table.block_of(state), delay);
        }
    }

    /// `state.canSurvive(level, pos)` as placement asks it in live play
    /// (`BlockItem.canPlace`): live play's survival facts, wire's floor and
    /// fire's support; the other rules in code (chorus, corals, vines,
    /// speleothems, mossy carpets) are not checked yet and survive.
    pub fn live_survives(&self, access: &mut dyn BlockAccess, state: u16, pos: [i32; 3]) -> bool {
        let table = self.table.as_ref();
        let mut read = |p: [i32; 3]| access.get(p);
        if let Some(live) = self.live.as_ref().filter(|l| l.dependent(state)) {
            return live.survives(state, pos, &mut read);
        }
        if table.block_of(state) == self.redstone.wire {
            return self.redstone.can_survive_on(table, read(at(pos, 0)));
        }
        match self.fire.update_shape(table, &mut read, state, pos) {
            Some(new_state) => !table.is_air(new_state),
            None => true,
        }
    }

    /// At a dependent state's scheduled tick in live play: whether it breaks.
    pub fn live_breaks(&self, access: &mut dyn BlockAccess, state: u16, pos: [i32; 3]) -> bool {
        self.live
            .as_ref()
            .is_some_and(|live| live.breaks(state, pos, &mut |p| access.get(p)))
    }

    /// The updates whose rules are code; `None` for the rest.
    fn code_update(
        &self,
        access: &mut dyn BlockAccess,
        state: u16,
        pos: [i32; 3],
        d: usize,
        replaced: Option<([i32; 3], u16)>,
        live: bool,
    ) -> Option<Result<u16, String>> {
        let table = self.table.as_ref();
        let class = table.class_name(state);
        if class.contains("Coral") {
            if let Some(new_state) = self.coral_update(access, replaced, class, state, pos, d) {
                return Some(Ok(new_state));
            }
        }
        if live {
            if let Some(new_state) = self.component_shape(access, state, pos, d, replaced) {
                return Some(Ok(new_state));
            }
        }
        let mut read = |p: [i32; 3]| match replaced {
            Some((at, s)) if at == p => s,
            _ => access.get(p),
        };
        if let Some(new_state) = self.fire.update_shape(table, &mut read, state, pos) {
            return Some(Ok(new_state));
        }
        if let Some((new_state, tick)) = self.chorus.update_shape(table, &mut read, state, pos, d) {
            if let Some(block) = tick {
                access.schedule_block_tick(pos, block, 1);
            }
            return Some(Ok(new_state));
        }
        if self.connections.handles(table, state) {
            let (new_state, waterlogged) = self
                .connections
                .update_shape(table, &mut read, state, pos, d);
            if waterlogged {
                access.schedule_fluid_tick(pos, FLUID_WATER, WATER_DELAY);
            }
            return Some(Ok(new_state));
        }
        if table.block_of(state) == self.redstone.wire {
            if live {
                let floor = replaced.filter(|&(p, _)| d == 0 && p == at(pos, 0));
                let mut level = |p: [i32; 3]| match floor {
                    Some((at, s)) if at == p => s,
                    _ => access.get(p),
                };
                let new_state = self.redstone.update_shape(table, &mut level, state, pos, d);
                return Some(Ok(new_state));
            }
            return Some(Ok(self
                .redstone
                .update_shape(table, &mut read, state, pos, d)));
        }
        if table.block_of(state) == self.vine_block {
            return Some(Ok(crate::worldgen::multiface::vine_update(
                table, &mut read, state, pos, d,
            )));
        }
        if table.in_tag(state, &self.speleothems) {
            return Some(crate::worldgen::speleothem::update_shape(
                table, access, state, pos, d,
            ));
        }
        if table.flag(state, MOSSY_CARPET) {
            let carpet = match crate::worldgen::multiface::MossyCarpet::new(table) {
                Ok(carpet) => carpet,
                Err(e) => return Some(Err(e)),
            };
            let air = table.default_state("air").ok()?;
            return Some(Ok(carpet.update_shape(
                &self.support,
                &mut read,
                state,
                pos,
                air,
            )));
        }
        None
    }

    /// The generated shape update facts' rule for `state` toward `d`.
    fn table_update(
        &self,
        access: &mut dyn BlockAccess,
        state: u16,
        pos: [i32; 3],
        d: usize,
        replaced: Option<([i32; 3], u16)>,
    ) -> Result<u16, String> {
        let mut read = |p: [i32; 3]| match replaced {
            Some((at, s)) if at == p => s,
            _ => access.get(p),
        };
        let shapes = self.shapes.as_ref().ok_or("no shape update facts")?;
        let (new_state, ticks, random) = shapes.update(state, d, pos, &mut read)?;
        // A random outcome draws after its reads, as vanilla's update does.
        let new_state = match random.len() {
            0 => new_state,
            n => random[access.next_int(n as i32) as usize],
        };
        for tick in ticks {
            let tick_pos = [
                pos[0] + tick.offset[0],
                pos[1] + tick.offset[1],
                pos[2] + tick.offset[2],
            ];
            if tick.fluid {
                access.schedule_fluid_tick(tick_pos, tick.id as u8, tick.delay);
            } else {
                access.schedule_block_tick(tick_pos, tick.id, tick.delay);
            }
        }
        Ok(new_state)
    }

    /// Whether `state`'s block falls (a `FallingBlock`, VMC-050a2).
    fn falls(&self, state: u16) -> bool {
        self.table.flag2(state, FALLING)
    }

    /// A falling block's `updateShape` in live play: it checks for a fall two
    /// ticks out; concrete powder beside water whose face toward it is not
    /// sturdy hardens (`ConcretePowderBlock.touchesLiquid`, which never looks
    /// down).
    fn falling_update(
        &self,
        access: &mut dyn BlockAccess,
        state: u16,
        pos: [i32; 3],
        replaced: Option<([i32; 3], u16)>,
    ) -> u16 {
        let table = self.table.as_ref();
        access.schedule_block_tick(pos, table.block_of(state), FALL_DELAY);
        if table.class_name(state) != "ConcretePowderBlock" {
            return state;
        }
        let wet = (1..6).any(|d| {
            let neighbour = match replaced {
                Some((p, s)) if p == at(pos, d) => s,
                _ => access.get(at(pos, d)),
            };
            let fluid = table.fluid(neighbour);
            (fluid == FLUID_WATER || fluid == FLUID_FLOWING_WATER)
                && !table.flag(neighbour, STURDY << (d ^ 1))
        });
        let name = &table.names[table.block_of(state) as usize];
        match name.strip_suffix("_powder") {
            Some(concrete) if wet => table.default_state(concrete).unwrap_or(state),
            _ => state,
        }
    }

    /// The corals' `updateShape` (VMC-025f): a live coral without water
    /// beside it (or, for plants and fans, in it) schedules its death 60–99
    /// ticks out, the delay from the level's random; waterlogged plants and
    /// fans schedule water; plants and fans need a sturdy floor, wall fans
    /// the face they hang on.
    fn coral_update(
        &self,
        access: &mut dyn BlockAccess,
        replaced: Option<([i32; 3], u16)>,
        class: &str,
        state: u16,
        pos: [i32; 3],
        d: usize,
    ) -> Option<u16> {
        const NAMES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];
        let neighbours: [u16; 6] = std::array::from_fn(|d| match replaced {
            Some((p, s)) if p == at(pos, d) => s,
            _ => access.get(at(pos, d)),
        });
        let table = self.table.as_ref();
        let water = |s: u16| {
            let fluid = table.fluid(s);
            fluid == FLUID_WATER || fluid == FLUID_FLOWING_WATER
        };
        let die_unless_wet = |access: &mut dyn BlockAccess| {
            if !(0..6).any(|d| water(neighbours[d])) {
                let delay = 60 + access.next_int(40);
                access.schedule_block_tick(pos, table.block_of(state), delay);
            }
        };
        let waterlogged = table.value(state, "waterlogged") == Some("true");
        let (live, wall) = match class {
            "CoralBlock" => {
                die_unless_wet(access);
                return Some(state);
            }
            "CoralPlantBlock" | "CoralFanBlock" => (true, false),
            "CoralWallFanBlock" => (true, true),
            "BaseCoralPlantBlock" | "BaseCoralFanBlock" => (false, false),
            "BaseCoralWallFanBlock" => (false, true),
            _ => return None,
        };
        // `canSurvive`: a sturdy top below, or the face behind a wall fan.
        let facing = if wall {
            NAMES
                .iter()
                .position(|n| Some(*n) == table.value(state, "facing"))
                .unwrap_or(2)
        } else {
            1
        };
        let support = if wall { facing ^ 1 } else { 0 };
        let breaks = d == support && !table.flag(neighbours[support], STURDY << facing);
        // Live corals break before anything else; dead ones schedule water
        // first.
        if breaks && live {
            return table.default_state("air").ok();
        }
        if live && !waterlogged {
            die_unless_wet(access);
        }
        if waterlogged {
            access.schedule_fluid_tick(pos, FLUID_WATER, WATER_DELAY);
        }
        if breaks {
            return table.default_state("air").ok();
        }
        Some(state)
    }
}
