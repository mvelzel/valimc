//! Block outline shapes and the outline ray (`Valimc.Physics.Clip` with
//! `:outline` shapes and no fluid): vanilla's `BlockGetter.clip` through
//! `getShape` outlines, as an enderman's `EndermanTakeBlockGoal` casts it.
//! The shapes are `priv/physics/outlines.json`'s (`FluidOracle outlines`):
//! a palette of voxel shapes with their merged boxes, each state's palette
//! index and the offset kinds of the states that wobble (flowers, grass).
//!
//! Cells are visited as `traverseBlocks` visits them; each cell's outline is
//! clipped as `VoxelShape.clip` clips it (a start just inside a filled voxel
//! hits there, else the boxes' nearest entered face, `AABB.clip`).

use crate::mobs::ai::fmath::{emax, emin, f};
use crate::worldgen::json::Json;
use std::collections::HashMap;

/// One outline shape: its voxel grid (`axes` coordinates, `sizes` cells per
/// axis, the filled bits, x major) and its boxes.
#[derive(Clone, Debug, PartialEq)]
pub struct Outline {
    pub axes: [Vec<f64>; 3],
    pub sizes: [usize; 3],
    pub bits: Vec<u8>,
    pub boxes: Vec<[f64; 6]>,
}

/// Every state's outline.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outlines {
    pub palette: Vec<Outline>,
    /// Per state its palette index.
    pub states: Vec<u16>,
    /// The offset kind (`1` horizontal, `2` with a vertical part), its
    /// horizontal limit and vertical scale of the states that have one.
    pub offsets: HashMap<u16, (i64, f64, f64)>,
}

fn hex(text: &str) -> Result<Vec<u8>, String> {
    if !text.len().is_multiple_of(2) {
        return Err("odd hex".into());
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect()
}

fn floats(json: &Json) -> Result<Vec<f64>, String> {
    json.as_array()?.iter().map(Json::as_f64).collect()
}

impl Outlines {
    /// `priv/physics/outlines.json`'s `palette`, `states` and `offsets`.
    pub fn parse(json: &Json) -> Result<Outlines, String> {
        let mut palette = Vec::new();
        for shape in json.field("palette")?.as_array()? {
            let axes = shape.field("axes")?.as_array()?;
            let [x, y, z] = axes else {
                return Err("an outline needs three axes".into());
            };
            let sizes = shape.field("sizes")?.as_array()?;
            let [sx, sy, sz] = sizes else {
                return Err("an outline needs three sizes".into());
            };
            let size = |j: &Json| j.as_f64().map(|v| v as usize);
            let boxes = shape
                .field("boxes")?
                .as_array()?
                .iter()
                .map(|b| {
                    let b = floats(b)?;
                    b.try_into()
                        .map_err(|_| "a box needs six numbers".to_string())
                })
                .collect::<Result<Vec<[f64; 6]>, String>>()?;
            palette.push(Outline {
                axes: [floats(x)?, floats(y)?, floats(z)?],
                sizes: [size(sx)?, size(sy)?, size(sz)?],
                bits: hex(shape.field("bits")?.as_str()?)?,
                boxes,
            });
        }
        let states = hex(json.field("states")?.as_str()?)?
            .chunks(2)
            .map(|c| u16::from_be_bytes([c[0], c[1]]))
            .collect();
        let mut offsets = HashMap::new();
        for row in json.field("offsets")?.as_array()? {
            let row = floats(row)?;
            let [state, kind, h, v] = row[..] else {
                return Err("an offset needs four numbers".into());
            };
            offsets.insert(state as u16, (kind as i64, h, v));
        }
        Ok(Outlines {
            palette,
            states,
            offsets,
        })
    }

    /// `Clip.outline/2`: a state's outline and its offset at column `x, z`
    /// (an unknown state's is the first, air's).
    pub fn outline(&self, state: u16, x: i32, z: i32) -> Option<(&Outline, [f64; 3])> {
        let index = *self.states.get(state as usize)? as usize;
        let shape = self.palette.get(index)?;
        let offset = match self.offsets.get(&state) {
            Some(&(kind, h, v)) => offset(kind, h, v, x, z),
            None => [0.0; 3],
        };
        Some((shape, offset))
    }
}

/// `BlockBehaviour.Properties.offsetType`'s offsets from `Mth.getSeed(x, 0,
/// z)`.
fn offset(kind: i64, h: f64, v: f64, x: i32, z: i32) -> [f64; 3] {
    let seed = (x.wrapping_mul(3_129_871) as i64) ^ (z as i64).wrapping_mul(116_129_781);
    let seed = seed
        .wrapping_mul(seed)
        .wrapping_mul(42_317_861)
        .wrapping_add(seed.wrapping_mul(11))
        >> 16;
    let part = |n: i64| f((n & 15) as f64 / 15.0);
    let clamp = |value: f64| emin(emax(value, -h), h);
    let dx = clamp((part(seed) - 0.5) * 0.5);
    let dz = clamp((part(seed >> 8) - 0.5) * 0.5);
    let dy = if kind == 2 {
        (part(seed >> 4) - 1.0) * v
    } else {
        0.0
    };
    [dx, dy, dz]
}

/// A ray's hit (`%{miss, position, face, location, inside}`): a miss has
/// the end point, the face toward the start and the cell holding the end.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hit {
    pub miss: bool,
    pub position: [i32; 3],
    pub face: u8,
    pub location: [f64; 3],
    pub inside: bool,
}

