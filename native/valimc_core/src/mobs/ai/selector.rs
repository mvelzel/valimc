//! Vanilla's `GoalSelector` (`Valimc.AI.Selector`): goals with a priority,
//! control flags and a goal value, held in registration order, and the flags
//! running goals lock.
//!
//! An update (`tick`) stops running goals that hold a disabled flag or cannot
//! continue, frees the flags of stopped goals, then starts, in order, every
//! goal that is not running, whose flags no running goal of the same or a
//! lower priority number holds, and that can be used (a started goal stops
//! the goals holding its flags), then ticks every running goal. Between
//! updates (`tick_running` with `all` false) only goals updated every tick
//! tick.
//!
//! A goal is taken out of its entry while its callback runs (the turn holds
//! the mind and so the selector): what it returns replaces its state, as the
//! Elixir puts the returned state over its entry.

use super::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use super::turn::Turn;

/// Which of a mind's two selectors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Which {
    Goals,
    Targets,
}

/// One registered goal (`WrappedGoal`).
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub priority: i32,
    /// `goal::MOVE | LOOK | JUMP | TARGET`.
    pub flags: u8,
    pub running: bool,
    /// None only while its own callback runs.
    pub goal: Option<Box<dyn Goal>>,
}

/// A selector: its entries in registration order and the flags locked by
/// entry index.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Selector {
    pub entries: Vec<Entry>,
    pub locks: [Option<usize>; 4],
}

const FLAGS: [u8; 4] = [MOVE, LOOK, JUMP, TARGET];

fn slot(flag: u8) -> usize {
    FLAGS.iter().position(|&f| f == flag).unwrap_or(0)
}

impl Selector {
    /// A selector of `(priority, flags, goal)` in registration order.
    pub fn new(goals: Vec<(i32, u8, Box<dyn Goal>)>) -> Selector {
        Selector {
            entries: goals
                .into_iter()
                .map(|(priority, flags, goal)| Entry {
                    priority,
                    flags,
                    running: false,
                    goal: Some(goal),
                })
                .collect(),
            locks: [None; 4],
        }
    }

    /// The goal holding `flag`.
    pub fn lock(&self, flag: u8) -> Option<usize> {
        self.locks[slot(flag)]
    }

    /// The running goals, in order (`Selector.running`).
    pub fn running(&self) -> impl Iterator<Item = &dyn Goal> {
        self.entries
            .iter()
            .filter(|e| e.running)
            .filter_map(|e| e.goal.as_deref())
    }

    /// Whether a goal of type `T` runs.
    pub fn runs<T: 'static>(&self) -> bool {
        self.running().any(|g| g.is::<T>())
    }

    /// `Selector.change`: the state of every goal of type `T` changed by `f`.
    pub fn change<T: 'static>(&mut self, mut f: impl FnMut(&mut T)) {
        for e in &mut self.entries {
            if let Some(g) = e.goal.as_mut().and_then(|g| g.downcast_mut::<T>()) {
                f(g);
            }
        }
    }

    /// The first goal of type `T`.
    pub fn find<T: 'static>(&self) -> Option<&T> {
        self.entries
            .iter()
            .find_map(|e| e.goal.as_ref().and_then(|g| g.downcast_ref::<T>()))
    }
}

fn selector<'a>(t: &'a mut Turn, which: Which) -> &'a mut Selector {
    match which {
        Which::Goals => &mut t.mind.goals,
        Which::Targets => &mut t.mind.targets,
    }
}

fn selector_ref<'a>(t: &'a Turn, which: Which) -> &'a Selector {
    match which {
        Which::Goals => &t.mind.goals,
        Which::Targets => &t.mind.targets,
    }
}

/// Run `f` on goal `index` of `which`, taken out of its entry meanwhile.
fn with_goal<R>(
    t: &mut Turn,
    which: Which,
    index: usize,
    f: impl FnOnce(&mut dyn Goal, &mut Turn) -> R,
) -> R {
    let mut goal = selector(t, which).entries[index]
        .goal
        .take()
        .expect("a goal runs one callback at a time");
    let result = f(&mut *goal, t);
    selector(t, which).entries[index].goal = Some(goal);
    result
}

fn len(t: &Turn, which: Which) -> usize {
    selector_ref(t, which).entries.len()
}

/// `GoalSelector.tick`: one update of selector `which`.
pub fn tick(t: &mut Turn, which: Which) {
    cleanup(t, which);
    update(t, which);
    tick_running(t, which, true);
}

// Stop what holds a disabled flag or cannot continue, then free the flags of
// goals no longer running.
fn cleanup(t: &mut Turn, which: Which) {
    for index in 0..len(t, which) {
        let entry = &selector_ref(t, which).entries[index];
        if !entry.running {
            continue;
        }
        if disabled(t, which, entry.flags) {
            stop(t, which, index);
            continue;
        }
        let keep = with_goal(t, which, index, |g, t| g.can_continue(t));
        if !keep {
            stop(t, which, index);
        }
    }
    let s = selector(t, which);
    for i in 0..4 {
        if let Some(holder) = s.locks[i] {
            if !s.entries[holder].running {
                s.locks[i] = None;
            }
        }
    }
}

fn update(t: &mut Turn, which: Which) {
    for index in 0..len(t, which) {
        let entry = &selector_ref(t, which).entries[index];
        let flags = entry.flags;
        if entry.running || disabled(t, which, flags) || !replaceable(t, which, index) {
            continue;
        }
        if !with_goal(t, which, index, |g, t| g.can_use(t)) {
            continue;
        }
        for flag in FLAGS {
            if flags & flag == 0 {
                continue;
            }
            if let Some(holder) = selector_ref(t, which).lock(flag) {
                stop(t, which, holder);
            }
            selector(t, which).locks[slot(flag)] = Some(index);
        }
        start(t, which, index);
    }
}

// `goalContainsAnyFlags(goal, disabledFlags)`: the goal selector's only.
fn disabled(t: &Turn, which: Which, flags: u8) -> bool {
    which == Which::Goals && t.mind.disabled & flags != 0
}

// `goalCanBeReplacedForAllFlags`: each flag free, or held by an
// interruptable goal of a higher priority number.
fn replaceable(t: &Turn, which: Which, index: usize) -> bool {
    let s = selector_ref(t, which);
    let entry = &s.entries[index];
    FLAGS.iter().all(|&flag| {
        if entry.flags & flag == 0 {
            return true;
        }
        match s.lock(flag) {
            None => true,
            Some(holder) => {
                let holder = &s.entries[holder];
                // A goal mid-callback cannot hold a flag another asks about.
                holder.goal.as_ref().is_some_and(|g| g.interruptable())
                    && entry.priority < holder.priority
            }
        }
    })
}

/// `tickRunningGoals`: tick the running goals (all of them, or those
/// updated every tick).
pub fn tick_running(t: &mut Turn, which: Which, all: bool) {
    for index in 0..len(t, which) {
        let entry = &selector_ref(t, which).entries[index];
        let every = entry.goal.as_ref().is_some_and(|g| g.every_tick());
        if entry.running && (all || every) {
            with_goal(t, which, index, |g, t| g.tick(t));
        }
    }
}

fn start(t: &mut Turn, which: Which, index: usize) {
    selector(t, which).entries[index].running = true;
    with_goal(t, which, index, |g, t| g.start(t));
}

/// `WrappedGoal.stop`: stop goal `index` of `which` if it runs.
pub fn stop(t: &mut Turn, which: Which, index: usize) {
    let entry = &mut selector(t, which).entries[index];
    if entry.running {
        entry.running = false;
        with_goal(t, which, index, |g, t| g.stop(t));
    }
}
