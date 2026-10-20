//! Multiface growth and sculk (VMC-025c): `MultifaceGrowthFeature` (glow
//! lichen, sculk veins), `MultifaceSpreader` with the default and the sculk
//! vein configurations, and `SculkPatchFeature` with the world generation
//! `SculkSpreader`, its charge cursors and the sculk behaviours of sculk,
//! sculk veins and other blocks.

use super::blocks::{
    BlockSet, BlockTable, FLUID_EMPTY, FLUID_WATER, FULL_COLLISION, REPLACEABLE, STURDY,
};
use super::feature::Decoration;
use super::json::Json;
use super::multiface::attaches;
use super::plants::shuffle;
use super::predicate::offset;
use super::random::Random;
use super::region::Region;

const DIRECTIONS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];
const DOWN: usize = 0;
const UP: usize = 1;
const NORTH: usize = 2;
const SOUTH: usize = 3;
const WEST: usize = 4;
const EAST: usize = 5;
const FACES: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

fn axis(d: usize) -> usize {
    d / 2
}

/// `MultifaceBlock.hasFace`: a face property set to true.
fn has_face(table: &BlockTable, state: u16, d: usize) -> bool {
    table.value(state, FACES[d]) == Some("true")
}

fn is_water_source(table: &BlockTable, state: u16) -> bool {
    table.fluid(state) == FLUID_WATER
}

/// `MultifaceSpreader.SpreadType`.
#[derive(Clone, Copy, Debug)]
enum SpreadType {
    SamePosition,
    SamePlane,
    WrapAround,
}

impl SpreadType {
    fn spread(self, pos: [i32; 3], direction: usize, from: usize) -> ([i32; 3], usize) {
        match self {
            SpreadType::SamePosition => (pos, direction),
            SpreadType::SamePlane => (offset(pos, DIRECTIONS[direction]), from),
            SpreadType::WrapAround => (
                offset(offset(pos, DIRECTIONS[direction]), DIRECTIONS[from]),
                direction ^ 1,
            ),
        }
    }
}

const DEFAULT_ORDER: [SpreadType; 3] = [
    SpreadType::SamePosition,
    SpreadType::SamePlane,
    SpreadType::WrapAround,
];

/// A multiface block and the blocks its spreading tests.
#[derive(Debug)]
pub struct Multiface {
    block: u16,
    default: u16,
    water: u16,
    sculk: u16,
    sculk_catalyst: u16,
    moving_piston: u16,
    fire: BlockSet,
}

impl Multiface {
    fn new(table: &BlockTable, name: &str) -> Result<Multiface, String> {
        Ok(Multiface {
            block: table.block(name)?,
            default: table.default_state(name)?,
            water: table.block("water")?,
            sculk: table.block("sculk")?,
            sculk_catalyst: table.block("sculk_catalyst")?,
            moving_piston: table.block("moving_piston")?,
            fire: table.tag("minecraft:fire")?.clone(),
        })
    }

    fn is(&self, table: &BlockTable, state: u16) -> bool {
        table.block_of(state) == self.block
    }

    /// `isValidStateForPlacement`.
    fn valid_placement(
        &self,
        table: &BlockTable,
        region: &mut Region,
        old: u16,
        pos: [i32; 3],
        d: usize,
    ) -> bool {
        if self.is(table, old) && has_face(table, old, d) {
            return false;
        }
        let neighbour = region.get(offset(pos, DIRECTIONS[d]));
        attaches(table, neighbour, d)
    }

    /// `getStateForPlacement(oldState, level, pos, direction)`.
    fn placement(
        &self,
        table: &BlockTable,
        region: &mut Region,
        old: u16,
        pos: [i32; 3],
        d: usize,
    ) -> Option<u16> {
        if !self.valid_placement(table, region, old, pos, d) {
            return None;
        }
        let base = if self.is(table, old) {
            old
        } else if is_water_source(table, old) {
            table.with(self.default, "waterlogged", "true")?
        } else {
            self.default
        };
        table.with(base, FACES[d], "true")
    }
}

/// A `MultifaceSpreader` configuration.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Config {
    /// `DefaultSpreaderConfig` (glow lichen).
    Default,
    /// `SculkVeinSpreaderConfig` in the default spread order.
    Vein,
    /// `SculkVeinSpreaderConfig` on the same position only.
    VeinSameSpace,
}

