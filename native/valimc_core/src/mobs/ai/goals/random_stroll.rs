//! `RandomStrollGoal`, `WaterAvoidingRandomStrollGoal` (`water_avoiding`) and
//! `RandomSwimmingGoal` (`swim`) (`Goals.RandomStroll`): now and then (one
//! chance in half its interval per update), unless idle for 100 ticks, a
//! walk to a random target ten blocks around; a water-avoiding stroll picks
//! land targets (from water, fifteen blocks around), all but a thousandth
//! of the time; a swim picks targets in water. `guard` is a family's test
//! before anything is drawn, `position` a family's own target;
//! `trigger` makes its next update go without the chance.

use crate::mobs::ai::fmath::{f, reduced};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::navigation;
use crate::mobs::ai::random_pos;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, PartialEq)]
pub struct RandomStroll {
    pub speed: f64,
    pub interval: i64,
    pub check_idle: bool,
    pub water_avoiding: bool,
    pub swim: bool,
    pub guard: Option<Tag>,
    pub probability: f64,
    pub position: Option<Tag>,
    pub force: bool,
    pub wanted: Option<[f64; 3]>,
}

/// `RandomStroll.new/2`'s options.
#[derive(Clone, Debug, PartialEq)]
pub struct StrollOptions {
    pub interval: i64,
    pub check_idle: bool,
    pub water_avoiding: bool,
    pub swim: bool,
    pub guard: Option<Tag>,
    pub probability: f64,
    pub position: Option<Tag>,
}

impl Default for StrollOptions {
    fn default() -> StrollOptions {
        StrollOptions {
            interval: 120,
            check_idle: true,
            water_avoiding: false,
            swim: false,
            guard: None,
            probability: 0.001,
            position: None,
        }
    }
}

impl RandomStroll {
    pub fn new(speed: f64, o: StrollOptions) -> RandomStroll {
        RandomStroll {
            speed,
            interval: o.interval,
            check_idle: o.check_idle,
            water_avoiding: o.water_avoiding,
            swim: o.swim,
            guard: o.guard,
            probability: f(o.probability),
            position: o.position,
            force: false,
            wanted: None,
        }
    }

    /// `RandomStrollGoal.trigger`.
    pub fn trigger(&mut self) {
        self.force = true;
    }

    fn position(&self, t: &mut Turn) -> Option<[f64; 3]> {
        if let Some(tag) = self.position {
            let hooks = t.hooks;
            return hooks.position(t, tag);
        }
        if self.swim {
            return random_pos::swimmable(t, 10, 7);
        }
        if !self.water_avoiding {
            return random_pos::default(t, 10, 7);
        }
        if t.in_water() {
            match random_pos::land(t, 15, 7) {
                None => random_pos::default(t, 10, 7),
                found => found,
            }
        } else if t.float() >= self.probability {
            random_pos::land(t, 10, 7)
        } else {
            random_pos::default(t, 10, 7)
        }
    }
}

impl Goal for RandomStroll {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if let Some(tag) = self.guard {
            let hooks = t.hooks;
            if !hooks.test(t, tag) {
                return false;
            }
        }
        if !self.force && self.check_idle && t.mind.no_action >= 100 {
            return false;
        }
        let go = self.force || t.int(reduced(self.interval) as i32) == 0;
        if !go {
            return false;
        }
        match self.position(t) {
            None => false,
            Some(pos) => {
                self.wanted = Some(pos);
                self.force = false;
                true
            }
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !t.mind.navigation.done()
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(p) = self.wanted {
            navigation::move_to(t, p, self.speed);
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        navigation::stop(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.RandomStroll"
    }
}
