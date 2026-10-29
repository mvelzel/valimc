//! `LeapAtTargetGoal` (`Goals.LeapAtTarget`, spiders): on the ground, a
//! target two to four blocks away is leapt at now and then (one update in
//! three): toward it at 0.4 plus a fifth of its motion, `yd` up; it lasts
//! until it lands.

use crate::mobs::ai::fmath::{f, reduced};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::Turn;
use crate::mobs::sensing::Ref;

#[derive(Clone, Debug, PartialEq)]
pub struct LeapAtTarget {
    pub yd: f64,
    pub target: Option<Ref>,
}

impl LeapAtTarget {
    pub fn new(yd: f64) -> LeapAtTarget {
        LeapAtTarget {
            yd: f(yd),
            target: None,
        }
    }
}

impl Goal for LeapAtTarget {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let Some(target) = t.target() else {
            return false;
        };
        let d = t.distance_sq(target.position);
        if d < 4.0 || d > 16.0 || !t.on_ground() {
            return false;
        }
        let n = t.int(reduced(5) as i32);
        self.target = Some(target.reference);
        n == 0
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !t.on_ground()
    }

    fn start(&mut self, t: &mut Turn) {
        let Some(target) = t.entity(self.target.as_ref()) else {
            return;
        };
        let [vx, _, vz] = t.velocity();
        let (dx, dz) = (target.x() - t.x(), target.z() - t.z());
        let (x, z) = if dx * dx + dz * dz > 1.0e-7 {
            let length = (dx * dx + dz * dz).sqrt();
            (dx / length * 0.4 + vx * 0.2, dz / length * 0.4 + vz * 0.2)
        } else {
            (dx, dz)
        };
        t.mob.body.velocity = [x, self.yd, z];
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.LeapAtTarget"
    }
}
