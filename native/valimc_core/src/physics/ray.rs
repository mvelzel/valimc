//! The collider ray a projectile casts (VMC-037o): vanilla's
//! `CollisionGetter.clipIncludingBorder` with `ClipContext.Block.COLLIDER`
//! and no fluid. Cells are visited as `BlockGetter.traverseBlocks` visits
//! them; each cell's collision shape is clipped as `VoxelShape.clip` clips it
//! (a start just inside a filled voxel hits there, else the boxes' nearest
//! entered face), and a ray that leaves the world border stops on it. Also
//! `AABB.clip` with the face it enters, for entity boxes.
//!
//! Not applied: `clipWithInteractionOverride` (an interaction shape's face
//! for cauldrons, composters and hoppers; the hit point is the same).

use super::aabb::Aabb;
use super::border::Border;
use super::facts::Facts;
use super::shape::Place;
use super::source::{BlockSource, Unreadable};
use super::table::Context;

/// `Direction` indices.
pub const DOWN: u8 = 0;
pub const UP: u8 = 1;
pub const NORTH: u8 = 2;
pub const SOUTH: u8 = 3;
pub const WEST: u8 = 4;
pub const EAST: u8 = 5;

/// A `BlockHitResult`: where the ray stopped, the face it entered, the cell,
/// whether it started inside the shape, whether it missed (the end point) and
/// whether the world border stopped it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BlockHit {
    pub location: [f64; 3],
    pub face: u8,
    pub cell: [i32; 3],
    pub inside: bool,
    pub miss: bool,
    pub border: bool,
}

const NORMALS: [[f32; 3]; 6] = [
    [0.0, -1.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, -1.0],
    [0.0, 0.0, 1.0],
    [-1.0, 0.0, 0.0],
    [1.0, 0.0, 0.0],
];

/// `Direction.getApproximateNearest` (of the float components).
pub fn nearest(d: [f64; 3]) -> u8 {
    let (x, y, z) = (d[0] as f32, d[1] as f32, d[2] as f32);
    let mut result = NORTH;
    let mut highest = f32::from_bits(1);
    for (i, n) in NORMALS.iter().enumerate() {
        let dot = x * n[0] + y * n[1] + z * n[2];
        if dot > highest {
            highest = dot;
            result = i as u8;
        }
    }
    result
}

pub fn opposite(face: u8) -> u8 {
    face ^ 1
}

fn lerp(t: f64, a: f64, b: f64) -> f64 {
    a + t * (b - a)
}

fn frac(v: f64) -> f64 {
    v - v.floor()
}

fn sign(v: f64) -> i32 {
    if v == 0.0 {
        0
    } else if v > 0.0 {
        1
    } else {
        -1
    }
}

fn containing(p: [f64; 3]) -> [i32; 3] {
    p.map(|v| v.floor() as i32)
}

fn miss(from: [f64; 3], to: [f64; 3]) -> BlockHit {
    BlockHit {
        location: to,
        face: nearest([from[0] - to[0], from[1] - to[1], from[2] - to[2]]),
        cell: containing(to),
        inside: false,
        miss: true,
        border: false,
    }
}

/// `AABB.getDirection` over `boxes` (each moved by `place`): the smallest
/// entry scale below `scale` and its face, the first box and face winning a
/// tie, as vanilla accumulates them.
fn enter(
    boxes: impl Iterator<Item = Aabb>,
    from: [f64; 3],
    d: [f64; 3],
    mut scale: f64,
) -> Option<(f64, u8)> {
    let mut face = None;
    // Per axis: the axis, the two others, the face entered moving up and down.
    const AXES: [(usize, usize, usize, u8, u8); 3] = [
        (0, 1, 2, WEST, EAST),
        (1, 2, 0, DOWN, UP),
        (2, 0, 1, NORTH, SOUTH),
    ];
    for b in boxes {
        for &(a, p, q, up_face, down_face) in &AXES {
            let (plane, entered) = if d[a] > 1.0e-7 {
                (b.min[a], up_face)
            } else if d[a] < -1.0e-7 {
                (b.max[a], down_face)
            } else {
                continue;
            };
            let s = (plane - from[a]) / d[a];
            let pb = from[p] + s * d[p];
            let pc = from[q] + s * d[q];
            if 0.0 < s
                && s < scale
                && b.min[p] - 1.0e-7 < pb
                && pb < b.max[p] + 1.0e-7
                && b.min[q] - 1.0e-7 < pc
                && pc < b.max[q] + 1.0e-7
            {
                scale = s;
                face = Some(entered);
            }
        }
    }
    face.map(|f| (scale, f))
}

/// `AABB.clip` of one box: where `from -> to` enters it and the face.
pub fn clip_box(b: &Aabb, from: [f64; 3], to: [f64; 3]) -> Option<([f64; 3], u8)> {
    let d = [to[0] - from[0], to[1] - from[1], to[2] - from[2]];
    enter(std::iter::once(*b), from, d, 1.0).map(|(s, f)| {
        (
            [from[0] + s * d[0], from[1] + s * d[1], from[2] + s * d[2]],
            f,
        )
    })
}

