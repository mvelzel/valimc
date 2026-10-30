//! What a native mob's AI reads of the world (VMC-081d), mirroring
//! `Valimc.AI.World`'s level half: block states through a `BlockSource`
//! (the published snapshots the owner's ticker holds), light, biome, rain
//! and sky through an `Environment` (the owner's own store, as the Elixir's
//! closures read `Valimc.World.Blocks`), and the tick's scalars: time, day,
//! difficulty, the game rules, sea level, border, build height, knots,
//! structures and the section's level random (`state.ai_random`).
//!
//! Predicates read the block fact table as `Valimc.Data.BlockFacts` does: an
//! unreadable cell is no air, not solid and has no fluid, but collides.

use super::facts::{Climate, MobFacts};
use super::random::LegacyRandom;
use crate::column::ColumnStore;
use crate::facts::StateFacts;
use crate::physics::collide;
use crate::physics::facts::{Facts as PhysicsFacts, LAVA, WATER};
use crate::physics::source::BlockSource;
use crate::physics::table::Context;
use crate::physics::Aabb;
use std::collections::HashMap;

/// Flag bits of the block fact table (`flag_bits`) the AI asks.
pub const AIR: u32 = 0;
pub const SOLID: u32 = 2;
pub const SOLID_RENDER: u32 = 16;
pub const REDSTONE_CONDUCTOR: u32 = 35;
pub const INVISIBLE: u32 = 51;
/// `Heightmap.Types.MOTION_BLOCKING`'s bit.
pub const MOTION_BLOCKING: u8 = 1 << 4;

/// A structure query (`World.locate/2`'s request): the nearest structure of
/// a structure tag within a radius of chunks around a block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Query {
    pub tag: &'static str,
    pub position: [i32; 3],
    pub radius: i32,
}

/// What answers structure queries at once (`world.locate` a function:
/// fixtures and oracles); without one they are deferred to the owner, whose
/// results reach the mob by `Level::located`.
pub trait Locator: Sync {
    /// The structure's position, None where there is none.
    fn locate(&self, query: &Query) -> Option<[i32; 3]>;
}

/// `Difficulty`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Difficulty {
    Peaceful,
    Easy,
    Normal,
    Hard,
}

/// A fluid kind (`BlockFacts.fluid(state).kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FluidKind {
    Empty,
    Water,
    Lava,
}

/// The game rules mobs read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rules {
    pub mob_griefing: bool,
    pub mob_drops: bool,
    /// A dropped lead's item.
    pub entity_drops: bool,
    pub universal_anger: bool,
}

impl Default for Rules {
    fn default() -> Self {
        Rules {
            mob_griefing: true,
            mob_drops: true,
            entity_drops: true,
            universal_anger: false,
        }
    }
}

/// A kept structure start (`RegionData` `structures`): its name and its
/// pieces' inclusive boxes `[x0, y0, z0, x1, y1, z1]`.
#[derive(Clone, Debug, PartialEq)]
pub struct StructureStart {
    pub name: String,
    pub pieces: Vec<[i32; 6]>,
}

/// Light, biome, rain and sky at a block: what `Valimc.AI.World`'s
/// closures read (`light`, `biome`, `rain`, `sky`, `chunks`).
pub trait Environment {
    /// Sky and block light, None where the light does not know the chunk.
    fn light(&self, p: [i32; 3]) -> Option<(u8, u8)>;
    /// The biome registry id (`Level.getBiome`), None where unknown.
    fn biome(&self, p: [i32; 3]) -> Option<u16>;
    /// Rain at a body's feet and at height `top` (`isInRain`); None: the
    /// world has no rain reader (nothing is rained on).
    fn rain(&self, _position: [f64; 3], _top: f64) -> Option<bool> {
        None
    }
    /// `canSeeSky` read apart from light (`world.sky`); None: by light.
    fn sky(&self, _p: [i32; 3]) -> Option<bool> {
        None
    }
    /// Whether a chunk is loaded (`world.chunks`); None: by reading a block.
    fn chunk_loaded(&self, _chunk: (i32, i32)) -> Option<bool> {
        None
    }
    /// The blocks of a chunk whose state is one of `states` (`World.find`'s
    /// snapshot search, `View.find`); None: the world has no finder (it
    /// finds nothing).
    fn find(&self, _chunk: (i32, i32), _states: &[u16]) -> Option<Vec<(i32, i32, i32, u16)>> {
        None
    }
    /// Where a mob of `type_id` getting up from the bed at `head` (facing
    /// `facing`, an index of north, south, west, east) stands
    /// (`world.stand_up`, `StandUp.bed`); None: above the bed.
    fn stand_up(&self, _type_id: u16, _head: [i32; 3], _facing: u8, _yaw: f64) -> Option<[f64; 3]> {
        None
    }
}

