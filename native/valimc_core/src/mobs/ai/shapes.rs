//! Block collision shapes as a mob reads them (`Valimc.AI.Shapes`), as
//! `Valimc.Physics.Clip.collider/2` gives them: scaffolding, powder snow
//! and moving pistons empty, shulker boxes closed (a mob beside them, no
//! block entity). Whether a box is free of blocks and inside the border
//! (`noCollision`), whether a block's face is full (`Block.isFaceFull`),
//! the free position nearest a point (`findFreePosition`), the faces in
//! 3D order and a ray through the collider shapes with or without fluids
//! (`Clip.clip/5`'s miss). A cell that cannot be read stops everything.

use crate::mobs::ai::fmath::{emax, emin};
use crate::mobs::level::Level;
use crate::physics::facts::Facts;
use crate::physics::ray;
use crate::physics::source::{BlockSource, AIR};
use crate::physics::table::{Context, Entry};
use crate::physics::Aabb;

/// `Direction` by its 3D value: axis (0 x, 1 y, 2 z) and sign.
const FACES: [(usize, i32); 6] = [(1, -1), (1, 1), (2, -1), (2, 1), (0, -1), (0, 1)];
const STEPS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

/// The cell next to `p` across `face` (3D order).
pub fn relative(p: [i32; 3], face: usize) -> [i32; 3] {
    let d = STEPS[face];
    [p[0] + d[0], p[1] + d[1], p[2] + d[2]]
}

/// The face opposite `face`.
pub fn opposite(face: usize) -> usize {
    face ^ 1
}

/// The axis of `face`: 0 x, 1 y, 2 z.
pub fn axis(face: usize) -> usize {
    FACES[face].0
}

/// A face's unit step.
pub fn step(face: usize) -> [i32; 3] {
    STEPS[face]
}

/// The cells a mob's collider ray reads: an unreadable cell is air, and the
/// shapes that depend on the colliding entity or a block entity read as
/// vanilla gives a mob beside them.
pub struct Collider<'a, 'b>(pub &'a Level<'b>);

impl BlockSource for Collider<'_, '_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        let state = self.0.block([x, y, z]).unwrap_or(AIR);
        Some(if empty_for_mobs(self.0.physics, state) {
            AIR
        } else {
            state
        })
    }
}

fn empty_for_mobs(physics: &Facts, state: u16) -> bool {
    let table = &physics.shapes;
    matches!(
        table
            .states
            .get(state as usize)
            .and_then(|&e| table.entries.get(e as usize)),
        Some(Entry::Scaffolding | Entry::PowderSnow | Entry::MovingPiston)
    )
}

/// The collider boxes of `state` at `cell` in world space.
pub fn state_boxes(physics: &Facts, state: u16, cell: [i32; 3]) -> Vec<Aabb> {
    if empty_for_mobs(physics, state) {
        return Vec::new();
    }
    let picked = physics.shapes.shape(state, cell, &Context::default());
    let o = picked.offset;
    picked
        .shape
        .cells()
        .into_iter()
        .map(|b| Aabb {
            min: std::array::from_fn(|a| b.min[a] + cell[a] as f64 + o[a]),
            max: std::array::from_fn(|a| b.max[a] + cell[a] as f64 + o[a]),
        })
        .collect()
}

/// `Shapes.boxes/2`: the collider boxes of the block at `cell`, None where
/// it cannot be read.
pub fn boxes(level: &Level, cell: [i32; 3]) -> Option<Vec<Aabb>> {
    level
        .block(cell)
        .map(|state| state_boxes(level.physics, state, cell))
}

fn intersects(a: &Aabb, b: &Aabb) -> bool {
    crate::mobs::sensing::intersects(a, b)
}

/// `Shapes.free?/2`: no block's collider meets `b`, it stays inside the
/// border, and no cell it touches is unreadable.
pub fn free(level: &Level, b: &Aabb) -> bool {
    if let Some([min_x, min_z, max_x, max_z]) = level.border {
        if !(b.min[0] >= min_x && b.min[2] >= min_z && b.max[0] <= max_x && b.max[2] <= max_z) {
            return false;
        }
    }
    let lo = |v: f64| (v - 1.0e-7).floor() as i32;
    let hi = |v: f64| (v + 1.0e-7).floor() as i32;
    for x in lo(b.min[0])..=hi(b.max[0]) {
        for y in lo(b.min[1])..=hi(b.max[1]) {
            for z in lo(b.min[2])..=hi(b.max[2]) {
                match boxes(level, [x, y, z]) {
                    None => return false,
                    Some(list) => {
                        if list.iter().any(|c| intersects(c, b)) {
                            return false;
                        }
                    }
                }
            }
        }
    }
    b.max[0] > b.min[0] && b.max[1] > b.min[1] && b.max[2] > b.min[2]
}

