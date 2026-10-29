//! `FollowParentGoal` (`Goals.FollowParent`): a baby follows the nearest
//! adult of its type within eight blocks (four up and down) once more than
//! three away, repathing every ten ticks, until within three or past
//! sixteen blocks.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::{Kinds, Turn};
use crate::mobs::sensing::{inflate, Ref};

#[derive(Clone, Debug, PartialEq)]
pub struct FollowParent {
    pub speed: f64,
    pub parent: Option<Ref>,
    pub recalculate: i64,
}

impl FollowParent {
    pub fn new(speed: f64) -> FollowParent {
        FollowParent {
            speed,
            parent: None,
            recalculate: 0,
        }
    }
}

fn age(t: &Turn) -> i64 {
    t.data().age().unwrap_or(0)
}

impl Goal for FollowParent {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if age(t) >= 0 {
            return false;
        }
        let b = inflate(&t.bbox(), 8.0, 4.0, 8.0);
        let mut closest = None;
        let mut distance: Option<f64> = None;
        for other in t.mobs_in(Kinds::Types(&[t.type_id]), &b) {
            let od = t.distance_sq(other.position);
            if other.age >= 0 && distance.is_none_or(|d| od <= d) {
                closest = Some(other);
                distance = Some(od);
            }
        }
        match (closest, distance) {
            (Some(c), Some(d)) if d >= 9.0 => {
                self.parent = Some(c.reference);
                true
            }
            _ => false,
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.entity(self.parent.as_ref()) {
            Some(p) if p.alive && age(t) < 0 => {
                let d = t.distance_sq(p.position);
                (9.0..=256.0).contains(&d)
            }
            _ => false,
        }
    }

    fn start(&mut self, _t: &mut Turn) {
        self.recalculate = 0;
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.parent = None;
    }

    fn tick(&mut self, t: &mut Turn) {
        let recalculate = self.recalculate - 1;
        if recalculate <= 0 {
            if let Some(parent) = t.entity(self.parent.as_ref()) {
                navigation::move_to_entity(t, &parent, self.speed, 1);
            }
            self.recalculate = self.adjusted(10);
        } else {
            self.recalculate = recalculate;
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.FollowParent"
    }
}
