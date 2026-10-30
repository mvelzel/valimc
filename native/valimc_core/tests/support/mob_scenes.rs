//! Randomized mob kernel scenes (VMC-081d): a made-up block table with
//! vanilla's shape kinds (full blocks, slabs, stairs, fences and walls past
//! their cell, ladders, carpets, chests, offset bamboo, powder snow), water
//! and lava with flowing edges, slowing and hazard blocks; terrain over
//! published chunk snapshots; and an owner's mobs of every travel kind with a
//! small deterministic AI between ticks. The kernel parity test digests what
//! the kernel returns; the benchmark times it.

#![allow(dead_code)]

use std::sync::Arc;
use valimc_core::column::{Column, HEIGHT, MIN_Y};
use valimc_core::physics::aabb::Aabb;
use valimc_core::physics::border::Border;
use valimc_core::physics::facts::{
    shape_table, Boundary, Climb, Facts, Fluid, Hazard, Inside, InsideKind, InsideShape, Motion,
    PlayerFacts, LARGE_COLLISION, LAVA, WATER,
};
use valimc_core::physics::item::{self, ItemBody};
use valimc_core::physics::mob::{
    Attributes, Control, CubeJump, Float, Hop, Mob, Ticked, Ticker, Travel,
};
use valimc_core::physics::player::pose::Dimensions;
use valimc_core::physics::player::{Fault, World};
use valimc_core::physics::shape::{box_shape, VoxelShape};
use valimc_core::physics::source::Rows;
use valimc_core::physics::table::Entry;
use valimc_core::snapshot::ChunkSnapshot;

pub const AIR: u16 = 0;
pub const STONE: u16 = 1;
pub const GRASS: u16 = 2;
pub const SLAB: u16 = 3;
pub const TOP_SLAB: u16 = 4;
pub const STAIRS: u16 = 5; // 5..=8: north, east, south, west
pub const FENCE_POST: u16 = 9;
pub const FENCE_NS: u16 = 10;
pub const FENCE_EW: u16 = 11;
pub const WATER_SOURCE: u16 = 12;
pub const FLOWING_WATER: u16 = 13; // 13..=19: amount 1..=7
pub const FALLING_WATER: u16 = 20;
pub const ICE: u16 = 21;
pub const SOUL_SAND: u16 = 22;
pub const LADDER: u16 = 23;
pub const COBWEB: u16 = 24;
pub const LAVA_SOURCE: u16 = 25;
pub const FLOWING_LAVA: u16 = 26; // 26..=28: amount 2, 4, 6
pub const HONEY: u16 = 29;
pub const SLIME: u16 = 30;
pub const CARPET: u16 = 31;
pub const CHEST: u16 = 32;
pub const POWDER_SNOW: u16 = 33;
pub const CACTUS: u16 = 34;
pub const MAGMA: u16 = 35;
pub const FIRE: u16 = 36;
pub const BAMBOO: u16 = 37;
pub const WET_SLAB: u16 = 38;
pub const WALL: u16 = 39;
pub const SAND: u16 = 40;
const STATES: usize = 41;

const FENCE_FLAG: u64 = 1 << 47;
const ALL_STURDY: u64 = 0b11_1111 << 5;

fn b(min: [f64; 3], max: [f64; 3]) -> VoxelShape {
    box_shape(&Aabb::new(min, max))
}

fn px(v: f64) -> f64 {
    v / 16.0
}

