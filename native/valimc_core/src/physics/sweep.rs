//! The blocks a body passes through while moving, in vanilla's order
//! (`BlockGetter.forEachBlockIntersectedBetween` as `Entity.checkInsideBlocks`
//! walks it): the cells of the start, then the cells each grid crossing of
//! the leading corner adds, then the cells of the end, each visited once,
//! with the crossing step it was found at.

use super::aabb::Aabb;
use super::cells::CellBuild;
use std::collections::HashSet;

const TINY_SQUARE: f64 = 9.999999439624929e-11;
const EPSILON: f64 = 9.999999747378752e-6;
/// Visits and crossings a walk may take before it is cut short (a ghast's
/// 4-block box crossing 60 blocks stays within them, VMC-043d).
const MAX_ATTEMPTS: usize = 32768;
const MAX_CROSSINGS: usize = 256;

/// A visited cell and the crossing step it was found at.
pub type Visit = ([i32; 3], u32);

pub struct Sweep {
    pub visits: Vec<Visit>,
    /// False when `stop_after` visits ended the walk early.
    pub complete: bool,
}

/// Visits a walk finds new cells among by searching them; past this many, by
/// a hash set of them.
const LISTED: usize = 32;

struct Walk {
    /// The visited cells once there are more than `LISTED`.
    seen: Option<HashSet<[i32; 3], CellBuild>>,
    visits: Vec<Visit>,
    attempts: usize,
    stop: usize,
}

enum Flow {
    Go,
    Stop,
}

impl Walk {
    /// Whether `p` is new to the walk.
    #[inline]
    fn new_cell(&mut self, p: [i32; 3]) -> bool {
        if let Some(seen) = &mut self.seen {
            return seen.insert(p);
        }
        if self.visits.iter().any(|v| v.0 == p) {
            return false;
        }
        if self.visits.len() >= LISTED {
            let mut seen = HashSet::with_capacity_and_hasher(4 * LISTED, CellBuild::default());
            seen.extend(self.visits.iter().map(|v| v.0));
            seen.insert(p);
            self.seen = Some(seen);
        }
        true
    }

    /// Visit the cells a box covers, in the order the walk visits them: Y,
    /// then the horizontal axes with the larger movement component last (X,
    /// Y, Z for a stationary body), each against the movement's direction.
    /// `None` when the box covers too many cells or the walk runs out of
    /// attempts.
    fn visit(&mut self, b: &Aabb, delta: [f64; 3], stationary: bool, step: u32) -> Option<Flow> {
        let lo: [i32; 3] = std::array::from_fn(|i| b.min[i].min(b.max[i]).floor() as i32);
        let hi: [i32; 3] = std::array::from_fn(|i| b.min[i].max(b.max[i]).floor() as i32);
        let count: i64 = (0..3).map(|i| (hi[i] - lo[i] + 1) as i64).product();
        if count > 512 {
            return None;
        }
        let (a, bb, c) = if stationary {
            (2, 1, 0)
        } else if delta[0].abs() < delta[2].abs() {
            (1, 2, 0)
        } else {
            (1, 0, 2)
        };
        // Each axis's first cell, its step and how many cells it spans.
        let span = |i: usize| -> (i32, i32, i32) {
            let n = hi[i] - lo[i] + 1;
            if delta[i] < 0.0 {
                (hi[i], -1, n)
            } else {
                (lo[i], 1, n)
            }
        };
        let (sa, sb, sc) = (span(a), span(bb), span(c));
        let mut p = [0; 3];
        for ia in 0..sa.2 {
            p[a] = sa.0 + ia * sa.1;
            for ib in 0..sb.2 {
                p[bb] = sb.0 + ib * sb.1;
                for ic in 0..sc.2 {
                    p[c] = sc.0 + ic * sc.1;
                    self.attempts += 1;
                    if self.attempts > MAX_ATTEMPTS {
                        return None;
                    }
                    if self.new_cell(p) {
                        self.visits.push((p, step));
                        if self.visits.len() >= self.stop {
                            return Some(Flow::Stop);
                        }
                    }
                }
            }
        }
        Some(Flow::Go)
    }
}

fn direction(x: f64) -> f64 {
    if x < 0.0 {
        -1.0
    } else {
        1.0
    }
}

fn sign(x: f64) -> f64 {
    if x == 0.0 {
        0.0
    } else {
        direction(x)
    }
}

/// The corner of the box that leads the movement.
fn corner(d: [f64; 3]) -> [f64; 3] {
    let s = d.map(direction);
    let [x, y, z] = d.map(f64::abs);
    if x <= y && x <= z {
        [-s[0], -s[2], s[1]]
    } else if y <= z {
        [s[2], -s[1], -s[0]]
    } else {
        [-s[1], s[0], -s[2]]
    }
}

