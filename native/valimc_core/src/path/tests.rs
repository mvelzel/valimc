//! Searches over small scenes with a made-up state table: air, stone, water,
//! a fence and a closed wooden door. Vanilla parity is the `paths` stage's;
//! these check the evaluators' shape.

use super::*;
use crate::physics::facts::{shape_table, Boundary, Fluid, Motion};
use crate::physics::shape::VoxelShape;
use crate::physics::source::States;
use crate::physics::table::Entry;

const STONE: u16 = 1;
const WATER_STATE: u16 = 2;
const FENCE_STATE: u16 = 3;
const DOOR: u16 = 4;

fn facts() -> (Facts, PathFacts) {
    let shapes = vec![
        VoxelShape::empty(),
        VoxelShape::block(),
        VoxelShape::from_box([0.375, 0.0, 0.375], [0.625, 1.5, 0.625]),
        VoxelShape::from_box([0.0, 0.0, 0.0], [1.0, 1.0, 0.1875]),
    ];
    let entries = vec![
        Entry::Fixed(0),
        Entry::Fixed(1),
        Entry::Fixed(2),
        Entry::Fixed(3),
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
    let facts = Facts::new(
        table,
        vec![1, 0, 0, 0, 0],
        vec![0; 5],
        vec![motion],
        vec![0, 0, 1, 0, 0],
        vec![empty, water],
        vec![0; 5],
        vec![boundary],
    )
    .unwrap();
    let paths = PathFacts::new(
        vec![OPEN, BLOCKED, types::WATER, FENCE, DOOR_WOOD_CLOSED],
        vec![LAND | FLYABLE, 0, LAND | SWIMMABLE | WATER_BLOCK, 0, 0],
    )
    .unwrap();
    (facts, paths)
}

fn default_malus() -> [f32; COUNT] {
    let mut m = [0.0; COUNT];
    for (t, v) in [
        (BLOCKED, -1.0),
        (POWDER_SNOW, -1.0),
        (FENCE, -1.0),
        (LAVA, -1.0),
        (types::WATER, 8.0),
        (WATER_BORDER, 8.0),
        (UNPASSABLE_RAIL, -1.0),
        (FIRE_IN_NEIGHBOR, 8.0),
        (FIRE, 16.0),
        (DAMAGING_IN_NEIGHBOR, 8.0),
        (DAMAGING, -1.0),
        (DOOR_WOOD_CLOSED, -1.0),
        (DOOR_IRON_CLOSED, -1.0),
        (BREACH, 4.0),
        (LEAVES, -1.0),
        (STICKY_HONEY, 8.0),
        (BIG_MOBS_CLOSE_TO_DANGER, 4.0),
    ] {
        m[t as usize] = v;
    }
    m
}

fn mob(position: [f64; 3]) -> Mob {
    Mob {
        position,
        width: 0.6,
        height: 1.95,
        on_ground: true,
        in_water: false,
        step: 0.6,
        max_fall: 3,
        fall_distance: 0.0,
        malus: default_malus(),
        can_pass_doors: true,
        can_open_doors: false,
        can_float: false,
        can_walk_over_fences: false,
        random: 0,
    }
}

fn request(evaluator: Evaluator, mob: Mob, target: [i32; 3]) -> Request {
    let b = mob.block();
    Request {
        evaluator,
        mob,
        targets: vec![target],
        // A zombie's follow range.
        max_path_length: 35.0,
        reach: 0,
        max_visited: 560,
        multiplier: 1.0,
        region: (b.map(|v| v - 24), b.map(|v| v + 24)),
        min_y: -64,
        height: 384,
        sea_level: 63,
        border: None,
    }
}

/// A stone floor at y 63 over x and z in -8..=8, with `extra` blocks.
fn scene(extra: &[([i32; 3], u16)]) -> States {
    let mut map = HashMap::new();
    for x in -8..=8 {
        for z in -8..=8 {
            map.insert([x, 63, z], STONE);
            for y in 64..70 {
                map.insert([x, y, z], 0);
            }
        }
    }
    for &(p, s) in extra {
        map.insert(p, s);
    }
    States(map)
}

/// A wall at x = 2 from y 64 to 66, with `gap` (a z) holding `fill`.
fn wall(gap: i32, fill: u16) -> Vec<([i32; 3], u16)> {
    let mut out = vec![];
    for z in -8..=8 {
        for y in 64..=66 {
            let state = if z == gap && y < 66 { fill } else { STONE };
            out.push(([2, y, z], state));
        }
    }
    out
}

fn positions(path: &Path) -> Vec<[i32; 3]> {
    path.nodes.iter().map(|n| n.pos).collect()
}

#[test]
fn walks_around_a_wall_through_its_gap() {
    let (facts, paths) = facts();
    let source = scene(&wall(5, 0));
    let found = find(
        &source,
        &facts,
        &paths,
        &request(Evaluator::Walk, mob([0.5, 64.0, 0.5]), [4, 64, 0]),
    );
    let path = found.path.unwrap();
    assert!(path.reached);
    assert_eq!(path.nodes.last().unwrap().pos, [4, 64, 0]);
    assert!(positions(&path).contains(&[2, 64, 5]));
    assert!(positions(&path).iter().all(|p| p[0] != 2 || p[2] == 5));
    assert_eq!(found.chunks[0], (0, 0));
}

#[test]
fn a_closed_wooden_door_opens_only_for_a_door_opener() {
    let (facts, paths) = facts();
    let source = scene(&wall(5, DOOR));
    let target = [4, 64, 5];
    let closed = find(
        &source,
        &facts,
        &paths,
        &request(Evaluator::Walk, mob([0.5, 64.0, 5.5]), target),
    );
    assert!(!closed.path.unwrap().reached);
    let mut opener = mob([0.5, 64.0, 5.5]);
    opener.can_open_doors = true;
    let open = find(
        &source,
        &facts,
        &paths,
        &request(Evaluator::Walk, opener, target),
    )
    .path
    .unwrap();
    assert!(open.reached);
    let door = open.nodes.iter().find(|n| n.pos == [2, 64, 5]).unwrap();
    assert_eq!(door.kind, WALKABLE_DOOR);
}

#[test]
fn fences_stop_walkers_and_fliers_go_over() {
    let (facts, paths) = facts();
    let source = scene(
        &(-8..=8)
            .map(|z| ([2, 64, z], FENCE_STATE))
            .collect::<Vec<_>>(),
    );
    let walk = find(
        &source,
        &facts,
        &paths,
        &request(Evaluator::Walk, mob([0.5, 64.0, 0.5]), [4, 64, 0]),
    );
    assert!(!walk.path.unwrap().reached);
    let mut flier = mob([0.5, 64.0, 0.5]);
    flier.width = 0.7;
    flier.height = 0.6;
    let fly = find(
        &source,
        &facts,
        &paths,
        &request(Evaluator::Fly, flier, [4, 64, 0]),
    )
    .path
    .unwrap();
    assert!(fly.reached);
    assert!(fly.nodes.iter().all(|n| n.pos[0] != 2 || n.pos[1] >= 66));
}

#[test]
fn swimmers_stay_in_water_and_amphibians_enter_it() {
    let (facts, paths) = facts();
    // A pool at x 1..=6, z -2..=2, y 60..=63.
    let mut extra = vec![];
    for x in 1..=6 {
        for z in -2..=2 {
            for y in 60..=63 {
                extra.push(([x, y, z], WATER_STATE));
            }
        }
    }
    let source = scene(&extra);
    let mut fish = mob([2.5, 61.0, 0.5]);
    fish.width = 0.5;
    fish.height = 0.3;
    fish.in_water = true;
    fish.on_ground = false;
    fish.can_pass_doors = false;
    let swim = find(
        &source,
        &facts,
        &paths,
        &request(Evaluator::Swim { breaching: false }, fish, [6, 60, -2]),
    )
    .path
    .unwrap();
    assert!(swim.reached);
    assert!(swim.nodes.iter().all(|n| n.kind == types::WATER));
    let turtle = mob([-2.5, 64.0, 0.5]);
    let amphibious = find(
        &source,
        &facts,
        &paths,
        &request(Evaluator::Amphibious { shallow: false }, turtle, [4, 61, 0]),
    )
    .path
    .unwrap();
    assert!(amphibious.reached);
    assert!(amphibious.nodes.iter().any(|n| n.kind == types::WATER));
}

#[test]
fn chunks_outside_the_region_read_as_air() {
    let (facts, paths) = facts();
    let source = scene(&[]);
    let mut r = request(Evaluator::Walk, mob([0.5, 64.0, 0.5]), [6, 64, 0]);
    // A region of the mob's chunk alone: x past 15 reads as air, nothing beyond.
    r.region = ([0, 0, 0], [15, 128, 15]);
    let found = find(&source, &facts, &paths, &r);
    assert!(found.path.unwrap().reached);
    assert_eq!(found.chunks, vec![(0, 0)]);
}
