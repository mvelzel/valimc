//! Brain behaviours shared by mobs with brains (`Valimc.AI.Behaviors`), as
//! vanilla's `ai.behavior` classes build them: the look and walk sinks
//! (`LookAtTargetSink`, `MoveToTargetSink`), look targets
//! (`SetEntityLookTarget`, `SetLookAndInteract`,
//! `SetEntityLookTargetSometimes`), walks (`RandomStroll`,
//! `SetWalkTargetFromLookTarget`, `InteractWith`, `GoToWantedItem`,
//! `BabyFollowAdult`, `SetWalkTargetAwayFrom`), `BecomePassiveIfMemoryPresent`,
//! `Swim` and `InteractWithDoor`.
//!
//! The Elixir's closures over the mob or a sensed entity are `Test`, `Pick`
//! and `Speed`: the common cases, or a family's own by tag.

use super::behavior::{self, one_shot, Behavior, Timer, Trigger};
use super::sensors::{self, visible_closest};
use super::{Cond, Conds, Global, Mem, MemValue, Tracker, WalkTarget};
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::navigation;
use crate::mobs::ai::paths::NavPath;
use crate::mobs::ai::random_pos;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::ai::{Effect, Extra};
use crate::mobs::sensing::{Entity, GameMode, Kind, Ref};

use Cond::{Absent, Present, Registered};

// ## Closures as data

/// A test of the mob (`fn self -> bool`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Test {
    Always,
    /// Its family's test `tag`.
    Family(u32),
    /// Not its family's test `tag`.
    Not(u32),
}

impl Test {
    pub fn holds(&self, t: &mut Turn) -> bool {
        match self {
            Test::Always => true,
            Test::Family(tag) => t.family().is_some_and(|f| f.test(t, *tag)),
            Test::Not(tag) => !t.family().is_some_and(|f| f.test(t, *tag)),
        }
    }
}

/// A test of a sensed entity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pick {
    Any,
    /// `is?(e, :player)`.
    Player,
    /// `is?(e, type)`.
    Type(u16),
    /// Its family's test `tag`.
    Family(u32),
}

impl Pick {
    pub fn takes(&self, t: &Turn, e: Entity<'_, Extra>) -> bool {
        match self {
            Pick::Any => true,
            Pick::Player => e.kind() == Kind::Player,
            Pick::Type(ty) => e.type_id() == Some(*ty),
            Pick::Family(tag) => t.family().is_some_and(|f| f.select(t, *tag, e)),
        }
    }
}

/// A speed: fixed (rounded to a float) or of the mob's state.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Speed {
    Fixed(f64),
    Family(u32),
}

impl Speed {
    /// A fixed speed, `Float32.round`ed.
    pub fn of(speed: f64) -> Speed {
        Speed::Fixed(f(speed))
    }

    pub fn get(&self, t: &Turn) -> f64 {
        match self {
            Speed::Fixed(s) => *s,
            Speed::Family(tag) => t.family().map_or(0.0, |f| f.speed(t, *tag)),
        }
    }
}

// ## Trackers

/// `Behaviors.tracker/2`: an entity tracker (an item's with where it lay).
pub fn tracker(e: &Seen, eye: bool) -> Tracker {
    Tracker::Entity {
        target: e.reference,
        eye,
        at: (e.kind() == Kind::Item).then_some(e.position),
    }
}

/// `PositionTracker.currentPosition`.
pub fn position(t: &Turn, tracker: &Tracker) -> Option<[f64; 3]> {
    match *tracker {
        Tracker::Entity { target, eye, at } => match (t.entity(Some(&target)), at) {
            (Some(e), _) => Some([e.x(), if eye { e.y() + e.eye } else { e.y() }, e.z()]),
            (None, Some([x, y, z])) => Some([x, if eye { y + 0.2125000059604645 } else { y }, z]),
            (None, None) => None,
        },
        Tracker::Block { center, .. } => Some(center),
    }
}

