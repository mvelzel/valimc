//! `RandomLookAroundGoal` (`Goals.RandomLookAround`): by chance (2% an
//! update), a random direction for 20 to 39 ticks.

use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RandomLookAround {
    pub x: f64,
    pub z: f64,
    pub time: i64,
}

impl RandomLookAround {
    pub fn new() -> RandomLookAround {
        RandomLookAround::default()
    }
}

impl Goal for RandomLookAround {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.float() < f(0.02)
    }

    fn can_continue(&mut self, _t: &mut Turn) -> bool {
        self.time >= 0
    }

    fn start(&mut self, t: &mut Turn) {
        let d = t.double();
        let (sin, cos) = fmath::java_sin_cos(std::f64::consts::PI * 2.0 * d);
        let n = t.int(20);
        self.x = cos;
        self.z = sin;
        self.time = 20 + n as i64;
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        self.time -= 1;
        let p = [t.x() + self.x, t.eye_y(), t.z() + self.z];
        t.look_at_point(p);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.RandomLookAround"
    }
}
