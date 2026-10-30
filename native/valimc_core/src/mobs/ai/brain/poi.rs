//! The point-of-interest behaviours of the village family
//! (`Valimc.AI.Behaviors.Poi`), as vanilla's `ai.behavior` classes build
//! them: claiming a POI the mob can path to (`AcquirePoi`), forgetting one
//! gone or taken (`ValidateNearbyPoi`), walking to a remembered POI
//! (`SetWalkTargetFromBlockMemory`), strolling near one (`StrollAroundPoi`,
//! `StrollToPoi`, `StrollToPoiList`), and the village-bound walks
//! (`VillageBoundRandomStroll`, `GoToClosestVillage`,
//! `SetClosestHomeAsWalkTarget`).
//!
//! A POI memory is a `Global` (vanilla's `GlobalPos`). `release` gives a
//! memory's ticket back as `Villager.releasePoi` does: the level's claims
//! are the villagers' memories, so erasing the memory is the release.
//! Path searches run at once in process, so the Elixir's deferred answers
//! never wait here.

use super::behavior::{one_shot, Behavior, Trigger};
use super::behaviors::{near_center, walk};
use super::{Cond, Conds, Global, Mem, MemValue, Tracker};
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::navigation;
use crate::mobs::ai::pois::{self, Occupancy};
use crate::mobs::ai::random_pos;
use crate::mobs::ai::turn::Turn;
use crate::mobs::ai::Effect;

use Cond::{Absent, Present, Registered};

/// A POI memory of the mob's dimension at `pos`.
pub fn global(t: &Turn, pos: [i32; 3]) -> Global {
    Global {
        dimension: t.level.dimension.clone(),
        pos,
    }
}

/// The position of a POI memory in the mob's dimension.
pub fn here(t: &Turn, m: Mem) -> Option<[i32; 3]> {
    t.mem_global(m)
        .filter(|g| g.dimension == t.level.dimension)
        .map(|g| g.pos)
}

/// `Villager.releasePoi(memory)`: the claim goes with the memory.
pub fn release(t: &mut Turn, m: Mem) {
    if let Some(g) = t.mem_global(m) {
        pois::release(t.level, g.pos);
        t.forget(m);
    }
}

fn walk_block(pos: [i32; 3], speed: f64, close: i32) -> MemValue {
    walk(Tracker::block(pos), f(speed), close)
}

fn walk_point(p: [f64; 3], speed: f64, close: i32) -> MemValue {
    walk(Tracker::point(p), f(speed), close)
}

fn manhattan(a: [i32; 3], b: [i32; 3]) -> i32 {
    (a[0] - b[0]).abs() + (a[1] - b[1]).abs() + (a[2] - b[2]).abs()
}

/// The POI types a behaviour searches: fixed, or of the mob's profession
/// (its family's).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Types {
    Fixed(&'static [&'static str]),
    /// Its profession's acquirable job sites.
    Acquirable,
    /// Its profession's held job sites.
    Held,
}

impl Types {
    pub fn of(&self, t: &Turn) -> Vec<String> {
        let profession = || {
            let name = t
                .data()
                .get("profession")
                .and_then(|v| v.as_binary())
                .and_then(|b| std::str::from_utf8(b).ok())
                .unwrap_or("minecraft:none");
            t.level.facts.village.profession(name)
        };
        match self {
            Types::Fixed(list) => list.iter().map(|s| s.to_string()).collect(),
            Types::Acquirable => profession()
                .map(|p| p.acquirable.clone())
                .unwrap_or_default(),
            Types::Held => profession().map(|p| p.held.clone()).unwrap_or_default(),
        }
    }
}

// ## AcquirePoi

/// A POI's retry marker (`JitteredLinearRetry`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Retry {
    previous: i64,
    next: i64,
    delay: i64,
}

/// `AcquirePoi.create(types, validate, acquire, onlyIfAdult, event,
/// valid)`: every 20 to 40 ticks, the five nearest POIs of `types` with a
/// ticket free (each skipped while its retry marker waits) that `valid`
/// accepts, and a path to any of them: reached, the mob takes the one it
/// reaches and remembers it in `acquire`. A failed search marks each for a
/// retry later (40 to 80 ticks more each time, at most 400).
#[derive(Clone, Debug, PartialEq)]
pub struct Acquire {
    pub types: Types,
    pub validate: Mem,
    pub acquire: Mem,
    pub adult: bool,
    pub event: Option<i32>,
    /// A free bed (`validateBedPoi`) where true.
    pub bed: bool,
    next: i64,
    cache: Vec<([i32; 3], Retry)>,
}

