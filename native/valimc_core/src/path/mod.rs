//! Vanilla's path search (VMC-041b): `PathFinder`'s A* over a mob's node
//! evaluator, walk (`WalkNodeEvaluator`), amphibious, swim and fly, read
//! from published chunk snapshots the way `PathNavigationRegion` reads a
//! level: chunks outside the region, or not loaded, read as void air, and
//! states outside the build height as air. Path types per state come from
//! one generated table (`ai_facts.json`, `getPathTypeFromState`), with the
//! few state facts the evaluators ask beside it (`isPathfindable`, the water
//! block); shapes, fluids and air come from the kernel's facts.
//!
//! A search is pure: a request in (the mob as its navigation sees it, the
//! targets, the limits), a path out with the chunks it read, so an owner can
//! tell whether a result is still current (VMC-041b's fence).

mod finder;
mod fly;
mod swim;
mod walk;

use crate::physics::border::Border;
use crate::physics::facts::{Facts, WATER};
use crate::physics::source::{BlockSource, AIR};
use crate::physics::Aabb;
use crate::worldgen::random::Random;
use std::cell::RefCell;
use std::collections::HashMap;

pub use finder::find;

/// Vanilla's `PathType`, by ordinal.
pub mod types {
    pub const BLOCKED: u8 = 0;
    pub const OPEN: u8 = 1;
    pub const WALKABLE: u8 = 2;
    pub const WALKABLE_DOOR: u8 = 3;
    pub const TRAPDOOR: u8 = 4;
    pub const POWDER_SNOW: u8 = 5;
    pub const ON_TOP_OF_POWDER_SNOW: u8 = 6;
    pub const FENCE: u8 = 7;
    pub const LAVA: u8 = 8;
    pub const WATER: u8 = 9;
    pub const WATER_BORDER: u8 = 10;
    pub const RAIL: u8 = 11;
    pub const UNPASSABLE_RAIL: u8 = 12;
    pub const FIRE_IN_NEIGHBOR: u8 = 13;
    pub const FIRE: u8 = 14;
    pub const DAMAGING_IN_NEIGHBOR: u8 = 15;
    pub const DAMAGING: u8 = 16;
    pub const DOOR_OPEN: u8 = 17;
    pub const DOOR_WOOD_CLOSED: u8 = 18;
    pub const DOOR_IRON_CLOSED: u8 = 19;
    pub const BREACH: u8 = 20;
    pub const LEAVES: u8 = 21;
    pub const STICKY_HONEY: u8 = 22;
    pub const COCOA: u8 = 23;
    pub const DAMAGE_CAUTIOUS: u8 = 24;
    pub const ON_TOP_OF_TRAPDOOR: u8 = 25;
    pub const BIG_MOBS_CLOSE_TO_DANGER: u8 = 26;
    pub const COUNT: usize = 27;
}

use types::*;

/// `isPathfindable(LAND)`.
pub const LAND: u8 = 1;
/// `isPathfindable(WATER)`.
pub const SWIMMABLE: u8 = 2;
/// `isPathfindable(AIR)`.
pub const FLYABLE: u8 = 4;
/// The water block itself (`Blocks.WATER`, any level).
pub const WATER_BLOCK: u8 = 8;

/// The generated per-state path facts.
#[derive(Debug)]
pub struct PathFacts {
    /// `getPathTypeFromState` per state.
    pub types: Vec<u8>,
    /// The bits above per state.
    pub flags: Vec<u8>,
}

impl PathFacts {
    /// `None` when the columns differ in length or name a type that does not exist.
    pub fn new(types: Vec<u8>, flags: Vec<u8>) -> Option<PathFacts> {
        (types.len() == flags.len() && types.iter().all(|&t| (t as usize) < COUNT))
            .then_some(PathFacts { types, flags })
    }

    fn kind(&self, state: u16) -> u8 {
        self.types.get(state as usize).copied().unwrap_or(BLOCKED)
    }

    fn flag(&self, state: u16, bit: u8) -> bool {
        self.flags.get(state as usize).is_some_and(|f| f & bit != 0)
    }
}

/// Which node evaluator a navigation searches with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Evaluator {
    Walk,
    /// `AmphibiousNodeEvaluator(prefersShallowSwimming)`.
    Amphibious {
        shallow: bool,
    },
    /// `SwimNodeEvaluator(allowBreaching)`.
    Swim {
        breaching: bool,
    },
    Fly,
}

