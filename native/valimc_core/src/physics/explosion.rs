//! An explosion's reach (VMC-050a), as vanilla's `ServerExplosion` measures
//! it: the cells its rays break (`calculateExplodedPositions`) and how much of
//! an entity's box sees the centre (`getSeenPercent`, a collider ray per
//! sample point).
//!
//! Rays read the explosion resistance column of the block fact table. A ray
//! stops where it leaves the world (vanilla's `isInWorldBounds`) or meets a
//! cell the source cannot read (a chunk that is not loaded: vanilla would load
//! it, ValiMC leaves it standing); the cells it already passed still count.

use super::aabb::Aabb;
use super::facts::Facts;
use super::shape::Place;
use super::source::BlockSource;
use super::table::Context;
use crate::worldgen::random::Random;
use std::collections::HashMap;

/// What `exploded` found: the cells its rays reached with their states
/// (air included, as vanilla's set holds them), sorted, and whether a ray
/// stopped at an unreadable cell.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Reach {
    pub cells: Vec<([i32; 3], u16)>,
    pub unreadable: bool,
}

/// The world's height as the rays see it: cells below `min_y` or at or above
/// `min_y + height` are outside.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Height {
    pub min_y: i32,
    pub height: i32,
}

const HORIZONTAL: i32 = 30_000_000;

fn in_world(p: [i32; 3], h: Height) -> bool {
    p[1] >= h.min_y
        && p[1] < h.min_y + h.height
        && p[0] >= -HORIZONTAL
        && p[0] < HORIZONTAL
        && p[2] >= -HORIZONTAL
        && p[2] < HORIZONTAL
}

/// `calculateExplodedPositions` of an explosion of `radius` at `center`,
/// drawing one float per ray from `random` in vanilla's ray order (the 1352
/// cells on the faces of a 16 × 16 × 16 cube).
pub fn exploded(
    source: &dyn BlockSource,
    facts: &Facts,
    center: [f64; 3],
    radius: f32,
    random: &mut Random,
    height: Height,
) -> Reach {
    let mut cells = HashMap::new();
    let mut unreadable = false;
    for xx in 0..16 {
        for yy in 0..16 {
            for zz in 0..16 {
                if !(xx == 0 || xx == 15 || yy == 0 || yy == 15 || zz == 0 || zz == 15) {
                    continue;
                }
                // Float arithmetic widened to double, as the Java expression does.
                let mut xd = ((xx as f32) / 15.0 * 2.0 - 1.0) as f64;
                let mut yd = ((yy as f32) / 15.0 * 2.0 - 1.0) as f64;
                let mut zd = ((zz as f32) / 15.0 * 2.0 - 1.0) as f64;
                let d = (xd * xd + yd * yd + zd * zd).sqrt();
                xd /= d;
                yd /= d;
                zd /= d;
                let mut power = radius * (0.7 + random.next_float() * 0.6);
                let [mut xp, mut yp, mut zp] = center;
                let step = 0.3f32 as f64;
                while power > 0.0 {
                    let pos = [xp.floor() as i32, yp.floor() as i32, zp.floor() as i32];
                    if !in_world(pos, height) {
                        break;
                    }
                    let Some(state) = source.state(pos[0], pos[1], pos[2]) else {
                        unreadable = true;
                        break;
                    };
                    if let Some(resistance) = facts.explosion_resistance(state) {
                        power -= (resistance + 0.3) * 0.3;
                    }
                    if power > 0.0 {
                        cells.insert(pos, state);
                    }
                    xp += xd * step;
                    yp += yd * step;
                    zp += zd * step;
                    power -= 0.225_000_01;
                }
            }
        }
    }
    let mut cells: Vec<([i32; 3], u16)> = cells.into_iter().collect();
    cells.sort_unstable();
    Reach { cells, unreadable }
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

/// Whether the collider ray `from -> to` (vanilla's `Level.clip` with
/// `Block.COLLIDER` and no fluid) hits a block, visiting cells as
/// `BlockGetter.traverseBlocks` does. A cell the source cannot read is open.
pub fn blocked(
    source: &dyn BlockSource,
    facts: &Facts,
    from: [f64; 3],
    to: [f64; 3],
    ctx: &Context,
) -> bool {
    if from == to {
        return false;
    }
    let end = [
        lerp(-1.0e-7, to[0], from[0]),
        lerp(-1.0e-7, to[1], from[1]),
        lerp(-1.0e-7, to[2], from[2]),
    ];
    let start = [
        lerp(-1.0e-7, from[0], to[0]),
        lerp(-1.0e-7, from[1], to[1]),
        lerp(-1.0e-7, from[2], to[2]),
    ];
    let mut cell = [
        start[0].floor() as i32,
        start[1].floor() as i32,
        start[2].floor() as i32,
    ];
    if hits(source, facts, cell, from, to, ctx) {
        return true;
    }
    let d = [end[0] - start[0], end[1] - start[1], end[2] - start[2]];
    let s = [sign(d[0]), sign(d[1]), sign(d[2])];
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
        if hits(source, facts, cell, from, to, ctx) {
            return true;
        }
    }
    false
}

