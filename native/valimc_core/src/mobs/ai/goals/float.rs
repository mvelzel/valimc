//! `FloatGoal` (`Goals.Float`): in water deeper than its jump threshold, or
//! in lava, it jumps (80%).

use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Float;

impl Float {
    pub fn new() -> Float {
        Float
    }
}

impl Goal for Float {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.mob.body.mob.motion.water > t.jump_threshold() || t.in_lava()
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        if t.float() < f(0.8) {
            t.jump();
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.Float"
    }
}