struct Spreader<'a> {
    block: &'a Multiface,
    config: Config,
}

impl Spreader<'_> {
    fn types(&self) -> &'static [SpreadType] {
        match self.config {
            Config::VeinSameSpace => &DEFAULT_ORDER[..1],
            _ => &DEFAULT_ORDER,
        }
    }

    fn other_source(&self, table: &BlockTable, state: u16) -> bool {
        self.config != Config::Default && !self.block.is(table, state)
    }

    fn can_spread_from(&self, table: &BlockTable, state: u16, face: usize) -> bool {
        self.other_source(table, state) || has_face(table, state, face)
    }

    fn can_be_replaced(
        &self,
        table: &BlockTable,
        region: &mut Region,
        source: [i32; 3],
        pos: [i32; 3],
        d: usize,
        existing: u16,
    ) -> bool {
        let default = |table: &BlockTable| {
            table.is_air(existing)
                || self.block.is(table, existing)
                || (table.block_of(existing) == self.block.water
                    && is_water_source(table, existing))
        };
        if self.config == Config::Default {
            return default(table);
        }
        let against = table.block_of(region.get(offset(pos, DIRECTIONS[d])));
        let b = self.block;
        if against == b.sculk || against == b.sculk_catalyst || against == b.moving_piston {
            return false;
        }
        let manhattan =
            (source[0] - pos[0]).abs() + (source[1] - pos[1]).abs() + (source[2] - pos[2]).abs();
        if manhattan == 2 {
            let neighbour = region.get(offset(source, DIRECTIONS[d ^ 1]));
            if table.flag(neighbour, STURDY << d) {
                return false;
            }
        }
        let fluid = table.fluid(existing);
        if fluid != FLUID_EMPTY && fluid != FLUID_WATER {
            return false;
        }
        if table.in_tag(existing, &b.fire) {
            return false;
        }
        table.flag(existing, REPLACEABLE) || default(table)
    }

    fn can_spread_into(
        &self,
        table: &BlockTable,
        region: &mut Region,
        source: [i32; 3],
        (pos, face): ([i32; 3], usize),
    ) -> bool {
        let existing = region.get(pos);
        self.can_be_replaced(table, region, source, pos, face, existing)
            && self
                .block
                .valid_placement(table, region, existing, pos, face)
    }

    /// `getSpreadFromFaceTowardDirection`.
    fn spread_position(
        &self,
        table: &BlockTable,
        region: &mut Region,
        state: u16,
        pos: [i32; 3],
        start: usize,
        direction: usize,
    ) -> Option<([i32; 3], usize)> {
        if axis(direction) == axis(start) {
            return None;
        }
        if !(self.other_source(table, state)
            || has_face(table, state, start) && !has_face(table, state, direction))
        {
            return None;
        }
        self.types()
            .iter()
            .map(|t| t.spread(pos, direction, start))
            .find(|&spread| self.can_spread_into(table, region, pos, spread))
    }

    /// `spreadFromFaceTowardDirection`: placed through `placeBlock`.
    #[allow(clippy::too_many_arguments)]
    fn spread_toward(
        &self,
        table: &BlockTable,
        region: &mut Region,
        state: u16,
        pos: [i32; 3],
        start: usize,
        direction: usize,
        post_process: bool,
    ) -> bool {
        let Some((at, face)) = self.spread_position(table, region, state, pos, start, direction)
        else {
            return false;
        };
        let old = region.get(at);
        let Some(spread) = self.block.placement(table, region, old, at, face) else {
            return false;
        };
        if post_process {
            region.mark(at);
        }
        region.set(at, spread, 2)
    }

    /// `spreadFromFaceTowardRandomDirection`.
    #[allow(clippy::too_many_arguments)]
    fn spread_random(
        &self,
        table: &BlockTable,
        region: &mut Region,
        state: u16,
        pos: [i32; 3],
        start: usize,
        random: &mut Random,
        post_process: bool,
    ) {
        let mut directions = [DOWN, UP, NORTH, SOUTH, WEST, EAST];
        shuffle(&mut directions, random);
        for direction in directions {
            if self.spread_toward(table, region, state, pos, start, direction, post_process) {
                return;
            }
        }
    }

    /// `spreadAll`: the number of faces placed.
    fn spread_all(
        &self,
        table: &BlockTable,
        region: &mut Region,
        state: u16,
        pos: [i32; 3],
        post_process: bool,
    ) -> i64 {
        let mut placed = 0;
        for start in 0..6 {
            if !self.can_spread_from(table, state, start) {
                continue;
            }
            for direction in 0..6 {
                if self.spread_toward(table, region, state, pos, start, direction, post_process) {
                    placed += 1;
                }
            }
        }
        placed
    }
}