/// The block table.
pub fn facts() -> Facts {
    let stairs = |filled_top: [bool; 4]| {
        // A 2 x 2 x 2 grid: the bottom half full, the top half's quarters
        // (x, z) = (0,0), (0,1), (1,0), (1,1) as given.
        let half = vec![0.0, 0.5, 1.0];
        let mut filled = vec![false; 8];
        for x in 0..2 {
            for z in 0..2 {
                filled[(x * 2) * 2 + z] = true;
                filled[(x * 2 + 1) * 2 + z] = filled_top[x * 2 + z];
            }
        }
        VoxelShape::new([half.clone(), half.clone(), half], [2, 2, 2], &filled).unwrap()
    };
    let (lo, hi) = (0.375, 0.625);
    let fence_ns = VoxelShape::new(
        [vec![lo, hi], vec![0.0, 1.5], vec![0.0, lo, hi, 1.0]],
        [1, 1, 3],
        &[true, true, true],
    )
    .unwrap();
    let fence_ew = VoxelShape::new(
        [vec![0.0, lo, hi, 1.0], vec![0.0, 1.5], vec![lo, hi]],
        [3, 1, 1],
        &[true, true, true],
    )
    .unwrap();
    let shapes = vec![
        VoxelShape::empty(),                                        // 0
        VoxelShape::block(),                                        // 1
        b([0.0; 3], [1.0, 0.5, 1.0]),                               // 2 slab
        b([0.0, 0.5, 0.0], [1.0; 3]),                               // 3 top slab
        stairs([true, false, true, false]),                         // 4 stairs north
        stairs([false, false, true, true]),                         // 5 east
        stairs([false, true, false, true]),                         // 6 south
        stairs([true, true, false, false]),                         // 7 west
        b([lo, 0.0, lo], [hi, 1.5, hi]),                            // 8 fence post
        fence_ns,                                                   // 9
        fence_ew,                                                   // 10
        b([0.0; 3], [1.0, px(14.0), 1.0]),                          // 11 soul sand
        b([0.0, 0.0, px(13.0)], [1.0, 1.0, 1.0]),                   // 12 ladder
        b([px(1.0), 0.0, px(1.0)], [px(15.0), px(15.0), px(15.0)]), // 13 honey
        b([0.0; 3], [1.0, px(1.0), 1.0]),                           // 14 carpet
        b([px(1.0), 0.0, px(1.0)], [px(15.0), px(14.0), px(15.0)]), // 15 chest
        b([px(1.0), 0.0, px(1.0)], [px(15.0), 1.0, px(15.0)]),      // 16 cactus
        b([px(6.5), 0.0, px(6.5)], [px(9.5), 1.0, px(9.5)]),        // 17 bamboo
        b([px(4.0), 0.0, px(4.0)], [px(12.0), 1.5, px(12.0)]),      // 18 wall
    ];
    let mut entries: Vec<Entry> = (0..shapes.len()).map(Entry::Fixed).collect();
    let powder = entries.len();
    entries.push(Entry::PowderSnow);
    let bamboo = entries.len();
    entries.push(Entry::Offset(17, 0.25));
    let entry_of = |s: u16| -> u16 {
        (match s {
            STONE | GRASS | ICE | SLIME | MAGMA | SAND => 1,
            SLAB | WET_SLAB => 2,
            TOP_SLAB => 3,
            5..=8 => 4 + (s - STAIRS) as usize,
            FENCE_POST => 8,
            FENCE_NS => 9,
            FENCE_EW => 10,
            SOUL_SAND => 11,
            LADDER => 12,
            HONEY => 13,
            CARPET => 14,
            CHEST => 15,
            CACTUS => 16,
            WALL => 18,
            POWDER_SNOW => powder,
            BAMBOO => bamboo,
            _ => 0,
        }) as u16
    };
    let states: Vec<u16> = (0..STATES as u16).map(entry_of).collect();
    let table = shape_table(
        shapes,
        entries,
        states,
        vec![],
        VoxelShape::empty(),
        VoxelShape::empty(),
        0.0,
        b([0.0; 3], [1.0, 0.9, 1.0]),
    )
    .unwrap();
    let flags: Vec<u64> = (0..STATES as u16)
        .map(|s| match s {
            AIR => valimc_core::facts::AIR,
            STONE | GRASS | ICE | SLIME | MAGMA | SAND => ALL_STURDY,
            SLAB | WET_SLAB => 1 << 5,
            TOP_SLAB => 1 << 6,
            5..=8 => 1 << 5,
            FENCE_POST | FENCE_NS | FENCE_EW => FENCE_FLAG | LARGE_COLLISION,
            WALL => LARGE_COLLISION,
            _ => 0,
        })
        .collect();
    let motion = |friction: f32, speed: f32, jump: f32, bounce: f32| Motion {
        friction,
        speed_factor: speed,
        jump_factor: jump,
        bounciness: bounce,
        suppresses_bounce: false,
        support_holds_y: false,
        speed_override: false,
    };
    let motions = vec![
        motion(0.6, 1.0, 1.0, 0.0),
        motion(0.98, 1.0, 1.0, 0.0),
        motion(0.6, 0.4, 1.0, 0.0),
        motion(0.6, 0.4, 0.5, 0.0),
        motion(0.8, 1.0, 1.0, 1.0),
        Motion {
            support_holds_y: true,
            ..motion(0.6, 1.0, 1.0, 0.0)
        },
    ];
    let motion_states: Vec<u8> = (0..STATES as u16)
        .map(|s| match s {
            ICE => 1,
            SOUL_SAND => 2,
            HONEY => 3,
            SLIME => 4,
            WALL => 5,
            _ => 0,
        })
        .collect();
    let fluid = |kind: u8, amount: u8, source: bool, falling: bool| Fluid {
        kind,
        amount,
        height: if kind == 0 { 0.0 } else { amount as f32 / 9.0 },
        source,
        falling,
    };
    let mut fluids = vec![fluid(0, 0, false, false), fluid(WATER, 8, true, false)];
    for a in 1..=7 {
        fluids.push(fluid(WATER, a, false, false));
    }
    fluids.push(fluid(WATER, 8, false, true));
    fluids.push(fluid(LAVA, 8, true, false));
    for a in [2, 4, 6] {
        fluids.push(fluid(LAVA, a, false, false));
    }
    let fluid_states: Vec<u8> = (0..STATES as u16)
        .map(|s| match s {
            WATER_SOURCE | WET_SLAB => 1,
            13..=19 => 2 + (s - FLOWING_WATER) as u8,
            FALLING_WATER => 9,
            LAVA_SOURCE => 10,
            26..=28 => 11 + (s - FLOWING_LAVA) as u8,
            _ => 0,
        })
        .collect();
    let boundaries = vec![
        Boundary {
            blocks_flow: false,
            ice: false,
            context: 0,
        },
        Boundary {
            blocks_flow: true,
            ice: false,
            context: 0,
        },
        Boundary {
            blocks_flow: true,
            ice: true,
            context: 0,
        },
    ];
    let boundary_states: Vec<u8> = (0..STATES as u16)
        .map(|s| match s {
            ICE => 2,
            STONE | GRASS | SLIME | MAGMA | SAND | SLAB | TOP_SLAB | 5..=8 | CHEST | WALL => 1,
            _ => 0,
        })
        .collect();
    let mut facts = Facts::new(
        table,
        flags,
        motion_states,
        motions,
        fluid_states,
        fluids,
        boundary_states,
        boundaries,
    )
    .unwrap();
    let climb_states = (0..STATES as u16).map(|s| u8::from(s == LADDER)).collect();
    let climbs = vec![
        Climb {
            ladder_facing: -1,
            trapdoor_facing: -1,
            ..Climb::default()
        },
        Climb {
            climbable: true,
            ladder_facing: 2,
            trapdoor_facing: -1,
            ..Climb::default()
        },
    ];
    let inside_states = (0..STATES as u16)
        .map(|s| match s {
            COBWEB => 1,
            POWDER_SNOW => 2,
            FIRE => 3,
            CACTUS => 4,
            _ => 0,
        })
        .collect();
    let insides = vec![
        Inside::default(),
        Inside {
            kind: InsideKind::Cobweb,
            shape: InsideShape::Full,
        },
        Inside {
            kind: InsideKind::PowderSnow,
            shape: InsideShape::Context,
        },
        Inside {
            kind: InsideKind::Fire,
            shape: InsideShape::Full,
        },
        Inside {
            kind: InsideKind::None,
            shape: InsideShape::Boxes(vec![Aabb::new(
                [px(1.0), 0.0, px(1.0)],
                [px(15.0), px(15.0), px(15.0)],
            )]),
        },
    ];
    let hazard_states = (0..STATES as u16)
        .map(|s| match s {
            MAGMA => 1,
            CACTUS => 2,
            _ => 0,
        })
        .collect();
    facts.player = PlayerFacts {
        climb_states,
        climbs,
        inside_states,
        insides,
        hazard_states,
        hazards: vec![None, Some(Hazard::Magma), Some(Hazard::Cactus)],
        poses: vec![],
    };
    facts
}

