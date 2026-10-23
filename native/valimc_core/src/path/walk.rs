//! `WalkNodeEvaluator` and `AmphibiousNodeEvaluator` (which extends it).

use super::types::*;
use super::{Search, LAND};
use crate::physics::Aabb;

/// `Direction.Plane.HORIZONTAL`'s order (north, east, south, west) as steps.
pub(super) const HORIZONTAL: [[i32; 3]; 4] = [[0, 0, -1], [1, 0, 0], [0, 0, 1], [-1, 0, 0]];

/// `getClockWise` of a horizontal direction's index.
pub(super) fn clockwise(i: usize) -> usize {
    (i + 1) % 4
}

/// `Direction.values()`: down, up, north, south, west, east.
pub(super) const ALL: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

fn partial(kind: u8) -> bool {
    kind == FENCE || kind == DOOR_WOOD_CLOSED || kind == DOOR_IRON_CLOSED
}

/// The bit of a type in a set kept as a mask (an `EnumSet`, by ordinal).
fn bit(kind: u8) -> u32 {
    1 << kind
}

/// `getPathTypeWithinMobBB`.
fn within(s: &Search, x: i32, y: i32, z: i32) -> u32 {
    let mut set = 0;
    let [w, h, d] = s.size;
    let mob = s.mob;
    let [mx, my, mz] = s.mob_block;
    for dx in 0..w {
        for dy in 0..h {
            for dz in 0..d {
                let mut kind = s.path_type(x + dx, y + dy, z + dz);
                if kind == DOOR_WOOD_CLOSED && mob.can_open_doors && mob.can_pass_doors {
                    kind = WALKABLE_DOOR;
                }
                if kind == DOOR_OPEN && !mob.can_pass_doors {
                    kind = BLOCKED;
                }
                if kind == RAIL
                    && s.path_type(mx, my, mz) != RAIL
                    && s.path_type(mx, my - 1, mz) != RAIL
                {
                    kind = UNPASSABLE_RAIL;
                }
                set |= bit(kind);
            }
        }
    }
    set
}

/// `WalkNodeEvaluator.getPathTypeOfMob`.
pub(super) fn type_of_mob(s: &Search, x: i32, y: i32, z: i32) -> u8 {
    let set = within(s, x, y, z);
    if set.count_ones() == 1 {
        return set.trailing_zeros() as u8;
    }
    if set & bit(FENCE) != 0 {
        return FENCE;
    }
    if set & bit(UNPASSABLE_RAIL) != 0 {
        return UNPASSABLE_RAIL;
    }
    let mut highest = BLOCKED;
    let mut highest_malus = s.malus(BLOCKED);
    for kind in 0..COUNT as u8 {
        if set & bit(kind) == 0 {
            continue;
        }
        let m = s.malus(kind);
        if m < 0.0 {
            return kind;
        }
        if m >= highest_malus {
            highest_malus = m;
            highest = kind;
        }
    }
    let current = s.path_type(x, y, z);
    if s.size[0] > 1 {
        let cheaper = s.malus(current) < highest_malus;
        if cheaper && s.malus(BIG_MOBS_CLOSE_TO_DANGER) < highest_malus {
            BIG_MOBS_CLOSE_TO_DANGER
        } else {
            highest
        }
    } else if current == OPEN && highest != OPEN && highest_malus == 0.0 {
        OPEN
    } else {
        highest
    }
}

/// `AmphibiousNodeEvaluator.getPathType`: water beside a blocked block is
/// its border.
pub(super) fn amphibious_type(s: &Search, x: i32, y: i32, z: i32) -> u8 {
    if s.level.state_type(x, y, z) == WATER {
        for [dx, dy, dz] in ALL {
            if s.level.state_type(x + dx, y + dy, z + dz) == BLOCKED {
                return WATER_BORDER;
            }
        }
        WATER
    } else {
        s.level.path_type_static(x, y, z)
    }
}

fn can_float_or_amphibious(s: &Search) -> bool {
    s.mob.can_float || s.amphibious()
}

/// The evaluator's `getFloorLevel(pos)`: in a floatable fluid, half up it.
pub(super) fn floor_level(s: &Search, x: i32, y: i32, z: i32) -> f64 {
    if can_float_or_amphibious(s) && s.level.water(x, y, z) {
        y as f64 + 0.5
    } else {
        s.level.floor(x, y, z)
    }
}

