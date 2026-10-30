//! A brain's behaviour (`Valimc.AI.Behavior`, vanilla's `BehaviorControl`):
//! a value that tries to start, ticks or stops while it runs, and stops.
//! The kinds are vanilla's: `Timed` (`Behavior`: memory conditions, a run
//! time drawn from the level's random, a tick while it can still be used),
//! `OneShot` (a trigger that runs once and stops on its next tick), `Gate`
//! (`RunOne`: children shuffled by their own random, the first that starts
//! runs), `TriggerGate`, `TryAllGate`, `DoNothing` and `Inert` (one whose
//! system does not exist yet: it never starts).
//!
//! Behaviours are boxed trait objects so a family's own sit beside the
//! shared ones, cloned and compared through their concrete types as goals
//! are.

use super::{Conds, Mem};
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::turn::Turn;
use crate::mobs::random::LegacyRandom;
use std::any::Any;
use std::fmt::Debug;

pub trait Behavior: BehaviorBox + Debug + Send + Sync {
    /// `try_start/2`: whether it started.
    fn try_start(&mut self, t: &mut Turn) -> bool;

    /// `tick_or_stop/2`.
    fn tick_or_stop(&mut self, t: &mut Turn);

    /// `stop/2`.
    fn stop(&mut self, t: &mut Turn);

    /// Whether it runs (`behavior.running`).
    fn running(&self) -> bool;

    /// Its running flag set from outside (a trigger gate's children).
    fn set_running(&mut self, running: bool);
}

/// Cloning, comparing and downcasting boxed behaviours.
pub trait BehaviorBox: Any {
    fn clone_behavior(&self) -> Box<dyn Behavior>;
    fn eq_behavior(&self, other: &dyn Behavior) -> bool;
    fn as_any(&self) -> &dyn Any;
}

impl<T: Behavior + Clone + PartialEq> BehaviorBox for T {
    fn clone_behavior(&self) -> Box<dyn Behavior> {
        Box::new(self.clone())
    }

