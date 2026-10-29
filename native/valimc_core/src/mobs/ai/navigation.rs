//! Vanilla's `PathNavigation` and its kinds (`Valimc.AI.Navigation`):
//! ground (`GroundPathNavigation`: targets raised to their surface, the sun
//! avoided, cauldron nodes raised), water-bound, flying, amphibious and the
//! wall climber's. A path comes from vanilla's search (`paths`), run at once
//! in process, and is followed node by node into the move control's wanted
//! position, cutting corners where vanilla does, with stuck detection (too
//! little progress in 100 ticks), the node timeout (three times the time the
//! mob's speed needs) and recomputation (at most once in 20 ticks).
//!
//! The Elixir also defers searches to an owner job (`:deferred`, pending
//! paths, `receive/1`); the native turn always searches at once, so a path
//! is never pending.

use super::fmath::{self, f};
use super::paths::{self, bottom_center, NavPath};
use super::shapes::{self, Fluids};
use super::turn::{Seen, Turn};
use crate::mobs::level::{FluidKind, Level};
use crate::path::Evaluator;
use crate::physics::table::Entry;

/// A navigation's kind (`createNavigation`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NavKind {
    Ground,
    Water,
    Fly,
    Amphibious,
}

/// `PathNavigation`'s state.
#[derive(Clone, Debug, PartialEq)]
pub struct Navigation {
    pub path: Option<NavPath>,
    pub speed: f64,
    pub tick: i64,
    pub last_stuck_check: i64,
    pub last_stuck_pos: [f64; 3],
    pub timeout_node: [i32; 3],
    pub timeout_timer: i64,
    pub last_timeout_check: i64,
    pub timeout_limit: f64,
    pub target: Option<[i32; 3]>,
    pub reach: i32,
    pub stuck: bool,
    pub delayed: bool,
    pub last_recompute: i64,
    pub requests: i64,
    pub kind: NavKind,
    pub evaluator: Evaluator,
    pub can_float: bool,
    pub can_open_doors: bool,
    pub can_pass_doors: bool,
    pub can_walk_over_fences: bool,
    /// `GroundPathNavigation.setAvoidSun`.
    pub avoid_sun: bool,
    /// `WallClimberNavigation`: where its last path went.
    pub climber: bool,
    pub climb_to: Option<[i32; 3]>,
    pub required_length: f64,
}

impl Default for Navigation {
    /// `%Navigation{}`.
    fn default() -> Navigation {
        Navigation {
            path: None,
            speed: 0.0,
            tick: 0,
            last_stuck_check: 0,
            last_stuck_pos: [0.0; 3],
            timeout_node: [0; 3],
            timeout_timer: 0,
            last_timeout_check: 0,
            timeout_limit: 0.0,
            target: None,
            reach: 0,
            stuck: false,
            delayed: false,
            last_recompute: 0,
            requests: 0,
            kind: NavKind::Ground,
            evaluator: Evaluator::Walk,
            can_float: false,
            can_open_doors: false,
            can_pass_doors: true,
            can_walk_over_fences: false,
            avoid_sun: false,
            climber: false,
            climb_to: None,
            required_length: 16.0,
        }
    }
}

impl Navigation {
    /// `Navigation.new/2`: a navigation of `kind` (`breaching`: a swimmer's
    /// `allowBreaching`); the other options are its fields.
    pub fn new(kind: NavKind, breaching: bool) -> Navigation {
        let evaluator = match kind {
            NavKind::Ground => Evaluator::Walk,
            NavKind::Water => Evaluator::Swim { breaching },
            NavKind::Fly => Evaluator::Fly,
            NavKind::Amphibious => Evaluator::Amphibious { shallow: false },
        };
        Navigation {
            kind,
            evaluator,
            can_pass_doors: kind != NavKind::Water,
            ..Navigation::default()
        }
    }