/// `canStartAt`.
fn can_start_at(s: &mut Search, [x, y, z]: [i32; 3]) -> bool {
    let kind = s.cached(x, y, z);
    kind != OPEN && s.malus(kind) >= 0.0
}

/// `getStartNode`.
pub(super) fn start_node(s: &mut Search, pos: [i32; 3]) -> usize {
    let node = s.node(pos);
    let kind = s.cached(pos[0], pos[1], pos[2]);
    s.nodes[node].kind = kind;
    s.nodes[node].malus = s.malus(kind);
    node
}

/// `WalkNodeEvaluator.getStart`.
pub(super) fn start(s: &mut Search) -> usize {
    let mob = s.mob;
    let [px, py, pz] = mob.position;
    let (bx, bz) = (px.floor() as i32, pz.floor() as i32);
    let mut start_y = py.floor() as i32;
    // `canStandOnFluid` is a strider's: no modelled mob stands on fluid.
    if mob.can_float && mob.in_water {
        while s.level.water(bx, start_y, bz) {
            start_y += 1;
        }
        start_y -= 1;
    } else if mob.on_ground {
        start_y = (py + 0.5).floor() as i32;
    } else {
        let mut y = (py + 1.0).floor() as i32;
        while y > s.level.min_y {
            start_y = y;
            y -= 1;
            let below = s.level.state(bx, y, bz);
            if !s.level.air(below) && !s.level.paths.flag(below, LAND) {
                break;
            }
        }
    }
    let [sx, _, sz] = s.mob_block;
    if !can_start_at(s, [sx, start_y, sz]) {
        let b = mob.bounds();
        for (x, z) in [
            (b.min[0], b.min[2]),
            (b.min[0], b.max[2]),
            (b.max[0], b.min[2]),
            (b.max[0], b.max[2]),
        ] {
            let pos = [x.floor() as i32, start_y, z.floor() as i32];
            if can_start_at(s, pos) {
                return start_node(s, pos);
            }
        }
    }
    start_node(s, [sx, start_y, sz])
}

/// `AmphibiousNodeEvaluator.getStart`: in water, the box's corner.
pub(super) fn amphibious_start(s: &mut Search) -> usize {
    if !s.mob.in_water {
        return start(s);
    }
    let b = s.mob.bounds();
    let pos = [
        b.min[0].floor() as i32,
        (b.min[1] + 0.5).floor() as i32,
        b.min[2].floor() as i32,
    ];
    start_node(s, pos)
}

fn neighbor_valid(s: &Search, node: Option<usize>, current: usize) -> bool {
    node.is_some_and(|n| {
        let n = &s.nodes[n];
        !n.closed && (n.malus >= 0.0 || s.nodes[current].malus < 0.0)
    })
}

fn diagonal_valid(s: &Search, pos: usize, ew: Option<usize>, ns: Option<usize>) -> bool {
    let (Some(ew), Some(ns)) = (ew, ns) else {
        return false;
    };
    let (p, ew, ns) = (&s.nodes[pos], &s.nodes[ew], &s.nodes[ns]);
    if ns.pos[1] > p.pos[1] || ew.pos[1] > p.pos[1] {
        return false;
    }
    if ew.kind == WALKABLE_DOOR || ns.kind == WALKABLE_DOOR {
        return false;
    }
    if s.mob.width > 1.0 && (ew.malus > 0.0 || ns.malus > 0.0) {
        return false;
    }
    let between_posts = ns.kind == FENCE && ew.kind == FENCE && (s.mob.width as f64) < 0.5;
    (ns.pos[1] < p.pos[1] || ns.malus >= 0.0 || between_posts)
        && (ew.pos[1] < p.pos[1] || ew.malus >= 0.0 || between_posts)
}

fn diagonal_node_valid(s: &Search, node: Option<usize>) -> bool {
    node.is_some_and(|n| {
        let n = &s.nodes[n];
        !n.closed && n.kind != WALKABLE_DOOR && n.malus >= 0.0
    })
}

fn jump_size(s: &mut Search, [x, y, z]: [i32; 3]) -> (i32, u8) {
    let above = s.cached(x, y + 1, z);
    let current = s.cached(x, y, z);
    let jump = if s.malus(above) >= 0.0 && current != STICKY_HONEY {
        s.mob.step.max(1.0).floor() as i32
    } else {
        0
    };
    (jump, current)
}