/// `PositionTracker.currentBlockPosition`.
pub fn block(t: &Turn, tracker: &Tracker) -> Option<[i32; 3]> {
    match *tracker {
        Tracker::Entity { target, at, .. } => match (t.entity(Some(&target)), at) {
            (Some(e), _) => Some(fmath::block(e.position)),
            (None, Some(at)) => Some(fmath::block(at)),
            (None, None) => None,
        },
        Tracker::Block { block, .. } => Some(block),
    }
}

/// `PositionTracker.isVisibleBy`: a living entity alive and in sight,
/// anything else.
pub fn visible_by(t: &mut Turn, tracker: &Tracker) -> bool {
    match *tracker {
        Tracker::Entity {
            target, at: None, ..
        } => match t.entity(Some(&target)) {
            Some(e) if e.kind() == Kind::Item => true,
            None => false,
            Some(e) if !e.alive => false,
            Some(_) => sensors::visible_contains(t, &target),
        },
        _ => true,
    }
}

/// `WalkTarget.reachedTarget`: within its distance, by Manhattan blocks.
pub fn reached(t: &Turn, walk: &WalkTarget) -> bool {
    match block(t, &walk.target) {
        None => false,
        Some([tx, ty, tz]) => {
            let [x, y, z] = t.block();
            (tx - x).abs() + (ty - y).abs() + (tz - z).abs() <= walk.close
        }
    }
}

/// A walk target of a tracker.
pub fn walk(target: Tracker, speed: f64, close: i32) -> MemValue {
    MemValue::Walk(WalkTarget {
        target,
        speed,
        close,
    })
}

/// `BehaviorUtils.setWalkAndLookTargetMemories(mob, pos, speed, close)`.
pub fn walk_and_look(t: &mut Turn, pos: [i32; 3], speed: f64, close: i32) {
    let tracker = Tracker::block(pos);
    t.remember(Mem::LookTarget, MemValue::Tracker(tracker));
    t.remember(Mem::WalkTarget, walk(tracker, f(speed), close));
}

/// A look at an entity's eyes (`{:entity, ref, true}`).
pub fn look_at_entity(t: &mut Turn, r: Ref) {
    t.remember(Mem::LookTarget, MemValue::Tracker(Tracker::entity(r, true)));
}

/// A walk to an entity (`{:entity, ref, false}`).
pub fn walk_to_entity(t: &mut Turn, r: Ref, speed: f64, close: i32) {
    t.remember(
        Mem::WalkTarget,
        walk(Tracker::entity(r, false), speed, close),
    );
}

/// The squared distance from the mob to a sensed entity
/// (`World.distance_sq/2`).
pub fn distance_sq(t: &Turn, e: &Seen) -> f64 {
    t.distance_sq(e.position)
}

fn entity_distance_sq(t: &Turn, e: Entity<'_, Extra>) -> f64 {
    t.distance_sq(e.position())
}

// ## LookAtTargetSink

#[derive(Clone, Debug, PartialEq)]
pub struct LookSink;

impl Timer for LookSink {
    fn still(&mut self, t: &mut Turn) -> bool {
        match t.mem_tracker(Mem::LookTarget) {
            None => false,
            Some(tracker) => visible_by(t, &tracker),
        }
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(tracker) = t.mem_tracker(Mem::LookTarget) {
            if let Some(point) = position(t, &tracker) {
                t.look_at_point(point);
            }
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        t.forget(Mem::LookTarget);
    }
}

/// `LookAtTargetSink(min, max)`.
pub fn look_sink(min: i32, max: i32) -> Box<dyn Behavior> {
    behavior::timed(
        Conds::new(&[(Mem::LookTarget, Present)]),
        min,
        max,
        LookSink,
    )
}

// ## MoveToTargetSink

#[derive(Clone, Debug, PartialEq)]
pub struct MoveSink {
    pub cooldown: i32,
    pub path: Option<NavPath>,
    pub last: Option<[i32; 3]>,
    pub speed: f64,
}

impl MoveSink {
    // `tryComputePath`. A target entity gone from the world has no place to
    // path to.
    fn compute(&mut self, t: &mut Turn, walk: &WalkTarget) -> bool {
        let Some([x, y, z]) = block(t, &walk.target) else {
            return false;
        };
        let path = navigation::path_to(t, [x as f64, y as f64, z as f64], 0);
        self.path = path.clone();
        self.speed = walk.speed;
        if reached(t, walk) {
            t.forget(Mem::CantReachWalkTargetSince);
            return false;
        }
        if path.as_ref().is_some_and(|p| p.reached) {
            t.forget(Mem::CantReachWalkTargetSince);
        } else if !t.has(Mem::CantReachWalkTargetSince) {
            let now = t.level.time;
            t.remember(Mem::CantReachWalkTargetSince, MemValue::Int(now));
        }
        if path.is_some() {
            return true;
        }
        let towards = [x as f64 + 0.5, y as f64, z as f64 + 0.5];
        match random_pos::default_towards(t, 10, 7, towards, f(std::f64::consts::PI / 2.0)) {
            None => false,
            Some(point) => {
                let path = navigation::path_to(t, point, 0);
                self.path = path.clone();
                path.is_some()
            }
        }
    }

