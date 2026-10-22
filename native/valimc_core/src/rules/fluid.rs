//! Water and lava (VMC-031a): vanilla's `FlowingFluid` with `WaterFluid`
//! and `LavaFluid`, the `LiquidBlock` hooks (mixing into cobblestone,
//! obsidian, stone and basalt), `LiquidBlockContainer.placeLiquid`
//! (waterlogging), buckets (`BucketItem.emptyContents`,
//! `BucketPickup.pickupBlock`) and a generated chunk's post-processing marks
//! (`LevelChunk.postProcessGeneration`), run by the block-update engine.
//!
//! Fluid states come from the block fact table (fluid registry id, amount and
//! the falling flag); what the table does not hold (which containers take
//! which fluid, what a container becomes with water, what a bucket picks up,
//! what a bucket may replace) from `priv/physics/fluids.json`
//! (`FluidOracle facts`). Flow between cells reads collision shapes from the
//! physics fact table (`canPassThroughWall`).

use std::collections::HashMap;

use super::at;
use super::updater::{Engine, World, ALL, KNOWN_SHAPE, UPDATE_LIMIT, UPDATE_SHAPE_ORDER};
use crate::physics::facts::Facts as Physics;
use crate::physics::table::Context;
use crate::physics::VoxelShape;
use crate::worldgen::blocks::{
    BlockSet, BlockTable, FLUID_EMPTY, FLUID_FLOWING_LAVA, FLUID_FLOWING_WATER, FLUID_LAVA,
    FLUID_WATER, LIQUID, LIQUID_BLOCK, LIQUID_CONTAINER, SIMPLE_WATERLOGGED, SOLID,
};
use crate::worldgen::json::Json;

const DOWN: usize = 0;
const UP: usize = 1;
/// `Direction.Plane.HORIZONTAL`: north, east, south, west.
const HORIZONTAL: [usize; 4] = [2, 5, 3, 4];
/// `LiquidBlock.POSSIBLE_FLOW_DIRECTIONS`: down, south, north, east, west.
const FLOW_DIRECTIONS: [usize; 5] = [0, 3, 2, 5, 4];
/// `LevelEvent.LAVA_FIZZ`.
pub const FIZZ: i32 = 1501;
/// `LevelEvent.PARTICLES_DESTROY_BLOCK`.
pub const BREAK: i32 = 2001;

/// The level's settings a run reads: the dimension's `fast_lava` and
/// `water_evaporates` and the source conversion game rules.
#[derive(Clone, Copy, Debug, Default)]
pub struct Options {
    pub fast_lava: bool,
    pub water_evaporates: bool,
    pub water_conversion: bool,
    pub lava_conversion: bool,
}

impl Options {
    /// From the NIF's flag bits: fast lava, evaporating water, water and lava
    /// source conversion.
    pub fn from_bits(bits: u32) -> Options {
        Options {
            fast_lava: bits & 1 != 0,
            water_evaporates: bits & 2 != 0,
            water_conversion: bits & 4 != 0,
            lava_conversion: bits & 8 != 0,
        }
    }
}

/// A fluid state: its registry id, amount (1..8) and falling flag.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fluid {
    pub kind: u8,
    pub amount: u8,
    pub falling: bool,
}

pub const EMPTY: Fluid = Fluid {
    kind: FLUID_EMPTY,
    amount: 0,
    falling: false,
};

impl Fluid {
    pub fn of(table: &BlockTable, state: u16) -> Fluid {
        let kind = table.fluid(state);
        if kind == FLUID_EMPTY {
            return EMPTY;
        }
        let level = table.fluid_level[state as usize];
        Fluid {
            kind,
            amount: level & 15,
            falling: level & 16 != 0,
        }
    }

    pub fn is_empty(self) -> bool {
        self.kind == FLUID_EMPTY
    }

    pub fn is_source(self) -> bool {
        self.kind == FLUID_WATER || self.kind == FLUID_LAVA
    }

    pub fn is_water(self) -> bool {
        self.kind == FLUID_WATER || self.kind == FLUID_FLOWING_WATER
    }

    pub fn is_lava(self) -> bool {
        self.kind == FLUID_LAVA || self.kind == FLUID_FLOWING_LAVA
    }

    /// `Fluid.isSame`: water with water, lava with lava.
    fn same(self, kind: u8) -> bool {
        kind != FLUID_EMPTY && self.kind != FLUID_EMPTY && self.kind.div_ceil(2) == kind.div_ceil(2)
    }

    /// `getOwnHeight`.
    fn own_height(self) -> f32 {
        self.amount as f32 / 9.0
    }
}

fn source_of(kind: u8) -> u8 {
    if kind <= FLUID_WATER {
        FLUID_WATER
    } else {
        FLUID_LAVA
    }
}