/// splitmix64.
#[derive(Clone)]
pub struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    pub fn f(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.f()
    }

    pub fn int(&mut self, lo: i32, hi: i32) -> i32 {
        lo + (self.next() % (hi - lo + 1) as u64) as i32
    }

    pub fn chance(&mut self, p: f64) -> bool {
        self.f() < p
    }
}

/// Chunks -3..=2 on both axes: blocks -48..=47.
pub const CHUNKS: std::ops::RangeInclusive<i32> = -3..=2;
pub const GROUND: i32 = 63;

/// The scene's terrain.
pub fn terrain(rng: &mut Rng) -> Vec<((i32, i32), Column)> {
    let mut layers = [AIR; HEIGHT];
    for (i, l) in layers.iter_mut().enumerate() {
        let y = i as i32 + MIN_Y;
        *l = if y < GROUND {
            STONE
        } else if y == GROUND {
            GRASS
        } else {
            AIR
        };
    }
    let mut columns: Vec<((i32, i32), Column)> = Vec::new();
    for cx in CHUNKS {
        for cz in CHUNKS {
            columns.push(((cx, cz), Column::from_layers(&layers)));
        }
    }
    let mut world = Terrain(columns);
    let w = &mut world;
    // A pond: sources over a floor with waterlogged slabs, flowing edges and
    // a waterfall from a ledge.
    for x in 8..=24 {
        for z in 8..=24 {
            for y in 59..=GROUND {
                w.set(x, y, z, WATER_SOURCE);
            }
            w.set(x, 58, z, if rng.chance(0.2) { SAND } else { STONE });
            if rng.chance(0.08) {
                w.set(x, 59, z, WET_SLAB);
            }
        }
    }
    for i in 7..=25 {
        for (x, z) in [(i, 7), (i, 25), (7, i), (25, i)] {
            let amount = rng.int(1, 7) as u16;
            w.set(x, GROUND, z, FLOWING_WATER + amount - 1);
        }
    }
    for y in GROUND + 1..=GROUND + 4 {
        w.set(26, y, 16, STONE);
        w.set(25, y, 16, FALLING_WATER);
    }
    // A rough field of partial blocks, slowing and hazard blocks.
    for x in -40..=-8 {
        for z in -40..=-8 {
            let r = rng.f();
            let y = GROUND + 1;
            let (state, ground) = match r {
                r if r < 0.22 => (SLAB, GRASS),
                r if r < 0.28 => (TOP_SLAB, GRASS),
                r if r < 0.38 => (STAIRS + rng.int(0, 3) as u16, GRASS),
                r if r < 0.42 => (CARPET, GRASS),
                r if r < 0.44 => (CHEST, GRASS),
                r if r < 0.48 => (AIR, SOUL_SAND),
                r if r < 0.52 => (AIR, ICE),
                r if r < 0.54 => (HONEY, GRASS),
                r if r < 0.55 => (AIR, SLIME),
                r if r < 0.57 => (COBWEB, GRASS),
                r if r < 0.58 => (POWDER_SNOW, GRASS),
                r if r < 0.59 => (CACTUS, SAND),
                r if r < 0.60 => (AIR, MAGMA),
                r if r < 0.605 => (FIRE, GRASS),
                r if r < 0.62 => (BAMBOO, GRASS),
                r if r < 0.64 => (STONE, GRASS),
                _ => (AIR, GRASS),
            };
            w.set(x, GROUND, z, ground);
            w.set(x, y, z, state);
            if state == STONE && rng.chance(0.3) {
                w.set(x, y + 1, z, STONE);
            }
        }
    }
    // Fence pens, one roomy and one tight, and a stretch of wall.
    for (x0, x1, z0, z1) in [(-40, -28, 8, 20), (-24, -18, 8, 14)] {
        for x in x0..=x1 {
            for z in z0..=z1 {
                let edge_x = x == x0 || x == x1;
                let edge_z = z == z0 || z == z1;
                let state = match (edge_x, edge_z) {
                    (true, true) => FENCE_POST,
                    (true, false) => FENCE_NS,
                    (false, true) => FENCE_EW,
                    _ => continue,
                };
                w.set(x, GROUND + 1, z, state);
            }
        }
    }
    for x in -12..=-4 {
        w.set(x, GROUND + 1, 30, WALL);
    }
    // A climbing tower with ladders on its north face and a stone wall.
    for y in GROUND + 1..=GROUND + 10 {
        for x in 28..=32 {
            w.set(x, y, -30, STONE);
            w.set(x, y, -31, LADDER);
        }
        for x in 10..=26 {
            w.set(x, y, -20, STONE);
        }
    }
    // A lava pool with flowing edges.
    for x in 30..=38 {
        for z in 30..=38 {
            for y in 60..=GROUND {
                w.set(x, y, z, LAVA_SOURCE);
            }
        }
    }
    for i in 29..=39 {
        for (x, z) in [(i, 29), (i, 39), (29, i), (39, i)] {
            w.set(x, GROUND, z, FLOWING_LAVA + rng.int(0, 2) as u16);
        }
    }
    world.0
}