    fn begin(&mut self, t: &mut Turn) {
        t.remember_opt(
            Mem::Path,
            self.path.clone().map(|p| MemValue::Path(Box::new(p))),
        );
        navigation::follow(t, self.path.clone(), self.speed);
    }
}

impl Timer for MoveSink {
    fn extra(&mut self, t: &mut Turn) -> bool {
        if self.cooldown > 0 {
            self.cooldown -= 1;
            return false;
        }
        let Some(walk) = t.mem_walk() else {
            return false;
        };
        let reached = reached(t, &walk);
        let computed = if reached {
            false
        } else {
            self.compute(t, &walk)
        };
        if computed {
            self.last = block(t, &walk.target);
            true
        } else {
            t.forget(Mem::WalkTarget);
            if reached {
                t.forget(Mem::CantReachWalkTargetSince);
            }
            false
        }
    }

    fn start(&mut self, t: &mut Turn) {
        self.begin(t);
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        if self.path.is_none() || self.last.is_none() {
            return false;
        }
        let walk = t.mem_walk();
        let spectator = match walk.map(|w| w.target) {
            Some(Tracker::Entity { target, .. }) => t
                .entity(Some(&target))
                .is_some_and(|e| e.mode == Some(GameMode::Spectator)),
            _ => false,
        };
        !t.mind.navigation.done() && walk.is_some_and(|w| !reached(t, &w)) && !spectator
    }

