//! `FlyNodeEvaluator`: every neighbour of the 26, a diagonal only past open
//! sides, and open air above ground.

use super::types::*;
use super::walk::start_node;
use super::{Search, WATER_BLOCK};

/// `FlyNodeEvaluator.getPathType`.
pub(super) fn path_type(s: &Search, x: i32, y: i32, z: i32) -> u8 {
    let level = &s.level;
    let mut kind = level.state_type(x, y, z);
    if kind == OPEN && y > level.min_y {
        let below = level.state_type(x, y - 1, z);
        kind = match below {
            FIRE | LAVA => FIRE,
            DAMAGING => DAMAGING,
            COCOA => COCOA,
            FENCE => {
                if [x, y - 1, z] != s.mob_block {
                    FENCE
                } else {
                    kind
                }
            }
            WALKABLE | OPEN | WATER => OPEN,
            _ => WALKABLE,
        };
    }
    if kind == WALKABLE || kind == OPEN {
        kind = level.neighbours(x, y, z, kind);
    }
    kind
}

fn can_start_at(s: &mut Search, [x, y, z]: [i32; 3]) -> bool {
    let kind = s.cached(x, y, z);
    s.malus(kind) >= 0.0
}

/// `getStart`: in water (floating), above it; else half a block up; where
/// that cannot start, the box's corners (a large flier) or ten random
/// blocks around it (a small one, drawn from its random).
pub(super) fn start(s: &mut Search) -> usize {
    let mob = s.mob;
    let [px, py, pz] = mob.position;
    let (bx, bz) = (px.floor() as i32, pz.floor() as i32);
    let start_y = if mob.can_float && mob.in_water {
        let mut y = py.floor() as i32;
        while s.level.flag(bx, y, bz, WATER_BLOCK) {
            y += 1;
        }
        y
    } else {
        (py + 0.5).floor() as i32
    };
    let start = [bx, start_y, bz];
    if !can_start_at(s, start) {
        let b = mob.bounds();
        let size = [0, 1, 2].map(|a| b.max[a] - b.min[a]);
        if (size[0] + size[1] + size[2]) / 3.0 >= 1.0 {
            let y = py.floor() as i32;
            for (x, z) in [
                (b.min[0], b.min[2]),
                (b.min[0], b.max[2]),
                (b.max[0], b.min[2]),
                (b.max[0], b.max[2]),
            ] {
                let pos = [x.floor() as i32, y, z.floor() as i32];
                if can_start_at(s, pos) {
                    return start_node(s, pos);
                }
            }
        } else {
            let pad = |size: f64| 0.0f64.max(1.1f32 as f64 - size);
            let (xp, yp, zp) = (pad(size[0]), pad(size[1]), pad(size[2]));
            let lo = [b.min[0] - xp, b.min[1] - yp, b.min[2] - zp].map(|v| v.floor() as i32);
            let hi = [b.max[0] + xp, b.max[1] + yp, b.max[2] + zp].map(|v| v.floor() as i32);
            let span = [0, 1, 2].map(|a| hi[a] - lo[a] + 1);
            for _ in 0..10 {
                let x = lo[0] + s.random.next_int_bounded(span[0]);
                let y = lo[1] + s.random.next_int_bounded(span[1]);
                let z = lo[2] + s.random.next_int_bounded(span[2]);
                if can_start_at(s, [x, y, z]) {
                    return start_node(s, [x, y, z]);
                }
            }
        }
    }
    start_node(s, start)
}

fn accepted(s: &mut Search, x: i32, y: i32, z: i32) -> Option<usize> {
    let kind = s.cached(x, y, z);
    let cost = s.malus(kind);
    if cost < 0.0 {
        return None;
    }
    let n = s.node([x, y, z]);
    s.nodes[n].kind = kind;
    s.nodes[n].malus = s.nodes[n].malus.max(cost);
    if kind == WALKABLE {
        s.nodes[n].malus += 1.0;
    }
    Some(n)
}

/// `getNeighbors`, in vanilla's order.
pub(super) fn neighbors(s: &mut Search, current: usize) -> Vec<usize> {
    let [x, y, z] = s.nodes[current].pos;
    let mut out = Vec::with_capacity(26);
    let open = |s: &Search, n: Option<usize>| n.is_some_and(|n| !s.nodes[n].closed);
    let malus = |s: &Search, n: Option<usize>| n.is_some_and(|n| s.nodes[n].malus >= 0.0);
    let at = |s: &mut Search, dx: i32, dy: i32, dz: i32| accepted(s, x + dx, y + dy, z + dz);

    let south = at(s, 0, 0, 1);
    if open(s, south) {
        out.extend(south);
    }
    let west = at(s, -1, 0, 0);
    if open(s, west) {
        out.extend(west);
    }
    let east = at(s, 1, 0, 0);
    if open(s, east) {
        out.extend(east);
    }
    let north = at(s, 0, 0, -1);
    if open(s, north) {
        out.extend(north);
    }
    let up = at(s, 0, 1, 0);
    if open(s, up) {
        out.extend(up);
    }
    let down = at(s, 0, -1, 0);
    if open(s, down) {
        out.extend(down);
    }

    // The diagonals of two sides, each needing both sides passable.
    let pair =
        |s: &mut Search, d: [i32; 3], a: Option<usize>, b: Option<usize>, out: &mut Vec<usize>| {
            let node = at(s, d[0], d[1], d[2]);
            if open(s, node) && malus(s, a) && malus(s, b) {
                out.extend(node);
            }
            node
        };
    let south_up = pair(s, [0, 1, 1], south, up, &mut out);
    let west_up = pair(s, [-1, 1, 0], west, up, &mut out);
    let east_up = pair(s, [1, 1, 0], east, up, &mut out);
    let north_up = pair(s, [0, 1, -1], north, up, &mut out);
    let south_down = pair(s, [0, -1, 1], south, down, &mut out);
    let west_down = pair(s, [-1, -1, 0], west, down, &mut out);
    let east_down = pair(s, [1, -1, 0], east, down, &mut out);
    let north_down = pair(s, [0, -1, -1], north, down, &mut out);
    let north_east = pair(s, [1, 0, -1], north, east, &mut out);
    let south_east = pair(s, [1, 0, 1], south, east, &mut out);
    let north_west = pair(s, [-1, 0, -1], north, west, &mut out);
    let south_west = pair(s, [-1, 0, 1], south, west, &mut out);

    // The corners of three sides, each needing all six faces and edges.
    let corners = [
        ([1, 1, -1], [north_east, north, east, up, north_up, east_up]),
        ([1, 1, 1], [south_east, south, east, up, south_up, east_up]),
        (
            [-1, 1, -1],
            [north_west, north, west, up, north_up, west_up],
        ),
        ([-1, 1, 1], [south_west, south, west, up, south_up, west_up]),
        (
            [1, -1, -1],
            [north_east, north, east, down, north_down, east_down],
        ),
        (
            [1, -1, 1],
            [south_east, south, east, down, south_down, east_down],
        ),
        (
            [-1, -1, -1],
            [north_west, north, west, down, north_down, west_down],
        ),
        (
            [-1, -1, 1],
            [south_west, south, west, down, south_down, west_down],
        ),
    ];
    for (d, needs) in corners {
        let node = at(s, d[0], d[1], d[2]);
        if open(s, node) && needs.iter().all(|&n| malus(s, n)) {
            out.extend(node);
        }
    }
    out
}