/// No light, biome or rain known (tests and oracles that give none).
pub struct Unknown;

impl Environment for Unknown {
    fn light(&self, _p: [i32; 3]) -> Option<(u8, u8)> {
        None
    }
    fn biome(&self, _p: [i32; 3]) -> Option<u16> {
        None
    }
}

/// A section owner's own store, as `Valimc.World.Blocks.light/2` and
/// `biome/3` read it (`region_light`, `region_biome`): light where its light
/// knows the chunk, the biome of the fuzzed zoom's quart where the store
/// holds it.
pub struct Store<'a> {
    pub store: &'a ColumnStore,
    pub zoom_seed: i64,
    /// The plains' registry id, a column without biomes'.
    pub plains: u16,
}

impl Environment for Store<'_> {
    fn light(&self, p: [i32; 3]) -> Option<(u8, u8)> {
        self.store.light_at(p[0], p[1], p[2])
    }

    fn biome(&self, p: [i32; 3]) -> Option<u16> {
        let quart = crate::worldgen::surface::zoom(self.zoom_seed, p[0], p[1], p[2]);
        self.store.noise_biome(quart, self.plains)
    }

    fn find(&self, chunk: (i32, i32), states: &[u16]) -> Option<Vec<(i32, i32, i32, u16)>> {
        Some(self.store.find(chunk, states).unwrap_or_default())
    }
}

/// A section owner's own store's blocks (`Valimc.World.Blocks.get/2` where
/// it holds them): unreadable outside its chunks or the build height.
pub struct StoreBlocks<'a>(pub &'a ColumnStore);

impl BlockSource for StoreBlocks<'_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        self.0.get(x, y, z).ok()
    }
}

/// The world a native mob's AI reads in one tick of its section.
pub struct Level<'a> {
    pub blocks: &'a dyn BlockSource,
    pub environment: &'a dyn Environment,
    pub facts: &'a MobFacts,
    pub physics: &'a PhysicsFacts,
    pub states: &'a StateFacts,
    /// The game time (`state.game_tick`).
    pub time: i64,
    /// The overworld clock's ticks (the day's sky, the villager schedule).
    pub day: i64,
    pub difficulty: Difficulty,
    /// A local difficulty that holds everywhere (oracles), else None.
    pub local: Option<f64>,
    /// The sky's darkening (`Spawning.darken`).
    pub darken: i32,
    /// `isBrightOutside`.
    pub bright: bool,
    /// The dimension's time stands still (the Nether, the End): it is
    /// never dark outside there (`isDarkOutside`).
    pub fixed_time: bool,
    pub monsters_burn: bool,
    pub halloween: bool,
    pub rules: Rules,
    /// False: no mob's goals run.
    pub goals: bool,
    pub min_y: i32,
    pub max_y: i32,
    pub sea_level: i32,
    /// The stationary border `[min_x, min_z, max_x, max_z]`.
    pub border: Option<[f64; 4]>,
    /// Fence knots by block: their network ids.
    pub knots: HashMap<[i32; 3], i32>,
    /// Kept structure starts by chunk.
    pub structures: HashMap<(i32, i32), Vec<StructureStart>>,
    /// The POI tickets taken by block (`World.pois`, the living villagers'
    /// claims): `mobs::ai::pois` reads them; a claim made or given back in
    /// a tick counts for the mobs after.
    pub pois: HashMap<[i32; 3], i32>,
    /// The 16-block sections holding an occupied village POI where the
    /// owner gives them (`World.villages`); None: from `pois`.
    pub villages: Option<Vec<[i32; 3]>>,
    /// The section's level random (`World.random`).
    pub random: LegacyRandom,
    /// The loot registry (spawn equipment's enchanting), where the owner
    /// gives one.
    pub loot: Option<&'a crate::loot::Loot>,
    /// Structure queries answered at once (`world.locate`); None: deferred.
    pub locator: Option<&'a dyn Locator>,
    /// Results of deferred structure queries by mob and request
    /// (`world.located`), taken by the mob that asked.
    pub located: HashMap<([u8; 16], u64), Option<[i32; 3]>>,
    /// The dimension (`World.dimension`: a POI memory's `GlobalPos`).
    pub dimension: crate::mobs::term::Atom,
    /// What players did that brain mobs react to before thinking
    /// (`World.events`: piglins angered by a player opening or breaking
    /// what they guard).
    pub events: Vec<crate::mobs::ai::brain::Reaction>,
    /// The seeds mobs' loot rolls take in turn (`World.loot_seeds`, a
    /// piglin's barter); empty: fresh ones.
    pub loot_seeds: std::collections::VecDeque<i64>,
}