pub fn acquire(
    types: Types,
    validate: Mem,
    acquire: Mem,
    adult: bool,
    event: Option<i32>,
    bed: bool,
) -> Box<dyn Behavior> {
    one_shot(Acquire {
        types,
        validate,
        acquire,
        adult,
        event,
        bed,
        next: 0,
        cache: Vec::new(),
    })
}

fn baby(t: &Turn) -> bool {
    t.data().age().is_some_and(|a| a < 0)
}

// `JitteredLinearRetry.markAttempt`.
fn mark(t: &mut Turn, r: Retry, now: i64) -> Retry {
    let n = t.level_int(40) as i64;
    let delay = (r.delay + n + 40).min(400);
    Retry {
        previous: now,
        delay,
        next: now + delay,
    }
}

/// `validateBedPoi`: a bed villagers sleep on that no one lies in.
pub fn free_bed(t: &Turn, pos: [i32; 3]) -> bool {
    match t.level.block(pos) {
        None => false,
        Some(state) => sleeps_on(t, state) && !occupied(t, state),
    }
}

/// Whether villagers sleep on `state` (`VILLAGERS_CAN_SLEEP_ON_BED`).
pub fn sleeps_on(t: &Turn, state: u16) -> bool {
    let facts = t.level.facts;
    facts.blocks.block_id(state).is_some_and(|b| {
        facts.tags.has(
            "minecraft:block",
            "minecraft:villagers_can_sleep_on_bed",
            b as i32,
        )
    })
}

/// A bed state's `occupied`.
pub fn occupied(t: &Turn, state: u16) -> bool {
    t.level.facts.blocks.property(state, "occupied") == Some("true")
}

impl Acquire {
    fn scan(&mut self, t: &mut Turn, types: &[String]) -> bool {
        let now = t.level.time;
        let n = t.level_int(20) as i64;
        self.next = now + 20 + n;
        self.cache.retain(|(_, r)| now - r.previous < 400);
        let refs: Vec<&str> = types.iter().map(String::as_str).collect();
        let center = t.block();
        let found = pois::in_range(t.level, &refs, center, 48, Occupancy::HasSpace);
        // The retry test runs over every POI in range before the nearest
        // are taken.
        let mut kept = Vec::new();
        for (ty, pos) in found {
            match self.cache.iter().position(|(p, _)| *p == pos) {
                Some(i) => {
                    if now >= self.cache[i].1.next {
                        let r = mark(t, self.cache[i].1, now);
                        self.cache[i].1 = r;
                        kept.push((ty, pos));
                    }
                }
                None => kept.push((ty, pos)),
            }
        }
        kept.sort_by_key(|(_, p)| pois::dist_sq(*p, center));
        kept.truncate(5);
        let bed = self.bed;
        let pois: Vec<(String, [i32; 3])> = kept
            .into_iter()
            .filter(|(_, p)| !bed || free_bed(t, *p))
            .collect();
        if pois.is_empty() {
            return true;
        }
        let reach = pois
            .iter()
            .fold(1, |r, (ty, _)| r.max(pois::valid_range(t.level, ty)));
        let path = navigation::path_to_any(t, pois.iter().map(|(_, p)| *p).collect(), reach);
        match path {
            Some(p) if p.reached => self.take(t, p.target),
            _ => self.fail(t, &pois, now),
        }
        true
    }

    // `poiManager.take` of the reached POI, if it still is one.
    fn take(&mut self, t: &mut Turn, target: [i32; 3]) {
        if pois::type_at(t.level, target).is_none() {
            return;
        }
        pois::take(t.level, target);
        let g = global(t, target);
        t.remember(self.acquire, MemValue::Global(g));
        if let Some(e) = self.event {
            t.effect(Effect::Event(e));
        }
        self.cache.clear();
    }

    // Each POI tried gets a retry marker (in the set's order).
    fn fail(&mut self, t: &mut Turn, pois: &[(String, [i32; 3])], now: i64) {
        for (_, pos) in pois {
            if !self.cache.iter().any(|(p, _)| p == pos) {
                let r = mark(
                    t,
                    Retry {
                        previous: 0,
                        next: 0,
                        delay: 0,
                    },
                    now,
                );
                self.cache.push((*pos, r));
            }
        }
    }
}