/// `Clip.clip(from, to, :none, read, :outline)`: the first outline a ray
/// from `from` to `to` meets, reading cells with `read` (None reads as air,
/// state 0).
pub fn clip(
    outlines: &Outlines,
    read: impl Fn([i32; 3]) -> Option<u16>,
    from: [f64; 3],
    to: [f64; 3],
) -> Hit {
    let visit = |cell: [i32; 3]| {
        let state = read(cell).unwrap_or(0);
        let (shape, offset) = outlines.outline(state, cell[0], cell[2])?;
        shape_clip(shape, offset, from, to, cell)
    };
    traverse(from, to, visit).unwrap_or_else(|| miss(from, to))
}

// `BlockGetter.traverseBlocks`; None stands for `Double.MAX_VALUE` (an axis
// the ray does not move along).
fn traverse(from: [f64; 3], to: [f64; 3], visit: impl Fn([i32; 3]) -> Option<Hit>) -> Option<Hit> {
    if from == to {
        return None;
    }
    let lerp = |delta: f64, a: f64, b: f64| a + delta * (b - a);
    let end: [f64; 3] = std::array::from_fn(|a| lerp(-1.0e-7, to[a], from[a]));
    let start: [f64; 3] = std::array::from_fn(|a| lerp(-1.0e-7, from[a], to[a]));
    let mut cell = start.map(|v| v.floor() as i32);
    if let Some(hit) = visit(cell) {
        return Some(hit);
    }
    let d: [f64; 3] = std::array::from_fn(|a| end[a] - start[a]);
    let s = d.map(|v| {
        if v > 0.0 {
            1
        } else if v < 0.0 {
            -1
        } else {
            0
        }
    });
    let delta: [Option<f64>; 3] = std::array::from_fn(|a| (s[a] != 0).then(|| s[a] as f64 / d[a]));
    let frac = |v: f64| v - v.floor();
    let mut t: [Option<f64>; 3] = std::array::from_fn(|a| {
        delta[a].map(|td| {
            td * if s[a] > 0 {
                1.0 - frac(start[a])
            } else {
                frac(start[a])
            }
        })
    });
    let le = |a: Option<f64>, b: f64| a.is_some_and(|a| a <= b);
    let lt = |a: Option<f64>, b: Option<f64>| match (a, b) {
        (None, _) => false,
        (Some(_), None) => true,
        (Some(a), Some(b)) => a < b,
    };
    let add = |a: Option<f64>, b: Option<f64>| match (a, b) {
        (Some(a), Some(b)) => Some(a + b),
        _ => None,
    };
    while le(t[0], 1.0) || le(t[1], 1.0) || le(t[2], 1.0) {
        let axis = if lt(t[0], t[1]) && lt(t[0], t[2]) {
            0
        } else if lt(t[0], t[1]) {
            2
        } else if lt(t[1], t[2]) {
            1
        } else {
            2
        };
        cell[axis] += s[axis];
        t[axis] = add(t[axis], delta[axis]);
        if let Some(hit) = visit(cell) {
            return Some(hit);
        }
    }
    None
}

fn miss(from: [f64; 3], to: [f64; 3]) -> Hit {
    Hit {
        miss: true,
        position: to.map(|v| v.floor() as i32),
        face: nearest(from[0] - to[0], from[1] - to[1], from[2] - to[2]),
        location: to,
        inside: false,
    }
}

/// `Direction.getApproximateNearest`: the face whose normal best matches the
/// vector (as floats), north for none.
pub fn nearest(dx: f64, dy: f64, dz: f64) -> u8 {
    let (dx, dy, dz) = (f(dx), f(dy), f(dz));
    let mut best = 2u8;
    let mut highest = 1.401298464324817e-45;
    for (d, dot) in [-dy, dy, -dz, dz, -dx, dx].into_iter().enumerate() {
        if dot > highest {
            best = d as u8;
            highest = dot;
        }
    }
    best
}