/// The mob as its node evaluator reads it.
#[derive(Clone, Debug)]
pub struct Mob {
    pub position: [f64; 3],
    pub width: f32,
    pub height: f32,
    pub on_ground: bool,
    /// `isInWater` (and so `isInFloatableFluid`: the floatable fluid is water).
    pub in_water: bool,
    /// `maxUpStep`.
    pub step: f32,
    /// `getMaxFallDistance`.
    pub max_fall: i32,
    pub fall_distance: f64,
    /// `getPathfindingMalus` per path type.
    pub malus: [f32; COUNT],
    pub can_pass_doors: bool,
    pub can_open_doors: bool,
    pub can_float: bool,
    pub can_walk_over_fences: bool,
    /// The mob's random (`LegacyRandomSource`'s 48-bit state): a small
    /// flier's start candidates draw on it.
    pub random: u64,
}

impl Mob {
    fn block(&self) -> [i32; 3] {
        self.position.map(|v| v.floor() as i32)
    }

    /// `getBoundingBox`: its dimensions around its feet.
    fn bounds(&self) -> Aabb {
        let half = (self.width / 2.0) as f64;
        let [x, y, z] = self.position;
        Aabb {
            min: [x - half, y, z - half],
            max: [x + half, y + self.height as f64, z + half],
        }
    }
}

/// One search (`PathFinder.findPath` with its region).
#[derive(Clone, Debug)]
pub struct Request {
    pub evaluator: Evaluator,
    pub mob: Mob,
    pub targets: Vec<[i32; 3]>,
    pub max_path_length: f32,
    pub reach: i32,
    pub max_visited: i32,
    pub multiplier: f32,
    /// `PathNavigationRegion`'s corners (blocks): the chunks it reads.
    pub region: ([i32; 3], [i32; 3]),
    pub min_y: i32,
    pub height: i32,
    pub sea_level: i32,
    pub border: Option<Border>,
}

/// A found node.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PathNode {
    pub pos: [i32; 3],
    pub kind: u8,
}

/// `Path`: its nodes, the target it was made for and whether it reaches it.
#[derive(Clone, Debug, PartialEq)]
pub struct Path {
    pub nodes: Vec<PathNode>,
    pub target: [i32; 3],
    pub reached: bool,
}

/// A search's result: the path (none found), the mob's random after it and
/// the chunks it read.
#[derive(Clone, Debug)]
pub struct Found {
    pub path: Option<Path>,
    pub random: u64,
    pub chunks: Vec<(i32, i32)>,
}

/// What a search reads: the region's blocks over a source, its facts.
pub(crate) struct Level<'a> {
    source: &'a dyn BlockSource,
    facts: &'a Facts,
    paths: &'a PathFacts,
    chunks: ([i32; 2], [i32; 2]),
    min_y: i32,
    max_y: i32,
    read: RefCell<Vec<(i32, i32)>>,
    types: RefCell<HashMap<[i32; 3], u8>>,
}

impl<'a> Level<'a> {
    fn new(
        source: &'a dyn BlockSource,
        facts: &'a Facts,
        paths: &'a PathFacts,
        r: &Request,
    ) -> Self {
        let (lo, hi) = r.region;
        Level {
            source,
            facts,
            paths,
            chunks: ([lo[0] >> 4, lo[2] >> 4], [hi[0] >> 4, hi[2] >> 4]),
            min_y: r.min_y,
            max_y: r.min_y + r.height - 1,
            read: RefCell::new(Vec::new()),
            types: RefCell::new(HashMap::new()),
        }
    }

    fn inside(&self, cx: i32, cz: i32) -> bool {
        let ([x0, z0], [x1, z1]) = self.chunks;
        (x0..=x1).contains(&cx) && (z0..=z1).contains(&cz)
    }

    /// `PathNavigationRegion.getBlockState`.
    fn state(&self, x: i32, y: i32, z: i32) -> u16 {
        if y < self.min_y || y > self.max_y {
            return AIR;
        }
        let chunk = (x >> 4, z >> 4);
        if !self.inside(chunk.0, chunk.1) {
            return AIR;
        }
        match self.source.state(x, y, z) {
            Some(state) => {
                let mut read = self.read.borrow_mut();
                if read.last() != Some(&chunk) && !read.contains(&chunk) {
                    read.push(chunk);
                }
                state
            }
            None => AIR,
        }
    }