    /// `isDone`: no path, or every node reached.
    pub fn done(&self) -> bool {
        self.path.as_ref().is_none_or(NavPath::done)
    }

    // `found`: a found path's target resets the stuck timeout.
    fn found(&mut self, target: [i32; 3], reach: i32) {
        self.target = Some(target);
        self.reach = reach;
        self.timeout_node = [0; 3];
        self.timeout_timer = 0;
        self.timeout_limit = 0.0;
        self.stuck = false;
    }

    fn advance(&mut self) {
        if let Some(p) = &mut self.path {
            p.index += 1;
        }
    }
}

fn nav<'a>(t: &'a mut Turn) -> &'a mut Navigation {
    &mut t.mind.navigation
}

/// `stop`.
pub fn stop(t: &mut Turn) {
    nav(t).path = None;
}

/// `setSpeedModifier`.
pub fn set_speed(t: &mut Turn, speed: f64) {
    nav(t).speed = speed;
}

/// `setCanFloat` (water-bound and amphibious navigations ignore it).
pub fn can_float(t: &mut Turn) {
    let n = nav(t);
    if !matches!(n.kind, NavKind::Water | NavKind::Amphibious) {
        n.can_float = true;
    }
}

/// `GroundPathNavigation.setAvoidSun`.
pub fn avoid_sun(t: &mut Turn, avoid: bool) {
    nav(t).avoid_sun = avoid;
}

/// `moveTo(x, y, z, speed)`: a path to the block holding the point, reach 1.
pub fn move_to(t: &mut Turn, point: [f64; 3], speed: f64) -> bool {
    let path = path_to(t, point, 1);
    follow(t, path, speed)
}

/// `moveTo(entity, speed)`: a path to the entity (none keeps the old one; a
/// climber heads for the target's block anyway).
pub fn move_to_entity(t: &mut Turn, target: &Seen, speed: f64, reach: i32) -> bool {
    match path_to_entity(t, target, reach) {
        None => {
            if nav(t).climber {
                let n = nav(t);
                n.climb_to = Some(fmath::block(target.position));
                n.speed = speed;
                true
            } else {
                false
            }
        }
        path => follow(t, path, speed),
    }
}

/// `createPath(entity, reach)`: ground and flying navigations path to its
/// block; the others from a block above the mob, sixteen blocks wider.
pub fn path_to_entity(t: &mut Turn, target: &Seen, reach: i32) -> Option<NavPath> {
    let block = fmath::block(target.position);
    climbing_to(t, block);
    if matches!(nav(t).kind, NavKind::Ground | NavKind::Fly) {
        path_to_block(t, block, reach)
    } else {
        create(t, vec![block], 16, true, reach)
    }
}

/// `createPath(targets, reach)` of a set of blocks (no surface raise).
pub fn path_to_any(t: &mut Turn, targets: Vec<[i32; 3]>, reach: i32) -> Option<NavPath> {
    create(t, targets, 8, false, reach)
}

/// `createPath(x, y, z, reach)`.
pub fn path_to(t: &mut Turn, point: [f64; 3], reach: i32) -> Option<NavPath> {
    let block = fmath::block(point);
    climbing_to(t, block);
    path_to_block(t, block, reach)
}

// `WallClimberNavigation.createPath`: it remembers where the path went.
fn climbing_to(t: &mut Turn, block: [i32; 3]) {
    let n = nav(t);
    if n.climber {
        n.climb_to = Some(block);
    }
}

// `createPath(pos, reach)`: a ground navigation raises the target to its
// surface (none where its chunk cannot be read).
fn path_to_block(t: &mut Turn, target: [i32; 3], reach: i32) -> Option<NavPath> {
    if nav(t).kind == NavKind::Ground {
        if t.level.block(target).is_none() {
            None
        } else {
            let surface = surface(t.level, target);
            create(t, vec![surface], 8, false, reach)
        }
    } else {
        create(t, vec![target], 8, false, reach)
    }
}

