//! `MoveTowardsRestrictionGoal` (`Goals.MoveTowardsRestriction`): a mob
//! outside its home walks to a random spot up to 16 blocks toward it
//! (within a quarter turn of its way), until its navigation is done.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::random_pos;
use crate::mobs::ai::turn::Turn;

const QUARTER: f64 = std::f64::consts::FRAC_PI_2 as f32 as f64;

#[derive(Clone, Debug, PartialEq)]
pub struct MoveTowardsRestriction {
    pub speed: f64,
    pub wanted: Option<[f64; 3]>,
}

impl MoveTowardsRestriction {
    pub fn new(speed: f64) -> MoveTowardsRestriction {
        MoveTowardsRestriction {
            speed,
            wanted: None,
        }
    }
}

impl Goal for MoveTowardsRestriction {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let Some([hx, hy, hz]) = t.mob.body.mob.home.as_ref().map(|h| h.center) else {
            return false;
        };
        if random_pos::within_home(t, t.block()) {
            return false;
        }
        let towards = [hx as f64 + 0.5, hy as f64, hz as f64 + 0.5];
        match random_pos::default_towards(t, 16, 7, towards, QUARTER) {
            None => false,
            Some(p) => {
                self.wanted = Some(p);
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

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.MoveTowardsRestriction"
    }
}