// `VoxelShape.clip` of the collision shape at `cell`.
fn clip_cell(
    source: &dyn BlockSource,
    facts: &Facts,
    cell: [i32; 3],
    from: [f64; 3],
    to: [f64; 3],
    ctx: &Context,
) -> Result<Option<BlockHit>, Unreadable> {
    let state = source
        .state(cell[0], cell[1], cell[2])
        .ok_or(Unreadable(cell))?;
    let picked = facts.shapes.shape(state, cell, ctx);
    if picked.shape.is_empty() {
        return Ok(None);
    }
    let d = [to[0] - from[0], to[1] - from[1], to[2] - from[2]];
    if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < 1.0e-7 {
        return Ok(None);
    }
    let place = Place {
        offset: Some(picked.offset),
        position: Some([cell[0] as f64, cell[1] as f64, cell[2] as f64]),
    };
    let placed = |b: Aabb| Aabb {
        min: std::array::from_fn(|a| place.coord(a, b.min[a])),
        max: std::array::from_fn(|a| place.coord(a, b.max[a])),
    };
    let cells = picked.shape.cells();
    let test = [
        from[0] + d[0] * 0.001,
        from[1] + d[1] * 0.001,
        from[2] + d[2] * 0.001,
    ];
    if cells.iter().any(|b| {
        let b = placed(*b);
        (0..3).all(|a| test[a] >= b.min[a] && test[a] < b.max[a])
    }) {
        return Ok(Some(BlockHit {
            location: test,
            face: opposite(nearest(d)),
            cell,
            inside: true,
            miss: false,
            border: false,
        }));
    }
    Ok(
        enter(cells.into_iter().map(placed), from, d, 1.0).map(|(s, face)| BlockHit {
            location: [from[0] + s * d[0], from[1] + s * d[1], from[2] + s * d[2]],
            face,
            cell,
            inside: false,
            miss: false,
            border: false,
        }),
    )
}

/// `BlockGetter.clip` with the collider shapes and no fluid. A cell the
/// source cannot read fails the ray.
pub fn clip(
    source: &dyn BlockSource,
    facts: &Facts,
    from: [f64; 3],
    to: [f64; 3],
    ctx: &Context,
) -> Result<BlockHit, Unreadable> {
    if from == to {
        return Ok(miss(from, to));
    }
    let end = std::array::from_fn::<f64, 3, _>(|a| lerp(-1.0e-7, to[a], from[a]));
    let start = std::array::from_fn::<f64, 3, _>(|a| lerp(-1.0e-7, from[a], to[a]));
    let mut cell = containing(start);
    if let Some(hit) = clip_cell(source, facts, cell, from, to, ctx)? {
        return Ok(hit);
    }
    let d = [end[0] - start[0], end[1] - start[1], end[2] - start[2]];
    let s = d.map(sign);
    let delta: [f64; 3] = std::array::from_fn(|a| {
        if s[a] == 0 {
            f64::MAX
        } else {
            s[a] as f64 / d[a]
        }
    });
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
        if let Some(hit) = clip_cell(source, facts, cell, from, to, ctx)? {
            return Ok(hit);
        }
    }
    Ok(miss(from, to))
}

/// `clipIncludingBorder`: a ray from inside the border whose hit lies
/// outside it stops on the border.
pub fn clip_including_border(
    source: &dyn BlockSource,
    facts: &Facts,
    from: [f64; 3],
    to: [f64; 3],
    ctx: &Context,
    border: Option<&Border>,
) -> Result<BlockHit, Unreadable> {
    let hit = clip(source, facts, from, to, ctx)?;
    let Some(b) = border else {
        return Ok(hit);
    };
    let within =
        |p: [f64; 3]| p[0] >= b.min_x && p[0] < b.max_x && p[2] >= b.min_z && p[2] < b.max_z;
    if within(from) && !within(hit.location) {
        let l = hit.location;
        let face = nearest([l[0] - from[0], l[1] - from[1], l[2] - from[2]]);
        let edge = 1.0e-5f32 as f64;
        let p = [
            l[0].clamp(b.min_x, b.max_x - edge),
            l[1],
            l[2].clamp(b.min_z, b.max_z - edge),
        ];
        Ok(BlockHit {
            location: p,
            face,
            cell: containing(p),
            inside: false,
            miss: false,
            border: true,
        })
    } else {
        Ok(hit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_follows_direction_order() {
        assert_eq!(nearest([0.0, -1.0, 0.0]), DOWN);
        assert_eq!(nearest([1.0, 0.0, 0.0]), EAST);
        assert_eq!(nearest([0.0, 0.0, 0.0]), NORTH);
        // A tie keeps the first of the order (up before south).
        assert_eq!(nearest([0.0, 1.0, 1.0]), UP);
    }

    #[test]
    fn a_box_is_entered_through_its_near_face() {
        let b = Aabb::new([0.0, 0.0, 0.0], [1.0, 1.0, 1.0]);
        let (p, face) = clip_box(&b, [-1.0, 0.5, 0.5], [2.0, 0.5, 0.5]).unwrap();
        assert_eq!(p, [0.0, 0.5, 0.5]);
        assert_eq!(face, WEST);
        assert!(clip_box(&b, [0.5, 0.5, 0.5], [2.0, 0.5, 0.5]).is_none());
    }
}