/// `WalkNodeEvaluator.getNeighbors`.
pub(super) fn neighbors(s: &mut Search, current: usize) -> Vec<usize> {
    let pos = s.nodes[current].pos;
    let [x, y, z] = pos;
    let (jump, kind) = jump_size(s, pos);
    let height = floor_level(s, x, y, z);
    let mut out = Vec::with_capacity(16);
    let mut around = [None; 4];
    for (i, [dx, _, dz]) in HORIZONTAL.into_iter().enumerate() {
        let node = accepted(s, x + dx, y, z + dz, jump, height, [dx, 0, dz], kind);
        around[i] = node;
        if neighbor_valid(s, node, current) {
            out.extend(node);
        }
    }
    for (i, [dx, _, dz]) in HORIZONTAL.into_iter().enumerate() {
        let second = clockwise(i);
        let [sx, _, sz] = HORIZONTAL[second];
        if diagonal_valid(s, current, around[i], around[second]) {
            let node = accepted(
                s,
                x + dx + sx,
                y,
                z + dz + sz,
                jump,
                height,
                [dx, 0, dz],
                kind,
            );
            if diagonal_node_valid(s, node) {
                out.extend(node);
            }
        }
    }
    out
}

/// `AmphibiousNodeEvaluator.getNeighbors`: the walker's, then up and down
/// through water.
pub(super) fn amphibious_neighbors(s: &mut Search, current: usize, shallow: bool) -> Vec<usize> {
    let mut out = neighbors(s, current);
    let pos = s.nodes[current].pos;
    let [x, y, z] = pos;
    let (jump, kind) = jump_size(s, pos);
    let height = floor_level(s, x, y, z);
    let up = accepted(s, x, y + 1, z, (jump - 1).max(0), height, [0, 1, 0], kind);
    let down = accepted(s, x, y - 1, z, jump, height, [0, -1, 0], kind);
    if neighbor_valid(s, up, current) && up.is_some_and(|n| s.nodes[n].kind == WATER) {
        out.extend(up);
    }
    if neighbor_valid(s, down, current)
        && down.is_some_and(|n| s.nodes[n].kind == WATER)
        && kind != TRAPDOOR
    {
        out.extend(down);
    }
    if shallow {
        for &n in &out {
            if s.nodes[n].kind == WATER && s.nodes[n].pos[1] < s.request.sea_level - 10 {
                s.nodes[n].malus += 1.0;
            }
        }
    }
    out
}

/// `getNodeAndUpdateCostToMax`.
fn cost_to_max(s: &mut Search, pos: [i32; 3], kind: u8, cost: f32) -> usize {
    let n = s.node(pos);
    s.nodes[n].kind = kind;
    s.nodes[n].malus = s.nodes[n].malus.max(cost);
    n
}

fn blocked_node(s: &mut Search, pos: [i32; 3]) -> usize {
    let n = s.node(pos);
    s.nodes[n].kind = BLOCKED;
    s.nodes[n].malus = -1.0;
    n
}

/// `PathType.getMalus`, a type's default.
fn default_malus(kind: u8) -> f32 {
    match kind {
        BLOCKED | POWDER_SNOW | FENCE | LAVA | UNPASSABLE_RAIL | DAMAGING | DOOR_WOOD_CLOSED
        | DOOR_IRON_CLOSED | LEAVES => -1.0,
        WATER | WATER_BORDER | FIRE_IN_NEIGHBOR | DAMAGING_IN_NEIGHBOR | STICKY_HONEY => 8.0,
        FIRE => 16.0,
        BREACH | BIG_MOBS_CLOSE_TO_DANGER => 4.0,
        _ => 0.0,
    }
}

fn closed_node(s: &mut Search, pos: [i32; 3], kind: u8) -> usize {
    let n = s.node(pos);
    s.nodes[n].closed = true;
    s.nodes[n].kind = kind;
    s.nodes[n].malus = default_malus(kind);
    n
}

/// `canReachWithoutCollision`: the mob's box swept to the node in steps of
/// its size meets nothing.
fn reach_without_collision(s: &mut Search, node: usize) -> bool {
    let mob = s.mob;
    let mut b = mob.bounds();
    let [nx, ny, nz] = s.nodes[node].pos;
    let size = [0, 1, 2].map(|a| b.max[a] - b.min[a]);
    let mut delta = [
        nx as f64 - mob.position[0] + size[0] / 2.0,
        ny as f64 - mob.position[1] + size[1] / 2.0,
        nz as f64 - mob.position[2] + size[2] / 2.0,
    ];
    let length = (delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]).sqrt();
    let average = (size[0] + size[1] + size[2]) / 3.0;
    let steps = (length / average).ceil() as i32;
    let scale = (1.0f32 / steps as f32) as f64;
    delta = delta.map(|d| d * scale);
    for _ in 1..=steps {
        b = b.moved(delta);
        if s.collides(&b) {
            return false;
        }
    }
    true
}