    fn eq_behavior(&self, other: &dyn Behavior) -> bool {
        other.as_any().downcast_ref::<T>() == Some(self)
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

impl Clone for Box<dyn Behavior> {
    fn clone(&self) -> Self {
        (**self).clone_behavior()
    }
}

impl PartialEq for Box<dyn Behavior> {
    fn eq(&self, other: &Self) -> bool {
        (**self).eq_behavior(&**other)
    }
}

/// Boxes a behaviour.
pub fn boxed(b: impl Behavior + Clone + PartialEq) -> Box<dyn Behavior> {
    Box::new(b)
}

// ## One-shots

/// A one-shot's trigger (`Behavior.one_shot/2,3`): its memory conditions
/// and what it does (with what vanilla's closure keeps in `self`).
pub trait Trigger: Debug + Clone + PartialEq + Send + Sync + 'static {
    fn conditions(&self) -> Conds;

    /// Whether it started.
    fn trigger(&mut self, t: &mut Turn) -> bool;
}

/// `OneShot`.
#[derive(Clone, Debug, PartialEq)]
pub struct OneShot<T> {
    pub running: bool,
    pub trigger: T,
}

/// A one-shot of `trigger`, boxed.
pub fn one_shot<T: Trigger>(trigger: T) -> Box<dyn Behavior> {
    Box::new(OneShot {
        running: false,
        trigger,
    })
}

impl<T: Trigger> Behavior for OneShot<T> {
    fn try_start(&mut self, t: &mut Turn) -> bool {
        if t.conditions(&self.trigger.conditions()) {
            let started = self.trigger.trigger(t);
            self.running = started;
            started
        } else {
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

// ## Timed behaviours

/// What a timed behaviour's module does (`extra`, `start`, `still`, `tick`,
/// `stop`).
pub trait Timer: Debug + Clone + PartialEq + Send + Sync + 'static {
    /// `checkExtraStartConditions`.
    fn extra(&mut self, _t: &mut Turn) -> bool {
        true
    }

    fn start(&mut self, _t: &mut Turn) {}

    /// `canStillUse`.
    fn still(&mut self, _t: &mut Turn) -> bool {
        false
    }

    fn tick(&mut self, _t: &mut Turn) {}

    fn stop(&mut self, _t: &mut Turn) {}
}

/// `Timed`: run for `min` to `max` ticks (drawn from the level's random), or
/// while it may be (`forever`, after vanilla's default 60-tick draw).
#[derive(Clone, Debug, PartialEq)]
pub struct Timed<T> {
    pub running: bool,
    pub conditions: Conds,
    pub min: i32,
    pub max: i32,
    pub end: i64,
    pub forever: bool,
    pub state: T,
}

/// `Behavior.timed(module, conditions, {min, max}, state)`.
pub fn timed<T: Timer>(conditions: Conds, min: i32, max: i32, state: T) -> Box<dyn Behavior> {
    Box::new(Timed {
        running: false,
        conditions,
        min,
        max,
        end: 0,
        forever: false,
        state,
    })
}

/// `Behavior.timed(module, conditions, :forever, state)`.
pub fn forever<T: Timer>(conditions: Conds, state: T) -> Box<dyn Behavior> {
    Box::new(Timed {
        running: false,
        conditions,
        min: 60,
        max: 60,
        end: 0,
        forever: true,
        state,
    })
}

impl<T: Timer> Behavior for Timed<T> {
    fn try_start(&mut self, t: &mut Turn) -> bool {
        if !t.conditions(&self.conditions) {
            return false;
        }
        if self.state.extra(t) {
            let n = t.level_int(self.max.wrapping_add(1).wrapping_sub(self.min));
            self.running = true;
            self.end = t.level.time + self.min as i64 + n as i64;
            self.state.start(t);
            true
        } else {
            false
        }
    }

    fn tick_or_stop(&mut self, t: &mut Turn) {
        let still = if !self.forever && t.level.time > self.end {
            false
        } else {
            self.state.still(t)
        };
        if still {
            self.state.tick(t);
        } else {
            self.stop(t);
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        self.state.stop(t);
        self.running = false;
    }

    fn running(&self) -> bool {
        self.running
    }

    fn set_running(&mut self, running: bool) {
        self.running = running;
    }
}

// ## Gates

/// A gate's child and its weight.
#[derive(Clone, Debug)]
pub struct Child {
    pub behavior: Box<dyn Behavior>,
    pub weight: i32,
}

impl PartialEq for Child {
    fn eq(&self, other: &Child) -> bool {
        self.weight == other.weight && self.behavior.eq_behavior(&*other.behavior)
    }
}

fn children(list: Vec<(Box<dyn Behavior>, i32)>) -> Vec<Child> {
    list.into_iter()
        .map(|(mut behavior, weight)| {
            behavior.set_running(false);
            Child { behavior, weight }
        })
        .collect()
}

/// `ShufflingList.shuffle`: each entry a random weight, sorted (stably).
fn shuffle(children: &mut Vec<Child>, random: &mut LegacyRandom) {
    let mut keyed: Vec<(f64, Child)> = children
        .drain(..)
        .map(|child| {
            let r = random.float() as f64;
            let exponent = f(1.0 / child.weight as f64);
            (-r.powf(exponent), child)
        })
        .collect();
    keyed.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    children.extend(keyed.into_iter().map(|(_, c)| c));
}

/// `GateBehavior(entry, exitErased, order, RUN_ONE)`: shuffled by its random
/// (or ordered), its children's first that starts runs; stopping erases
/// `erase`.
#[derive(Clone, Debug, PartialEq)]
pub struct Gate {
    pub running: bool,
    pub children: Vec<Child>,
    pub random: LegacyRandom,
    pub conditions: Conds,
    pub erase: &'static [Mem],
    pub ordered: bool,
}

/// `Behavior.run_one(children, random, conditions)`.
pub fn run_one(
    list: Vec<(Box<dyn Behavior>, i32)>,
    random: LegacyRandom,
    conditions: Conds,
) -> Box<dyn Behavior> {
    gate(list, random, conditions, &[], false)
}

/// `Behavior.gate(children, random, conditions, erase, order)`.
pub fn gate(
    list: Vec<(Box<dyn Behavior>, i32)>,
    random: LegacyRandom,
    conditions: Conds,
    erase: &'static [Mem],
    ordered: bool,
) -> Box<dyn Behavior> {
    Box::new(Gate {
        running: false,
        children: children(list),
        random,
        conditions,
        erase,
        ordered,
    })
}

fn tick_children(children: &mut [Child], t: &mut Turn) {
    for child in children.iter_mut() {
        if child.behavior.running() {
            child.behavior.tick_or_stop(t);
        }
    }
}

fn stop_children(children: &mut [Child], t: &mut Turn, erase: &[Mem]) {
    for child in children.iter_mut() {
        if child.behavior.running() {
            child.behavior.stop(t);
        }
    }
    for &m in erase {
        t.forget(m);
    }
}

impl Behavior for Gate {
    fn try_start(&mut self, t: &mut Turn) -> bool {
        if !t.conditions(&self.conditions) {
            return false;
        }
        if !self.ordered {
            shuffle(&mut self.children, &mut self.random);
        }
        // `RUN_ONE`: the first stopped child that starts.
        for child in self.children.iter_mut() {
            if !child.behavior.running() && child.behavior.try_start(t) {
                break;
            }
        }
        self.running = true;
        true
    }

    fn tick_or_stop(&mut self, t: &mut Turn) {
        tick_children(&mut self.children, t);
        if !self.children.iter().any(|c| c.behavior.running()) {
            self.stop(t);
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        stop_children(&mut self.children, t, self.erase);
        self.running = false;
    }

    fn running(&self) -> bool {
        self.running
    }

    fn set_running(&mut self, running: bool) {
        self.running = running;
    }
}

/// `TriggerGate.triggerOneShuffled`: a one-shot that shuffles its triggers
/// by its random and fires them in turn until one starts.
#[derive(Clone, Debug, PartialEq)]
pub struct TriggerGate {
    pub running: bool,
    pub children: Vec<Child>,
    pub random: LegacyRandom,
}

pub fn trigger_gate(
    list: Vec<(Box<dyn Behavior>, i32)>,
    random: LegacyRandom,
) -> Box<dyn Behavior> {
    Box::new(TriggerGate {
        running: false,
        children: children(list),
        random,
    })
}

impl Behavior for TriggerGate {
    fn try_start(&mut self, t: &mut Turn) -> bool {
        shuffle(&mut self.children, &mut self.random);
        for child in self.children.iter_mut() {
            let started = child.behavior.try_start(t);
            child.behavior.set_running(false);
            if started {
                break;
            }
        }
        self.running = true;
        true
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

/// `GateBehavior(conditions, ..., ORDERED, TRY_ALL, children)`: with its
/// memory conditions, every stopped child in order tries to start.
#[derive(Clone, Debug, PartialEq)]
pub struct TryAllGate {
    pub running: bool,
    pub conditions: Conds,
    pub children: Vec<Child>,
}

pub fn try_all_gate(conditions: Conds, list: Vec<Box<dyn Behavior>>) -> Box<dyn Behavior> {
    Box::new(TryAllGate {
        running: false,
        conditions,
        children: children(list.into_iter().map(|b| (b, 1)).collect()),
    })
}

impl Behavior for TryAllGate {
    fn try_start(&mut self, t: &mut Turn) -> bool {
        if !t.conditions(&self.conditions) {
            return false;
        }
        for child in self.children.iter_mut() {
            if !child.behavior.running() {
                child.behavior.try_start(t);
            }
        }
        self.running = true;
        true
    }

    fn tick_or_stop(&mut self, t: &mut Turn) {
        tick_children(&mut self.children, t);
        if !self.children.iter().any(|c| c.behavior.running()) {
            self.stop(t);
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        stop_children(&mut self.children, t, &[]);
        self.running = false;
    }

    fn running(&self) -> bool {
        self.running
    }

    fn set_running(&mut self, running: bool) {
        self.running = running;
    }
}

// ## Waiting and nothing

/// `DoNothing(min, max)`.
#[derive(Clone, Debug, PartialEq)]
pub struct DoNothing {
    pub running: bool,
    pub min: i32,
    pub max: i32,
    pub end: i64,
}

pub fn do_nothing(min: i32, max: i32) -> Box<dyn Behavior> {
    Box::new(DoNothing {
        running: false,
        min,
        max,
        end: 0,
    })
}

impl Behavior for DoNothing {
    fn try_start(&mut self, t: &mut Turn) -> bool {
        let n = t.level_int(self.max + 1 - self.min);
        self.running = true;
        self.end = t.level.time + self.min as i64 + n as i64;
        true
    }

    fn tick_or_stop(&mut self, t: &mut Turn) {
        if t.level.time > self.end {
            self.stop(t);
        }
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

/// A behaviour that never starts: one whose system (or memories) does not
/// exist yet (`Behavior.inert/1`).
#[derive(Clone, Debug, PartialEq)]
pub struct Inert {
    pub name: &'static str,
}

pub fn inert(name: &'static str) -> Box<dyn Behavior> {
    Box::new(Inert { name })
}

impl Behavior for Inert {
    fn try_start(&mut self, _t: &mut Turn) -> bool {
        false
    }

    fn tick_or_stop(&mut self, _t: &mut Turn) {}

    fn stop(&mut self, _t: &mut Turn) {}

    fn running(&self) -> bool {
        false
    }

    fn set_running(&mut self, _running: bool) {}
}