    fn air(&self, state: u16) -> bool {
        self.facts.flags(state) & 1 != 0
    }

    fn fluid(&self, x: i32, y: i32, z: i32) -> u8 {
        self.facts.fluid(self.state(x, y, z)).kind
    }

    fn water(&self, x: i32, y: i32, z: i32) -> bool {
        self.fluid(x, y, z) == WATER
    }

    fn flag(&self, x: i32, y: i32, z: i32, bit: u8) -> bool {
        self.paths.flag(self.state(x, y, z), bit)
    }

    /// `PathfindingContext.getPathTypeFromState` (the level's cache).
    fn state_type(&self, x: i32, y: i32, z: i32) -> u8 {
        if let Some(&t) = self.types.borrow().get(&[x, y, z]) {
            return t;
        }
        let t = self.paths.kind(self.state(x, y, z));
        self.types.borrow_mut().insert([x, y, z], t);
        t
    }

    /// `WalkNodeEvaluator.getFloorLevel(level, pos)`: the top of the
    /// collision shape below.
    fn floor(&self, x: i32, y: i32, z: i32) -> f64 {
        let state = self.state(x, y - 1, z);
        let picked = self
            .facts
            .shapes
            .shape(state, [x, y - 1, z], &Default::default());
        (y - 1) as f64 + picked.shape.bounds().map_or(0.0, |b| b.max[1])
    }

    /// `WalkNodeEvaluator.checkNeighbourBlocks`.
    fn neighbours(&self, x: i32, y: i32, z: i32, kind: u8) -> u8 {
        for dx in -1..=1 {
            for dy in -1..=1 {
                for dz in -1..=1 {
                    if dx != 0 || dz != 0 {
                        match self.state_type(x + dx, y + dy, z + dz) {
                            DAMAGING => return DAMAGING_IN_NEIGHBOR,
                            FIRE | LAVA => return FIRE_IN_NEIGHBOR,
                            types::WATER => return WATER_BORDER,
                            DAMAGE_CAUTIOUS => return DAMAGE_CAUTIOUS,
                            _ => {}
                        }
                    }
                }
            }
        }
        kind
    }

    /// `WalkNodeEvaluator.getPathTypeStatic`.
    fn path_type_static(&self, x: i32, y: i32, z: i32) -> u8 {
        let kind = self.state_type(x, y, z);
        if kind == OPEN && y > self.min_y {
            match self.state_type(x, y - 1, z) {
                OPEN | types::WATER | LAVA | WALKABLE => OPEN,
                FIRE => FIRE,
                DAMAGING => DAMAGING,
                STICKY_HONEY => STICKY_HONEY,
                POWDER_SNOW => ON_TOP_OF_POWDER_SNOW,
                DAMAGE_CAUTIOUS => DAMAGE_CAUTIOUS,
                TRAPDOOR => ON_TOP_OF_TRAPDOOR,
                _ => self.neighbours(x, y, z, WALKABLE),
            }
        } else {
            kind
        }
    }
}

/// A node of the search (`Node`), in the search's arena.
#[derive(Clone, Debug)]
pub(crate) struct Node {
    pub pos: [i32; 3],
    pub heap: i32,
    pub g: f32,
    pub h: f32,
    pub f: f32,
    pub came_from: Option<usize>,
    pub closed: bool,
    pub walked: f32,
    pub malus: f32,
    pub kind: u8,
}

impl Node {
    fn new(pos: [i32; 3]) -> Node {
        Node {
            pos,
            heap: -1,
            g: 0.0,
            h: 0.0,
            f: 0.0,
            came_from: None,
            closed: false,
            walked: 0.0,
            malus: 0.0,
            kind: BLOCKED,
        }
    }
}

fn sqrt(v: f32) -> f32 {
    (v as f64).sqrt() as f32
}

/// `Node.distanceTo`.
pub(crate) fn distance(a: [i32; 3], b: [i32; 3]) -> f32 {
    let d = [0, 1, 2].map(|i| b[i] as f32 - a[i] as f32);
    sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
}

/// `Node.distanceManhattan`.
pub(crate) fn manhattan(a: [i32; 3], b: [i32; 3]) -> f32 {
    let d = [0, 1, 2].map(|i| (b[i] - a[i]).abs() as f32);
    d[0] + d[1] + d[2]
}

