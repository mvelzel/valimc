//! Vanilla's random walk targets (`Valimc.AI.RandomPos`: `RandomPos`,
//! `DefaultRandomPos`, `LandRandomPos`, `GoalUtils`, the swimming stroll's
//! targets): ten candidate blocks around the mob, each inside the build
//! height, standing on a block that renders solid and with no path malus
//! (land targets: moved up out of solid blocks and not in water), the best
//! by the mob's walk target value. Draws come from the mob's random in
//! vanilla's order. A mob with a home leans each candidate toward it and,
//! near it, keeps to it.

use super::fmath::{self, f};
use super::navigation::NavKind;
use super::turn::Turn;
use crate::mobs::level::{FluidKind, Level};
use crate::path::{types, SWIMMABLE};

const SQRT2: f64 = std::f64::consts::SQRT_2 as f32 as f64;
const HALF_PI: f64 = std::f64::consts::FRAC_PI_2 as f32 as f64;

type Direction = [i32; 3];

/// `DefaultRandomPos.getPos(mob, h, v)`.
pub fn default(t: &mut Turn, h: i32, v: i32) -> Option<[f64; 3]> {
    let restrict = restricted(t, h);
    best(t, walk_value, |t| {
        let d = direction(t, h, v);
        toward(t, h, d, false, restrict)
    })
}

/// `DefaultRandomPos.getPosAway(mob, h, v, from)`.
pub fn default_away(t: &mut Turn, h: i32, v: i32, from: [f64; 3]) -> Option<[f64; 3]> {
    let (dx, dz) = (t.x() - from[0], t.z() - from[2]);
    let restrict = restricted(t, h);
    best(t, walk_value, |t| {
        let d = within(t, 0.0, h as f64, v, dx, dz, HALF_PI)?;
        toward(t, h, d, false, restrict)
    })
}

/// `DefaultRandomPos.getPosTowards(mob, h, v, towards, radians)`.
pub fn default_towards(
    t: &mut Turn,
    h: i32,
    v: i32,
    towards: [f64; 3],
    radians: f64,
) -> Option<[f64; 3]> {
    let (dx, dz) = (towards[0] - t.x(), towards[2] - t.z());
    let restrict = restricted(t, h);
    best(t, walk_value, |t| {
        let d = within(t, 0.0, h as f64, v, dx, dz, radians)?;
        toward(t, h, d, false, restrict)
    })
}

/// `BehaviorUtils.getRandomSwimmablePos(mob, h, v)`: a default target,
/// tried again up to ten times while its block is not swimmable.
pub fn swimmable(t: &mut Turn, h: i32, v: i32) -> Option<[f64; 3]> {
    let mut attempts = 0;
    loop {
        let pos = default(t, h, v)?;
        if swimmable_at(t, pos) || attempts >= 10 {
            return Some(pos);
        }
        attempts += 1;
    }
}

const SWIM_TIERS: [(i32, i32); 6] = [(1, 1), (3, 3), (5, 5), (6, 5), (7, 7), (10, 7)];

/// `RandomStroll.getTargetSwimPos`: a swimmable target one block off, then
/// each farther tier along the way to the last, stopping at the last
/// target in water within its home.
pub fn swim_target(t: &mut Turn) -> Option<[f64; 3]> {
    let mut fallback: Option<[f64; 3]> = None;
    for (h, v) in SWIM_TIERS {
        let target = match fallback {
            None => swimmable(t, h, v),
            Some(fb) => Some(along(
                t,
                [fb[0] - t.x(), fb[1] - t.y(), fb[2] - t.z()],
                h,
                v,
            )),
        };
        let Some(target) = target else {
            break;
        };
        let cell = fmath::block(target);
        if t.level.fluid(cell) == FluidKind::Empty || (restricted(t, h) && !within_home(t, cell)) {
            break;
        }
        fallback = Some(target);
    }
    fallback
}