#[allow(clippy::too_many_arguments)]
fn jump_on(
    s: &mut Search,
    x: i32,
    y: i32,
    z: i32,
    jump: i32,
    height: f64,
    direction: [i32; 3],
    current: u8,
) -> Option<usize> {
    let above = accepted(s, x, y + 1, z, jump - 1, height, direction, current)?;
    let mob = s.mob;
    if mob.width >= 1.0 {
        return Some(above);
    }
    let kind = s.nodes[above].kind;
    if kind != OPEN && kind != WALKABLE {
        return Some(above);
    }
    let cx = (x - direction[0]) as f64 + 0.5;
    let cz = (z - direction[2]) as f64 + 0.5;
    let half = mob.width as f64 / 2.0;
    let [ax, ay, az] = s.nodes[above].pos;
    let low = floor_level(s, cx.floor() as i32, y + 1, cz.floor() as i32) + 0.001;
    let high = mob.height as f64 + floor_level(s, ax, ay, az) - 0.002;
    let grow = Aabb::new([cx - half, low, cz - half], [cx + half, high, cz + half]);
    if s.collides(&grow) {
        None
    } else {
        Some(above)
    }
}

fn first_non_water_below(
    s: &mut Search,
    x: i32,
    mut y: i32,
    z: i32,
    mut best: Option<usize>,
) -> Option<usize> {
    y -= 1;
    while y > s.level.min_y {
        let kind = s.cached(x, y, z);
        if kind != WATER {
            return best;
        }
        let m = s.malus(kind);
        best = Some(cost_to_max(s, [x, y, z], kind, m));
        y -= 1;
    }
    best
}

fn first_ground_below(s: &mut Search, x: i32, y: i32, z: i32) -> usize {
    let mut below = y - 1;
    while below >= s.level.min_y {
        if y - below > s.mob.max_fall {
            return blocked_node(s, [x, below, z]);
        }
        let kind = s.cached(x, below, z);
        let cost = s.malus(kind);
        if kind != OPEN {
            if cost >= 0.0 {
                return cost_to_max(s, [x, below, z], kind, cost);
            }
            return blocked_node(s, [x, below, z]);
        }
        below -= 1;
    }
    blocked_node(s, [x, y, z])
}

/// `WalkNodeEvaluator.findAcceptedNode`.
#[allow(clippy::too_many_arguments)]
fn accepted(
    s: &mut Search,
    x: i32,
    y: i32,
    z: i32,
    jump: i32,
    height: f64,
    direction: [i32; 3],
    current: u8,
) -> Option<usize> {
    let target_height = floor_level(s, x, y, z);
    if target_height - height > 1.125f64.max(s.mob.step as f64) {
        return None;
    }
    let kind = s.cached(x, y, z);
    let cost = s.malus(kind);
    let mut best = (cost >= 0.0).then(|| cost_to_max(s, [x, y, z], kind, cost));
    if partial(current) {
        if let Some(n) = best {
            if s.nodes[n].malus >= 0.0 && !reach_without_collision(s, n) {
                best = None;
            }
        }
    }
    let amphibious = s.amphibious();
    if kind == WALKABLE || (amphibious && kind == WATER) {
        return best;
    }
    if (best.is_none() || best.is_some_and(|n| s.nodes[n].malus < 0.0))
        && jump > 0
        && (kind != FENCE || s.mob.can_walk_over_fences)
        && kind != UNPASSABLE_RAIL
        && kind != TRAPDOOR
        && kind != POWDER_SNOW
    {
        jump_on(s, x, y, z, jump, height, direction, current)
    } else if !amphibious && kind == WATER && !s.mob.can_float {
        first_non_water_below(s, x, y, z, best)
    } else if kind == OPEN {
        Some(first_ground_below(s, x, y, z))
    } else if partial(kind) && best.is_none() {
        Some(closed_node(s, [x, y, z], kind))
    } else {
        best
    }
}