fn flowing_of(kind: u8) -> u8 {
    source_of(kind) - 1
}

/// `getSource(false)`.
fn source(kind: u8) -> Fluid {
    Fluid {
        kind: source_of(kind),
        amount: 8,
        falling: false,
    }
}

/// `getFlowing(amount, falling)`.
fn flowing(kind: u8, amount: u8, falling: bool) -> Fluid {
    Fluid {
        kind: flowing_of(kind),
        amount,
        falling,
    }
}

fn hex(json: &Json, key: &str) -> Result<Vec<u8>, String> {
    let text = json.field(key)?.as_str()?;
    if !text.len().is_multiple_of(2) {
        return Err(format!("{key}: odd hex"));
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).map_err(|e| format!("{key}: {e}")))
        .collect()
}

/// The facts the fluid rules read (`priv/physics/fluids.json`) and the
/// blocks they name.
#[derive(Debug)]
pub struct FluidFacts {
    /// Per state: bit 0 a liquid container, bit f (1..4) whether it takes
    /// fluid f, bit 5 replaceable by water, bit 6 by lava.
    liquid: Vec<u8>,
    waterlogs: HashMap<u16, u16>,
    pickups: HashMap<u16, (u16, u8)>,
    pub pickup_items: Vec<String>,
    /// The liquid blocks' states by legacy level: water's, then lava's.
    water: [u16; 16],
    lava: [u16; 16],
    air: u16,
    stone: u16,
    cobblestone: u16,
    obsidian: u16,
    basalt: u16,
    soul_soil: u16,
    blue_ice: u16,
    powder_snow: u16,
    washed: BlockSet,
    physics: Option<&'static Physics>,
}

impl FluidFacts {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        physics: Option<&'static Physics>,
    ) -> Result<FluidFacts, String> {
        let liquid = hex(json, "liquid")?;
        if liquid.len() != table.block_of.len() {
            return Err("fluid facts: state count".into());
        }
        let u16_at = |bytes: &[u8], i: usize| u16::from_be_bytes([bytes[i], bytes[i + 1]]);
        let waterlogs = hex(json, "waterlogs")?;
        let pickups = hex(json, "pickups")?;
        if !waterlogs.len().is_multiple_of(4) || !pickups.len().is_multiple_of(5) {
            return Err("fluid facts: record sizes".into());
        }
        let levels = |name: &str| -> Result<[u16; 16], String> {
            let default = table.default_state(name)?;
            let mut states = [0; 16];
            for (level, state) in states.iter_mut().enumerate() {
                *state = table
                    .with(default, "level", &level.to_string())
                    .ok_or("liquid levels")?;
            }
            Ok(states)
        };
        let pickup_items = json
            .field("pickup_items")?
            .as_array()?
            .iter()
            .map(|n| n.as_str().map(str::to_string))
            .collect::<Result<_, _>>()?;
        Ok(FluidFacts {
            liquid,
            waterlogs: (0..waterlogs.len())
                .step_by(4)
                .map(|i| (u16_at(&waterlogs, i), u16_at(&waterlogs, i + 2)))
                .collect(),
            pickups: (0..pickups.len())
                .step_by(5)
                .map(|i| {
                    (
                        u16_at(&pickups, i),
                        (u16_at(&pickups, i + 2), pickups[i + 4]),
                    )
                })
                .collect(),
            pickup_items,
            water: levels("water")?,
            lava: levels("lava")?,
            air: table.default_state("air")?,
            stone: table.default_state("stone")?,
            cobblestone: table.default_state("cobblestone")?,
            obsidian: table.default_state("obsidian")?,
            basalt: table.default_state("basalt")?,
            soul_soil: table.block("soul_soil")?,
            blue_ice: table.block("blue_ice")?,
            powder_snow: table.block("powder_snow")?,
            washed: table.tag("minecraft:washed_away_by_fluids")?.clone(),
            physics,
        })
    }

    /// `FluidState.createLegacyBlock`.
    pub fn legacy(&self, fluid: Fluid) -> u16 {
        if fluid.is_empty() {
            return self.air;
        }
        let level = if fluid.is_source() {
            0
        } else {
            8 - fluid.amount.min(8) as usize + if fluid.falling { 8 } else { 0 }
        };
        if fluid.is_water() {
            self.water[level]
        } else {
            self.lava[level]
        }
    }

    /// The item `pickupBlock` returns at `state` and the state it leaves.
    pub fn pickup(&self, state: u16) -> Option<(u16, u8)> {
        self.pickups.get(&state).copied()
    }

    /// The collision shape `canPassThroughWall` reads: the empty context's.
    fn shape(&self, state: u16, pos: [i32; 3]) -> Option<(&VoxelShape, [f64; 3])> {
        let picked = self.physics?.shapes.shape(state, pos, &Context::default());
        Some((picked.shape, picked.offset))
    }
}