    fn tick(&mut self, t: &mut Turn) {
        let current = t.mind.navigation.path.clone();
        if self.path != current {
            self.path = current.clone();
            t.remember_opt(
                Mem::Path,
                current.clone().map(|p| MemValue::Path(Box::new(p))),
            );
        }
        let walk = t.mem_walk();
        let target = walk.and_then(|w| block(t, &w.target));
        if let (Some(_), Some([lx, ly, lz]), Some(target), Some(walk)) =
            (current, self.last, target, walk)
        {
            let [tx, ty, tz] = target;
            let d = (tx - lx).pow(2) + (ty - ly).pow(2) + (tz - lz).pow(2);
            if d > 4 && self.compute(t, &walk) {
                self.last = Some(target);
                self.begin(t);
            }
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        if let Some(walk) = t.mem_walk() {
            if !reached(t, &walk) && t.mind.navigation.stuck {
                self.cooldown = t.level_int(40);
            }
        }
        navigation::stop(t);
        t.forget(Mem::WalkTarget);
        t.forget(Mem::Path);
        self.path = None;
    }
}

/// `MoveToTargetSink(min, max)` (by default 150 to 250 ticks).
pub fn move_sink(min: i32, max: i32) -> Box<dyn Behavior> {
    behavior::timed(
        Conds::new(&[
            (Mem::CantReachWalkTargetSince, Registered),
            (Mem::Path, Absent),
            (Mem::WalkTarget, Present),
        ]),
        min,
        max,
        MoveSink {
            cooldown: 0,
            path: None,
            last: None,
            speed: 0.0,
        },
    )
}

// ## One-shots

/// `SetEntityLookTarget.create(predicate, maxDist)`.
#[derive(Clone, Debug, PartialEq)]
pub struct LookTarget {
    pub pick: Pick,
    pub max: f64,
}

pub fn look_target(pick: Pick, distance: f64) -> Box<dyn Behavior> {
    one_shot(LookTarget {
        pick,
        max: f(f(distance) * f(distance)),
    })
}

impl Trigger for LookTarget {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::LookTarget, Absent),
            (Mem::NearestVisibleLivingEntities, Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let (pick, max) = (self.pick, self.max);
        match visible_closest(t, |t, e| {
            pick.takes(t, e) && entity_distance_sq(t, e) <= max
        }) {
            Some(target) => {
                look_at_entity(t, target.reference);
                true
            }
            None => false,
        }
    }
}

/// `SetLookAndInteract.create(type, range)`.
#[derive(Clone, Debug, PartialEq)]
pub struct LookAndInteract {
    pub pick: Pick,
    pub max: i32,
}

pub fn look_and_interact(pick: Pick, range: i32) -> Box<dyn Behavior> {
    one_shot(LookAndInteract {
        pick,
        max: range * range,
    })
}

impl Trigger for LookAndInteract {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::LookTarget, Registered),
            (Mem::InteractionTarget, Absent),
            (Mem::NearestVisibleLivingEntities, Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let (pick, max) = (self.pick, self.max as f64);
        match visible_closest(t, |t, e| {
            entity_distance_sq(t, e) <= max && pick.takes(t, e)
        }) {
            Some(target) => {
                t.remember(Mem::InteractionTarget, MemValue::Ref(target.reference));
                look_at_entity(t, target.reference);
                true
            }
            None => false,
        }
    }
}

/// `BehaviorBuilder.triggerIf(predicate, oneShot)`.
#[derive(Clone, Debug, PartialEq)]
pub struct TriggerIf<T> {
    pub test: Test,
    pub inner: T,
}

pub fn trigger_if<T: Trigger>(test: Test, inner: T) -> Box<dyn Behavior> {
    one_shot(TriggerIf { test, inner })
}

impl<T: Trigger> Trigger for TriggerIf<T> {
    fn conditions(&self) -> Conds {
        self.inner.conditions()
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if self.test.holds(t) {
            self.inner.trigger(t)
        } else {
            false
        }
    }
}

/// `Behavior.one_shot([], fn self -> {test, self} end)`: it starts when the
/// test holds, doing nothing.
#[derive(Clone, Debug, PartialEq)]
pub struct Check {
    pub test: Test,
}

pub fn check(test: Test) -> Box<dyn Behavior> {
    one_shot(Check { test })
}

impl Trigger for Check {
    fn conditions(&self) -> Conds {
        Conds::NONE
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        self.test.holds(t)
    }
}

/// `BecomePassiveIfMemoryPresent.create(memory, duration)`.
#[derive(Clone, Debug, PartialEq)]
pub struct BecomePassive {
    pub memory: Mem,
    pub duration: i64,
}

pub fn become_passive(memory: Mem, duration: i64) -> Box<dyn Behavior> {
    one_shot(BecomePassive { memory, duration })
}

impl Trigger for BecomePassive {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AttackTarget, Registered),
            (Mem::Pacified, Absent),
            (self.memory, Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        t.remember_for(Mem::Pacified, MemValue::True, self.duration);
        t.forget(Mem::AttackTarget);
        true
    }
}

/// `SetEntityLookTargetSometimes.create(maxDist, interval)`: with an entity
/// in sight within the distance, a look at the nearest once its ticker,
/// counting down from a wait drawn from the level's random, runs out.
#[derive(Clone, Debug, PartialEq)]
pub struct LookSometimes {
    pub running: bool,
    pub pick: Pick,
    pub max: f64,
    pub interval: (i32, i32),
    pub ticks: i32,
}

