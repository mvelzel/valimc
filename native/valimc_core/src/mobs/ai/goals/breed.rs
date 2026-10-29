//! `BreedGoal` (`Goals.Breed`): in love, the nearest mob of its type within
//! eight blocks also in love and not panicking is walked to and looked at;
//! after 60 ticks (30 updates) within three blocks they breed. `guard`
//! keeps it from starting (a turtle with an egg) and `breeding` breeds its
//! own way (a turtle's egg); None: `Animal.breed`.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::{Kinds, Seen, Targeting, Turn};
use crate::mobs::sensing::{inflate, Ref};

#[derive(Clone, Debug, PartialEq)]
pub struct Breed {
    pub speed: f64,
    pub partner: Option<Ref>,
    pub love: i64,
    pub guard: Option<Tag>,
    pub breeding: Option<Tag>,
}

impl Breed {
    pub fn new(speed: f64, guard: Option<Tag>, breeding: Option<Tag>) -> Breed {
        Breed {
            speed,
            partner: None,
            love: 0,
            guard,
            breeding,
        }
    }

    fn partner(&self, t: &mut Turn) -> Option<Seen> {
        let b = inflate(&t.bbox(), 8.0, 8.0, 8.0);
        let targeting = Targeting::new(false).range(8.0).sight(false);
        let candidates = t.mobs_in(Kinds::Types(&[t.type_id]), &b);
        let mut best: Option<Seen> = None;
        for other in candidates {
            let passes = t.test(&other.reference, &targeting);
            let fits = passes
                && other.uuid() != t.uuid
                && other.in_love > 0
                && !other.panicking
                && best.is_none_or(|b| t.distance_sq(other.position) < t.distance_sq(b.position));
            if fits {
                best = Some(other);
            }
        }
        best
    }
}

impl Goal for Breed {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.data().in_love().unwrap_or(0) <= 0 {
            return false;
        }
        if let Some(tag) = self.guard {
            let hooks = t.hooks;
            if !hooks.test(t, tag) {
                return false;
            }
        }
        let partner = self.partner(t);
        self.partner = partner.map(|p| p.reference);
        partner.is_some()
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.entity(self.partner.as_ref()) {
            Some(p) if p.alive && p.in_love > 0 && !p.panicking => self.love < 60,
            _ => false,
        }
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.partner = None;
        self.love = 0;
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(partner) = t.entity(self.partner.as_ref()) else {
            return;
        };
        let x_max = t.facts.max_head_x_rot;
        t.look_at([partner.x(), partner.eye_y(), partner.z()], 10.0, x_max);
        navigation::move_to_entity(t, &partner, self.speed, 1);
        let love = self.love + 1;
        if love >= self.adjusted(60) && t.distance_sq(partner.position) < 9.0 {
            let hooks = t.hooks;
            hooks.breed(t, self.breeding, &partner);
        }
        self.love = love;
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.Breed"
    }
}