// `PathNavigation.createPath(targets, offset, above, reach)`.
fn create(
    t: &mut Turn,
    targets: Vec<[i32; 3]>,
    offset: i32,
    above: bool,
    reach: i32,
) -> Option<NavPath> {
    if targets.is_empty() || t.y() < t.level.min_y as f64 || !updatable(t) {
        return None;
    }
    let n = &t.mind.navigation;
    if n.path.is_some() && !n.done() && n.target.is_some_and(|g| targets.contains(&g)) {
        return n.path.clone();
    }
    let request = paths::request(t, targets, offset, above, reach);
    let (path, random) = paths::find(t, &request);
    if let Some(r) = crate::mobs::random::LegacyRandom::from_state(random) {
        t.random = r;
    }
    if let Some(p) = &path {
        nav(t).found(p.target, reach);
    }
    path
}

/// `moveTo(path, speed)`: whether it follows a path now.
pub fn follow(t: &mut Turn, path: Option<NavPath>, speed: f64) -> bool {
    let Some(path) = path else {
        nav(t).path = None;
        return false;
    };
    let n = nav(t);
    if n.path.as_ref().is_none_or(|old| old.nodes != path.nodes) {
        n.path = Some(path);
    }
    if n.done() {
        return false;
    }
    let mut path = n.path.take().expect("a path that is not done");
    trim(t.level, &mut path);
    sun(t, &mut path);
    nav(t).path = Some(path);
    let position = temp_position(t);
    let n = nav(t);
    n.speed = speed;
    n.last_stuck_check = n.tick;
    n.last_stuck_pos = position;
    true
}

// `findSurfacePosition`: down to the first non-air below an air target (up
// past air above when there is none), then up past solid blocks.
fn surface(level: &Level, target: [i32; 3]) -> [i32; 3] {
    let [x, y, z] = target;
    let mut target = target;
    if level.air(target) {
        target = match (level.min_y..y).rev().find(|&b| !level.air([x, b, z])) {
            Some(below) => [x, below + 1, z],
            None => {
                let up = (y + 1..=level.max_y).find(|&u| !level.air([x, u, z]));
                [x, up.unwrap_or(level.max_y + 1), z]
            }
        };
    }
    let [x, y, z] = target;
    if level.solid(target) {
        let up = (y + 1..=level.max_y).find(|&u| !level.solid([x, u, z]));
        [x, up.unwrap_or(level.max_y + 1), z]
    } else {
        target
    }
}

fn cauldron(level: &Level, state: Option<u16>) -> bool {
    let Some(state) = state else {
        return false;
    };
    let blocks = &level.facts.blocks;
    [
        "cauldron",
        "water_cauldron",
        "lava_cauldron",
        "powder_snow_cauldron",
    ]
    .iter()
    .any(|name| blocks.is(state, name))
}

// `trimPath`: a node in a cauldron stands on its rim, and the node after it
// no lower than that.
fn trim(level: &Level, path: &mut NavPath) {
    for i in 0..path.nodes.len() {
        let [x, y, z] = path.nodes[i];
        if cauldron(level, level.block([x, y, z])) {
            path.nodes[i] = [x, y + 1, z];
            if i + 1 < path.nodes.len() && y >= path.nodes[i + 1][1] {
                let [nx, _, nz] = path.nodes[i + 1];
                // `cloneAndMove` of the cauldron's node: its type goes along.
                path.nodes[i + 1] = [nx, y + 1, nz];
                path.types[i + 1] = path.types[i];
            }
        }
    }
}

// `GroundPathNavigation.trimPath` avoiding the sun: from the shade, the path
// ends before its first node under the open sky.
fn sun(t: &Turn, path: &mut NavPath) {
    if !t.mind.navigation.avoid_sun {
        return;
    }
    let at = [
        fmath::floor(t.x()),
        fmath::floor(t.y() + 0.5),
        fmath::floor(t.z()),
    ];
    if t.level.sees_sky(at) {
        return;
    }
    if let Some(i) = path.nodes.iter().position(|&n| t.level.sees_sky(n)) {
        path.nodes.truncate(i);
        path.types.truncate(i);
    }
}

