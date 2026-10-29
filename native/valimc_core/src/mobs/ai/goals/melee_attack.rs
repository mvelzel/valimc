//! `MeleeAttackGoal` and `ZombieAttackGoal` (`raise_arms`)
//! (`Goals.MeleeAttack`): with a living target it can path to or reach, at
//! most once a second, it walks to the target (a new path every 4 to 10
//! ticks when the target moved or by chance, later far away), looks at it,
//! and hits it when its cooldown is over, the target is within reach of its
//! box and in sight: a swing and an attack. A zombie raises its arms five
//! ticks in, while its next hit is less than half a cooldown away.

use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::paths::NavPath;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::model::Hand;
use crate::mobs::sensing::{inflate, intersects, Kind};

#[derive(Clone, Debug, PartialEq)]
pub struct MeleeAttack {
    pub speed: f64,
    pub follow_unseen: bool,
    pub raise_arms: bool,
    pub path: Option<NavPath>,
    pub pathed: [f64; 3],
    pub recalculate: i64,
    pub cooldown: i64,
    pub last_check: i64,
    pub arms: i64,
}

impl MeleeAttack {
    pub fn new(speed: f64, follow_unseen: bool, raise_arms: bool) -> MeleeAttack {
        MeleeAttack {
            speed,
            follow_unseen,
            raise_arms,
            path: None,
            pathed: [0.0; 3],
            recalculate: 0,
            cooldown: 0,
            last_check: 0,
            arms: 0,
        }
    }

    fn chase(&mut self, t: &mut Turn, target: &Seen) {
        t.look_at([target.x(), target.eye_y(), target.z()], 30.0, 30.0);
        self.recalculate = (self.recalculate - 1).max(0);
        let seen = self.follow_unseen || t.sees(&target.reference);
        if seen && self.recalculate <= 0 && self.repath(t, target) {
            self.do_repath(t, target);
        }
        self.cooldown = (self.cooldown - 1).max(0);
        self.attack(t, target);
    }

    fn repath(&self, t: &mut Turn, target: &Seen) -> bool {
        let [px, py, pz] = self.pathed;
        let (dx, dy, dz) = (target.x() - px, target.y() - py, target.z() - pz);
        if (px == 0.0 && py == 0.0 && pz == 0.0) || dx * dx + dy * dy + dz * dz >= 1.0 {
            true
        } else {
            t.float() < f(0.05)
        }
    }

    fn do_repath(&mut self, t: &mut Turn, target: &Seen) {
        let n = t.int(7) as i64;
        let mut recalculate = 4 + n;
        let distance = t.distance_sq(target.position);
        if distance > 1024.0 {
            recalculate += 10;
        } else if distance > 256.0 {
            recalculate += 5;
        }
        if !navigation::move_to_entity(t, target, self.speed, 0) {
            recalculate += 15;
        }
        self.pathed = target.position;
        self.recalculate = self.adjusted(recalculate);
    }

    fn attack(&mut self, t: &mut Turn, target: &Seen) {
        if self.cooldown <= 0 && within_reach(t, target) && t.sees(&target.reference) {
            t.swing(Hand::MainHand);
            // What the type's `doHurtTarget` does (a creeper's nothing).
            if !t.hooks.harmless(t.type_id) {
                t.effect(Effect::Attack(target.reference));
                let hooks = t.hooks;
                hooks.hit(t, target);
                t.melee(&target.reference);
            }
            self.cooldown = self.adjusted(20);
        }
    }
}

/// `Mob.isWithinMeleeAttackRange`: its box widened by its reach meets the
/// target's.
pub fn within_reach(t: &Turn, target: &Seen) -> bool {
    let reach = (f(2.04)).sqrt() - f(0.6);
    intersects(&inflate(&t.bbox(), reach, 0.0, reach), &target.bbox)
}

impl Goal for MeleeAttack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let time = t.level.time;
        if time - self.last_check < 20 {
            return false;
        }
        self.last_check = time;
        match t.target() {
            Some(target) if target.alive => {
                let path = navigation::path_to_entity(t, &target, 0);
                let ok = path.is_some() || within_reach(t, &target);
                self.path = path;
                ok
            }
            _ => false,
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(target) if target.alive => {
                if self.follow_unseen {
                    target.kind() != Kind::Player || !super::exempt(target.mode)
                } else {
                    !t.mind.navigation.done()
                }
            }
            _ => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::follow(t, self.path.clone(), self.speed);
        t.set_aggressive(true);
        self.recalculate = 0;
        self.cooldown = 0;
        self.arms = 0;
    }

    fn stop(&mut self, t: &mut Turn) {
        t.set_aggressive(false);
        navigation::stop(t);
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(target) = t.target() {
            self.chase(t, &target);
        }
        if self.raise_arms {
            self.arms += 1;
            let raised = self.arms >= 5 && self.cooldown < self.adjusted(20) / 2;
            t.set_aggressive(raised);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.MeleeAttack"
    }
}