struct Terrain(Vec<((i32, i32), Column)>);

impl Terrain {
    fn set(&mut self, x: i32, y: i32, z: i32, state: u16) {
        let chunk = (x >> 4, z >> 4);
        let (_, c) = self.0.iter_mut().find(|(k, _)| *k == chunk).unwrap();
        c.set(x, y, z, state);
    }
}

/// The published view a tick reads.
pub fn rows(columns: &[((i32, i32), Column)], facts: &Facts) -> Rows<Arc<ChunkSnapshot>> {
    let mut rows = Rows::new(AIR);
    for (chunk, column) in columns {
        let snapshot = Arc::new(ChunkSnapshot::new(*chunk, column, 1, None));
        // The sections a tick's region reaches (y 40..=127).
        rows.insert(snapshot, 6..=11, &facts.shapes);
    }
    rows
}

/// What the scene's AI does with a mob between its ticks.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Plan {
    /// Walk to a target in `area`, idling between targets.
    Walk {
        area: [f64; 4],
        target: Option<[f64; 3]>,
    },
    Idle,
    Swim {
        area: [f64; 4],
    },
    Squid,
    Ghast {
        area: [f64; 4],
    },
    Bat,
    Blaze,
    Spider {
        area: [f64; 4],
        target: Option<[f64; 3]>,
    },
    Rabbit {
        area: [f64; 4],
    },
    Slime {
        area: [f64; 4],
    },
    Strider {
        area: [f64; 4],
        target: Option<[f64; 3]>,
    },
    Fixed,
}