/// `MultifaceGrowthFeature`.
#[derive(Debug)]
pub struct MultifaceGrowth {
    block: Multiface,
    config: Config,
    search_range: i32,
    directions: Vec<usize>,
    chance_of_spreading: f32,
    can_be_placed_on: BlockSet,
}

impl MultifaceGrowth {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<MultifaceGrowth, String> {
        let name = json.field("block")?.as_str()?;
        let name = name.strip_prefix("minecraft:").unwrap_or(name);
        let config = match name {
            "glow_lichen" => Config::Default,
            "sculk_vein" => Config::Vein,
            other => return Err(format!("multiface growth of {other}")),
        };
        let flag = |k: &str| json.get(k).map_or(Ok(false), Json::as_bool);
        let mut directions = Vec::new();
        if flag("can_place_on_ceiling")? {
            directions.push(UP);
        }
        if flag("can_place_on_floor")? {
            directions.push(DOWN);
        }
        if flag("can_place_on_wall")? {
            directions.extend([NORTH, EAST, SOUTH, WEST]);
        }
        Ok(MultifaceGrowth {
            block: Multiface::new(table, name)?,
            config,
            search_range: json.get("search_range").map_or(Ok(10), Json::as_i32)?,
            directions,
            chance_of_spreading: json
                .get("chance_of_spreading")
                .map_or(Ok(0.5), |v| v.as_f64())? as f32,
            can_be_placed_on: table.block_set(json.field("can_be_placed_on")?)?,
        })
    }

