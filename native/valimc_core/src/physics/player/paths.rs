//! The player's movement history (vanilla `Entity.movementThisTick`): the
//! paths moves took since the last tick, at most 100, and the ordered block
//! visits of a body along them (`checkInsideBlocks`).

use super::pose::{self, Dimensions};
use super::Fault;
use crate::physics::aabb::Aabb;
use crate::physics::sweep;

/// One recorded movement: from, to, and the pre-collision displacement whose
/// larger horizontal component orders the axes (none for a gap).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Path {
    pub from: [f64; 3],
    pub to: [f64; 3],
    pub axis: Option<[f64; 3]>,
}

pub type Paths = Vec<Path>;

const GAP_SQUARED: f64 = 9.999999439624929e-11;
const MAX_PATHS: usize = 100;

fn squared(v: [f64; 3]) -> f64 {
    v[0] * v[0] + v[1] * v[1] + v[2] * v[2]
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

/// Native move admission: a substantially blocked tiny displacement does not
/// change the position.
pub fn records(actual: [f64; 3], requested: [f64; 3]) -> bool {
    let a = squared(actual);
    a > 1.0e-7 || squared(requested) - a < 1.0e-7
}

/// Record a move after collision; the 101st merges the oldest two.
pub fn record(paths: &mut Paths, from: [f64; 3], actual: [f64; 3], requested: [f64; 3]) {
    if !records(actual, requested) {
        return;
    }
    let path = Path {
        from,
        to: add(from, actual),
        axis: Some(requested),
    };
    if paths.len() >= MAX_PATHS {
        let merged = Path {
            from: paths[0].from,
            to: paths[1].to,
            axis: None,
        };
        paths.drain(0..2);
        paths.insert(0, merged);
    }
    paths.push(path);
}

/// The paths a tick visits: the recorded ones and the gap to the current
/// position, or the travel from `old` when none was recorded.
pub fn collect(paths: &[Path], old: [f64; 3], current: [f64; 3]) -> Paths {
    match paths.last() {
        None => vec![Path {
            from: old,
            to: current,
            axis: None,
        }],
        Some(last) => {
            let mut out = paths.to_vec();
            if squared(sub(current, last.to)) > GAP_SQUARED {
                out.push(Path {
                    from: last.to,
                    to: current,
                    axis: None,
                });
            }
            out
        }
    }
}

fn union(a: Aabb, b: Aabb) -> Aabb {
    Aabb::new(
        std::array::from_fn(|i| a.min[i].min(b.min[i])),
        std::array::from_fn(|i| a.max[i].max(b.max[i])),
    )
}

/// `body` grown to enclose every retained path's standing bodies and the
/// cell above their heads (inside-fluid contact reads it).
pub fn enclose(catalog: &[Dimensions], paths: &[Path], body: Aabb) -> Result<Aabb, Fault> {
    let mut out = body;
    for p in paths {
        for point in [p.from, p.to] {
            let g = pose::geometry(catalog, pose::STANDING, point)?;
            out = union(out, g.body.expand_towards([0.0, 1.0, 0.0]));
        }
    }
    Ok(out)
}

const EPSILON: f64 = 9.999999747378752e-6;

fn point_ok(p: [f64; 3]) -> bool {
    p.iter().all(|c| c.abs() <= 60_000_000.0)
}

fn vector_ok(v: [f64; 3]) -> bool {
    v.iter().all(|c| c.abs() <= 64.0)
}

/// The segments of a path: one line, or one per axis (Y, then the horizontal
/// axes with the larger displacement last) for a recorded move.
/// A straight part of a path: from, to.
type Segment = ([f64; 3], [f64; 3]);

fn segments(p: &Path) -> Result<Vec<Segment>, Fault> {
    let delta = sub(p.to, p.from);
    if !point_ok(p.from) || !point_ok(p.to) || !p.axis.is_none_or(vector_ok) || !vector_ok(delta) {
        return Err(Fault::Limit("body_contact_limit"));
    }
    match p.axis {
        Some(axis) if squared(delta) > 0.0 => {
            let order = if axis[0].abs() < axis[2].abs() {
                [1, 2, 0]
            } else {
                [1, 0, 2]
            };
            let mut current = p.from;
            let mut out = Vec::with_capacity(3);
            for i in order {
                if delta[i] != 0.0 {
                    let mut next = current;
                    next[i] += delta[i];
                    out.push((current, next));
                    current = next;
                }
            }
            Ok(out)
        }
        _ => Ok(vec![(p.from, p.to)]),
    }
}

/// A block visit: the cell, the crossing step it was found at, the body at
/// the segment's start and the segment's displacement.
pub struct Visit {
    pub position: [i32; 3],
    pub step: u32,
    pub body: Aabb,
    pub delta: [f64; 3],
}

/// Visit the blocks `pose`'s body passes along `paths` in vanilla's order,
/// each segment within a budget of 16 crossings per path (a path that runs
/// out ends with one visit of its end).
pub fn visit(
    catalog: &[Dimensions],
    paths: &[Path],
    pose: u8,
    visitor: &mut dyn FnMut(&Visit) -> Result<(), Fault>,
) -> Result<(), Fault> {
    if paths.len() > 101 {
        return Err(Fault::Limit("invalid_contact_paths"));
    }
    let mut attempts = 0usize;
    let mut line =
        |from: [f64; 3], to: [f64; 3], budget: i64, attempts: &mut usize| -> Result<i64, Fault> {
            let before = pose::geometry(catalog, pose, from)?;
            let after = pose::geometry(catalog, pose, to)?;
            let s = sweep::sweep(from, to, &after.body.deflate(EPSILON), 512)
                .ok_or(Fault::Limit("body_sweep_limit"))?;
            let delta = sub(to, from);
            let mut last = 0u32;
            for &(position, step) in &s.visits {
                if step as i64 >= budget {
                    return Ok(last as i64 + 1);
                }
                if *attempts >= 4096 {
                    return Err(Fault::Limit("body_contact_limit"));
                }
                *attempts += 1;
                visitor(&Visit {
                    position,
                    step,
                    body: before.body,
                    delta,
                })?;
                last = step;
            }
            if s.complete {
                Ok(last as i64 + 1)
            } else {
                Err(Fault::Limit("body_contact_limit"))
            }
        };
    for p in paths {
        let parts = segments(p)?;
        let mut budget = 16i64;
        for (from, to) in parts {
            budget -= line(from, to, budget, &mut attempts)?;
        }
        if budget <= 0 {
            line(p.to, p.to, 1, &mut attempts)?;
        }
    }
    Ok(())
}