/// A kind of mob, for the benchmark's breakdown.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    Walker,
    Idle,
    Crowd,
    Rough,
    Swimmer,
    Flier,
    Climber,
    Hopper,
    Lava,
    Fixed,
}

fn dims(width: f64, height: f64, eye: f64) -> Dimensions {
    Dimensions { width, height, eye }
}

fn mob(at: [f64; 3], size: Dimensions, speed: f64) -> Mob {
    Mob {
        position: at,
        size,
        attributes: Attributes {
            movement_speed: speed,
            ..Attributes::default()
        },
        on_ground: true,
        ..Mob::default()
    }
}

fn spot(rng: &mut Rng, area: [f64; 4], y: f64) -> [f64; 3] {
    [rng.range(area[0], area[1]), y, rng.range(area[2], area[3])]
}

fn spot_y(rng: &mut Rng, area: [f64; 4], lo: f64, hi: f64) -> [f64; 3] {
    let p = spot(rng, area, 0.0);
    [p[0], rng.range(lo, hi), p[2]]
}

/// One mob of `kind` in its area.
fn spawn(rng: &mut Rng, kind: Kind) -> (Mob, Plan) {
    let ground = (GROUND + 1) as f64;
    match kind {
        Kind::Walker => {
            let area = [-6.0, 6.0, -40.0, 4.0];
            let m = mob(spot(rng, area, ground), dims(0.6, 1.95, 1.74), 0.23);
            (m, Plan::Walk { area, target: None })
        }
        Kind::Idle => {
            let area = [-46.0, 46.0, -6.0, 6.0];
            let mut m = mob(spot(rng, area, ground), dims(0.9, 1.4, 1.3), 0.2);
            m.yaw = rng.range(0.0, 360.0) as f32;
            (m, Plan::Idle)
        }
        Kind::Crowd => {
            let area = if rng.chance(0.5) {
                [-39.5, -28.5, 8.5, 19.5]
            } else {
                [-23.5, -18.5, 8.5, 13.5]
            };
            let size = if rng.chance(0.5) {
                dims(0.9, 1.4, 1.3)
            } else {
                dims(0.9, 1.3, 1.105)
            };
            let m = mob(spot(rng, area, ground), size, 0.2);
            (m, Plan::Walk { area, target: None })
        }
        Kind::Rough => {
            let area = [-39.0, -9.0, -39.0, -9.0];
            let (size, speed) = match rng.int(0, 2) {
                0 => (dims(0.6, 1.95, 1.74), 0.23),
                1 => (dims(0.4, 0.7, 0.644), 0.25),
                _ => (dims(0.9, 1.4, 1.3), 0.2),
            };
            let mut m = mob(spot(rng, area, ground + 1.0), size, speed);
            if size.width < 0.5 {
                m.fall_scale = 0.6;
            }
            m.on_ground = false;
            (m, Plan::Walk { area, target: None })
        }
        Kind::Swimmer => {
            let area = [9.0, 24.0, 9.0, 24.0];
            let at = spot_y(rng, area, 59.2, 63.0);
            let (size, travel) = match rng.int(0, 3) {
                0 => (dims(0.5, 0.3, 0.195), Travel::Fish { sink: false }),
                1 => (dims(0.7, 0.4, 0.26), Travel::Fish { sink: true }),
                2 => (dims(0.9, 0.6, 0.3), Travel::Dolphin { sink: false }),
                _ => (dims(0.8, 0.8, 0.4), Travel::Squid),
            };
            let mut m = mob(at, size, 1.2);
            m.travel = travel;
            m.fluid_pushed = false;
            m.on_ground = false;
            if travel == Travel::Squid {
                (m, Plan::Squid)
            } else {
                m.control = Control::Set {
                    speed: 0.1,
                    lift: false,
                };
                (m, Plan::Swim { area })
            }
        }
        Kind::Flier => match rng.int(0, 2) {
            0 => {
                let area = [-40.0, 40.0, -40.0, 40.0];
                let mut m = mob(spot_y(rng, area, 75.0, 90.0), dims(4.0, 4.0, 2.6), 0.7);
                m.travel = Travel::Flying;
                m.no_gravity = true;
                m.on_ground = false;
                m.emits = false;
                m.float = Some(Float {
                    wanted: None,
                    duration: 0,
                    random: rng.next() & ((1 << 48) - 1),
                    speed: 0.1 * 5.0 / 3.0,
                });
                (m, Plan::Ghast { area })
            }
            1 => {
                let area = [-30.0, 30.0, -30.0, 30.0];
                let mut m = mob(spot_y(rng, area, 66.0, 72.0), dims(0.5, 0.9, 0.45), 0.0);
                m.pushes = false;
                m.on_ground = false;
                m.emits = false;
                (m, Plan::Bat)
            }
            _ => {
                let area = [-30.0, 30.0, -30.0, 30.0];
                let mut m = mob(spot_y(rng, area, 64.0, 70.0), dims(0.6, 1.8, 1.53), 0.23);
                m.fall_scale = 0.6;
                m.on_ground = false;
                (m, Plan::Blaze)
            }
        },
        Kind::Climber => {
            let area = [10.0, 34.0, -34.0, -21.0];
            let mut m = if rng.chance(0.6) {
                mob(spot(rng, area, ground), dims(1.4, 0.9, 0.65), 0.3)
            } else {
                mob(spot(rng, area, ground), dims(0.6, 1.95, 1.74), 0.23)
            };
            if m.size.width > 1.0 {
                m.wall_climb = Some(false);
            }
            (m, Plan::Spider { area, target: None })
        }
        Kind::Hopper => {
            if rng.chance(0.5) {
                let area = [-6.0, 6.0, 8.0, 20.0];
                let mut m = mob(spot(rng, area, ground), dims(0.4, 0.5, 0.3), 0.3);
                m.hop = Some(Hop {
                    wanted: m.position,
                    baby: rng.chance(0.3),
                    ..Hop::default()
                });
                (m, Plan::Rabbit { area })
            } else {
                let area = [-6.0, 6.0, 22.0, 40.0];
                let size = [0.52, 1.04, 2.08][rng.int(0, 2) as usize];
                let mut m = mob(spot(rng, area, ground), dims(size, size, 0.625 * size), 0.3);
                m.cube = Some(CubeJump {
                    bonus: 0.0,
                    lava: None,
                });
                (m, Plan::Slime { area })
            }
        }
        Kind::Lava => {
            let area = [30.5, 37.5, 30.5, 37.5];
            let mut m = mob(spot(rng, area, 63.5), dims(0.9, 1.7, 1.445), 0.175);
            m.lava_walker = true;
            m.step_gap = Some(0.15);
            (m, Plan::Strider { area, target: None })
        }
        Kind::Fixed => {
            let area = [40.0, 46.0, -46.0, 46.0];
            let p = spot(rng, area, ground);
            let mut m = mob(
                [p[0].floor() + 0.5, p[1], p[2].floor() + 0.5],
                dims(1.0, 1.0, 0.5),
                0.0,
            );
            m.fixed = true;
            m.pushable = false;
            (m, Plan::Fixed)
        }
    }
}