    fn air_or_water(&self, table: &BlockTable, state: u16) -> bool {
        table.is_air(state) || table.block_of(state) == self.block.water
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let here = region.get(origin);
        if !self.air_or_water(table, here) {
            return Ok(false);
        }
        let mut directions = self.directions.clone();
        shuffle(&mut directions, random);
        if self.place_growth(table, region, origin, here, random, &directions) {
            return Ok(true);
        }
        for &search in &directions {
            let mut placement: Vec<usize> = self
                .directions
                .iter()
                .copied()
                .filter(|&dir| dir != search ^ 1)
                .collect();
            shuffle(&mut placement, random);
            // Vanilla moves its cursor to the same neighbour on every step
            // of the search range, so each step repeats the first: a step
            // that places nothing changes nothing.
            if self.search_range > 0 {
                let pos = offset(origin, DIRECTIONS[search]);
                let state = region.get(pos);
                if !self.air_or_water(table, state) && !self.block.is(table, state) {
                    continue;
                }
                if self.place_growth(table, region, pos, state, random, &placement) {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }

    /// `placeGrowthIfPossible`.
    fn place_growth(
        &self,
        table: &BlockTable,
        region: &mut Region,
        pos: [i32; 3],
        old: u16,
        random: &mut Random,
        directions: &[usize],
    ) -> bool {
        for &dir in directions {
            let neighbour = region.get(offset(pos, DIRECTIONS[dir]));
            if !table.in_tag(neighbour, &self.can_be_placed_on) {
                continue;
            }
            let Some(state) = self.block.placement(table, region, old, pos, dir) else {
                return false;
            };
            region.set(pos, state, 3);
            region.mark(pos);
            if random.next_float() < self.chance_of_spreading {
                let spreader = Spreader {
                    block: &self.block,
                    config: self.config,
                };
                spreader.spread_random(table, region, state, pos, dir, random, true);
            }
            return true;
        }
        false
    }
}

/// `SculkPatchFeature` with the world generation `SculkSpreader`.
#[derive(Debug)]
pub struct SculkPatch {
    charge_count: i32,
    amount_per_charge: i32,
    spread_attempts: i32,
    growth_rounds: i32,
    spread_rounds: i32,
    vein: Multiface,
    vein_default: u16,
    sculk_default: u16,
    sensor: u16,
    shrieker: u16,
    replaceable: BlockSet,
    level_replaceable: BlockSet,
    inhibitors: BlockSet,
    air: u16,
    water_state: u16,
}

/// A `SculkSpreader.ChargeCursor`.
#[derive(Clone, Debug)]
struct Cursor {
    pos: [i32; 3],
    charge: i32,
    update_delay: i32,
    decay_delay: i32,
    /// The faces it carries, as bits by direction; `None` before it moved.
    facings: Option<u8>,
}

/// A block's `SculkBehaviour`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Behaviour {
    Sculk,
    Vein,
    Default,
}

const GROWTH_SPAWN_COST: i32 = 50;
const NO_GROWTH_RADIUS: i32 = 1;
const CHARGE_DECAY_RATE: i32 = 5;
const ADDITIONAL_DECAY_RATE: i32 = 10;

impl SculkPatch {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<SculkPatch, String> {
        let i = |k: &str| json.field(k)?.as_i32();
        Ok(SculkPatch {
            charge_count: i("charge_count")?,
            amount_per_charge: i("amount_per_charge")?,
            spread_attempts: i("spread_attempts")?,
            growth_rounds: i("growth_rounds")?,
            spread_rounds: i("spread_rounds")?,
            vein: Multiface::new(table, "sculk_vein")?,
            vein_default: table.default_state("sculk_vein")?,
            sculk_default: table.default_state("sculk")?,
            sensor: table.default_state("sculk_sensor")?,
            shrieker: table
                .with(table.default_state("sculk_shrieker")?, "can_summon", "true")
                .ok_or("shrieker can_summon")?,
            replaceable: table.tag("minecraft:sculk_replaceable_world_gen")?.clone(),
            level_replaceable: table.tag("minecraft:sculk_replaceable")?.clone(),
            inhibitors: table.tag("minecraft:sculk_growth_inhibitors")?.clone(),
            air: table.default_state("air")?,
            water_state: table.default_state("water")?,
        })
    }

    fn behaviour(&self, table: &BlockTable, state: u16) -> Behaviour {
        let b = table.block_of(state);
        if b == self.vein.sculk {
            Behaviour::Sculk
        } else if b == self.vein.block {
            Behaviour::Vein
        } else {
            Behaviour::Default
        }
    }

    fn vein_spreader(&self) -> Spreader<'_> {
        Spreader {
            block: &self.vein,
            config: Config::Vein,
        }
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        if !self.can_spread_from(table, region, origin) {
            return Ok(false);
        }
        let mut cursors: Vec<Cursor> = Vec::new();
        for round in 0..self.spread_rounds + self.growth_rounds {
            for _ in 0..self.charge_count {
                let mut charge = self.amount_per_charge;
                while charge > 0 {
                    let current = charge.min(1000);
                    if cursors.len() < 32 {
                        cursors.push(Cursor {
                            pos: origin,
                            charge: current,
                            update_delay: 0,
                            decay_delay: 1,
                            facings: None,
                        });
                    }
                    charge -= current;
                }
            }
            let spread_veins = round < self.spread_rounds;
            for _ in 0..self.spread_attempts {
                if cursors.is_empty() {
                    continue;
                }
                let mut processed = Vec::with_capacity(cursors.len());
                for mut cursor in cursors {
                    let far = (cursor.pos[0] - origin[0])
                        .abs()
                        .max((cursor.pos[1] - origin[1]).abs())
                        .max((cursor.pos[2] - origin[2]).abs())
                        > 1024;
                    if far {
                        continue;
                    }
                    self.update(table, region, &mut cursor, origin, random, spread_veins);
                    if cursor.charge > 0 {
                        processed.push(cursor);
                    }
                }
                cursors = processed;
            }
            cursors.clear();
        }
        Ok(true)
    }

    fn can_spread_from(&self, table: &BlockTable, region: &mut Region, origin: [i32; 3]) -> bool {
        let start = region.get(origin);
        if self.behaviour(table, start) != Behaviour::Default {
            return true;
        }
        if !table.is_air(start)
            && (table.block_of(start) != self.vein.water || !is_water_source(table, start))
        {
            return false;
        }
        DIRECTIONS
            .iter()
            .any(|dir| table.flag(region.get(offset(origin, *dir)), FULL_COLLISION))
    }

    /// `ChargeCursor.update`.
    fn update(
        &self,
        table: &BlockTable,
        region: &mut Region,
        cursor: &mut Cursor,
        origin: [i32; 3],
        random: &mut Random,
        spread_veins: bool,
    ) {
        if cursor.charge <= 0 {
            return;
        }
        if cursor.update_delay > 0 {
            cursor.update_delay -= 1;
            return;
        }
        let mut current = region.get(cursor.pos);
        let mut behaviour = self.behaviour(table, current);
        if spread_veins
            && self.spread_vein(
                table,
                region,
                behaviour,
                cursor.pos,
                current,
                cursor.facings,
            )
            && behaviour != Behaviour::Sculk
        {
            current = region.get(cursor.pos);
            behaviour = self.behaviour(table, current);
        }
        cursor.charge = self.use_charge(
            table,
            region,
            behaviour,
            cursor,
            origin,
            random,
            spread_veins,
        );
        if cursor.charge <= 0 {
            self.discharged(table, region, behaviour, current, cursor.pos, random);
            return;
        }
        match self.movement(table, region, cursor.pos, random, origin) {
            Some(to) => {
                self.discharged(table, region, behaviour, current, cursor.pos, random);
                cursor.pos = to;
                current = region.get(to);
            }
            None => {
                self.discharged(table, region, behaviour, current, cursor.pos, random);
                cursor.charge = 0;
                return;
            }
        }
        if self.behaviour(table, current) != Behaviour::Default {
            // `MultifaceBlock.availableFaces`: none for a block that is not
            // multiface.
            let mut faces = 0u8;
            if table.block_of(current) == self.vein.block {
                for dir in 0..6 {
                    if has_face(table, current, dir) {
                        faces |= 1 << dir;
                    }
                }
            }
            cursor.facings = Some(faces);
        }
        cursor.decay_delay = match behaviour {
            Behaviour::Default => (cursor.decay_delay - 1).max(0),
            _ => 1,
        };
        cursor.update_delay = 1;
    }

    /// `attemptSpreadVein`.
    fn spread_vein(
        &self,
        table: &BlockTable,
        region: &mut Region,
        behaviour: Behaviour,
        pos: [i32; 3],
        state: u16,
        facings: Option<u8>,
    ) -> bool {
        if behaviour == Behaviour::Default {
            match facings {
                None => {
                    let same = Spreader {
                        block: &self.vein,
                        config: Config::VeinSameSpace,
                    };
                    let here = region.get(pos);
                    return same.spread_all(table, region, here, pos, true) > 0;
                }
                Some(faces) if faces != 0 => {
                    if !table.is_air(state) && !is_water_source(table, state) {
                        return false;
                    }
                    return self.regrow(table, region, pos, state, faces);
                }
                Some(_) => {}
            }
        }
        self.vein_spreader()
            .spread_all(table, region, state, pos, true)
            > 0
    }

    /// `SculkVeinBlock.regrow`.
    fn regrow(
        &self,
        table: &BlockTable,
        region: &mut Region,
        pos: [i32; 3],
        existing: u16,
        faces: u8,
    ) -> bool {
        let mut state = self.vein_default;
        let mut any = false;
        for dir in 0..6 {
            if faces & (1 << dir) == 0 {
                continue;
            }
            let neighbour = region.get(offset(pos, DIRECTIONS[dir]));
            if attaches(table, neighbour, dir) {
                state = table.with(state, FACES[dir], "true").unwrap_or(state);
                any = true;
            }
        }
        if !any {
            return false;
        }
        if table.fluid(existing) != FLUID_EMPTY {
            state = table.with(state, "waterlogged", "true").unwrap_or(state);
        }
        region.set(pos, state, 3);
        true
    }

    /// `attemptUseCharge`: the cursor's new charge.
    #[allow(clippy::too_many_arguments)]
    fn use_charge(
        &self,
        table: &BlockTable,
        region: &mut Region,
        behaviour: Behaviour,
        cursor: &Cursor,
        origin: [i32; 3],
        random: &mut Random,
        spread_veins: bool,
    ) -> i32 {
        let charge = cursor.charge;
        match behaviour {
            Behaviour::Default => {
                if cursor.decay_delay > 0 {
                    charge
                } else {
                    0
                }
            }
            Behaviour::Vein => {
                if spread_veins && self.place_sculk(table, region, cursor.pos, random) {
                    charge - 1
                } else if random.next_int_bounded(CHARGE_DECAY_RATE) == 0 {
                    (charge as f32 * 0.5).floor() as i32
                } else {
                    charge
                }
            }
            Behaviour::Sculk => {
                if charge == 0 || random.next_int_bounded(CHARGE_DECAY_RATE) != 0 {
                    return charge;
                }
                let pos = cursor.pos;
                let dist_sqr = {
                    let (dx, dy, dz) = (
                        (pos[0] - origin[0]) as f64,
                        (pos[1] - origin[1]) as f64,
                        (pos[2] - origin[2]) as f64,
                    );
                    dx * dx + dy * dy + dz * dz
                };
                let close = dist_sqr < (NO_GROWTH_RADIUS * NO_GROWTH_RADIUS) as f64;
                if !close && self.can_place_growth(table, region, pos) {
                    if random.next_int_bounded(GROWTH_SPAWN_COST) < charge {
                        let above = offset(pos, [0, 1, 0]);
                        let mut growth = if random.next_int_bounded(11) == 0 {
                            self.shrieker
                        } else {
                            self.sensor
                        };
                        if table.fluid(region.get(above)) != FLUID_EMPTY {
                            if let Some(wet) = table.with(growth, "waterlogged", "true") {
                                growth = wet;
                            }
                        }
                        region.set(above, growth, 3);
                    }
                    return (charge - GROWTH_SPAWN_COST).max(0);
                }
                if random.next_int_bounded(ADDITIONAL_DECAY_RATE) != 0 {
                    return charge;
                }
                if close {
                    return charge - 1;
                }
                // `getDecayPenalty`.
                let outer = (dist_sqr.sqrt() as f32) - NO_GROWTH_RADIUS as f32;
                let outer = outer * outer;
                let reach = (24 - NO_GROWTH_RADIUS) * (24 - NO_GROWTH_RADIUS);
                let factor = super::java::fmin(1.0, outer / reach as f32);
                charge - ((charge as f32 * factor * 0.5) as i32).max(1)
            }
        }
    }

    /// `SculkBlock.canPlaceGrowth`: room above, and at most two growth
    /// inhibitors around.
    fn can_place_growth(&self, table: &BlockTable, region: &mut Region, pos: [i32; 3]) -> bool {
        let above = region.get(offset(pos, [0, 1, 0]));
        if !(table.is_air(above)
            || (table.block_of(above) == self.vein.water && is_water_source(table, above)))
        {
            return false;
        }
        let (min_y, max_y) = (region.min_y(), region.min_y() + region.height() - 1);
        let mut found = 0;
        for y in pos[1].max(min_y)..=(pos[1] + 2).min(max_y) {
            for z in pos[2] - 4..=pos[2] + 4 {
                for x in pos[0] - 4..=pos[0] + 4 {
                    if table.in_tag(region.get([x, y, z]), &self.inhibitors) {
                        found += 1;
                        if found >= 3 {
                            return false;
                        }
                    }
                }
            }
        }
        true
    }

    /// `SculkVeinBlock.attemptPlaceSculk`.
    fn place_sculk(
        &self,
        table: &BlockTable,
        region: &mut Region,
        pos: [i32; 3],
        random: &mut Random,
    ) -> bool {
        let state = region.get(pos);
        let mut supports = [DOWN, UP, NORTH, SOUTH, WEST, EAST];
        shuffle(&mut supports, random);
        for support in supports {
            if !has_face(table, state, support) {
                continue;
            }
            let support_pos = offset(pos, DIRECTIONS[support]);
            if !table.in_tag(region.get(support_pos), &self.replaceable) {
                continue;
            }
            region.set(support_pos, self.sculk_default, 3);
            self.vein_spreader()
                .spread_all(table, region, self.sculk_default, support_pos, true);
            let skip = support ^ 1;
            for (dir, step) in DIRECTIONS.iter().enumerate() {
                if dir == skip {
                    continue;
                }
                let vein_pos = offset(support_pos, *step);
                let vein = region.get(vein_pos);
                if table.block_of(vein) == self.vein.block {
                    self.vein_discharged(table, region, vein, vein_pos);
                }
            }
            return true;
        }
        false
    }

    fn discharged(
        &self,
        table: &BlockTable,
        region: &mut Region,
        behaviour: Behaviour,
        state: u16,
        pos: [i32; 3],
        _random: &mut Random,
    ) {
        if behaviour == Behaviour::Vein {
            self.vein_discharged(table, region, state, pos);
        }
    }

    /// `SculkVeinBlock.onDischarged`: faces against sculk drop.
    fn vein_discharged(
        &self,
        table: &BlockTable,
        region: &mut Region,
        mut state: u16,
        pos: [i32; 3],
    ) {
        if table.block_of(state) != self.vein.block {
            return;
        }
        for dir in 0..6 {
            if has_face(table, state, dir)
                && table.block_of(region.get(offset(pos, DIRECTIONS[dir]))) == self.vein.sculk
            {
                state = table.with(state, FACES[dir], "false").unwrap_or(state);
            }
        }
        if !(0..6).any(|dir| has_face(table, state, dir)) {
            state = if table.fluid(region.get(pos)) == FLUID_EMPTY {
                self.air
            } else {
                self.water_state
            };
        }
        region.set(pos, state, 3);
    }

    /// `ChargeCursor.getValidMovementPos`.
    fn movement(
        &self,
        table: &BlockTable,
        region: &mut Region,
        pos: [i32; 3],
        random: &mut Random,
        origin: [i32; 3],
    ) -> Option<[i32; 3]> {
        let mut offsets = non_corner_neighbours();
        shuffle(&mut offsets, random);
        let mut target = pos;
        for o in offsets {
            let n = offset(pos, o);
            let dx = origin[0] - n[0];
            let dz = origin[2] - n[2];
            if dx * dx + dz * dz > 144 {
                continue;
            }
            let state = region.get(n);
            if self.behaviour(table, state) == Behaviour::Default
                || !self.unobstructed(table, region, pos, n)
            {
                continue;
            }
            target = n;
            if self.substrate_access(table, region, state, n) {
                break;
            }
        }
        (target != pos).then_some(target)
    }

    /// `SculkVeinBlock.hasSubstrateAccess`.
    fn substrate_access(
        &self,
        table: &BlockTable,
        region: &mut Region,
        state: u16,
        pos: [i32; 3],
    ) -> bool {
        if table.block_of(state) != self.vein.block {
            return false;
        }
        (0..6).any(|dir| {
            has_face(table, state, dir)
                && table.in_tag(
                    region.get(offset(pos, DIRECTIONS[dir])),
                    &self.level_replaceable,
                )
        })
    }

    /// `ChargeCursor.isMovementUnobstructed`.
    fn unobstructed(
        &self,
        table: &BlockTable,
        region: &mut Region,
        from: [i32; 3],
        to: [i32; 3],
    ) -> bool {
        let delta = [to[0] - from[0], to[1] - from[1], to[2] - from[2]];
        if delta[0].abs() + delta[1].abs() + delta[2].abs() == 1 {
            return true;
        }
        let x = if delta[0] < 0 { WEST } else { EAST };
        let y = if delta[1] < 0 { DOWN } else { UP };
        let z = if delta[2] < 0 { NORTH } else { SOUTH };
        let mut free = |dir: usize| {
            let test = offset(from, DIRECTIONS[dir]);
            !table.flag(region.get(test), STURDY << (dir ^ 1))
        };
        if delta[0] == 0 {
            free(y) || free(z)
        } else if delta[1] == 0 {
            free(x) || free(z)
        } else {
            free(x) || free(y)
        }
    }
}

/// `ChargeCursor.NON_CORNER_NEIGHBOURS`: X fastest, then Y, then Z.
fn non_corner_neighbours() -> Vec<[i32; 3]> {
    let mut out = Vec::with_capacity(18);
    for z in -1..=1 {
        for y in -1..=1 {
            for x in -1..=1 {
                if (x == 0 || y == 0 || z == 0) && (x, y, z) != (0, 0, 0) {
                    out.push([x, y, z]);
                }
            }
        }
    }
    out
}