pub fn look_sometimes(pick: Pick, distance: f64, interval: (i32, i32)) -> Box<dyn Behavior> {
    Box::new(LookSometimes {
        running: false,
        pick,
        max: f(f(distance) * f(distance)),
        interval,
        ticks: 0,
    })
}

const LOOK_SOMETIMES: Conds = Conds::new(&[
    (Mem::LookTarget, Absent),
    (Mem::NearestVisibleLivingEntities, Present),
]);

impl Behavior for LookSometimes {
    fn try_start(&mut self, t: &mut Turn) -> bool {
        if !t.conditions(&LOOK_SOMETIMES) {
            return false;
        }
        let (pick, max) = (self.pick, self.max);
        let Some(target) = visible_closest(t, |t, e| {
            pick.takes(t, e) && entity_distance_sq(t, e) <= max
        }) else {
            return false;
        };
        if self.ticks == 0 {
            let (min, max) = self.interval;
            let n = t.level_int(max - min + 1);
            self.ticks = min + n - 1;
            false
        } else if self.ticks - 1 == 0 {
            look_at_entity(t, target.reference);
            self.ticks = 0;
            self.running = true;
            true
        } else {
            self.ticks -= 1;
            false
        }
    }

    fn tick_or_stop(&mut self, _t: &mut Turn) {
        self.running = false;
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.running = false;
    }

    fn running(&self) -> bool {
        self.running
    }

    fn set_running(&mut self, running: bool) {
        self.running = running;
    }
}

/// `BabyFollowAdult.create(followRange, speed)`: a baby farther than the
/// range's least from the adult it sees, but within its most and one,
/// walks toward it and looks at it.
#[derive(Clone, Debug, PartialEq)]
pub struct BabyFollowAdult {
    pub min: i32,
    pub max: i32,
    pub speed: Speed,
}

pub fn baby_follow_adult(min: i32, max: i32, speed: Speed) -> Box<dyn Behavior> {
    one_shot(BabyFollowAdult { min, max, speed })
}

impl Trigger for BabyFollowAdult {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::NearestVisibleAdult, Present),
            (Mem::LookTarget, Registered),
            (Mem::WalkTarget, Absent),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let adult = t.remembered(Mem::NearestVisibleAdult);
        let baby = t.family().is_some_and(|f| f.young(t));
        let Some(adult) = adult else { return false };
        let d = distance_sq(t, &adult);
        let (min, max) = (self.min as f64, self.max as f64);
        if baby && d < (max + 1.0) * (max + 1.0) && d >= min * min {
            look_at_entity(t, adult.reference);
            let speed = self.speed.get(t);
            walk_to_entity(t, adult.reference, speed, self.min - 1);
            true
        } else {
            false
        }
    }
}

/// `RandomStroll.swim(speed)`: in water, toward a swimmable target; none
/// found clears the walk target.
#[derive(Clone, Debug, PartialEq)]
pub struct SwimStroll {
    pub speed: f64,
}

pub fn swim_stroll(speed: f64) -> Box<dyn Behavior> {
    one_shot(SwimStroll { speed })
}

impl Trigger for SwimStroll {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if !t.in_water() {
            return false;
        }
        match random_pos::swim_target(t) {
            None => t.forget(Mem::WalkTarget),
            Some(p) => t.remember(Mem::WalkTarget, walk(Tracker::point(p), self.speed, 0)),
        }
        true
    }
}

/// `RandomStroll.stroll(speed, h, v)` (behind a test of the mob): a land
/// target `h` blocks around and `v` up or down, or none.
#[derive(Clone, Debug, PartialEq)]
pub struct Stroll {
    pub speed: f64,
    pub h: i32,
    pub v: i32,
    pub may: Test,
}

pub fn stroll(speed: f64, h: i32, v: i32, may: Test) -> Box<dyn Behavior> {
    one_shot(Stroll { speed, h, v, may })
}

impl Trigger for Stroll {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if !self.may.holds(t) {
            return false;
        }
        match random_pos::land(t, self.h, self.v) {
            None => t.forget(Mem::WalkTarget),
            Some(p) => t.remember(Mem::WalkTarget, walk(Tracker::point(p), f(self.speed), 0)),
        }
        true
    }
}