/// Sees a mob's kernel step: its kind, result, pushes and nanoseconds.
pub type MobObserver<'a> = dyn FnMut(Kind, &Result<Ticked, Fault>, &[(usize, [f64; 3])], u64) + 'a;
/// Sees an item's step and its nanoseconds.
pub type ItemObserver<'a> = dyn FnMut(&Result<item::Stepped<ItemBody>, item::ItemFault>, u64) + 'a;

/// An owner's mobs, items and the players that push them, over one view.
pub struct Scene {
    pub facts: Facts,
    pub rows: Rows<Arc<ChunkSnapshot>>,
    pub border: Option<Border>,
    pub mobs: Vec<Mob>,
    pub plans: Vec<Plan>,
    pub kinds: Vec<Kind>,
    /// Solid lids (a shulker's box) by mob.
    pub solid: Vec<Option<Aabb>>,
    pub items: Vec<ItemBody>,
    pub players: Vec<([f64; 3], Aabb)>,
    pub rng: Rng,
}

/// The mix of kinds a scene draws from.
pub const MIXED: &[(Kind, usize)] = &[
    (Kind::Walker, 12),
    (Kind::Idle, 40),
    (Kind::Crowd, 24),
    (Kind::Rough, 18),
    (Kind::Swimmer, 14),
    (Kind::Flier, 10),
    (Kind::Climber, 10),
    (Kind::Hopper, 12),
    (Kind::Lava, 6),
    (Kind::Fixed, 4),
];