/// `Shapes.mergedFaceOccludes(source, target, direction)` over collision
/// shapes with their offsets: the faces of the two shapes that touch the
/// cells' shared side cover it together. `Shapes.block()` and two empty shapes
/// short-cut as vanilla's `canPassThroughWall` does.
fn merged_face_occludes(
    source: (&VoxelShape, [f64; 3]),
    target: (&VoxelShape, [f64; 3]),
    d: usize,
) -> bool {
    let axis = match d {
        0 | 1 => 1,
        2 | 3 => 2,
        _ => 0,
    };
    let positive = d == 1 || d == 3 || d == 5;
    let (first, second) = if positive {
        (source, target)
    } else {
        (target, source)
    };
    let (u, v) = match axis {
        0 => (1, 2),
        1 => (0, 2),
        _ => (0, 1),
    };
    let mut rects: Vec<[f64; 4]> = Vec::new();
    // The first shape's last layer if it reaches 1, the second's first layer
    // if it starts at 0 (vanilla's `SliceShape`s).
    for (shape, offset, last) in [(first.0, first.1, true), (second.0, second.1, false)] {
        if shape.is_empty() {
            continue;
        }
        let size = shape.sizes[axis] as isize;
        let filled_on = |layer: isize| {
            let mut cells = Vec::new();
            for i in 0..shape.sizes[u] as isize {
                for j in 0..shape.sizes[v] as isize {
                    let mut cell = [0isize; 3];
                    cell[axis] = layer;
                    cell[u] = i;
                    cell[v] = j;
                    if shape.full(cell[0], cell[1], cell[2]) {
                        cells.push((i as usize, j as usize));
                    }
                }
            }
            cells
        };
        let coordinate = |a: usize, i: usize| shape.axes[a][i] + offset[a];
        // `max(axis)`/`min(axis)`: the far edge of the last filled layer, the
        // near edge of the first.
        let layers: Vec<isize> = (0..size).filter(|&l| !filled_on(l).is_empty()).collect();
        let (Some(&low), Some(&high)) = (layers.first(), layers.last()) else {
            continue;
        };
        let edge = if last {
            coordinate(axis, high as usize + 1)
        } else {
            coordinate(axis, low as usize)
        };
        let target_edge = if last { 1.0 } else { 0.0 };
        if (edge - target_edge).abs() > 1.0e-7 {
            continue;
        }
        let layer = if last { size - 1 } else { 0 };
        for (i, j) in filled_on(layer) {
            rects.push([
                coordinate(u, i),
                coordinate(u, i + 1),
                coordinate(v, j),
                coordinate(v, j + 1),
            ]);
        }
    }
    covers_unit_square(&rects)
}

/// Whether the rectangles (`[u0, u1, v0, v1]`) cover `[0, 1]²`.
fn covers_unit_square(rects: &[[f64; 4]]) -> bool {
    if rects.is_empty() {
        return false;
    }
    let mut us = vec![0.0, 1.0];
    let mut vs = vec![0.0, 1.0];
    let inside = |value: &&f64| **value > 0.0 && **value < 1.0;
    for r in rects {
        us.extend(r[..2].iter().filter(inside));
        vs.extend(r[2..].iter().filter(inside));
    }
    for list in [&mut us, &mut vs] {
        list.sort_by(f64::total_cmp);
        list.dedup();
    }
    us.windows(2).all(|uw| {
        let mu = (uw[0] + uw[1]) / 2.0;
        vs.windows(2).all(|vw| {
            let mv = (vw[0] + vw[1]) / 2.0;
            rects
                .iter()
                .any(|r| r[0] <= mu && mu <= r[1] && r[2] <= mv && mv <= r[3])
        })
    })
}

/// `FlowingFluid.SpreadContext`: one `getSpread`'s state and hole caches.
struct SpreadContext {
    states: HashMap<[i32; 3], u16>,
    holes: HashMap<[i32; 3], bool>,
}

/// What a bucket emptied: nothing, its fluid, or water that evaporated.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Emptied {
    Failed,
    Placed,
    Evaporated,
}

