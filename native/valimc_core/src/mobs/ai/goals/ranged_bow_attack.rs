//! `RangedBowAttackGoal` (`Goals.RangedBowAttack`, skeletons): while it has
//! a target and holds a bow, it walks toward the target until within its
//! radius and in sight for a second, then holds still and circles it
//! (strafing, switching direction now and then by chance, backing off close
//! by), looking at it; it draws the bow when its cooldown is over and shoots
//! once the bow has been drawn for a second and the target is in sight, or
//! lets go after three seconds out of sight.

use crate::mobs::ai::effect::{Effect, Shot};
use crate::mobs::ai::fmath::{emin, f};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::item_id;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::model::{Hand, Slot};

#[derive(Clone, Debug, PartialEq)]
pub struct RangedBowAttack {
    pub speed: f64,
    pub interval: i64,
    pub radius_sq: f64,
    pub attack_time: i64,
    pub see_time: i64,
    pub clockwise: bool,
    pub backwards: bool,
    pub strafing_time: i64,
}

impl RangedBowAttack {
    pub fn new(speed: f64, interval: i64, radius: f64) -> RangedBowAttack {
        RangedBowAttack {
            speed,
            interval,
            radius_sq: f(f(radius) * f(radius)),
            attack_time: -1,
            see_time: 0,
            clockwise: false,
            backwards: false,
            strafing_time: -1,
        }
    }

    /// `setMinAttackInterval`.
    pub fn set_interval(&mut self, ticks: i64) {
        self.interval = ticks;
    }

    fn fight(&mut self, t: &mut Turn, target: &Seen) {
        let distance = t.distance_sq(target.position);
        let seen = t.sees(&target.reference);
        if seen != (self.see_time > 0) {
            self.see_time = 0;
        }
        self.see_time += if seen { 1 } else { -1 };
        if distance <= self.radius_sq && self.see_time >= 20 {
            self.strafing_time += 1;
            navigation::stop(t);
        } else {
            navigation::move_to_entity(t, target, self.speed, 0);
            self.strafing_time = -1;
        }
        if self.strafing_time >= 20 {
            if t.float() < 0.3 {
                self.clockwise = !self.clockwise;
            }
            if t.float() < 0.3 {
                self.backwards = !self.backwards;
            }
            self.strafing_time = 0;
        }
        if self.strafing_time > -1 {
            if distance > f(self.radius_sq * f(0.75)) {
                self.backwards = false;
            } else if distance < f(self.radius_sq * f(0.25)) {
                self.backwards = true;
            }
            t.strafe(
                if self.backwards { -0.5 } else { 0.5 },
                if self.clockwise { 0.5 } else { -0.5 },
            );
            t.look_at_entity(target, 30.0, 30.0);
        } else {
            t.look_at([target.x(), target.eye_y(), target.z()], 30.0, 30.0);
        }
        self.shoot(t, target, seen);
    }

    fn shoot(&mut self, t: &mut Turn, target: &Seen, seen: bool) {
        if t.using() {
            if !seen && self.see_time < -60 {
                t.stop_using();
            } else if seen && t.ticks_using() >= 20 {
                let power = power(t.ticks_using());
                t.stop_using();
                perform(t, target, power);
                self.attack_time = self.interval;
            }
        } else if self.attack_time - 1 <= 0 && self.see_time >= -60 {
            self.attack_time -= 1;
            let hand = hand(t);
            t.start_using(hand);
        } else {
            self.attack_time -= 1;
        }
    }
}

fn bow(t: &Turn) -> Option<i32> {
    t.level.facts.items.id("minecraft:bow")
}

fn holding(t: &Turn) -> bool {
    bow(t).is_some_and(|b| t.holding(b))
}

// `ProjectileUtil.getWeaponHoldingHand`: the main hand unless only the off
// hand holds a bow.
fn hand(t: &Turn) -> Hand {
    let main = t
        .mob
        .body
        .mob
        .equipment
        .get(Slot::Mainhand)
        .and_then(item_id);
    if main.is_some() && main == bow(t) {
        Hand::MainHand
    } else {
        Hand::OffHand
    }
}

/// `BowItem.getPowerForTime`.
pub fn power(ticks: i32) -> f64 {
    let p = f(ticks as f64 / 20.0);
    let p = f(f(f(p * p) + f(p * 2.0)) / 3.0);
    emin(p, 1.0)
}

// `performRangedAttack`: an arrow at the target (made by the owner), then
// the shot's sound with the mob's own pitch draw.
fn perform(t: &mut Turn, target: &Seen, power: f64) {
    let r = t.float();
    let pitch = f(1.0 / f(f(r * f(0.4)) + f(0.8)));
    let from = [t.x(), t.eye_y(), t.z()];
    t.effect(Effect::Shoot(Shot {
        target: target.reference,
        at: [target.x(), target.y(), target.z(), target.height],
        from,
        power,
        pitch,
    }));
}

impl Goal for RangedBowAttack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.target().is_some() && holding(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        (t.target().is_some() || !t.mind.navigation.done()) && holding(t)
    }

    fn start(&mut self, t: &mut Turn) {
        t.set_aggressive(true);
    }

    fn stop(&mut self, t: &mut Turn) {
        t.set_aggressive(false);
        t.stop_using();
        self.see_time = 0;
        self.attack_time = -1;
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(target) = t.target() {
            self.fight(t, &target);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.RangedBowAttack"
    }
}