// `position.add(vectorTo(fallback).normalize().multiply(h, v, h))`.
fn along(t: &Turn, [dx, dy, dz]: [f64; 3], h: i32, v: i32) -> [f64; 3] {
    let d = (dx * dx + dy * dy + dz * dz).sqrt();
    if d < f(1.0e-5) {
        t.pos()
    } else {
        [
            t.x() + dx / d * h as f64,
            t.y() + dy / d * v as f64,
            t.z() + dz / d * h as f64,
        ]
    }
}

// `isPathfindable(PathComputationType.WATER)` of the block holding `pos`.
fn swimmable_at(t: &Turn, pos: [f64; 3]) -> bool {
    t.level.block(fmath::block(pos)).is_some_and(|s| {
        t.paths
            .flags
            .get(s as usize)
            .is_some_and(|f| f & SWIMMABLE != 0)
    })
}

/// `LandRandomPos.getPos(mob, h, v)`.
pub fn land(t: &mut Turn, h: i32, v: i32) -> Option<[f64; 3]> {
    land_weighted(t, h, v, walk_value)
}

/// `LandRandomPos.getPos(mob, h, v, weight)`: the candidates weighed by
/// `weight` in place of the walk target value.
pub fn land_weighted(
    t: &mut Turn,
    h: i32,
    v: i32,
    weight: impl Fn(&mut Turn, [i32; 3]) -> f64,
) -> Option<[f64; 3]> {
    let restrict = restricted(t, h);
    best(t, weight, |t| {
        let d = direction(t, h, v);
        let pos = toward(t, h, d, true, restrict)?;
        out_of_solid(t, pos)
    })
}

/// `LandRandomPos.getPosAway(mob, h, v, from)`.
pub fn land_away(t: &mut Turn, h: i32, v: i32, from: [f64; 3]) -> Option<[f64; 3]> {
    let (dx, dy, dz) = (t.x() - from[0], t.y() - from[1], t.z() - from[2]);
    let (dx, dz) = if dx * dx + dy * dy + dz * dz == 0.0 {
        let a = t.double();
        let b = t.double();
        (a - 0.5, b - 0.5)
    } else {
        (dx, dz)
    };
    land_in_direction(t, h, v, dx, dz)
}

/// `LandRandomPos.getPosTowards(mob, h, v, towards)`.
pub fn land_towards(t: &mut Turn, h: i32, v: i32, towards: [f64; 3]) -> Option<[f64; 3]> {
    let (dx, dz) = (towards[0] - t.x(), towards[2] - t.z());
    land_in_direction(t, h, v, dx, dz)
}

// `getPosInDirection`: within a quarter turn of the direction.
fn land_in_direction(t: &mut Turn, h: i32, v: i32, dx: f64, dz: f64) -> Option<[f64; 3]> {
    let restrict = restricted(t, h);
    best(t, walk_value, |t| {
        let d = within(t, 0.0, h as f64, v, dx, dz, HALF_PI)?;
        let pos = toward(t, h, d, true, restrict)?;
        out_of_solid(t, pos)
    })
}

// `generateRandomPos`: ten draws, the first of the best value.
fn best(
    t: &mut Turn,
    weight: impl Fn(&mut Turn, [i32; 3]) -> f64,
    mut candidate: impl FnMut(&mut Turn) -> Option<[i32; 3]>,
) -> Option<[f64; 3]> {
    let mut best = None;
    let mut value = f64::NEG_INFINITY;
    for _ in 0..10 {
        if let Some(pos) = candidate(t) {
            let v = weight(t, pos);
            // A place worth negative infinity is never taken.
            if v != f64::NEG_INFINITY && (value == f64::NEG_INFINITY || v > value) {
                best = Some(pos);
                value = v;
            }
        }
    }
    best.map(|[x, y, z]| [x as f64 + 0.5, y as f64, z as f64 + 0.5])
}

// `generateRandomDirection`.
fn direction(t: &mut Turn, h: i32, v: i32) -> Direction {
    let xt = t.int(2 * h + 1);
    let yt = t.int(2 * v + 1);
    let zt = t.int(2 * h + 1);
    [xt - h, yt - v, zt - h]
}