/// `PathNavigation.tick`: recompute a delayed path, follow the path and set
/// the move control's wanted position at the next node's floor.
pub fn tick(t: &mut Turn) {
    let n = &t.mind.navigation;
    if n.climber && n.done() {
        climb(t);
    } else {
        ground_tick(t);
    }
}

// `WallClimberNavigation.tick` with no path left: straight for where the
// path went until within its width of that block's centre (or above it).
fn climb(t: &mut Turn) {
    let Some([bx, by, bz]) = t.mind.navigation.climb_to else {
        return;
    };
    let near = |t: &Turn, [x, y, z]: [i32; 3]| {
        let d = [
            x as f64 + 0.5 - t.x(),
            y as f64 + 0.5 - t.y(),
            z as f64 + 0.5 - t.z(),
        ];
        d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < t.width * t.width
    };
    if !near(t, [bx, by, bz]) && (t.y() <= by as f64 || !near(t, [bx, fmath::floor(t.y()), bz])) {
        let speed = t.mind.navigation.speed;
        t.move_to([bx as f64, by as f64, bz as f64], speed);
    } else {
        nav(t).climb_to = None;
    }
}

fn ground_tick(t: &mut Turn) {
    let n = nav(t);
    n.tick += 1;
    if n.delayed {
        recompute(t);
    }
    if t.mind.navigation.done() {
        return;
    }
    if t.mind.navigation.kind == NavKind::Fly {
        fly_tick(t);
        return;
    }
    if updatable(t) {
        follow_path(t);
    } else {
        airborne(t);
    }
    let n = &t.mind.navigation;
    if let (false, Some(path)) = (n.done(), &n.path) {
        let [x, y, z] = entity_position(t, path);
        let ground = ground_y(t, [x, y, z]);
        let speed = t.mind.navigation.speed;
        t.move_to([x, ground, z], speed);
    }
}

// `FlyingPathNavigation.tick`: a node is reached in its block while flying
// cannot update the path, and the wanted position is the node's.
fn fly_tick(t: &mut Turn) {
    if updatable(t) {
        follow_path(t);
    } else if let Some(path) = &t.mind.navigation.path {
        let p = entity_position(t, path);
        if t.block() == fmath::block(p) {
            nav(t).advance();
        }
    }
    let n = &t.mind.navigation;
    if let (false, Some(path)) = (n.done(), &n.path) {
        let p = entity_position(t, path);
        let speed = n.speed;
        t.move_to(p, speed);
    }
}

// `recomputePath`: at most once in 20 ticks and only while the path can
// update, else delayed.
fn recompute(t: &mut Turn) {
    let time = t.level.time;
    let n = &t.mind.navigation;
    if time - n.last_recompute <= 20 || !updatable(t) {
        nav(t).delayed = true;
    } else if let Some(target) = n.target {
        let reach = n.reach;
        nav(t).path = None;
        let path = path_to_block(t, target, reach);
        let n = nav(t);
        n.path = path;
        n.last_recompute = time;
        n.delayed = false;
    }
}

// Off the ground and out of liquid: a node passed over is reached.
fn airborne(t: &mut Turn) {
    let m = temp_position(t);
    let Some(path) = &t.mind.navigation.path else {
        return;
    };
    let p = entity_position(t, path);
    if m[1] > p[1]
        && !t.on_ground()
        && fmath::floor(m[0]) == fmath::floor(p[0])
        && fmath::floor(m[2]) == fmath::floor(p[2])
    {
        nav(t).advance();
    }
}