impl Trigger for Acquire {
    fn conditions(&self) -> Conds {
        if self.validate == self.acquire {
            Conds::new(&[(self.acquire, Absent)])
        } else {
            Conds::new(&[(self.validate, Absent), (self.acquire, Absent)])
        }
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let types = self.types.of(t);
        if self.adult && baby(t) {
            false
        } else if self.next == 0 {
            let n = t.level_int(20) as i64;
            self.next = t.level.time + n;
            false
        } else if t.level.time < self.next {
            false
        } else {
            self.scan(t, &types)
        }
    }
}

// ## ValidateNearbyPoi

/// `ValidateNearbyPoi.create(types, memory)`: within 16 blocks of the
/// remembered POI, forget it when it is no longer of `types`, or when it is
/// a bed someone else lies in (a villager's bed stays claimed).
#[derive(Clone, Debug, PartialEq)]
pub struct Validate {
    pub types: Types,
    pub memory: Mem,
}

pub fn validate(types: Types, memory: Mem) -> Box<dyn Behavior> {
    one_shot(Validate { types, memory })
}

impl Trigger for Validate {
    fn conditions(&self) -> Conds {
        Conds::new(&[(self.memory, Present)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let types = self.types.of(t);
        let Some(pos) = here(t, self.memory) else {
            return false;
        };
        if !near_center(pos, t.pos(), 16.0) {
            return false;
        }
        let ty = pois::type_at(t.level, pos).map(str::to_owned);
        if ty.is_none_or(|ty| !types.contains(&ty)) {
            t.forget(self.memory);
        } else if occupied_bed(t, pos) {
            t.forget(self.memory);
            if !sleeping_villager(t, pos) {
                pois::release(t.level, pos);
            }
        }
        true
    }
}

fn sleeping(t: &Turn) -> bool {
    t.data().get("sleeping").is_some_and(|v| !v.is_nil())
}

fn occupied_bed(t: &Turn, pos: [i32; 3]) -> bool {
    t.level
        .block(pos)
        .is_some_and(|state| sleeps_on(t, state) && occupied(t, state) && !sleeping(t))
}

// `world.mobs`: the villagers as the tick began.
fn sleeping_villager(t: &Turn, [x, y, z]: [i32; 3]) -> bool {
    let villager = t.level.facts.entities.id("minecraft:villager");
    let cell = crate::physics::Aabb::new(
        [x as f64, y as f64, z as f64],
        [x as f64 + 1.0, y as f64 + 1.0, z as f64 + 1.0],
    );
    t.sensing.mobs().iter().any(|m| {
        let s = crate::mobs::ai::Start::of(m);
        Some(m.type_id) == villager
            && s.sleeping
            && crate::mobs::sensing::intersects(&s.bbox, &cell)
    })
}

// ## Walks to and near POIs

/// `SetWalkTargetFromBlockMemory.create(memory, speed, close, tooFar,
/// tooLong)`.
#[derive(Clone, Debug, PartialEq)]
pub struct WalkToMemory {
    pub memory: Mem,
    pub speed: f64,
    pub close: i32,
    pub too_far: i32,
    pub too_long: i64,
}

pub fn walk_to_memory(
    memory: Mem,
    speed: f64,
    close: i32,
    too_far: i32,
    too_long: i64,
) -> Box<dyn Behavior> {
    one_shot(WalkToMemory {
        memory,
        speed,
        close,
        too_far,
        too_long,
    })
}

impl Trigger for WalkToMemory {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::CantReachWalkTargetSince, Registered),
            (Mem::WalkTarget, Absent),
            (self.memory, Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some(g) = t.mem_global(self.memory) else {
            return false;
        };
        let since = t.mem_int(Mem::CantReachWalkTargetSince);
        let now = t.level.time;
        if g.dimension == t.level.dimension && since.is_none_or(|s| now - s <= self.too_long) {
            let distance = manhattan(g.pos, t.block());
            if distance > self.too_far {
                self.step_toward(t, g.pos);
            } else if distance > self.close {
                t.remember(Mem::WalkTarget, walk_block(g.pos, self.speed, self.close));
            }
        } else {
            release(t, self.memory);
            t.remember(Mem::CantReachWalkTargetSince, MemValue::Int(now));
        }
        true
    }
}

impl WalkToMemory {
    fn step_toward(&self, t: &mut Turn, [x, y, z]: [i32; 3]) {
        let towards = [x as f64 + 0.5, y as f64, z as f64 + 0.5];
        let radians = f(std::f64::consts::PI / 2.0);
        for _ in 0..1000 {
            if let Some(point) = random_pos::default_towards(t, 15, 7, towards, radians) {
                if manhattan(fmath::block(point), t.block()) <= self.too_far {
                    t.remember(Mem::WalkTarget, walk_point(point, self.speed, self.close));
                    return;
                }
            }
        }
        release(t, self.memory);
        let now = t.level.time;
        t.remember(Mem::CantReachWalkTargetSince, MemValue::Int(now));
    }
}

fn near(t: &Turn, m: Mem, max: f64) -> Option<[i32; 3]> {
    here(t, m).filter(|&p| near_center(p, t.pos(), max))
}

/// `StrollAroundPoi.create(memory, speed, maxDistance)`: within `max` of the
/// remembered POI, a land walk target 8 blocks around now and then (180
/// ticks apart).
#[derive(Clone, Debug, PartialEq)]
pub struct StrollAround {
    pub memory: Mem,
    pub speed: f64,
    pub max: f64,
    next: i64,
}

pub fn stroll_around(memory: Mem, speed: f64, max: i32) -> StrollAround {
    StrollAround {
        memory,
        speed,
        max: max as f64,
        next: 0,
    }
}

impl Trigger for StrollAround {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Registered), (self.memory, Present)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if near(t, self.memory, self.max).is_none() {
            return false;
        }
        if t.level.time <= self.next {
            return true;
        }
        match random_pos::land(t, 8, 6) {
            Some(p) => t.remember(Mem::WalkTarget, walk_point(p, self.speed, 1)),
            None => t.forget(Mem::WalkTarget),
        }
        self.next = t.level.time + 180;
        true
    }
}