// `generateRandomDirectionWithinRadians`.
fn within(
    t: &mut Turn,
    min: f64,
    max: f64,
    v: i32,
    xd: f64,
    zd: f64,
    radians: f64,
) -> Option<Direction> {
    let center = fmath::atan2(zd, xd) - HALF_PI;
    let r = t.float();
    let angle = center + f(f(2.0 * r) - 1.0) * radians;
    let d = t.double();
    let distance = (min + d.sqrt() * (max - min)) * SQRT2;
    let (sin, cos) = fmath::java_sin_cos(angle);
    let xt = -distance * sin;
    let zt = distance * cos;
    if xt.abs() > max || zt.abs() > max {
        return None;
    }
    let yt = t.int(2 * v + 1);
    Some([fmath::floor(xt), yt - v, fmath::floor(zt)])
}

// `generateRandomPosTowardDirection` (leaning toward a home) and the checks
// of `DefaultRandomPos` (malus) or `LandRandomPos` (none here).
fn toward(
    t: &mut Turn,
    h: i32,
    [xt, yt, zt]: Direction,
    land: bool,
    restrict: bool,
) -> Option<[i32; 3]> {
    let (xt, zt) = lean(t, h as f64, xt, zt);
    let pos = [
        fmath::floor(xt + t.x()),
        fmath::floor(yt as f64 + t.y()),
        fmath::floor(zt + t.z()),
    ];
    let ok = !t.level.outside(pos)
        && !(restrict && !within_home(t, pos))
        && stable_destination(t, pos)
        && (land || !malus(t, pos));
    ok.then_some(pos)
}

fn lean(t: &mut Turn, h: f64, xt: i32, zt: i32) -> (f64, f64) {
    let home = t.mob.body.mob.home.as_ref().map(|h| h.center);
    match home {
        Some([hx, _, hz]) if h > 1.0 => {
            let a = t.double();
            let xt = if t.x() > hx as f64 {
                xt as f64 - a * h / 2.0
            } else {
                xt as f64 + a * h / 2.0
            };
            let b = t.double();
            let zt = if t.z() > hz as f64 {
                zt as f64 - b * h / 2.0
            } else {
                zt as f64 + b * h / 2.0
            };
            (xt, zt)
        }
        _ => (xt as f64, zt as f64),
    }
}

// `GoalUtils.mobRestricted`: a home whose centre is near the mob.
fn restricted(t: &Turn, h: i32) -> bool {
    match &t.mob.body.mob.home {
        Some(home) => {
            let [hx, hy, hz] = home.center;
            let d = [
                hx as f64 + 0.5 - t.x(),
                hy as f64 + 0.5 - t.y(),
                hz as f64 + 0.5 - t.z(),
            ];
            let r = home.radius as f64 + h as f64 + 1.0;
            d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < r * r
        }
        None => false,
    }
}

/// `Mob.isWithinHome(BlockPos)`: no home, or within its radius.
pub fn within_home(t: &Turn, [x, y, z]: [i32; 3]) -> bool {
    match &t.mob.body.mob.home {
        None => true,
        Some(home) => {
            let [hx, hy, hz] = home.center.map(|v| v as i64);
            let (x, y, z) = (x as i64, y as i64, z as i64);
            let r = home.radius as i64;
            (hx - x) * (hx - x) + (hy - y) * (hy - y) + (hz - z) * (hz - z) < r * r
        }
    }
}

// `LandRandomPos.movePosUpOutOfSolid`, then not into water or malus.
fn out_of_solid(t: &Turn, pos: [i32; 3]) -> Option<[i32; 3]> {
    let level = &*t.level;
    let [x, y, z] = pos;
    let pos = if level.solid(pos) {
        let up = (y + 1..=level.max_y).find(|&u| !level.solid([x, u, z]));
        [x, up.unwrap_or(level.max_y + 1), z]
    } else {
        pos
    };
    if level.fluid(pos) == FluidKind::Water || malus(t, pos) {
        None
    } else {
        Some(pos)
    }
}