// `VoxelShape.clip`: a start point just inside a filled cell hits at once,
// facing back along the ray; else the boxes' nearest face (`AABB.clip`).
fn shape_clip(
    shape: &Outline,
    offset: [f64; 3],
    from: [f64; 3],
    to: [f64; 3],
    position: [i32; 3],
) -> Option<Hit> {
    let [nx, ny, nz] = shape.sizes;
    if nx * ny * nz == 0 {
        return None;
    }
    let d: [f64; 3] = std::array::from_fn(|a| to[a] - from[a]);
    if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < 1.0e-7 {
        return None;
    }
    let test: [f64; 3] = std::array::from_fn(|a| from[a] + d[a] * 0.001);
    let index = |a: usize| find_index(&shape.axes[a], test[a] - position[a] as f64, offset[a]);
    if full_wide(shape, [index(0), index(1), index(2)]) {
        return Some(Hit {
            miss: false,
            position,
            face: nearest(d[0], d[1], d[2]) ^ 1,
            location: test,
            inside: true,
        });
    }
    let p = position.map(|v| v as f64);
    let boxes = shape.boxes.iter().map(|b| {
        [
            b[0] + offset[0] + p[0],
            b[1] + offset[1] + p[1],
            b[2] + offset[2] + p[2],
            b[3] + offset[0] + p[0],
            b[4] + offset[1] + p[1],
            b[5] + offset[2] + p[2],
        ]
    });
    aabb_clip(boxes, from, d, position)
}

// `VoxelShape.findIndex`: coordinates up to `value`, less one.
fn find_index(coords: &[f64], value: f64, offset: f64) -> i64 {
    let (mut low, mut high) = (0usize, coords.len());
    while low < high {
        let mid = (low + high) / 2;
        if value < coords[mid] + offset {
            high = mid;
        } else {
            low = mid + 1;
        }
    }
    low as i64 - 1
}

fn full_wide(shape: &Outline, [x, y, z]: [i64; 3]) -> bool {
    let [nx, ny, nz] = shape.sizes.map(|n| n as i64);
    if x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz {
        return false;
    }
    let i = ((x * ny + y) * nz + z) as usize;
    shape
        .bits
        .get(i / 8)
        .is_some_and(|byte| (byte >> (i % 8)) & 1 == 1)
}

// `AABB.clip`: the smallest positive scale at which the ray enters a face.
fn aabb_clip(
    boxes: impl Iterator<Item = [f64; 6]>,
    from: [f64; 3],
    d: [f64; 3],
    position: [i32; 3],
) -> Option<Hit> {
    let mut scale = 1.0;
    let mut face = None;
    // Per axis: the axis, the two others, the face entered moving up and down.
    const AXES: [(usize, usize, usize, u8, u8); 3] =
        [(0, 1, 2, 4, 5), (1, 2, 0, 0, 1), (2, 0, 1, 2, 3)];
    for b in boxes {
        let (min, max) = ([b[0], b[1], b[2]], [b[3], b[4], b[5]]);
        for &(a, p, q, low, high) in &AXES {
            let (point, new_face) = if d[a] > 1.0e-7 {
                (min[a], low)
            } else if d[a] < -1.0e-7 {
                (max[a], high)
            } else {
                continue;
            };
            let s = (point - from[a]) / d[a];
            let pb = from[p] + s * d[p];
            let pc = from[q] + s * d[q];
            if 0.0 < s
                && s < scale
                && min[p] - 1.0e-7 < pb
                && pb < max[p] + 1.0e-7
                && min[q] - 1.0e-7 < pc
                && pc < max[q] + 1.0e-7
            {
                scale = s;
                face = Some(new_face);
            }
        }
    }
    face.map(|face| Hit {
        miss: false,
        position,
        face,
        location: std::array::from_fn(|a| from[a] + scale * d[a]),
        inside: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full() -> Outlines {
        Outlines {
            palette: vec![
                Outline {
                    axes: [vec![0.0], vec![0.0], vec![0.0]],
                    sizes: [0, 0, 0],
                    bits: vec![],
                    boxes: vec![],
                },
                Outline {
                    axes: [vec![0.0, 1.0], vec![0.0, 1.0], vec![0.0, 1.0]],
                    sizes: [1, 1, 1],
                    bits: vec![1],
                    boxes: vec![[0.0, 0.0, 0.0, 1.0, 1.0, 1.0]],
                },
            ],
            states: vec![0, 1],
            offsets: HashMap::new(),
        }
    }

    #[test]
    fn a_ray_stops_at_the_first_outline_or_misses() {
        let o = full();
        let stone = |c: [i32; 3]| Some(if c == [3, 0, 0] { 1 } else { 0 });
        let hit = clip(&o, stone, [0.5, 0.5, 0.5], [5.5, 0.5, 0.5]);
        assert!(!hit.miss);
        assert_eq!(hit.position, [3, 0, 0]);
        assert_eq!(hit.face, 4);
        assert_eq!(hit.location[0], 3.0);
        let air = |_: [i32; 3]| None;
        let miss = clip(&o, air, [0.5, 0.5, 0.5], [5.5, 0.5, 0.5]);
        assert!(miss.miss);
        assert_eq!(miss.position, [5, 0, 0]);
    }

    #[test]
    fn a_start_inside_a_block_hits_there() {
        let o = full();
        let hit = clip(&o, |_| Some(1), [0.5, 0.5, 0.5], [5.5, 0.5, 0.5]);
        assert!(hit.inside);
        assert_eq!(hit.position, [0, 0, 0]);
    }
}