impl Scene {
    pub fn new(seed: u64, mix: &[(Kind, usize)], items: usize) -> Scene {
        let facts = facts();
        let mut rng = Rng(seed);
        let columns = terrain(&mut rng);
        let rows = rows(&columns, &facts);
        let mut mobs = Vec::new();
        let mut plans = Vec::new();
        let mut kinds = Vec::new();
        let mut solid = Vec::new();
        for &(kind, count) in mix {
            for _ in 0..count {
                let (m, plan) = spawn(&mut rng, kind);
                solid.push(m.fixed.then(|| {
                    let p = m.position;
                    Aabb::new(
                        [p[0] - 0.5, p[1], p[2] - 0.5],
                        [p[0] + 0.5, p[1] + 1.0, p[2] + 0.5],
                    )
                }));
                mobs.push(m);
                plans.push(plan);
                kinds.push(kind);
            }
        }
        let items = (0..items)
            .map(|_| {
                let area = [-46.0, 46.0, -46.0, 46.0];
                let p = spot_y(&mut rng, area, 64.2, 70.0);
                ItemBody {
                    position: p,
                    velocity: [
                        rng.range(-0.1, 0.1),
                        rng.range(-0.2, 0.2),
                        rng.range(-0.1, 0.1),
                    ],
                    on_ground: false,
                    no_gravity: false,
                }
            })
            .collect();
        let players = (0..2)
            .map(|i| {
                let feet = if i == 0 {
                    [-34.0, 64.0, 14.0]
                } else {
                    [0.3, 64.0, -10.0]
                };
                let body = Aabb::new(
                    [feet[0] - 0.3, feet[1], feet[2] - 0.3],
                    [feet[0] + 0.3, feet[1] + 1.8, feet[2] + 0.3],
                );
                (feet, body)
            })
            .collect();
        Scene {
            facts,
            rows,
            border: Some(Border {
                min_x: -29_999_984.0,
                min_z: -29_999_984.0,
                max_x: 29_999_984.0,
                max_z: 29_999_984.0,
            }),
            mobs,
            plans,
            kinds,
            solid,
            items,
            players,
            rng,
        }
    }