// `PathNavigation.isStableDestination` (a family's own navigation may judge).
fn stable_destination(t: &Turn, pos: [i32; 3]) -> bool {
    if let Some(stable) = t.hooks.stable_destination(t, pos) {
        return stable;
    }
    let [x, y, z] = pos;
    match t.mind.navigation.kind {
        NavKind::Water => !t.level.solid_render(pos),
        NavKind::Fly | NavKind::Amphibious => !t.level.air([x, y - 1, z]),
        NavKind::Ground => t.level.solid_render([x, y - 1, z]),
    }
}

/// `GoalUtils.hasMalus`: the mob's malus for the block's path type is not 0.
pub fn malus(t: &Turn, pos: [i32; 3]) -> bool {
    malus_of(t, static_type(t.level, t.paths, pos)) != 0.0
}

/// `Mob.getPathfindingMalus`.
pub fn malus_of(t: &Turn, kind: u8) -> f64 {
    t.facts.malus.get(kind as usize).copied().unwrap_or(0.0)
}

// An unreadable block blocks.
fn path_type(level: &Level, paths: &crate::path::PathFacts, pos: [i32; 3]) -> u8 {
    match level.block(pos) {
        None => types::BLOCKED,
        Some(s) => paths
            .types
            .get(s as usize)
            .copied()
            .unwrap_or(types::BLOCKED),
    }
}

/// `WalkNodeEvaluator.getPathTypeStatic`: an open block over ground is
/// walkable, or what borders it (danger, fire, water) taints it.
pub fn static_type(level: &Level, paths: &crate::path::PathFacts, pos: [i32; 3]) -> u8 {
    let [x, y, z] = pos;
    let kind = path_type(level, paths, pos);
    if kind != types::OPEN || y < level.min_y + 1 {
        return kind;
    }
    match path_type(level, paths, [x, y - 1, z]) {
        types::OPEN | types::WATER | types::LAVA | types::WALKABLE => types::OPEN,
        types::FIRE => types::FIRE,
        types::DAMAGING => types::DAMAGING,
        types::STICKY_HONEY => types::STICKY_HONEY,
        types::POWDER_SNOW => types::ON_TOP_OF_POWDER_SNOW,
        types::DAMAGE_CAUTIOUS => types::DAMAGE_CAUTIOUS,
        types::TRAPDOOR => types::ON_TOP_OF_TRAPDOOR,
        _ => neighbours(level, paths, pos),
    }
}

fn neighbours(level: &Level, paths: &crate::path::PathFacts, [x, y, z]: [i32; 3]) -> u8 {
    for dx in -1..=1 {
        for dy in -1..=1 {
            for dz in -1..=1 {
                if dx == 0 && dz == 0 {
                    continue;
                }
                match path_type(level, paths, [x + dx, y + dy, z + dz]) {
                    types::DAMAGING => return types::DAMAGING_IN_NEIGHBOR,
                    types::FIRE | types::LAVA => return types::FIRE_IN_NEIGHBOR,
                    types::WATER => return types::WATER_BORDER,
                    types::DAMAGE_CAUTIOUS => return types::DAMAGE_CAUTIOUS,
                    _ => {}
                }
            }
        }
    }
    types::WALKABLE
}

/// `getWalkTargetValue` at a block for the mob's family.
pub fn walk_value(t: &mut Turn, pos: [i32; 3]) -> f64 {
    let hooks = t.hooks;
    match hooks.walk_value(t, pos) {
        Some(v) => v,
        None => family_value(t, pos),
    }
}

/// `PathfinderMob`'s, `Animal`'s or `Monster`'s walk target value.
pub fn family_value(t: &Turn, pos: [i32; 3]) -> f64 {
    let level = &*t.level;
    let [x, y, z] = pos;
    let below = level.block([x, y - 1, z]);
    let on = |name: &str| below.is_some_and(|s| level.facts.blocks.is(s, name));
    let light = || f(level.light(pos) as f64 - 0.5);
    if level.facts.entities.id("minecraft:mooshroom") == Some(t.type_id) {
        if on("mycelium") {
            10.0
        } else {
            light()
        }
    } else if level.facts.animal.animal(t.type_id) {
        if on("grass_block") {
            10.0
        } else {
            light()
        }
    } else if level.facts.ai.mob(t.type_id).is_some_and(|m| m.monster) {
        -light()
    } else {
        0.0
    }
}