/// `Shapes.face_full?/3`: the collider shape at `cell` covers its face
/// `face` (the slice 1e-7 inside it). False where unreadable.
pub fn face_full(level: &Level, cell: [i32; 3], face: usize) -> bool {
    let Some(list) = boxes(level, cell) else {
        return false;
    };
    let (axis, sign) = FACES[face];
    let origin = cell.map(|v| v as f64);
    let plane = if sign > 0 { 1.0 - 1.0e-7 } else { 1.0e-7 };
    let [u, v] = match axis {
        0 => [1, 2],
        1 => [0, 2],
        _ => [0, 1],
    };
    let rects: Vec<[f64; 4]> = list
        .iter()
        .filter(|b| {
            let (low, high) = (b.min[axis] - origin[axis], b.max[axis] - origin[axis]);
            low <= plane && plane <= high
        })
        .map(|b| {
            [
                b.min[u] - origin[u],
                b.min[v] - origin[v],
                b.max[u] - origin[u],
                b.max[v] - origin[v],
            ]
        })
        .collect();
    covered(&rects)
}

fn grid(points: impl Iterator<Item = f64>) -> Vec<f64> {
    let mut g = vec![0.0, 1.0];
    for p in points {
        if p > 0.0 && p < 1.0 && !g.contains(&p) {
            g.push(p);
        }
    }
    g.sort_by(|a, b| a.total_cmp(b));
    g
}

// Whether rectangles `[u0, v0, u1, v1]` cover the unit square.
fn covered(rects: &[[f64; 4]]) -> bool {
    if rects.is_empty() {
        return false;
    }
    let us = grid(rects.iter().flat_map(|r| [r[0], r[2]]));
    let vs = grid(rects.iter().flat_map(|r| [r[1], r[3]]));
    for ua in us.windows(2) {
        for va in vs.windows(2) {
            let (u, v) = ((ua[0] + ua[1]) / 2.0, (va[0] + va[1]) / 2.0);
            if !rects
                .iter()
                .any(|r| r[0] <= u && u <= r[2] && r[1] <= v && v <= r[3])
            {
                return false;
            }
        }
    }
    true
}

const EPSILON: f64 = 1.0e-7;