/// `SetWalkTargetFromLookTarget.create(speed, close)` behind a test.
#[derive(Clone, Debug, PartialEq)]
pub struct WalkToLookTarget {
    pub test: Test,
    pub speed: Speed,
    pub close: i32,
}

pub fn walk_to_look_target(test: Test, speed: Speed, close: i32) -> Box<dyn Behavior> {
    one_shot(WalkToLookTarget { test, speed, close })
}

impl Trigger for WalkToLookTarget {
    fn conditions(&self) -> Conds {
        Conds::NONE
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if self.test.holds(t) && !t.has(Mem::WalkTarget) {
            if let Some(target) = t.mem_tracker(Mem::LookTarget) {
                let speed = self.speed.get(t);
                t.remember(Mem::WalkTarget, walk(target, speed, self.close));
                return true;
            }
        }
        false
    }
}

/// `InteractWith.of(type, range, memory, speed, stop)` with the mob's and
/// the target's filters.
#[derive(Clone, Debug, PartialEq)]
pub struct InteractWith {
    pub kind: Pick,
    pub max: i32,
    pub speed: f64,
    pub stop: i32,
    pub memory: Mem,
    pub own: Test,
    pub target: Pick,
}

pub fn interact_with(kind: Pick, range: i32, speed: f64, stop: i32) -> InteractWith {
    InteractWith {
        kind,
        max: range * range,
        speed,
        stop,
        memory: Mem::InteractionTarget,
        own: Test::Always,
        target: Pick::Any,
    }
}

impl Trigger for InteractWith {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (self.memory, Registered),
            (Mem::LookTarget, Registered),
            (Mem::WalkTarget, Absent),
            (Mem::NearestVisibleLivingEntities, Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let (kind, filter, max) = (self.kind, self.target, self.max as f64);
        let valid = move |t: &Turn, e: Entity<'_, Extra>| kind.takes(t, e) && filter.takes(t, e);
        let any = if self.own.holds(t) {
            visible_closest(t, valid)
        } else {
            None
        };
        if any.is_none() {
            return false;
        }
        if let Some(closest) =
            visible_closest(t, |t, e| entity_distance_sq(t, e) <= max && valid(t, e))
        {
            let r = closest.reference;
            t.remember(self.memory, MemValue::Ref(r));
            look_at_entity(t, r);
            walk_to_entity(t, r, f(self.speed), self.stop);
        }
        true
    }
}

/// `GoToWantedItem.create(predicate, speed, interrupt, maxDist)`.
#[derive(Clone, Debug, PartialEq)]
pub struct GoToWantedItem {
    pub test: Test,
    pub speed: f64,
    pub interrupt: bool,
    pub distance: f64,
}

pub fn go_to_wanted_item(
    test: Test,
    speed: f64,
    interrupt: bool,
    distance: i32,
) -> Box<dyn Behavior> {
    one_shot(GoToWantedItem {
        test,
        speed,
        interrupt,
        distance: distance as f64,
    })
}

impl Trigger for GoToWantedItem {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::LookTarget, Registered),
            (
                Mem::WalkTarget,
                if self.interrupt { Registered } else { Absent },
            ),
            (Mem::NearestVisibleWantedItem, Present),
            (Mem::ItemPickupCooldownTicks, Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some(item) = t.remembered(Mem::NearestVisibleWantedItem) else {
            return false;
        };
        if !t.has(Mem::ItemPickupCooldownTicks)
            && self.test.holds(t)
            && distance_sq(t, &item) < self.distance * self.distance
        {
            t.remember(
                Mem::WalkTarget,
                walk(tracker(&item, false), f(self.speed), 0),
            );
            t.remember(Mem::LookTarget, MemValue::Tracker(tracker(&item, true)));
            true
        } else {
            false
        }
    }
}

// ## Swim

/// `Swim(chance)`: in water deeper than its jump threshold, or in lava, it
/// jumps.
#[derive(Clone, Debug, PartialEq)]
pub struct Swim {
    pub chance: f64,
}