impl<'a> Level<'a> {
    /// A level with the defaults `%Valimc.AI.World{}` holds.
    pub fn new(
        blocks: &'a dyn BlockSource,
        environment: &'a dyn Environment,
        facts: &'a MobFacts,
        physics: &'a PhysicsFacts,
        states: &'a StateFacts,
        random: LegacyRandom,
    ) -> Level<'a> {
        Level {
            blocks,
            environment,
            facts,
            physics,
            states,
            time: 0,
            day: 0,
            difficulty: Difficulty::Normal,
            local: None,
            darken: 0,
            bright: false,
            fixed_time: false,
            monsters_burn: false,
            halloween: false,
            rules: Rules::default(),
            goals: true,
            min_y: -64,
            max_y: 319,
            sea_level: 63,
            border: None,
            knots: HashMap::new(),
            structures: HashMap::new(),
            pois: HashMap::new(),
            villages: None,
            random,
            loot: None,
            locator: None,
            located: HashMap::new(),
            dimension: crate::mobs::term::Atom::from_static("overworld"),
            events: Vec::new(),
            loot_seeds: std::collections::VecDeque::new(),
        }
    }

    /// `World.find/3` through the world's finder: the cells of `states` in
    /// an inclusive box, chunk by chunk (x then z), each chunk's in its
    /// finder's order; nothing without one.
    pub fn find_blocks(
        &self,
        min: [i32; 3],
        max: [i32; 3],
        states: &[u16],
    ) -> Vec<([i32; 3], u16)> {
        let mut out = Vec::new();
        for cx in min[0].div_euclid(16)..=max[0].div_euclid(16) {
            for cz in min[2].div_euclid(16)..=max[2].div_euclid(16) {
                let Some(found) = self.environment.find((cx, cz), states) else {
                    return Vec::new();
                };
                for (x, y, z, state) in found {
                    let p = [x, y, z];
                    if (0..3).all(|a| min[a] <= p[a] && p[a] <= max[a]) {
                        out.push((p, state));
                    }
                }
            }
        }
        out
    }

    /// `World.block/2`: the state at a position, None where unreadable.
    #[inline]
    pub fn block(&self, p: [i32; 3]) -> Option<u16> {
        self.blocks.state(p[0], p[1], p[2])
    }

    /// `World.chunk?/3`: `hasChunk(cx, cz)` (read at height `y` where no
    /// chunk reader is given).
    pub fn chunk(&self, chunk: (i32, i32), y: i32) -> bool {
        self.environment
            .chunk_loaded(chunk)
            .unwrap_or_else(|| self.block([chunk.0 * 16, y, chunk.1 * 16]).is_some())
    }

    fn flag(&self, p: [i32; 3], bit: u32) -> bool {
        self.block(p)
            .is_some_and(|s| self.physics.flags(s) >> bit & 1 == 1)
    }

    /// `World.air?/2` (an unreadable cell is no air).
    pub fn air(&self, p: [i32; 3]) -> bool {
        self.flag(p, AIR)
    }

    /// `World.solid?/2` (`BlockState.isSolid`).
    pub fn solid(&self, p: [i32; 3]) -> bool {
        self.flag(p, SOLID)
    }

    /// `World.conductor?/2`.
    pub fn conductor(&self, p: [i32; 3]) -> bool {
        self.flag(p, REDSTONE_CONDUCTOR)
    }

    /// `World.solid_render?/2`.
    pub fn solid_render(&self, p: [i32; 3]) -> bool {
        self.flag(p, SOLID_RENDER)
    }

    /// Whether `state` has the table's flag `bit`.
    pub fn state_flag(&self, state: u16, bit: u32) -> bool {
        self.physics.flags(state) >> bit & 1 == 1
    }

    /// `World.fluid/2`: the fluid kind at a position (empty where
    /// unreadable).
    pub fn fluid(&self, p: [i32; 3]) -> FluidKind {
        self.block(p).map_or(FluidKind::Empty, |s| self.fluid_of(s))
    }

    /// A state's fluid kind.
    pub fn fluid_of(&self, state: u16) -> FluidKind {
        match self.physics.fluid(state).kind {
            WATER => FluidKind::Water,
            LAVA => FluidKind::Lava,
            _ => FluidKind::Empty,
        }
    }

    /// `World.collides?/2`: the block has a collision shape (an unreadable
    /// one does) for the empty context.
    pub fn collides(&self, p: [i32; 3]) -> bool {
        match self.block(p) {
            None => true,
            Some(state) => {
                let cell = Aabb::new(
                    [p[0] as f64, p[1] as f64, p[2] as f64],
                    [p[0] as f64 + 1.0, p[1] as f64 + 1.0, p[2] as f64 + 1.0],
                );
                collide::obstructs(&self.physics.shapes, state, p, &Context::default(), &[cell])
            }
        }
    }

    /// `World.fits?/2` (`noCollision` over blocks): no collision shape of a
    /// cell the box reaches, or the cells around it, meets it; an unreadable
    /// cell collides.
    pub fn fits(&self, b: &Aabb) -> bool {
        let lo = |v: f64| (v - 1.0e-7).floor() as i32 - 1;
        let hi = |v: f64| (v + 1.0e-7).floor() as i32 + 1;
        let ctx = Context::default();
        for x in lo(b.min[0])..=hi(b.max[0]) {
            for y in lo(b.min[1])..=hi(b.max[1]) {
                for z in lo(b.min[2])..=hi(b.max[2]) {
                    match self.block([x, y, z]) {
                        None => return false,
                        Some(state) => {
                            if collide::obstructs(
                                &self.physics.shapes,
                                state,
                                [x, y, z],
                                &ctx,
                                std::slice::from_ref(b),
                            ) {
                                return false;
                            }
                        }
                    }
                }
            }
        }
        true
    }

    /// `World.in_water?/2` of an entity's box: water reaching above its feet
    /// in a cell the box, shrunk by 0.001, touches.
    pub fn in_water(&self, b: &Aabb) -> bool {
        let lo = b.min.map(|v| v + 0.001);
        let hi = b.max.map(|v| v - 0.001);
        for x in lo[0].floor() as i32..hi[0].ceil() as i32 {
            for y in lo[1].floor() as i32..hi[1].ceil() as i32 {
                for z in lo[2].floor() as i32..hi[2].ceil() as i32 {
                    if let Some(state) = self.block([x, y, z]) {
                        let fluid = self.physics.fluid(state);
                        if fluid.kind == WATER && y as f64 + fluid.height as f64 >= lo[1] {
                            return true;
                        }
                    }
                }
            }
        }
        false
    }

    /// `World.motion_blocking/3`: above the column's highest block that
    /// blocks motion or holds fluid; the bottom where none is read.
    pub fn motion_blocking(&self, x: i32, z: i32) -> i32 {
        (self.min_y..=self.max_y)
            .rev()
            .find(|&y| {
                self.block([x, y, z]).is_some_and(|s| {
                    self.states.heightmaps.get(s as usize).copied().unwrap_or(0) & MOTION_BLOCKING
                        != 0
                })
            })
            .map_or(self.min_y, |top| top + 1)
    }

    /// `World.light/2`: `getLightLevelDependentMagicValue`, 0 where the light
    /// is not known.
    pub fn light(&self, p: [i32; 3]) -> f32 {
        match self.environment.light(p) {
            None => 0.0,
            Some((sky, block)) => {
                let level = (sky as i32 - self.darken).max(block as i32);
                let v = (level as f64 / 15.0) as f32;
                v / (4.0 - 3.0 * v)
            }
        }
    }

    /// Sky and block light (`world.light`).
    pub fn raw_light(&self, p: [i32; 3]) -> Option<(u8, u8)> {
        self.environment.light(p)
    }

    /// `World.sees_sky?/2`: full sky light (never where unknown).
    pub fn sees_sky(&self, p: [i32; 3]) -> bool {
        matches!(self.environment.light(p), Some((15, _)))
    }

    /// `World.sky?/2`: the world's sky reader, else `sees_sky`.
    pub fn sky(&self, p: [i32; 3]) -> bool {
        self.environment.sky(p).unwrap_or_else(|| self.sees_sky(p))
    }

    /// `World.biome/2`'s registry id: plains where unknown.
    pub fn biome(&self, p: [i32; 3]) -> u16 {
        self.environment.biome(p).unwrap_or_else(|| self.plains())
    }

    /// `World.biome/2`'s name.
    pub fn biome_name(&self, p: [i32; 3]) -> &str {
        self.facts
            .registries
            .name("minecraft:worldgen/biome", self.biome(p) as u32)
            .unwrap_or("minecraft:plains")
    }

    fn plains(&self) -> u16 {
        self.facts
            .registries
            .id("minecraft:worldgen/biome", "minecraft:plains")
            .unwrap_or(0) as u16
    }

    /// `world.rain` at a body's feet and head (false without a reader).
    pub fn rain(&self, position: [f64; 3], top: f64) -> bool {
        self.environment.rain(position, top) == Some(true)
    }

    /// `World.outside?/2`: `isOutsideBuildHeight`.
    pub fn outside(&self, p: [i32; 3]) -> bool {
        p[1] < self.min_y || p[1] > self.max_y
    }

    /// `World.find/3`'s cells of `states` in an inclusive box, chunk by
    /// chunk (x then z) as `find_blocks` reads the published snapshots;
    /// `scan` gives a chunk's matches in the snapshot's order.
    pub fn find(
        &self,
        min: [i32; 3],
        max: [i32; 3],
        scan: impl Fn((i32, i32)) -> Vec<(i32, i32, i32, u16)>,
    ) -> Vec<([i32; 3], u16)> {
        let mut out = Vec::new();
        for cx in min[0].div_euclid(16)..=max[0].div_euclid(16) {
            for cz in min[2].div_euclid(16)..=max[2].div_euclid(16) {
                for (x, y, z, state) in scan((cx, cz)) {
                    let p = [x, y, z];
                    if (0..3).all(|a| min[a] <= p[a] && p[a] <= max[a]) {
                        out.push((p, state));
                    }
                }
            }
        }
        out
    }

    /// `World.in_structure?/3`: a piece of a kept start of one of `names`
    /// holds the position.
    pub fn in_structure(&self, p: [i32; 3], names: &[&str]) -> bool {
        self.structures
            .get(&(p[0] >> 4, p[2] >> 4))
            .is_some_and(|starts| {
                starts.iter().any(|s| {
                    names.contains(&s.name.as_str())
                        && s.pieces.iter().any(|b| {
                            (b[0]..=b[3]).contains(&p[0])
                                && (b[1]..=b[4]).contains(&p[1])
                                && (b[2]..=b[5]).contains(&p[2])
                        })
                })
            })
    }

    /// `World.locate/2`: a query's answer at once (`Some`), else deferred
    /// (`None`).
    pub fn locate(&self, query: &Query) -> Option<Option<[i32; 3]>> {
        self.locator.map(|l| l.locate(query))
    }

    /// The knot tied at a block (`World.knots`).
    pub fn knot(&self, p: [i32; 3]) -> Option<i32> {
        self.knots.get(&p).copied()
    }

    /// `level.random` draws (`World.random`).
    pub fn random(&mut self) -> &mut LegacyRandom {
        &mut self.random
    }
}