// `followThePath`.
fn follow_path(t: &mut Turn) {
    let position = temp_position(t);
    let width = t.width;
    let max_distance = if width > 0.75 {
        f(width / 2.0)
    } else {
        f(0.75 - f(width / 2.0))
    };
    let n = &t.mind.navigation;
    let path = n.path.as_ref().expect("a path being followed");
    let [nx, ny, nz] = path.nodes[path.index];
    let vertical = if n.kind == NavKind::Water { 0.5 } else { 1.0 };
    let close = (t.x() - (nx as f64 + 0.5)).abs() < max_distance
        && (t.z() - (nz as f64 + 0.5)).abs() < max_distance
        && (t.y() - ny as f64).abs() < vertical;
    if close || (paths::cut_corner(path.types[path.index]) && toward_next(t, path, position)) {
        nav(t).advance();
    }
    stuck_detection(t, position);
}

// `shouldTargetNextNodeInDirection`.
fn toward_next(t: &Turn, path: &NavPath, position: [f64; 3]) -> bool {
    if path.index + 1 >= path.nodes.len() {
        return false;
    }
    let current = bottom_center(path.nodes[path.index]);
    if fmath::distance_sq(position, current) >= 4.0 {
        return false;
    }
    if can_move_directly(t, position, entity_position(t, path)) {
        return true;
    }
    let next = bottom_center(path.nodes[path.index + 1]);
    let to_current = sub(current, position);
    let to_next = sub(next, position);
    let current_sq = dot(to_current, to_current);
    let closer = dot(to_next, to_next) < current_sq;
    if !closer && current_sq >= 0.5 {
        false
    } else {
        dot(normalize(to_next), normalize(to_current)) < 0.0
    }
}