/// `StrollToPoi.create(memory, speed, close, maxDistance)`: back to the POI
/// every 80 ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct StrollTo {
    pub memory: Mem,
    pub speed: f64,
    pub close: i32,
    pub max: f64,
    next: i64,
}

pub fn stroll_to(memory: Mem, speed: f64, close: i32, max: i32) -> Box<dyn Behavior> {
    one_shot(StrollTo {
        memory,
        speed,
        close,
        max: max as f64,
        next: 0,
    })
}

impl Trigger for StrollTo {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Registered), (self.memory, Present)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some(pos) = near(t, self.memory, self.max) else {
            return false;
        };
        if t.level.time > self.next {
            t.remember(Mem::WalkTarget, walk_block(pos, self.speed, self.close));
            self.next = t.level.time + 80;
        }
        true
    }
}

/// `StrollToPoiList.create(listMemory, speed, close, maxDistance, closeTo)`:
/// one of the listed POIs at random, while near `close_to`'s.
#[derive(Clone, Debug, PartialEq)]
pub struct StrollToList {
    pub list: Mem,
    pub speed: f64,
    pub close: i32,
    pub max: f64,
    pub close_to: Mem,
    next: i64,
}

pub fn stroll_to_list(
    list: Mem,
    speed: f64,
    close: i32,
    max: i32,
    close_to: Mem,
) -> Box<dyn Behavior> {
    one_shot(StrollToList {
        list,
        speed,
        close,
        max: max as f64,
        close_to,
        next: 0,
    })
}

impl Trigger for StrollToList {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::WalkTarget, Registered),
            (self.list, Present),
            (self.close_to, Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let targets = match t.memory(self.list) {
            Some(MemValue::Globals(l)) => l.clone(),
            _ => Vec::new(),
        };
        let Some(stay) = t.mem_global(self.close_to) else {
            return false;
        };
        if targets.is_empty() {
            return false;
        }
        let i = t.level_int(targets.len() as i32) as usize;
        let target = &targets[i];
        if target.dimension == t.level.dimension && near_center(stay.pos, t.pos(), self.max) {
            if t.level.time > self.next {
                t.remember(
                    Mem::WalkTarget,
                    walk_block(target.pos, self.speed, self.close),
                );
                self.next = t.level.time + 100;
            }
            true
        } else {
            false
        }
    }
}

// ## Village-bound walks

/// `VillageBoundRandomStroll.create(speed, h, v)`: in a village a land
/// target around; outside it a step toward the nearest section closer to
/// one.
#[derive(Clone, Debug, PartialEq)]
pub struct VillageStroll {
    pub speed: f64,
    pub h: i32,
    pub v: i32,
}

pub fn village_stroll(speed: f64, h: i32, v: i32) -> VillageStroll {
    VillageStroll { speed, h, v }
}