/// `World.manhattan/4`: `BlockPos.withinManhattan` from `origin` within
/// `rx`, `ry`, `rz`: nearest first, x then y, z and its mirror.
pub fn manhattan(origin: [i32; 3], rx: i32, ry: i32, rz: i32) -> Vec<[i32; 3]> {
    let mut out = Vec::new();
    for depth in 0..=(rx + ry + rz) {
        for x in -rx.min(depth)..=rx.min(depth) {
            let max_y = ry.min(depth - x.abs());
            for y in -max_y..=max_y {
                let z = depth - x.abs() - y.abs();
                if z > rz {
                    continue;
                }
                let p = [origin[0] + x, origin[1] + y];
                if z != 0 {
                    out.push([p[0], p[1], origin[2] + z]);
                    out.push([p[0], p[1], origin[2] - z]);
                } else {
                    out.push([p[0], p[1], origin[2]]);
                }
            }
        }
    }
    out
}

/// Precipitation at a block (`Valimc.World.Climate.precipitation/3`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Precipitation {
    None,
    Rain,
    Snow,
}

/// `Biome.getPrecipitationAt` of a biome's climate at `p` under a
/// generator with `sea_level`.
pub fn precipitation(climate: &Climate, p: [i32; 3], sea_level: i32) -> Precipitation {
    if !climate.precipitation {
        return Precipitation::None;
    }
    let biome = crate::worldgen::surface::BiomeClimate {
        temperature: climate.temperature as f32,
        frozen: climate.frozen,
    };
    let t = crate::worldgen::surface::temperature(&biome, p[0], p[1], p[2], sea_level);
    if (t as f64) < 0.15 {
        Precipitation::Snow
    } else {
        Precipitation::Rain
    }
}