// `VoxelShape.clip` at one cell: a start just inside the shape hits, else the
// segment must enter one of its boxes.
fn hits(
    source: &dyn BlockSource,
    facts: &Facts,
    cell: [i32; 3],
    from: [f64; 3],
    to: [f64; 3],
    ctx: &Context,
) -> bool {
    let Some(state) = source.state(cell[0], cell[1], cell[2]) else {
        return false;
    };
    let picked = facts.shapes.shape(state, cell, ctx);
    if picked.shape.is_empty() {
        return false;
    }
    let delta = [to[0] - from[0], to[1] - from[1], to[2] - from[2]];
    if delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] < 1.0e-7 {
        return false;
    }
    let place = Place {
        offset: Some(picked.offset),
        position: Some([cell[0] as f64, cell[1] as f64, cell[2] as f64]),
    };
    let test = [
        from[0] + delta[0] * 0.001,
        from[1] + delta[1] * 0.001,
        from[2] + delta[2] * 0.001,
    ];
    picked.shape.cells().iter().any(|b| {
        let placed = Aabb {
            min: std::array::from_fn(|a| place.coord(a, b.min[a])),
            max: std::array::from_fn(|a| place.coord(a, b.max[a])),
        };
        let inside = (0..3).all(|a| test[a] >= placed.min[a] && test[a] < placed.max[a]);
        inside || placed.clip(from, to).is_some()
    })
}

/// `getSeenPercent`: the share of sample points over `body` with a clear
/// collider ray to `center`, the samples spaced as vanilla spaces them.
pub fn seen(source: &dyn BlockSource, facts: &Facts, center: [f64; 3], body: &Aabb) -> f32 {
    let xs = 1.0 / ((body.max[0] - body.min[0]) * 2.0 + 1.0);
    let ys = 1.0 / ((body.max[1] - body.min[1]) * 2.0 + 1.0);
    let zs = 1.0 / ((body.max[2] - body.min[2]) * 2.0 + 1.0);
    let x_offset = (1.0 - (1.0 / xs).floor() * xs) / 2.0;
    let z_offset = (1.0 - (1.0 / zs).floor() * zs) / 2.0;
    if xs < 0.0 || ys < 0.0 || zs < 0.0 {
        return 0.0;
    }
    let ctx = Context {
        entity: true,
        bottom: body.min[1],
        entity_present: true,
        ..Context::default()
    };
    let mut hits = 0u32;
    let mut count = 0u32;
    let mut xx = 0.0;
    while xx <= 1.0 {
        let mut yy = 0.0;
        while yy <= 1.0 {
            let mut zz = 0.0;
            while zz <= 1.0 {
                let x = lerp(xx, body.min[0], body.max[0]);
                let y = lerp(yy, body.min[1], body.max[1]);
                let z = lerp(zz, body.min[2], body.max[2]);
                if !blocked(source, facts, [x + x_offset, y, z + z_offset], center, &ctx) {
                    hits += 1;
                }
                count += 1;
                zz += zs;
            }
            yy += ys;
        }
        xx += xs;
    }
    hits as f32 / count as f32
}