impl<W: World> Engine<'_, W> {
    fn fluids(&self) -> &FluidFacts {
        self.rules.fluids.as_ref().expect("fluid facts")
    }

    fn fluid_at(&mut self, pos: [i32; 3]) -> Fluid {
        let state = self.world.get(pos);
        Fluid::of(&self.rules.table, state)
    }

    fn lava_fast(&self) -> bool {
        self.options.fast_lava
    }

    /// `getTickDelay`.
    pub fn tick_delay(&self, kind: u8) -> i32 {
        if source_of(kind) == FLUID_WATER {
            5
        } else if self.lava_fast() {
            10
        } else {
            30
        }
    }

    fn drop_off(&self, kind: u8) -> u8 {
        if source_of(kind) == FLUID_LAVA && !self.lava_fast() {
            2
        } else {
            1
        }
    }

    fn slope_find_distance(&self, kind: u8) -> i32 {
        if source_of(kind) == FLUID_LAVA && !self.lava_fast() {
            2
        } else {
            4
        }
    }

    fn can_convert(&self, kind: u8) -> bool {
        if source_of(kind) == FLUID_WATER {
            self.options.water_conversion
        } else {
            self.options.lava_conversion
        }
    }

    /// `FlowingFluid.canPassThroughWall`.
    fn pass_through_wall(&self, d: usize, from: ([i32; 3], u16), to: ([i32; 3], u16)) -> bool {
        let facts = self.fluids();
        let (Some(source), Some(target)) = (facts.shape(from.1, from.0), facts.shape(to.1, to.0))
        else {
            return true;
        };
        if target.0.full_block || source.0.full_block {
            return false;
        }
        if source.0.is_empty() && target.0.is_empty() {
            return true;
        }
        !merged_face_occludes(source, target, d)
    }

    fn container(&self, state: u16) -> bool {
        self.rules.table.flag(state, LIQUID_CONTAINER)
    }

    /// `canHoldAnyFluid`.
    fn hold_any(&self, state: u16) -> bool {
        self.container(state) || self.rules.table.in_tag(state, &self.fluids().washed)
    }

    /// `canHoldSpecificFluid`: a container's `canPlaceLiquid`.
    fn hold_specific(&self, state: u16, kind: u8) -> bool {
        !self.container(state)
            || (kind != FLUID_EMPTY && self.fluids().liquid[state as usize] >> kind & 1 == 1)
    }

    fn source_of_this(kind: u8, fluid: Fluid) -> bool {
        fluid.same(kind) && fluid.is_source()
    }

    /// `canMaybePassThrough`.
    fn maybe_pass(&self, kind: u8, from: ([i32; 3], u16), d: usize, to: ([i32; 3], u16)) -> bool {
        let fluid = Fluid::of(&self.rules.table, to.1);
        !Self::source_of_this(kind, fluid)
            && self.hold_any(to.1)
            && self.pass_through_wall(d, from, to)
    }

    /// `isWaterHole`.
    fn water_hole(&self, kind: u8, top: ([i32; 3], u16), bottom: ([i32; 3], u16)) -> bool {
        if !self.pass_through_wall(DOWN, top, bottom) {
            return false;
        }
        Fluid::of(&self.rules.table, bottom.1).same(kind)
            || (self.hold_any(bottom.1) && self.hold_specific(bottom.1, flowing_of(kind)))
    }

    /// `getNewLiquid`.
    fn new_liquid(&mut self, kind: u8, pos: [i32; 3], state: u16) -> Fluid {
        let mut highest = 0;
        let mut sources = 0;
        for d in HORIZONTAL {
            let p = at(pos, d);
            let s = self.world.get(p);
            let f = Fluid::of(&self.rules.table, s);
            if f.same(kind) && self.pass_through_wall(d, (pos, state), (p, s)) {
                if f.is_source() {
                    sources += 1;
                }
                highest = highest.max(f.amount);
            }
        }
        if sources >= 2 && self.can_convert(kind) {
            let below = self.world.get(at(pos, DOWN));
            let f = Fluid::of(&self.rules.table, below);
            if self.rules.table.flag(below, SOLID) || Self::source_of_this(kind, f) {
                return source(kind);
            }
        }
        let above_pos = at(pos, UP);
        let above = self.world.get(above_pos);
        let f = Fluid::of(&self.rules.table, above);
        if f.same(kind) && self.pass_through_wall(UP, (pos, state), (above_pos, above)) {
            return flowing(kind, 8, true);
        }
        let amount = highest as i32 - self.drop_off(kind) as i32;
        if amount <= 0 {
            EMPTY
        } else {
            flowing(kind, amount as u8, false)
        }
    }

    /// `FluidState.getHeight` at `pos`.
    fn height(&mut self, fluid: Fluid, pos: [i32; 3]) -> f32 {
        if self.fluid_at(at(pos, UP)).same(fluid.kind) {
            1.0
        } else {
            fluid.own_height()
        }
    }

    /// `getSpreadDelay`: lava rising in place waits four times as long, three
    /// times in four.
    fn spread_delay(&mut self, pos: [i32; 3], old: Fluid, new: Fluid) -> i32 {
        let delay = self.tick_delay(old.kind);
        if old.is_lava()
            && !old.is_empty()
            && !new.is_empty()
            && !old.falling
            && !new.falling
            && self.height(new, pos) > self.height(old, pos)
            && self.world.next_int(4) != 0
        {
            return delay * 4;
        }
        delay
    }

    /// A due fluid tick of `kind` at `pos` (`ServerLevel.tickFluid`): the
    /// fluid there ticks if it is still that fluid. A tick whose reads would
    /// leave the owner's cells waits for its fluid's delay instead.
    pub fn fluid_tick(&mut self, pos: [i32; 3], kind: u8) {
        if !self.world.owns(pos) {
            return;
        }
        let state = self.world.get(pos);
        let fluid = Fluid::of(&self.rules.table, state);
        if fluid.kind != kind {
            return;
        }
        if !self.owns_around(pos) {
            self.report.stopped += 1;
            let delay = self.tick_delay(kind);
            self.world.schedule_fluid_tick(pos, kind, delay);
            return;
        }
        self.tick_fluid(pos, state, fluid);
    }

    /// Whether the owner holds every chunk a fluid tick at `pos` can read
    /// (five cells around it: the slope search and its holes).
    fn owns_around(&self, pos: [i32; 3]) -> bool {
        let chunks = |c: i32| ((c - 5) >> 4)..=((c + 5) >> 4);
        chunks(pos[0])
            .all(|cx| chunks(pos[2]).all(|cz| self.world.owns([cx * 16, pos[1], cz * 16])))
    }

    /// `FlowingFluid.tick`.
    fn tick_fluid(&mut self, pos: [i32; 3], mut state: u16, mut fluid: Fluid) {
        if !fluid.is_source() {
            let current = self.world.get(pos);
            let new = self.new_liquid(fluid.kind, pos, current);
            let delay = self.spread_delay(pos, fluid, new);
            if new.is_empty() {
                fluid = new;
                state = self.fluids().air;
                self.set_block(pos, state, ALL, UPDATE_LIMIT);
            } else if new != fluid {
                fluid = new;
                state = self.fluids().legacy(new);
                self.set_block(pos, state, ALL, UPDATE_LIMIT);
                self.world.schedule_fluid_tick(pos, new.kind, delay);
            }
        }
        self.spread(pos, state, fluid);
    }

    /// `FlowingFluid.spread`.
    fn spread(&mut self, pos: [i32; 3], state: u16, fluid: Fluid) {
        if fluid.is_empty() {
            return;
        }
        let below_pos = at(pos, DOWN);
        let below = self.world.get(below_pos);
        if self.maybe_pass(fluid.kind, (pos, state), DOWN, (below_pos, below)) {
            let new = self.new_liquid(fluid.kind, below_pos, below);
            let below_fluid = Fluid::of(&self.rules.table, below);
            if self.replaceable_with(below_fluid, below_pos, new.kind, DOWN)
                && self.hold_specific(below, new.kind)
            {
                self.spread_to(fluid.kind, below_pos, below, DOWN, new);
                if self.source_neighbors(fluid.kind, pos) >= 3 {
                    self.spread_to_sides(pos, fluid, state);
                }
                return;
            }
        }
        if fluid.is_source() || !self.water_hole(fluid.kind, (pos, state), (below_pos, below)) {
            self.spread_to_sides(pos, fluid, state);
        }
    }

    /// `FluidState.canBeReplacedWith`: water only from above by something
    /// else; lava at least 4/9 high by water.
    fn replaceable_with(&mut self, fluid: Fluid, pos: [i32; 3], other: u8, d: usize) -> bool {
        if fluid.is_water() {
            d == DOWN && !(other == FLUID_WATER || other == FLUID_FLOWING_WATER)
        } else if fluid.is_lava() {
            self.height(fluid, pos) >= 0.444_444_45
                && (other == FLUID_WATER || other == FLUID_FLOWING_WATER)
        } else {
            true
        }
    }

    /// `sourceNeighborCount`.
    fn source_neighbors(&mut self, kind: u8, pos: [i32; 3]) -> usize {
        HORIZONTAL
            .iter()
            .filter(|&&d| {
                let f = self.fluid_at(at(pos, d));
                Self::source_of_this(kind, f)
            })
            .count()
    }

    /// `spreadToSides`.
    fn spread_to_sides(&mut self, pos: [i32; 3], fluid: Fluid, state: u16) {
        let mut neighbor = fluid.amount as i32 - self.drop_off(fluid.kind) as i32;
        if fluid.falling {
            neighbor = 7;
        }
        if neighbor <= 0 {
            return;
        }
        for (d, new) in self.spreads(fluid.kind, pos, state) {
            let p = at(pos, d);
            let s = self.world.get(p);
            self.spread_to(fluid.kind, p, s, d, new);
        }
    }

    /// `getSpread`: the sides toward the nearest way down, each with its new
    /// fluid, in `Direction` order (an `EnumMap`'s).
    fn spreads(&mut self, kind: u8, pos: [i32; 3], state: u16) -> Vec<(usize, Fluid)> {
        let mut lowest = 1000;
        let mut result: Vec<(usize, Fluid)> = Vec::new();
        let mut context: Option<SpreadContext> = None;
        for d in HORIZONTAL {
            let p = at(pos, d);
            let s = self.world.get(p);
            if !self.maybe_pass(kind, (pos, state), d, (p, s)) {
                continue;
            }
            let new = self.new_liquid(kind, p, s);
            if !self.hold_specific(s, new.kind) {
                continue;
            }
            let context = context.get_or_insert_with(|| SpreadContext {
                states: HashMap::new(),
                holes: HashMap::new(),
            });
            let distance = if self.hole(kind, context, p) {
                0
            } else {
                self.slope_distance(kind, p, 1, d ^ 1, s, context)
            };
            if distance < lowest {
                result.clear();
            }
            if distance <= lowest {
                let fluid = Fluid::of(&self.rules.table, s);
                if self.replaceable_with(fluid, p, new.kind, d) {
                    result.push((d, new));
                }
                lowest = distance;
            }
        }
        result.sort_by_key(|&(d, _)| d);
        result
    }

    fn context_state(&mut self, context: &mut SpreadContext, pos: [i32; 3]) -> u16 {
        if let Some(&state) = context.states.get(&pos) {
            return state;
        }
        let state = self.world.get(pos);
        context.states.insert(pos, state);
        state
    }

    /// `SpreadContext.isHole`.
    fn hole(&mut self, kind: u8, context: &mut SpreadContext, pos: [i32; 3]) -> bool {
        if let Some(&hole) = context.holes.get(&pos) {
            return hole;
        }
        let state = self.context_state(context, pos);
        let below = at(pos, DOWN);
        let below_state = self.world.get(below);
        let hole = self.water_hole(kind, (pos, state), (below, below_state));
        context.holes.insert(pos, hole);
        hole
    }

    /// `getSlopeDistance`: the fewest steps from `pos` to a way down, not
    /// back toward `from`, within the slope find distance (1000: none).
    fn slope_distance(
        &mut self,
        kind: u8,
        pos: [i32; 3],
        pass: i32,
        from: usize,
        state: u16,
        context: &mut SpreadContext,
    ) -> i32 {
        let mut lowest = 1000;
        for d in HORIZONTAL {
            if d == from {
                continue;
            }
            let p = at(pos, d);
            let s = self.context_state(context, p);
            if !(self.maybe_pass(kind, (pos, state), d, (p, s))
                && self.hold_specific(s, flowing_of(kind)))
            {
                continue;
            }
            if self.hole(kind, context, p) {
                return pass;
            }
            if pass < self.slope_find_distance(kind) {
                let v = self.slope_distance(kind, p, pass + 1, d ^ 1, s, context);
                lowest = lowest.min(v);
            }
        }
        lowest
    }

    /// `spreadTo` (with `LavaFluid`'s: lava falling into water makes stone).
    fn spread_to(&mut self, kind: u8, pos: [i32; 3], state: u16, d: usize, target: Fluid) {
        if d == DOWN && source_of(kind) == FLUID_LAVA {
            let fluid = self.fluid_at(pos);
            if fluid.is_water() {
                if self.rules.table.flag(state, LIQUID_BLOCK) {
                    let stone = self.fluids().stone;
                    self.set_block(pos, stone, ALL, UPDATE_LIMIT);
                }
                self.event(pos, FIZZ, 0);
                return;
            }
        }
        if self.container(state) {
            self.place_liquid(pos, state, target);
            return;
        }
        if !self.rules.table.is_air(state) {
            self.before_destroying(kind, pos, state);
        }
        let legacy = self.fluids().legacy(target);
        self.set_block(pos, legacy, ALL, UPDATE_LIMIT);
    }

    /// `beforeDestroyingBlock`: water drops what it washes away, lava fizzes.
    fn before_destroying(&mut self, kind: u8, pos: [i32; 3], state: u16) {
        if source_of(kind) == FLUID_LAVA {
            self.event(pos, FIZZ, 0);
        } else if !self.rules.table.flag(state, LIQUID_BLOCK) {
            self.report.destroyed.push(super::updater::Destroyed {
                pos,
                state,
                drops: true,
                effects: false,
            });
        }
    }

    pub(super) fn event(&mut self, pos: [i32; 3], kind: i32, data: i32) {
        self.report.events.push((pos, kind, data));
    }

    /// `LiquidBlockContainer.placeLiquid`: a container that takes a water
    /// source becomes waterlogged and schedules its water.
    fn place_liquid(&mut self, pos: [i32; 3], state: u16, fluid: Fluid) -> bool {
        if fluid.kind != FLUID_WATER {
            return false;
        }
        let Some(&new) = self.fluids().waterlogs.get(&state) else {
            return false;
        };
        self.set_block(pos, new, ALL, UPDATE_LIMIT);
        let delay = self.tick_delay(FLUID_WATER);
        self.world.schedule_fluid_tick(pos, FLUID_WATER, delay);
        true
    }

    /// `LiquidBlock.shouldSpreadLiquid`: lava beside water (or above it)
    /// becomes obsidian (a source) or cobblestone; lava on soul soil beside
    /// blue ice becomes basalt.
    fn should_spread(&mut self, pos: [i32; 3], state: u16) -> bool {
        let fluid = Fluid::of(&self.rules.table, state);
        if !fluid.is_lava() {
            return true;
        }
        let table = self.rules.table.clone();
        let soul = table.block_of(self.world.get(at(pos, DOWN))) == self.fluids().soul_soil;
        for d in FLOW_DIRECTIONS {
            let n = at(pos, d ^ 1);
            let neighbor = self.world.get(n);
            if Fluid::of(&table, neighbor).is_water() {
                let source = self.fluid_at(pos).is_source();
                let facts = self.fluids();
                let block = if source {
                    facts.obsidian
                } else {
                    facts.cobblestone
                };
                self.set_block(pos, block, ALL, UPDATE_LIMIT);
                self.event(pos, FIZZ, 0);
                return false;
            }
            if soul && table.block_of(neighbor) == self.fluids().blue_ice {
                let basalt = self.fluids().basalt;
                self.set_block(pos, basalt, ALL, UPDATE_LIMIT);
                self.event(pos, FIZZ, 0);
                return false;
            }
        }
        true
    }

    /// `LiquidBlock.onPlace` and `neighborChanged`: mix, else schedule the
    /// fluid's tick.
    pub(super) fn liquid_changed(&mut self, pos: [i32; 3], state: u16) {
        if !self.rules.table.flag(state, LIQUID_BLOCK) || self.rules.fluids.is_none() {
            return;
        }
        if self.should_spread(pos, state) {
            let kind = Fluid::of(&self.rules.table, state).kind;
            let delay = self.tick_delay(kind);
            self.world.schedule_fluid_tick(pos, kind, delay);
        }
    }

    /// `LiquidBlock.updateShape`: a source here or beside schedules the
    /// fluid's tick; the state stays.
    pub(super) fn liquid_shape(&mut self, pos: [i32; 3], state: u16, neighbor: u16) {
        let table = &self.rules.table;
        let fluid = Fluid::of(table, state);
        if fluid.is_source() || Fluid::of(table, neighbor).is_source() {
            let delay = self.tick_delay(fluid.kind);
            self.world.schedule_fluid_tick(pos, fluid.kind, delay);
        }
    }

    /// `BucketPickup.pickupBlock` at `pos`: the item index it gives, if any.
    pub fn pickup(&mut self, pos: [i32; 3]) -> Option<u8> {
        if !self.world.owns(pos) {
            return None;
        }
        let state = self.world.get(pos);
        let (after, item) = self.fluids().pickup(state)?;
        let table = self.rules.table.clone();
        if table.flag(state, SIMPLE_WATERLOGGED) {
            self.set_block(pos, after, ALL, UPDATE_LIMIT);
            let mark = self.world.begin();
            let survives = self.rules.live_survives(&mut self.world, state, pos);
            if !self.world.crossed(mark) && !survives {
                self.destroy(pos, true, UPDATE_LIMIT);
            }
        } else {
            self.set_block(pos, after, ALL, UPDATE_LIMIT);
            if table.block_of(state) == self.fluids().powder_snow {
                self.event(pos, BREAK, state as i32);
            }
        }
        Some(item)
    }

    /// `BucketItem.emptyContents` of a bucket of `kind` (a source) at `pos`;
    /// `retry` is the cell beside the clicked face when there was a hit
    /// (`hitResult`), tried when `pos` cannot take the fluid; `secondary`
    /// whether the user sneaks.
    pub fn empty_bucket(
        &mut self,
        pos: [i32; 3],
        kind: u8,
        retry: Option<[i32; 3]>,
        secondary: bool,
    ) -> Emptied {
        if !self.world.owns(pos) {
            return Emptied::Failed;
        }
        let table = self.rules.table.clone();
        let state = self.world.get(pos);
        let bits = self.fluids().liquid[state as usize];
        let may_replace = bits >> if kind == FLUID_WATER { 5 } else { 6 } & 1 == 1;
        let container = self.container(state);
        let place = may_replace || (container && bits >> kind & 1 == 1);
        let inside = table.is_air(state) || (place && (!secondary || retry.is_none()));
        if !inside {
            return match retry {
                Some(next) => self.empty_bucket(next, kind, None, secondary),
                None => Emptied::Failed,
            };
        }
        if self.options.water_evaporates && kind == FLUID_WATER {
            // The fizz sound's pitch draws two floats from the level random.
            self.world.next_int(1 << 24);
            self.world.next_int(1 << 24);
            return Emptied::Evaporated;
        }
        if container && kind == FLUID_WATER {
            self.place_liquid(pos, state, source(kind));
            return Emptied::Placed;
        }
        if may_replace && !table.flag(state, LIQUID) && !table.is_air(state) {
            // `Level.destroyBlock`: fire goes without its particles.
            let fire = table.class_name(state).ends_with("FireBlock");
            self.report.destroyed.push(super::updater::Destroyed {
                pos,
                state,
                drops: true,
                effects: !fire,
            });
            let remains = table.remains[state as usize];
            self.set_block(pos, remains, ALL, UPDATE_LIMIT);
        }
        let legacy = self.fluids().legacy(source(kind));
        let old_fluid = Fluid::of(&table, state);
        if !self.set_block(pos, legacy, ALL, UPDATE_LIMIT) && !old_fluid.is_source() {
            return Emptied::Failed;
        }
        Emptied::Placed
    }

    /// A generated chunk's post-processing mark at `pos`
    /// (`LevelChunk.postProcessGeneration`): its fluid ticks at once, and a
    /// block other than a liquid takes the shape its neighbours give it,
    /// set without updates (flags 276). Whether the owner held what it read.
    pub fn post_process(&mut self, pos: [i32; 3]) -> bool {
        if !self.world.owns(pos) || !self.owns_around(pos) {
            return false;
        }
        let table = self.rules.table.clone();
        let state = self.world.get(pos);
        let fluid = Fluid::of(&table, state);
        if !fluid.is_empty() {
            self.tick_fluid(pos, state, fluid);
        }
        if table.flag(state, LIQUID_BLOCK) {
            return true;
        }
        let mut new = state;
        let mark = self.world.begin();
        for d in UPDATE_SHAPE_ORDER {
            let neighbor_pos = at(pos, d);
            let neighbor = self.world.get(neighbor_pos);
            match self.rules.live_update_shape(
                &mut self.world,
                new,
                pos,
                d,
                Some((neighbor_pos, neighbor)),
            ) {
                Ok(next) => new = next,
                Err(_) => return true,
            }
        }
        if self.world.crossed(mark) {
            return false;
        }
        if new != state {
            self.set_block(pos, new, 4 | KNOWN_SHAPE | 256, UPDATE_LIMIT);
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shape(min: [f64; 3], max: [f64; 3]) -> VoxelShape {
        VoxelShape::from_box(min, max)
    }

    #[test]
    fn faces_occlude_only_when_they_cover_the_side_together() {
        let none = [0.0; 3];
        let bottom = shape([0.0, 0.0, 0.0], [1.0, 0.5, 1.0]);
        let top = shape([0.0, 0.5, 0.0], [1.0, 1.0, 1.0]);
        let empty = VoxelShape::empty();
        // Two bottom slabs side by side leave the upper half open.
        assert!(!merged_face_occludes((&bottom, none), (&bottom, none), 5));
        // A bottom slab beside a top slab closes the side.
        assert!(merged_face_occludes((&bottom, none), (&top, none), 5));
        assert!(merged_face_occludes((&top, none), (&bottom, none), 4));
        // A bottom slab's top face does not reach its upper neighbour.
        assert!(!merged_face_occludes((&bottom, none), (&empty, none), 1));
        // A top slab's top face does.
        assert!(merged_face_occludes((&top, none), (&empty, none), 1));
        // Faces must touch the shared side.
        let post = shape([0.375, 0.0, 0.375], [0.625, 1.0, 0.625]);
        assert!(!merged_face_occludes((&post, none), (&top, none), 2));
    }

    #[test]
    fn rectangles_cover_the_unit_square_exactly() {
        assert!(covers_unit_square(&[[0.0, 1.0, 0.0, 1.0]]));
        assert!(covers_unit_square(&[
            [0.0, 0.5, 0.0, 1.0],
            [0.5, 1.0, 0.0, 1.0]
        ]));
        assert!(!covers_unit_square(&[
            [0.0, 0.5, 0.0, 1.0],
            [0.5, 1.0, 0.0, 0.9]
        ]));
        assert!(covers_unit_square(&[[-0.5, 1.5, -1.0, 2.0]]));
        assert!(!covers_unit_square(&[]));
    }

    #[test]
    fn fluid_kinds_pair_sources_with_their_flowing_forms() {
        let water = source(FLUID_FLOWING_WATER);
        assert_eq!(water.kind, FLUID_WATER);
        assert!(water.same(FLUID_FLOWING_WATER) && !water.same(FLUID_LAVA));
        assert_eq!(flowing(FLUID_LAVA, 3, false).kind, FLUID_FLOWING_LAVA);
        assert!(!EMPTY.same(FLUID_WATER));
    }
}