// `canMoveDirectly`: a ground navigation never; others when a collider ray
// (through fluids for a flier) clears from the mob to half its height over
// the next node (an amphibian only in a liquid).
fn can_move_directly(t: &Turn, from: [f64; 3], [x, y, z]: [f64; 3]) -> bool {
    let fluids = match t.mind.navigation.kind {
        NavKind::Ground => None,
        NavKind::Fly => Some(Fluids::Any),
        NavKind::Water => Some(Fluids::None),
        NavKind::Amphibious => t.in_liquid().then_some(Fluids::None),
    };
    fluids
        .is_some_and(|fluids| shapes::ray_misses(t.level, from, [x, y + t.height * 0.5, z], fluids))
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

// `Vec3.normalize`: below 1e-5F long, zero.
fn normalize(v: [f64; 3]) -> [f64; 3] {
    let length = dot(v, v).sqrt();
    if length < 9.999999747378752e-6 {
        [0.0; 3]
    } else {
        [v[0] / length, v[1] / length, v[2] / length]
    }
}

fn stuck_detection(t: &mut Turn, position: [f64; 3]) {
    let speed = t.speed();
    let time = t.level.time;
    let n = nav(t);
    if n.tick - n.last_stuck_check > 100 {
        let effective = if speed >= 1.0 {
            speed
        } else {
            f(speed * speed)
        };
        let threshold = f(f(effective * 100.0) * 0.25);
        if fmath::distance_sq(position, n.last_stuck_pos) < f(threshold * threshold) {
            n.stuck = true;
            n.path = None;
        } else {
            n.stuck = false;
        }
        n.last_stuck_check = n.tick;
        n.last_stuck_pos = position;
    }
    if n.path.is_some() && !n.done() {
        let path = n.path.as_ref().expect("a path");
        let node = path.nodes[path.index];
        if node == n.timeout_node {
            n.timeout_timer += time - n.last_timeout_check;
        } else {
            let distance = fmath::distance_sq(position, bottom_center(node)).sqrt();
            let limit = if speed > 0.0 {
                distance / speed * 20.0
            } else {
                0.0
            };
            n.timeout_node = node;
            n.timeout_limit = limit;
        }
        if n.timeout_limit > 0.0 && (n.timeout_timer as f64) > n.timeout_limit * 3.0 {
            n.timeout_node = [0; 3];
            n.timeout_timer = 0;
            n.timeout_limit = 0.0;
            n.stuck = false;
            n.path = None;
        }
        n.last_timeout_check = time;
    }
}

/// `getPath().getNextEntityPos(mob)` of an unfinished path.
pub fn next_entity_position(t: &Turn) -> Option<[f64; 3]> {
    let path = t.mind.navigation.path.as_ref()?;
    (path.index < path.nodes.len()).then(|| entity_position(t, path))
}

// `Path.getNextEntityPos`: the node's corner plus half the mob's rounded-up
// width.
fn entity_position(t: &Turn, path: &NavPath) -> [f64; 3] {
    let [x, y, z] = path.nodes[path.index];
    let offset = (f(t.width + 1.0) as i64) as f64 * 0.5;
    [x as f64 + offset, y as f64, z as f64 + offset]
}

// `getGroundY`: over air the point's own height, else the floor below it;
// water-bound and amphibious navigations keep the node's height.
fn ground_y(t: &Turn, [x, y, z]: [f64; 3]) -> f64 {
    let [bx, by, bz] = fmath::block([x, y, z]);
    if matches!(t.mind.navigation.kind, NavKind::Water | NavKind::Amphibious)
        || t.level.air([bx, by - 1, bz])
    {
        y
    } else {
        floor_level(t.level, [bx, by, bz])
    }
}

/// `WalkNodeEvaluator.getFloorLevel`: the top of the collision shape below.
pub fn floor_level(level: &Level, [x, y, z]: [i32; 3]) -> f64 {
    let below = y - 1;
    let top = level.block([x, below, z]).map_or(0.0, |s| top(level, s));
    below as f64 + top
}

fn top(level: &Level, state: u16) -> f64 {
    let table = &level.physics.shapes;
    let entry = table
        .states
        .get(state as usize)
        .and_then(|&e| table.entries.get(e as usize));
    match entry {
        Some(Entry::Fixed(i) | Entry::Offset(i, _)) => table.shapes[*i]
            .cells()
            .iter()
            .map(|b| b.max[1])
            .fold(None, |m: Option<f64>, v| {
                Some(m.map_or(v, |m| fmath::emax(m, v)))
            })
            .unwrap_or(0.0),
        _ => 0.0,
    }
}

// `getTempMobPos`: a ground navigation's the surface of the water it floats
// in, else its feet raised half a block; water-bound and amphibious its
// middle; a flier its position.
fn temp_position(t: &Turn) -> [f64; 3] {
    match t.mind.navigation.kind {
        NavKind::Ground => {
            let y = if t.in_water() && t.mind.navigation.can_float {
                surface_y(t)
            } else {
                fmath::floor(t.y() + 0.5)
            };
            [t.x(), y as f64, t.z()]
        }
        NavKind::Fly => t.pos(),
        _ => [t.x(), t.y() + t.height * 0.5, t.z()],
    }
}

fn surface_y(t: &Turn) -> i32 {
    let start = fmath::floor(t.y());
    let (x, z) = (fmath::floor(t.x()), fmath::floor(t.z()));
    let mut y = start;
    let mut steps = 0;
    loop {
        if t.level.fluid([x, y, z]) != FluidKind::Water {
            return y;
        }
        if steps + 1 > 16 {
            return start;
        }
        y += 1;
        steps += 1;
    }
}

// `canUpdatePath`: a ground navigation on the ground or in a liquid; a
// water-bound one breaching or in a liquid; fliers and amphibians always.
fn updatable(t: &Turn) -> bool {
    match t.mind.navigation.kind {
        NavKind::Ground => t.on_ground() || t.in_liquid(),
        NavKind::Water => match t.mind.navigation.evaluator {
            Evaluator::Swim { breaching } => breaching || t.in_liquid(),
            _ => true,
        },
        _ => true,
    }
}