/// The ordered visits of a body moving from `from` to `to`; `body` is the
/// destination box, already deflated for inside-block checks. `None` when the
/// walk exceeds its bounds.
pub fn sweep(from: [f64; 3], to: [f64; 3], body: &Aabb, stop_after: usize) -> Option<Sweep> {
    let delta = [to[0] - from[0], to[1] - from[1], to[2] - from[2]];
    // The server's bounds (not vanilla's): a movement of at most 64 blocks per
    // axis and a body of at most 16.
    let within = |v: f64, low: f64, high: f64| (low..=high).contains(&v) && v != low;
    if delta.iter().any(|d| !(-64.0..=64.0).contains(d))
        || (0..3).any(|a| !within(body.size(a), 0.0, 16.0))
    {
        return None;
    }
    let mut walk = Walk {
        seen: None,
        visits: Vec::with_capacity(LISTED),
        attempts: 0,
        stop: stop_after.max(1),
    };
    let finish = |walk: Walk, flow: Flow| Sweep {
        visits: walk.visits,
        complete: matches!(flow, Flow::Go),
    };
    if delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] < TINY_SQUARE {
        let flow = walk.visit(body, [0.0; 3], true, 0)?;
        return Some(finish(walk, flow));
    }
    let sizes: [f64; 3] = std::array::from_fn(|i| body.max[i] - body.min[i]);
    if let Flow::Stop = walk.visit(&body.moved(delta.map(|d| -d)), delta, false, 0)? {
        return Some(finish(walk, Flow::Stop));
    }
    let corner = corner(delta);
    let endpoint: [f64; 3] =
        std::array::from_fn(|i| body.min[i] + 0.5 * sizes[i] + 0.5 * sizes[i] * corner[i]);
    let start: [f64; 3] = std::array::from_fn(|i| endpoint[i] - delta[i]);
    let signs = delta.map(sign);
    let intervals: [f64; 3] = std::array::from_fn(|i| {
        if signs[i] == 0.0 {
            f64::MAX
        } else {
            signs[i] / delta[i]
        }
    });
    let mut times: [f64; 3] = std::array::from_fn(|i| {
        let fraction = start[i] - start[i].floor();
        intervals[i]
            * if signs[i] > 0.0 {
                1.0 - fraction
            } else {
                fraction
            }
    });
    let mut grid: [f64; 3] = start.map(f64::floor);
    let mut step = 0u32;
    let mut crossings = 0usize;
    loop {
        if crossings > MAX_CROSSINGS {
            return None;
        }
        let [tx, ty, tz] = times;
        if tx > 1.0 && ty > 1.0 && tz > 1.0 {
            let flow = walk.visit(body, delta, false, step + 1)?;
            return Some(finish(walk, flow));
        }
        let axis = if tx < ty {
            if tx < tz {
                0
            } else {
                2
            }
        } else if ty < tz {
            1
        } else {
            2
        };
        grid[axis] += signs[axis];
        times[axis] += intervals[axis];
        let cube = Aabb {
            min: grid,
            max: grid.map(|g| g + 1.0),
        };
        if let Some(hit) = cube.clip(start, endpoint) {
            let back: [f64; 3] = std::array::from_fn(|i| {
                let lo = grid[i];
                let clamped = hit[i].max(lo + EPSILON).min(lo + 1.0 - EPSILON);
                (clamped - sizes[i] * corner[i]).floor()
            });
            let crossed = Aabb {
                min: grid,
                max: back,
            };
            step += 1;
            if let Flow::Stop = walk.visit(&crossed, delta, false, step)? {
                return Some(finish(walk, Flow::Stop));
            }
        }
        crossings += 1;
    }
}

/// `AABB.collidedAlongVector`: whether `body`'s centre, moving by
/// `movement`, starts in, ends in or passes through any of `boxes` grown by
/// half the body's size (less 1e-7).
pub fn collided_along(body: &Aabb, movement: [f64; 3], boxes: &[Aabb]) -> bool {
    let size: [f64; 3] = std::array::from_fn(|a| body.max[a] - body.min[a]);
    let centre: [f64; 3] = std::array::from_fn(|a| body.min[a] + 0.5 * size[a]);
    let destination: [f64; 3] = std::array::from_fn(|a| centre[a] + movement[a]);
    let half: [f64; 3] = std::array::from_fn(|a| size[a] * 0.5 - 1.0e-7);
    let contains = |b: &Aabb, p: [f64; 3]| (0..3).all(|a| p[a] >= b.min[a] && p[a] < b.max[a]);
    boxes.iter().any(|b| {
        let grown = Aabb::new(
            std::array::from_fn(|a| b.min[a] - half[a]),
            std::array::from_fn(|a| b.max[a] + half[a]),
        );
        contains(&grown, centre)
            || contains(&grown, destination)
            || grown.clip(centre, destination).is_some()
    })
}
