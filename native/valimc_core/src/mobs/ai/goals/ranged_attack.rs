//! `RangedAttackGoal` (`Goals.RangedAttack`: a witch's potions, a drowned's
//! trident): while it has a living target it walks toward it until within
//! its radius and in sight for five ticks, looking at it; when its countdown
//! reaches zero in sight it attacks (its family's `perform` with the power,
//! the distance over the radius within 0.1 to 1) and waits between its least
//! and most interval by that distance.

use crate::mobs::ai::fmath::{emax, emin, f};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::sensing::Ref;

#[derive(Clone, Debug, PartialEq)]
pub struct RangedAttack {
    pub speed: f64,
    pub min: i64,
    pub max: i64,
    pub radius: f64,
    pub radius_sq: f64,
    pub perform: Tag,
    pub target: Option<Ref>,
    pub attack_time: i64,
    pub see_time: i64,
}

impl RangedAttack {
    pub fn new(speed: f64, min: i64, max: i64, radius: f64, perform: Tag) -> RangedAttack {
        let radius = f(radius);
        RangedAttack {
            speed,
            min,
            max,
            radius,
            radius_sq: f(radius * radius),
            perform,
            target: None,
            attack_time: -1,
            see_time: 0,
        }
    }

    fn fight(&mut self, t: &mut Turn, target: &Seen) {
        let distance = t.distance_sq(target.position);
        let seen = t.sees(&target.reference);
        self.see_time = if seen { self.see_time + 1 } else { 0 };
        if distance <= self.radius_sq && self.see_time >= 5 {
            navigation::stop(t);
        } else {
            navigation::move_to_entity(t, target, self.speed, 0);
        }
        t.look_at([target.x(), target.eye_y(), target.z()], 30.0, 30.0);
        let attack_time = self.attack_time - 1;
        let (min, max) = (self.min as f64, self.max as f64);
        if attack_time == 0 && !seen {
            self.attack_time = attack_time;
        } else if attack_time == 0 {
            let dist = f(f(distance.sqrt()) / self.radius);
            let power = emin(emax(dist, f(0.1)), 1.0);
            let hooks = t.hooks;
            hooks.perform(t, self.perform, target, power);
            self.attack_time = f(dist * (max - min) + min).floor() as i64;
        } else if attack_time < 0 {
            let delta = distance.sqrt() / self.radius;
            self.attack_time = (min + delta * (max - min)).floor() as i64;
        } else {
            self.attack_time = attack_time;
        }
    }

    fn usable(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(target) if target.alive => {
                self.target = Some(target.reference);
                true
            }
            _ => false,
        }
    }
}

impl Goal for RangedAttack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.usable(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if self.usable(t) {
            return true;
        }
        let alive = t.entity(self.target.as_ref()).is_some_and(|e| e.alive);
        alive && !t.mind.navigation.done()
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.target = None;
        self.see_time = 0;
        self.attack_time = -1;
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(target) = t.entity(self.target.as_ref()) {
            self.fight(t, &target);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.RangedAttack"
    }
}