fn deep(t: &Turn) -> bool {
    t.mob.body.mob.motion.water > t.jump_threshold() || t.in_lava()
}

impl Timer for Swim {
    fn extra(&mut self, t: &mut Turn) -> bool {
        deep(t)
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        deep(t)
    }

    fn tick(&mut self, t: &mut Turn) {
        if t.float() < self.chance {
            t.jump();
        }
    }
}

pub fn swim(chance: f64) -> Box<dyn Behavior> {
    behavior::timed(Conds::NONE, 60, 60, Swim { chance: f(chance) })
}

// ## InteractWithDoor

/// Whether `state` is a door mobs open (`MOB_INTERACTABLE_DOORS`).
pub fn mob_door(t: &Turn, state: u16) -> bool {
    let facts = t.level.facts;
    facts.blocks.block_id(state).is_some_and(|b| {
        facts.tags.has(
            "minecraft:block",
            "minecraft:mob_interactable_doors",
            b as i32,
        )
    })
}

/// Whether a door state is open.
pub fn door_open(t: &Turn, state: u16) -> bool {
    t.level.facts.blocks.property(state, "open") == Some("true")
}

/// `InteractWithDoor.create()`: along its path the mob opens a closed door
/// it comes from or goes to and remembers it; doors it passed it closes
/// again unless one of its kind is coming through or the door is more than
/// 3 blocks away. A node it checked waits 20 ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct InteractWithDoor {
    pub last: Option<[i32; 3]>,
    pub cooldown: i32,
}

pub fn interact_with_door() -> Box<dyn Behavior> {
    one_shot(InteractWithDoor {
        last: None,
        cooldown: 0,
    })
}

impl Trigger for InteractWithDoor {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::Path, Present),
            (Mem::DoorsToClose, Registered),
            (Mem::NearestLivingEntities, Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let step = match &t.mind.navigation.path {
            Some(p) if p.index > 0 && p.index < p.nodes.len() => {
                Some((p.nodes[p.index - 1], p.nodes[p.index]))
            }
            _ => None,
        };
        let Some((from, next)) = step else {
            return false;
        };
        let wait = if self.last == Some(next) {
            self.cooldown = 20;
            false
        } else if self.cooldown - 1 > 0 {
            self.cooldown -= 1;
            true
        } else {
            self.cooldown -= 1;
            false
        };
        if wait {
            return false;
        }
        through_doors(t, from, next);
        self.last = Some(next);
        true
    }
}

fn through_doors(t: &mut Turn, from: [i32; 3], to: [i32; 3]) {
    if let Some(state) = t.level.block(from) {
        if mob_door(t, state) {
            if !door_open(t, state) {
                t.effect(Effect::Door {
                    cell: from,
                    open: true,
                });
            }
            remember_door(t, from);
        }
    }
    if let Some(state) = t.level.block(to) {
        if mob_door(t, state) && !door_open(t, state) {
            t.effect(Effect::Door {
                cell: to,
                open: true,
            });
            remember_door(t, to);
        }
    }
    if let Some(MemValue::Globals(doors)) = t.memory(Mem::DoorsToClose) {
        let doors = doors.clone();
        close_doors(t, Some(from), Some(to), doors);
    }
}

fn remember_door(t: &mut Turn, pos: [i32; 3]) {
    let door = Global {
        dimension: t.level.dimension.clone(),
        pos,
    };
    let mut doors = match t.memory(Mem::DoorsToClose) {
        Some(MemValue::Globals(d)) => d.clone(),
        _ => Vec::new(),
    };
    if !doors.contains(&door) {
        doors.push(door);
        t.remember(Mem::DoorsToClose, MemValue::Globals(doors));
    }
}

/// `BlockPos.closerToCenterThan(position, distance)`.
pub fn near_center(b: [i32; 3], p: [f64; 3], distance: f64) -> bool {
    let (dx, dy, dz) = (
        b[0] as f64 + 0.5 - p[0],
        b[1] as f64 + 0.5 - p[1],
        b[2] as f64 + 0.5 - p[2],
    );
    dx * dx + dy * dy + dz * dz < distance * distance
}