/// `FreePosition.closest/3`: the point of `space` nearest `point` outside
/// every obstacle, None when they cover it.
pub fn closest(space: Aabb, point: [f64; 3], obstacles: &[Aabb]) -> Option<[f64; 3]> {
    let mut boxes = vec![space];
    for o in obstacles {
        boxes = boxes.into_iter().flat_map(|b| subtract(b, o)).collect();
    }
    boxes.sort_by(|a, b| {
        a.min
            .iter()
            .chain(&a.max)
            .zip(b.min.iter().chain(&b.max))
            .map(|(x, y)| x.total_cmp(y))
            .find(|o| o.is_ne())
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut best: Option<(f64, [f64; 3])> = None;
    for b in boxes {
        let candidate: [f64; 3] = std::array::from_fn(|a| emin(emax(point[a], b.min[a]), b.max[a]));
        let distance = crate::mobs::ai::fmath::distance_sq(point, candidate);
        match best {
            Some((previous, _)) if previous <= distance => {}
            _ => best = Some((distance, candidate)),
        }
    }
    best.map(|(_, p)| p)
}

fn subtract(b: Aabb, o: &Aabb) -> Vec<Aabb> {
    let c0: [f64; 3] = std::array::from_fn(|a| emax(b.min[a], o.min[a]));
    let c1: [f64; 3] = std::array::from_fn(|a| emin(b.max[a], o.max[a]));
    if (0..3).any(|a| c1[a] - c0[a] <= EPSILON) {
        return vec![b];
    }
    let pieces = [
        ([b.min[0], b.min[1], b.min[2]], [c0[0], b.max[1], b.max[2]]),
        ([c1[0], b.min[1], b.min[2]], [b.max[0], b.max[1], b.max[2]]),
        ([c0[0], b.min[1], b.min[2]], [c1[0], c0[1], b.max[2]]),
        ([c0[0], c1[1], b.min[2]], [c1[0], b.max[1], b.max[2]]),
        ([c0[0], c0[1], b.min[2]], [c1[0], c1[1], c0[2]]),
        ([c0[0], c0[1], c1[2]], [c1[0], c1[1], b.max[2]]),
    ];
    pieces
        .into_iter()
        .filter(|(lo, hi)| (0..3).all(|a| hi[a] - lo[a] > EPSILON))
        .map(|(min, max)| Aabb { min, max })
        .collect()
}

/// `Shapes.free_position/5`: `findFreePosition` over a mob's small resize
/// volume: the obstacles (collider boxes, a context-dependent shape's for
/// `context`) within the search box and the border, inflated by half the
/// size; None where a cell is unreadable or nothing is free.
pub fn free_position(
    level: &Level,
    space: Aabb,
    point: [f64; 3],
    size: [f64; 3],
    context: &Context,
) -> Option<[f64; 3]> {
    let search = Aabb {
        min: std::array::from_fn(|a| space.min[a] - size[a]),
        max: std::array::from_fn(|a| space.max[a] + size[a]),
    };
    let mut obstacles = Vec::new();
    for x in search.min[0].floor() as i32 - 1..=search.max[0].floor() as i32 + 1 {
        for y in search.min[1].floor() as i32 - 1..=search.max[1].floor() as i32 + 1 {
            for z in search.min[2].floor() as i32 - 1..=search.max[2].floor() as i32 + 1 {
                let cell = [x, y, z];
                let state = level.block(cell)?;
                let table = &level.physics.shapes;
                let contextual = matches!(
                    table
                        .states
                        .get(state as usize)
                        .and_then(|&e| table.entries.get(e as usize)),
                    Some(
                        Entry::Scaffolding
                            | Entry::PowderSnow
                            | Entry::ShulkerBox
                            | Entry::MovingPiston
                    )
                );
                let found = if contextual {
                    let picked = table.shape(state, cell, context);
                    picked
                        .shape
                        .cells()
                        .into_iter()
                        .map(|b| Aabb {
                            min: std::array::from_fn(|a| {
                                b.min[a] + cell[a] as f64 + picked.offset[a]
                            }),
                            max: std::array::from_fn(|a| {
                                b.max[a] + cell[a] as f64 + picked.offset[a]
                            }),
                        })
                        .collect()
                } else {
                    state_boxes(level.physics, state, cell)
                };
                // The Elixir prepends each cell's kept boxes.
                let kept: Vec<Aabb> = found
                    .into_iter()
                    .filter(|b| intersects(b, &search) && within_border(level, b))
                    .collect();
                obstacles.splice(0..0, kept);
            }
        }
    }
    let inflated: Vec<Aabb> = obstacles
        .iter()
        .map(|o| Aabb {
            min: std::array::from_fn(|a| o.min[a] - size[a] / 2.0),
            max: std::array::from_fn(|a| o.max[a] + size[a] / 2.0),
        })
        .collect();
    closest(space, point, &inflated)
}

fn within_border(level: &Level, b: &Aabb) -> bool {
    match level.border {
        None => true,
        Some([min_x, min_z, max_x, max_z]) => {
            b.max[0] > min_x && b.min[0] < max_x && b.max[2] > min_z && b.min[2] < max_z
        }
    }
}

/// Fluids a collider ray stops at (`Clip.clip/5`'s fluid mode).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fluids {
    None,
    Any,
}

/// Whether a collider ray from `from` to `to` misses every block (and,
/// with `Fluids::Any`, every fluid at its own height).
pub fn ray_misses(level: &Level, from: [f64; 3], to: [f64; 3], fluids: Fluids) -> bool {
    let blocks = match ray::clip(
        &Collider(level),
        level.physics,
        from,
        to,
        &Context::default(),
    ) {
        Ok(hit) => hit.miss,
        Err(_) => false,
    };
    if !blocks || fluids == Fluids::None || from == to {
        return blocks;
    }
    !cells(from, to).into_iter().any(|cell| {
        let state = level.block(cell).unwrap_or(AIR);
        let fluid = level.physics.fluid(state);
        fluid.kind != crate::physics::facts::EMPTY && {
            let b = Aabb {
                min: cell.map(|v| v as f64),
                max: [
                    cell[0] as f64 + 1.0,
                    cell[1] as f64 + fluid.height as f64,
                    cell[2] as f64 + 1.0,
                ],
            };
            ray::clip_box(&b, from, to).is_some()
        }
    })
}

// `Clip.cells/2`: the cells a ray visits, in order.
fn cells(from: [f64; 3], to: [f64; 3]) -> Vec<[i32; 3]> {
    let lerp = |d: f64, a: f64, b: f64| a + d * (b - a);
    let end: [f64; 3] = std::array::from_fn(|a| lerp(-1.0e-7, to[a], from[a]));
    let start: [f64; 3] = std::array::from_fn(|a| lerp(-1.0e-7, from[a], to[a]));
    let mut cell = start.map(|v| v.floor() as i32);
    let mut out = vec![cell];
    let d: [f64; 3] = std::array::from_fn(|a| end[a] - start[a]);
    let s: [i32; 3] = d.map(|v| {
        if v > 0.0 {
            1
        } else if v < 0.0 {
            -1
        } else {
            0
        }
    });
    let delta: [f64; 3] = std::array::from_fn(|a| {
        if s[a] == 0 {
            f64::MAX
        } else {
            s[a] as f64 / d[a]
        }
    });
    let frac = |v: f64| v - v.floor();
    let mut t: [f64; 3] = std::array::from_fn(|a| {
        delta[a]
            * if s[a] > 0 {
                1.0 - frac(start[a])
            } else {
                frac(start[a])
            }
    });
    while t[0] <= 1.0 || t[1] <= 1.0 || t[2] <= 1.0 {
        let axis = if t[0] < t[1] {
            if t[0] < t[2] {
                0
            } else {
                2
            }
        } else if t[1] < t[2] {
            1
        } else {
            2
        };
        cell[axis] += s[axis];
        t[axis] += delta[axis];
        out.push(cell);
    }
    out
}