/// One search's mutable state: the nodes made so far and the evaluator's
/// caches.
pub(crate) struct Search<'a> {
    pub level: Level<'a>,
    pub request: &'a Request,
    pub mob: &'a Mob,
    pub malus: [f32; COUNT],
    pub nodes: Vec<Node>,
    index: HashMap<[i32; 3], usize>,
    /// Width, height and depth in blocks (`floor(size + 1)`).
    pub size: [i32; 3],
    cached: HashMap<[i32; 3], u8>,
    collisions: HashMap<[u64; 6], bool>,
    pub random: Random,
    pub mob_block: [i32; 3],
}

impl<'a> Search<'a> {
    fn new(level: Level<'a>, request: &'a Request) -> Search<'a> {
        let mob = &request.mob;
        let mut malus = mob.malus;
        if let Evaluator::Amphibious { .. } = request.evaluator {
            malus[types::WATER as usize] = 0.0;
            malus[WALKABLE as usize] = 6.0;
            malus[WATER_BORDER as usize] = 4.0;
        }
        let w = (mob.width + 1.0).floor() as i32;
        let h = (mob.height + 1.0).floor() as i32;
        Search {
            level,
            request,
            mob,
            malus,
            nodes: Vec::new(),
            index: HashMap::new(),
            size: [w, h, w],
            cached: HashMap::new(),
            collisions: HashMap::new(),
            random: Random::legacy_at(mob.random),
            mob_block: mob.block(),
        }
    }

    pub fn malus(&self, kind: u8) -> f32 {
        self.malus[kind as usize]
    }

    /// `NodeEvaluator.getNode`.
    pub fn node(&mut self, pos: [i32; 3]) -> usize {
        if let Some(&i) = self.index.get(&pos) {
            return i;
        }
        self.nodes.push(Node::new(pos));
        let i = self.nodes.len() - 1;
        self.index.insert(pos, i);
        i
    }

    fn amphibious(&self) -> bool {
        matches!(self.request.evaluator, Evaluator::Amphibious { .. })
    }

    /// The evaluator's `getPathType`.
    pub fn path_type(&self, x: i32, y: i32, z: i32) -> u8 {
        match self.request.evaluator {
            Evaluator::Walk => self.level.path_type_static(x, y, z),
            Evaluator::Amphibious { .. } => walk::amphibious_type(self, x, y, z),
            Evaluator::Fly => fly::path_type(self, x, y, z),
            Evaluator::Swim { .. } => swim::path_type(self, x, y, z),
        }
    }

    /// The evaluator's `getCachedPathType` (`getPathTypeOfMob`, memoised).
    pub fn cached(&mut self, x: i32, y: i32, z: i32) -> u8 {
        if let Some(&t) = self.cached.get(&[x, y, z]) {
            return t;
        }
        let t = match self.request.evaluator {
            Evaluator::Swim { .. } => swim::path_type(self, x, y, z),
            _ => walk::type_of_mob(self, x, y, z),
        };
        self.cached.insert([x, y, z], t);
        t
    }

    /// `hasCollisions`: the box meets a block (for the mob) or the border.
    pub fn collides(&mut self, b: &Aabb) -> bool {
        let key = [b.min[0], b.min[1], b.min[2], b.max[0], b.max[1], b.max[2]].map(f64::to_bits);
        if let Some(&c) = self.collisions.get(&key) {
            return c;
        }
        let mob = self.mob;
        let ctx = crate::physics::Context {
            entity: true,
            bottom: mob.position[1],
            entity_present: true,
            fall_distance: mob.fall_distance,
            ..Default::default()
        };
        let extra = crate::physics::collide::Extra {
            entities: Vec::new(),
            border: self.request.border,
            subject: [mob.position[0], mob.position[2]],
        };
        let level = &self.level;
        let source = RegionSource(level);
        let clear =
            crate::physics::collide::no_collision(&source, &level.facts.shapes, b, &ctx, &extra)
                .unwrap_or(false);
        self.collisions.insert(key, !clear);
        !clear
    }
}

/// The region as a kernel block source (collisions read through it).
struct RegionSource<'l, 'a>(&'l Level<'a>);

impl BlockSource for RegionSource<'_, '_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        Some(self.0.state(x, y, z))
    }

    fn special_near(&self, x: i32, y: i32, z: i32) -> bool {
        self.0.source.special_near(x, y, z)
    }
}

#[cfg(test)]
mod tests;