/// `closeDoorsThatIHaveOpenedOrPassedThrough`: each remembered door but the
/// ones at `from` and `to` is forgotten, and closed when it is near, still
/// an open door, and no mob of its kind comes through it.
pub fn close_doors(t: &mut Turn, from: Option<[i32; 3]>, to: Option<[i32; 3]>, doors: Vec<Global>) {
    let mut kept = Vec::new();
    for door in doors {
        let pos = door.pos;
        if Some(pos) == from || Some(pos) == to {
            kept.push(door);
            continue;
        }
        if door.dimension != t.level.dimension || !near_center(pos, t.pos(), 3.0) {
            continue;
        }
        let open = t
            .level
            .block(pos)
            .is_some_and(|state| mob_door(t, state) && door_open(t, state));
        if open && !coming_through(t, pos) {
            t.effect(Effect::Door {
                cell: pos,
                open: false,
            });
        }
    }
    t.remember(Mem::DoorsToClose, MemValue::Globals(kept));
}

// `areOtherMobsComingThroughDoor`: one of its type within 2 blocks whose
// path goes from or to the door.
fn coming_through(t: &Turn, pos: [i32; 3]) -> bool {
    let own = t.type_id;
    t.mem_refs(Mem::NearestLivingEntities)
        .iter()
        .any(|r| match t.sensing.entity(r) {
            Some(Entity::Mob(m)) if m.type_id == own && near_center(pos, m.position, 2.0) => {
                m.extra.path_step.is_some_and(|(a, b)| a == pos || b == pos)
            }
            _ => false,
        })
}

// ## SetWalkTargetAwayFrom

/// `SetWalkTargetAwayFrom.entity(memory, speed, distance, interrupt)`:
/// closer than `distance` to the remembered entity, a land target 16 blocks
/// away from it (ten tries); a walk at this speed already leading away
/// stays.
#[derive(Clone, Debug, PartialEq)]
pub struct WalkAwayFrom {
    pub memory: Mem,
    pub speed: f64,
    pub distance: f64,
    pub interrupt: bool,
}

pub fn walk_away_from(
    memory: Mem,
    speed: f64,
    distance: i32,
    interrupt: bool,
) -> Box<dyn Behavior> {
    one_shot(WalkAwayFrom {
        memory,
        speed: f(speed),
        distance: distance as f64,
        interrupt,
    })
}

impl Trigger for WalkAwayFrom {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Registered), (self.memory, Present)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let walk = t.mem_walk();
        let Some(from) = t.remembered(self.memory) else {
            return false;
        };
        if walk.is_some() && !self.interrupt {
            return false;
        }
        let avoid = from.position;
        let [x, y, z] = t.pos();
        let (dx, dy, dz) = (x - avoid[0], y - avoid[1], z - avoid[2]);
        if dx * dx + dy * dy + dz * dz >= self.distance * self.distance {
            return false;
        }
        if let Some(w) = walk {
            if w.speed == self.speed && leading(t, &w, avoid) >= 0.0 {
                return false;
            }
        }
        flee(t, avoid, self.speed, 10);
        true
    }
}

/// The walk's direction against the threat's (a dot product).
pub fn leading(t: &Turn, walk: &WalkTarget, avoid: [f64; 3]) -> f64 {
    match position(t, &walk.target) {
        None => f64::NAN,
        Some([wx, wy, wz]) => {
            let [x, y, z] = t.pos();
            (wx - x) * (avoid[0] - x) + (wy - y) * (avoid[1] - y) + (wz - z) * (avoid[2] - z)
        }
    }
}

/// Up to `tries` land targets 16 blocks away from `avoid`: the first found
/// is the walk target.
pub fn flee(t: &mut Turn, avoid: [f64; 3], speed: f64, tries: i32) {
    for _ in 0..tries {
        if let Some(p) = random_pos::land_away(t, 16, 7, avoid) {
            t.remember(Mem::WalkTarget, walk(Tracker::point(p), speed, 0));
            return;
        }
    }
}
