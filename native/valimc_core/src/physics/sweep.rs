//! The blocks a body passes through while moving, in vanilla's order
//! (`BlockGetter.forEachBlockIntersectedBetween` as `Entity.checkInsideBlocks`
//! walks it): the cells of the start, then the cells each grid crossing of
//! the leading corner adds, then the cells of the end, each visited once,
//! with the crossing step it was found at.

use super::aabb::Aabb;

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

struct Walk {
    seen: std::collections::HashSet<[i32; 3]>,
    visits: Vec<Visit>,
    attempts: usize,
    stop: usize,
}

enum Flow {
    Go,
    Stop,
}

impl Walk {
    fn visit(&mut self, cells: &[[i32; 3]], step: u32) -> Result<Flow, ()> {
        for &pos in cells {
            self.attempts += 1;
            if self.attempts > MAX_ATTEMPTS {
                return Err(());
            }
            if self.seen.insert(pos) {
                self.visits.push((pos, step));
                if self.visits.len() >= self.stop {
                    return Ok(Flow::Stop);
                }
            }
        }
        Ok(Flow::Go)
    }
}

/// The cells a box covers, in the order the walk visits them: Y, then the
/// horizontal axes with the larger movement component last (X, Y, Z for a
/// stationary body), each against the movement's direction.
fn cells(b: &Aabb, delta: [f64; 3], stationary: bool) -> Option<Vec<[i32; 3]>> {
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
    let range = |i: usize| -> Vec<i32> {
        if delta[i] < 0.0 {
            (lo[i]..=hi[i]).rev().collect()
        } else {
            (lo[i]..=hi[i]).collect()
        }
    };
    let mut out = Vec::with_capacity(count as usize);
    for x in range(a) {
        for y in range(bb) {
            for z in range(c) {
                let mut p = [0; 3];
                p[a] = x;
                p[bb] = y;
                p[c] = z;
                out.push(p);
            }
        }
    }
    Some(out)
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
        seen: std::collections::HashSet::new(),
        visits: Vec::new(),
        attempts: 0,
        stop: stop_after.max(1),
    };
    let finish = |walk: Walk, flow: Flow| Sweep {
        visits: walk.visits,
        complete: matches!(flow, Flow::Go),
    };
    if delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] < TINY_SQUARE {
        let cells = cells(body, [0.0; 3], true)?;
        let flow = walk.visit(&cells, 0).ok()?;
        return Some(finish(walk, flow));
    }
    let sizes: [f64; 3] = std::array::from_fn(|i| body.max[i] - body.min[i]);
    let initial = cells(&body.moved(delta.map(|d| -d)), delta, false)?;
    if let Flow::Stop = walk.visit(&initial, 0).ok()? {
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
            let last = cells(body, delta, false)?;
            let flow = walk.visit(&last, step + 1).ok()?;
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
            let crossed = cells(
                &Aabb {
                    min: grid,
                    max: back,
                },
                delta,
                false,
            )?;
            step += 1;
            if let Flow::Stop = walk.visit(&crossed, step).ok()? {
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
