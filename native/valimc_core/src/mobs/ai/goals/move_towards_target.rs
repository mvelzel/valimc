//! `MoveTowardsTargetGoal` (`Goals.MoveTowardsTarget`): with a target within
//! `within` blocks, a walk to a spot 16 blocks toward it (within a quarter
//! turn), kept while the path lasts and the target lives and stays near.

use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::random_pos;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, PartialEq)]
pub struct MoveTowardsTarget {
    pub speed: f64,
    pub within: f64,
    pub wanted: Option<[f64; 3]>,
}

impl MoveTowardsTarget {
    pub fn new(speed: f64, within: f64) -> MoveTowardsTarget {
        MoveTowardsTarget {
            speed,
            within: f(within),
            wanted: None,
        }
    }
}

impl Goal for MoveTowardsTarget {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let Some(target) = t.target() else {
            return false;
        };
        if t.distance_sq(target.position) > self.within * self.within {
            return false;
        }
        let radians = f(std::f64::consts::FRAC_PI_2);
        match random_pos::default_towards(t, 16, 7, target.position, radians) {
            None => false,
            Some(p) => {
                self.wanted = Some(p);
                true
            }
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        let target = t.target();
        !t.mind.navigation.done()
            && target.is_some_and(|tg| {
                tg.alive && t.distance_sq(tg.position) < self.within * self.within
            })
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(p) = self.wanted {
            navigation::move_to(t, p, self.speed);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.MoveTowardsTarget"
    }
}
