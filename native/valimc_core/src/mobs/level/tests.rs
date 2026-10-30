//! The level's predicates over a made-up state table: air, stone, a water
//! source, a fence and a shulker box (the vanilla stages check the level
//! over real terrain).

use super::*;
use crate::mobs::facts::tests::fixture;
use crate::physics::facts::{shape_table, Boundary, Fluid, Motion};
use crate::physics::shape::VoxelShape;
use crate::physics::source::States;
use crate::physics::table::Entry;

pub(crate) const STONE: u16 = 1;
pub(crate) const WATER_STATE: u16 = 2;
pub(crate) const FENCE: u16 = 3;
pub(crate) const SHULKER: u16 = 4;

pub(crate) fn physics() -> (PhysicsFacts, StateFacts) {
    let shapes = vec![
        VoxelShape::empty(),
        VoxelShape::block(),
        VoxelShape::from_box([0.375, 0.0, 0.375], [0.625, 1.5, 0.625]),
    ];
    let entries = vec![
        Entry::Fixed(0),
        Entry::Fixed(1),
        Entry::Fixed(2),
        Entry::ShulkerBox,
    ];
    let table = shape_table(
        shapes,
        entries,
        vec![0, 1, 0, 2, 3],
        vec![],
        VoxelShape::empty(),
        VoxelShape::empty(),
        0.0,
        VoxelShape::empty(),
    )
    .unwrap();
    let motion = Motion {
        friction: 0.6,
        speed_factor: 1.0,
        jump_factor: 1.0,
        bounciness: 0.0,
        suppresses_bounce: false,
        support_holds_y: false,
        speed_override: false,
    };
    let water = Fluid {
        kind: crate::physics::facts::WATER,
        amount: 8,
        height: 0.8888889,
        source: true,
        falling: false,
    };
    let empty = Fluid { kind: 0, ..water };
    let boundary = Boundary {
        blocks_flow: false,
        ice: false,
        context: 0,
    };
    let stone = 1 << SOLID | 1 << SOLID_RENDER | 1 << REDSTONE_CONDUCTOR;
    let flags = vec![1 << AIR, stone, 0, 1 << SOLID, 1 << SOLID];
    let facts = PhysicsFacts::new(
        table,
        flags.clone(),
        vec![0; 5],
        vec![motion],
        vec![0, 0, 1, 0, 0],
        vec![empty, water],
        vec![0; 5],
        vec![boundary],
    )
    .unwrap();
    let all = 0b11_1111;
    let states = StateFacts::new(
        flags,
        vec![0, all, all, all, all],
        vec![0, 0, 2, 0, 0],
        vec![0, 0, 8, 0, 0],
        vec![0, 0, 2, 0, 0],
        vec![0; 5],
    )
    .unwrap();
    (facts, states)
}

struct Lit(HashMap<[i32; 3], (u8, u8)>);

impl Environment for Lit {
    fn light(&self, p: [i32; 3]) -> Option<(u8, u8)> {
        self.0.get(&p).copied()
    }
    fn biome(&self, p: [i32; 3]) -> Option<u16> {
        (p[1] > 100).then_some(0)
    }
}

pub(crate) fn scene() -> States {
    let mut cells = HashMap::new();
    for x in -2..=2 {
        for z in -2..=2 {
            cells.insert([x, 62, z], STONE);
            cells.insert([x, 63, z], STONE);
            for y in 64..=66 {
                cells.insert([x, y, z], 0);
            }
        }
    }
    cells.insert([1, 64, 0], WATER_STATE);
    cells.insert([-1, 64, 0], FENCE);
    cells.insert([0, 64, 1], SHULKER);
    States(cells)
}

#[test]
fn block_predicates_follow_the_fact_table() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    assert!(level.air([0, 64, 0]) && !level.air([0, 63, 0]) && !level.air([9, 64, 9]));
    assert!(level.solid([0, 63, 0]) && !level.solid([9, 63, 9]));
    assert!(level.conductor([0, 63, 0]) && level.solid_render([0, 63, 0]));
    assert_eq!(level.fluid([1, 64, 0]), FluidKind::Water);
    assert_eq!(level.fluid([9, 64, 0]), FluidKind::Empty);
    assert!(level.collides([0, 63, 0]) && level.collides([9, 9, 9]));
    assert!(!level.collides([0, 64, 0]) && level.collides([-1, 64, 0]));
    assert!(level.collides([0, 64, 1]));
    assert_eq!(level.motion_blocking(1, 0), 65);
    assert_eq!(level.motion_blocking(0, 0), 64);
    assert_eq!(level.motion_blocking(30, 30), -64);
    assert!(level.chunk((0, 0), 64) && !level.chunk((5, 5), 64));
    assert!(level.outside([0, -65, 0]) && !level.outside([0, 319, 0]));
}

