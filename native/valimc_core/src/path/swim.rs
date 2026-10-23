//! `SwimNodeEvaluator`: water nodes in all six directions and the four flat
//! diagonals, breaching the surface for a dolphin.

use super::types::*;
use super::walk::{clockwise, ALL, HORIZONTAL};
use super::{Search, SWIMMABLE};

/// `getStart`: the box's lower corner, half a block up.
pub(super) fn start(s: &mut Search) -> usize {
    let b = s.mob.bounds();
    s.node([
        b.min[0].floor() as i32,
        (b.min[1] + 0.5).floor() as i32,
        b.min[2].floor() as i32,
    ])
}

/// `getPathTypeOfMob` (the swimmer's `getPathType`): breach over air above
/// swimmable blocks, blocked out of water, else water where the last cell
/// is swimmable.
pub(super) fn path_type(s: &Search, x: i32, y: i32, z: i32) -> u8 {
    let level = &s.level;
    let [w, h, d] = s.size;
    let mut last = [x, y, z];
    for xx in x..x + w {
        for yy in y..y + h {
            for zz in z..z + d {
                last = [xx, yy, zz];
                let state = level.state(xx, yy, zz);
                let fluid = level.facts.fluid(state).kind;
                if fluid == 0 && level.flag(xx, yy - 1, zz, SWIMMABLE) && level.air(state) {
                    return BREACH;
                }
                if fluid != crate::physics::facts::WATER {
                    return BLOCKED;
                }
            }
        }
    }
    if level.flag(last[0], last[1], last[2], SWIMMABLE) {
        WATER
    } else {
        BLOCKED
    }
}

fn accepted(s: &mut Search, x: i32, y: i32, z: i32, breaching: bool) -> Option<usize> {
    let kind = s.cached(x, y, z);
    if !(breaching && kind == BREACH || kind == WATER) {
        return None;
    }
    let cost = s.malus(kind);
    if cost < 0.0 {
        return None;
    }
    let n = s.node([x, y, z]);
    s.nodes[n].kind = kind;
    s.nodes[n].malus = s.nodes[n].malus.max(cost);
    if s.level.fluid(x, y, z) == 0 {
        s.nodes[n].malus += 8.0;
    }
    Some(n)
}

fn open(s: &Search, node: Option<usize>) -> bool {
    node.is_some_and(|n| !s.nodes[n].closed)
}

fn has_malus(s: &Search, node: Option<usize>) -> bool {
    node.is_some_and(|n| s.nodes[n].malus >= 0.0)
}

/// `getNeighbors`.
pub(super) fn neighbors(s: &mut Search, current: usize, breaching: bool) -> Vec<usize> {
    let [x, y, z] = s.nodes[current].pos;
    let mut out = Vec::with_capacity(10);
    let mut by: [Option<usize>; 6] = [None; 6];
    for (i, [dx, dy, dz]) in ALL.into_iter().enumerate() {
        let node = accepted(s, x + dx, y + dy, z + dz, breaching);
        by[i] = node;
        if open(s, node) {
            out.extend(node);
        }
    }
    // `ALL`'s index of each horizontal direction (north, east, south, west).
    let index = [2, 5, 3, 4];
    for (i, [dx, _, dz]) in HORIZONTAL.into_iter().enumerate() {
        let second = clockwise(i);
        if has_malus(s, by[index[i]]) && has_malus(s, by[index[second]]) {
            let [sx, _, sz] = HORIZONTAL[second];
            let node = accepted(s, x + dx + sx, y, z + dz + sz, breaching);
            if open(s, node) {
                out.extend(node);
            }
        }
    }
    out
}