    /// The AI's input for mob `i` (as the ticker holds it) this tick.
    fn think(plan: &mut Plan, rng: &mut Rng, mut m: Mob) -> Mob {
        let ground = (GROUND + 1) as f64;
        let walk = |rng: &mut Rng, m: &mut Mob, area: [f64; 4], target: &mut Option<[f64; 3]>| {
            let arrived = target.is_some_and(|t| {
                let (dx, dz) = (t[0] - m.position[0], t[2] - m.position[2]);
                dx * dx + dz * dz < 0.5
            });
            if arrived || rng.chance(0.01) {
                *target = None;
            }
            if target.is_none() && rng.chance(0.05) {
                *target = Some(spot(rng, area, ground));
            }
            if let Some(t) = *target {
                m.control = Control::MoveTo {
                    target: t,
                    speed: 1.0,
                };
            }
            if rng.chance(0.01) && m.on_ground {
                m.jump = true;
            }
        };
        match plan {
            Plan::Walk { area, target } => walk(rng, &mut m, *area, target),
            Plan::Idle => {
                if rng.chance(0.02) {
                    m.yaw = rng.range(0.0, 360.0) as f32;
                }
            }
            Plan::Swim { area } => {
                if rng.chance(0.1) {
                    let t = spot_y(rng, *area, 59.5, 62.5);
                    m.yaw = (rng.range(-180.0, 180.0)) as f32;
                    m.control = Control::Set {
                        speed: rng.range(0.02, 0.15),
                        lift: rng.chance(0.3),
                    };
                    m.set_inputs = [None, Some(((t[1] - m.position[1]) * 0.1) as f32), None];
                }
            }
            Plan::Squid => {
                if rng.chance(0.05) {
                    m.velocity = [
                        rng.range(-0.2, 0.2),
                        rng.range(-0.1, 0.1),
                        rng.range(-0.2, 0.2),
                    ];
                }
            }
            Plan::Ghast { area } => {
                if let Some(f) = m.float.as_mut() {
                    if f.wanted.is_none() && rng.chance(0.1) {
                        f.wanted = Some(spot_y(rng, *area, 75.0, 92.0));
                    }
                }
            }
            Plan::Bat => {
                let v = m.velocity;
                m.impulse = vec![[
                    (rng.range(-1.0, 1.0) * 0.5 - v[0]) * 0.1,
                    (rng.range(-0.5, 0.7) * 0.7 - v[1]) * 0.1,
                    (rng.range(-1.0, 1.0) * 0.5 - v[2]) * 0.1,
                ]];
            }
            Plan::Blaze => {
                m.rise = rng.chance(0.4);
            }
            Plan::Spider { area, target } => {
                if let Some(c) = m.wall_climb.as_mut() {
                    *c = m.horizontal_collision;
                }
                walk(rng, &mut m, *area, target);
            }
            Plan::Rabbit { area } => {
                if let Some(h) = m.hop.as_mut() {
                    if m.on_ground && rng.chance(0.15) {
                        h.wanted = spot(rng, *area, ground);
                        h.next_speed = rng.range(0.6, 2.2);
                        m.control = Control::MoveTo {
                            target: h.wanted,
                            speed: h.next_speed,
                        };
                        m.jump = true;
                    } else if m.on_ground {
                        h.jumping = false;
                    }
                }
            }
            Plan::Slime { area } => {
                if m.on_ground && rng.chance(0.1) {
                    m.yaw = rng.range(0.0, 360.0) as f32;
                    m.control = Control::MoveTo {
                        target: spot(rng, *area, ground),
                        speed: 1.0,
                    };
                    m.jump = true;
                }
            }
            Plan::Strider { area, target } => walk(rng, &mut m, *area, target),
            Plan::Fixed => {}
        }
        m
    }

    /// One owner tick: every mob's turn in order (its AI, then the kernel),
    /// the players' pushes, then the items. `observe` sees each kernel step
    /// with its mob's kind and the time it took; `item_observe` each item.
    pub fn tick(&mut self, observe: &mut MobObserver, item_observe: &mut ItemObserver) {
        let world = World {
            source: &self.rows,
            facts: &self.facts,
            border: self.border,
            entities: &[],
        };
        let mut ticker = Ticker::new(self.mobs.clone());
        for (i, s) in self.solid.iter().enumerate() {
            if s.is_some() {
                let p = ticker.current[i].position;
                ticker.collider(i, p, *s);
            }
        }
        let mut results = Vec::with_capacity(self.mobs.len());
        for i in 0..self.mobs.len() {
            let current = ticker.current[i].clone();
            let input = Scene::think(&mut self.plans[i], &mut self.rng, current);
            let start = std::time::Instant::now();
            let (result, pushed) = ticker.step(&world, i, input, &self.players);
            let ns = start.elapsed().as_nanos() as u64;
            observe(self.kinds[i], &result, &pushed, ns);
            results.push(result);
        }
        let velocities = ticker.finish(&self.players);
        for (i, (result, v)) in results.into_iter().zip(velocities).enumerate() {
            match result {
                Ok(t) => {
                    self.mobs[i] = t.mob;
                    self.mobs[i].velocity = v;
                }
                Err(_) => self.mobs[i].velocity = v,
            }
        }
        for it in self.items.iter_mut() {
            let start = std::time::Instant::now();
            let r = item::step(&self.rows, &self.facts, it, false, self.border.as_ref());
            let ns = start.elapsed().as_nanos() as u64;
            item_observe(&r, ns);
            if let Ok(s) = &r {
                *it = s.body;
            }
        }
    }
}

/// FNV-1a over what the kernel returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Digest(pub u64);

impl Digest {
    pub fn new() -> Digest {
        Digest(0xcbf2_9ce4_8422_2325)
    }

    pub fn add(&mut self, text: &str) {
        for byte in text.bytes() {
            self.0 ^= byte as u64;
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
}