/// `Valimc.World.RainQuery.sample/3` over a column reader (`column(x, z)`:
/// its MOTION_BLOCKING height and lowest sky source) and a biome reader
/// (the zoomed quart's biome id), both None where unavailable: `Some(rain)`,
/// None where the column cannot be read or the observation is invalid.
pub fn rain_at(
    climates: &[Climate],
    wet: bool,
    sea_level: i32,
    position: [f64; 3],
    top: f64,
    column: impl Fn(i32, i32) -> Option<(i32, i32)>,
    biome: impl Fn([i32; 3]) -> Option<u16>,
) -> Option<bool> {
    if !wet {
        return Some(false);
    }
    let (x, z) = (position[0].floor() as i32, position[2].floor() as i32);
    let feet = [x, position[1].floor() as i32, z];
    let head = [x, top.floor() as i32, z];
    let (surface, sky_source) = column(x, z)?;
    let point = |p: [i32; 3]| -> Option<(i32, bool, Precipitation)> {
        let climate = climates.get(biome(p)? as usize)?;
        Some((
            p[1],
            p[1] >= sky_source,
            precipitation(climate, p, sea_level),
        ))
    };
    let (feet, head) = (point(feet)?, point(head)?);
    // `RainContact.exposed?`'s guards.
    let valid = |(y, _, _): (i32, bool, Precipitation)| (-1_000_000..=1_000_000).contains(&y);
    if !(-64..=320).contains(&surface)
        || !valid(feet)
        || !valid(head)
        || !(0..=2).contains(&(head.0 - feet.0))
        || (feet.0 == head.0 && feet != head)
    {
        return None;
    }
    let rain =
        |(y, sky, p): (i32, bool, Precipitation)| sky && surface <= y && p == Precipitation::Rain;
    Some(rain(feet) || rain(head))
}

#[cfg(test)]
pub(crate) mod tests;