impl Trigger for VillageStroll {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let block = t.block();
        let pos = if pois::village(t.level, block) {
            random_pos::land(t, self.h, self.v)
        } else {
            let section = pois::section(block);
            let closer = pois::closest_village_section(t.level, section, 2);
            if closer != section {
                let [sx, sy, sz] = closer;
                let towards = [
                    (sx * 16) as f64 + 8.5,
                    (sy * 16) as f64 + 8.0,
                    (sz * 16) as f64 + 8.5,
                ];
                random_pos::default_towards(
                    t,
                    self.h,
                    self.v,
                    towards,
                    f(std::f64::consts::PI / 2.0),
                )
            } else {
                random_pos::land(t, self.h, self.v)
            }
        };
        match pos {
            Some(p) => t.remember(Mem::WalkTarget, walk_point(p, self.speed, 0)),
            None => t.forget(Mem::WalkTarget),
        }
        true
    }
}

/// `GoToClosestVillage.create(speed, close)`: outside a village, the best
/// of five land targets toward one (by sections to it).
#[derive(Clone, Debug, PartialEq)]
pub struct GoToVillage {
    pub speed: f64,
    pub close: i32,
}

pub fn go_to_village(speed: f64, close: i32) -> GoToVillage {
    GoToVillage { speed, close }
}

impl Trigger for GoToVillage {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if pois::village(t.level, t.block()) {
            return false;
        }
        let here = pois::sections_to_village(t.level, pois::section(t.block()));
        let weight = |t: &mut Turn, pos: [i32; 3]| {
            // The Elixir negates the integer, so none is a positive zero.
            (-pois::sections_to_village(t.level, pois::section(pos))) as f64
        };
        let mut target = None;
        for _ in 0..5 {
            let Some(point) = random_pos::land_weighted(t, 15, 7, weight) else {
                continue;
            };
            let there = pois::sections_to_village(t.level, pois::section(fmath::block(point)));
            if there < here {
                target = Some(point);
                break;
            } else if there == here {
                target = Some(point);
            }
        }
        if let Some(p) = target {
            t.remember(Mem::WalkTarget, walk_point(p, self.speed, self.close));
        }
        true
    }
}

/// `SetClosestHomeAsWalkTarget.create(speed)`: without a home, toward a bed
/// it can path to (five at a time, each tried once in 40 ticks), 20 ticks
/// apart.
#[derive(Clone, Debug, PartialEq)]
pub struct WalkToClosestHome {
    pub speed: f64,
    last: i64,
    cache: Vec<([i32; 3], i64)>,
}

pub fn walk_to_closest_home(speed: f64) -> WalkToClosestHome {
    WalkToClosestHome {
        speed,
        last: 0,
        cache: Vec::new(),
    }
}

const HOME: &[&str] = &["minecraft:home"];

impl Trigger for WalkToClosestHome {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Absent), (Mem::Home, Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let now = t.level.time;
        if now - self.last < 20 {
            return false;
        }
        let block = t.block();
        let Some(closest) = pois::closest(t.level, HOME, block, 48, Occupancy::Any) else {
            return false;
        };
        if pois::dist_sq(closest, block) <= 4 {
            return false;
        }
        let n = t.level_int(20) as i64;
        let last = now + n;
        // The cache test counts every POI it does not skip, the fifth
        // refused.
        let (pois, tried) = cached_search(
            &mut self.cache,
            pois::in_range(t.level, HOME, block, 48, Occupancy::Any),
            last,
        );
        self.last = last;
        if pois.is_empty() {
            self.prune(tried);
            return true;
        }
        let path = navigation::path_to_any(t, pois, 1);
        match path {
            Some(p) if p.reached && pois::type_at(t.level, p.target).is_some() => {
                t.remember(Mem::WalkTarget, walk_block(p.target, self.speed, 1));
            }
            _ => self.prune(tried),
        }
        true
    }
}

impl WalkToClosestHome {
    // Fewer than five tried: markers older than this round go.
    fn prune(&mut self, tried: i32) {
        if tried < 5 {
            let last = self.last;
            self.cache.retain(|(_, until)| *until >= last);
        }
    }
}

/// The search of a bed cache (`SetClosestHomeAsWalkTarget`,
/// `NearestBedSensor`): of `found`, those not cached, the fifth tried and
/// later refused; each taken cached until `last + 40`. The positions taken
/// and how many were tried.
pub fn cached_search(
    cache: &mut Vec<([i32; 3], i64)>,
    found: Vec<(String, [i32; 3])>,
    last: i64,
) -> (Vec<[i32; 3]>, i32) {
    let mut taken = Vec::new();
    let mut tried = 0;
    for (_, pos) in found {
        if cache.iter().any(|(p, _)| *p == pos) {
            continue;
        }
        if tried + 1 >= 5 {
            tried += 1;
            continue;
        }
        cache.push((pos, last + 40));
        tried += 1;
        taken.push(pos);
    }
    (taken, tried)
}
