//! `LookAtPlayerGoal` (`Goals.LookAtPlayer`): by chance (2% an update), the
//! nearest player within its look distance, looked at for 40 to 79 ticks
//! while in range; with `only_horizontal` (a shulker) at its own eye
//! height. With `types` it looks at the nearest section mob of those types
//! instead, within its distance and three blocks up or down of its box.

use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::{Kinds, Targeting, Turn};
use crate::mobs::sensing::{inflate, Ref};

#[derive(Clone, Debug, PartialEq)]
pub struct LookAtPlayer {
    pub distance: f64,
    pub probability: f64,
    pub only_horizontal: bool,
    pub types: Option<Vec<u16>>,
    pub look_at: Option<Ref>,
    pub time: i64,
}

impl LookAtPlayer {
    /// `new(distance, probability \\ 0.02, opts)`.
    pub fn new(
        distance: f64,
        probability: f64,
        only_horizontal: bool,
        types: Option<Vec<u16>>,
    ) -> LookAtPlayer {
        LookAtPlayer {
            distance: f(distance),
            probability: f(probability),
            only_horizontal,
            types,
            look_at: None,
            time: 0,
        }
    }
}

impl Goal for LookAtPlayer {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.float() >= self.probability {
            return false;
        }
        let targeting = Targeting::new(false).range(self.distance);
        let point = [t.x(), t.eye_y(), t.z()];
        let found = match &self.types {
            None => t.nearest_player(&targeting, point),
            Some(types) => {
                let d = self.distance;
                let b = inflate(&t.bbox(), d, 3.0, d);
                t.nearest_mob(Kinds::Types(types), &b, &targeting, point)
            }
        };
        self.look_at = found.map(|e| e.reference);
        found.is_some()
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.entity(self.look_at.as_ref()) {
            Some(target) if target.alive => {
                if t.distance_sq(target.position) > f(self.distance * self.distance) {
                    false
                } else {
                    self.time > 0
                }
            }
            _ => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        let n = t.int(40) as i64;
        self.time = self.adjusted(40 + n);
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.look_at = None;
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(target) = t.entity(self.look_at.as_ref()) {
            if target.alive {
                let y = if self.only_horizontal {
                    t.eye_y()
                } else {
                    target.eye_y()
                };
                self.time -= 1;
                t.look_at_point([target.x(), y, target.z()]);
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.LookAtPlayer"
    }
}