#[test]
fn boxes_fit_and_touch_water() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    let at = |x: f64, y: f64, z: f64, w: f64, h: f64| {
        Aabb::new(
            [x - w / 2.0, y, z - w / 2.0],
            [x + w / 2.0, y + h, z + w / 2.0],
        )
    };
    // In the open, beside the fence's post, on the stone.
    assert!(level.fits(&at(0.5, 64.0, -0.5, 0.6, 1.8)));
    assert!(!level.fits(&at(-0.5, 64.0, 0.5, 0.6, 1.8)));
    // Reaching out of the scene reads an unreadable cell.
    assert!(!level.fits(&at(2.5, 64.0, 0.5, 0.6, 1.8)));
    assert!(level.in_water(&at(1.5, 64.0, 0.5, 0.6, 1.8)));
    assert!(!level.in_water(&at(1.5, 64.9, 0.5, 0.6, 1.8)));
    assert!(!level.in_water(&at(0.5, 64.0, 0.5, 0.6, 1.8)));
}

#[test]
fn light_follows_the_magic_curve() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let lit = Lit(HashMap::from([
        ([0, 64, 0], (15, 0)),
        ([1, 64, 0], (4, 9)),
        ([2, 64, 0], (14, 0)),
    ]));
    let mut level = Level::new(
        &blocks,
        &lit,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    assert_eq!(level.light([0, 64, 0]), 1.0);
    assert_eq!(level.light([5, 64, 0]), 0.0);
    // max(4 - 0, 9) = 9: v = 0.6, v / (4 - 1.8).
    let v = (9.0f64 / 15.0) as f32;
    assert_eq!(level.light([1, 64, 0]), v / (4.0 - 3.0 * v));
    level.darken = 11;
    let v = (4.0f64 / 15.0) as f32;
    assert_eq!(level.light([0, 64, 0]), v / (4.0 - 3.0 * v));
    assert!(level.sees_sky([0, 64, 0]) && !level.sees_sky([2, 64, 0]));
    assert!(level.sky([0, 64, 0]) && !level.sky([7, 64, 0]));
    assert_eq!(level.biome_name([0, 120, 0]), "minecraft:desert");
    assert_eq!(level.biome_name([0, 64, 0]), "minecraft:plains");
    assert!(!level.rain([0.5, 64.0, 0.5], 65.8));
}

#[test]
fn structures_knots_and_finds() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let mut level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    level.structures.insert(
        (1, 1),
        vec![StructureStart {
            name: "minecraft:swamp_hut".into(),
            pieces: vec![[16, 60, 16, 20, 70, 20]],
        }],
    );
    assert!(level.in_structure([17, 64, 18], &["minecraft:swamp_hut"]));
    assert!(!level.in_structure([17, 64, 18], &["minecraft:village"]));
    assert!(!level.in_structure([21, 64, 18], &["minecraft:swamp_hut"]));
    level.knots.insert([1, 65, 1], 42);
    assert_eq!(level.knot([1, 65, 1]), Some(42));
    let found = level.find([-20, 0, -3], [3, 80, 40], |(cx, cz)| {
        vec![
            (cx * 16 + 1, 64, cz * 16 + 2, 7),
            (cx * 16 + 5, 90, cz * 16, 7),
        ]
    });
    let at = |x, z| ([x, 64, z], 7);
    assert_eq!(
        found,
        vec![
            at(-15, 2),
            at(-15, 18),
            at(-15, 34),
            at(1, 2),
            at(1, 18),
            at(1, 34)
        ]
    );
    let r = level.random().int(10);
    assert_eq!(r, LegacyRandom::new(1).int(10));
}

#[test]
fn manhattan_orders_nearest_first() {
    let cells = manhattan([0, 0, 0], 1, 1, 1);
    assert_eq!(cells[0], [0, 0, 0]);
    assert_eq!(&cells[1..4], &[[-1, 0, 0], [0, -1, 0], [0, 0, 1]]);
    assert_eq!(cells[4], [0, 0, -1]);
    assert_eq!(cells.len(), 1 + 6 + 12 + 8);
}

#[test]
fn rain_reads_column_climate_and_guards() {
    let climates = [
        Climate {
            temperature: 2.0,
            frozen: false,
            precipitation: false,
        },
        Climate {
            temperature: 0.8,
            frozen: false,
            precipitation: true,
        },
    ];
    let column = |_, _| Some((64, 64));
    let plains = |_| Some(1);
    let at = [0.5, 64.0, 0.5];
    assert_eq!(
        rain_at(&climates, false, 63, at, 65.8, column, plains),
        Some(false)
    );
    assert_eq!(
        rain_at(&climates, true, 63, at, 65.8, column, plains),
        Some(true)
    );
    assert_eq!(
        rain_at(&climates, true, 63, at, 65.8, column, |_| Some(0)),
        Some(false)
    );
    // Under a roof.
    let roofed = |_, _| Some((70, 70));
    assert_eq!(
        rain_at(&climates, true, 63, at, 65.8, roofed, plains),
        Some(false)
    );
    assert_eq!(
        rain_at(&climates, true, 63, at, 65.8, |_, _| None, plains),
        None
    );
    // Head more than two blocks above the feet.
    assert_eq!(rain_at(&climates, true, 63, at, 67.5, column, plains), None);
}
