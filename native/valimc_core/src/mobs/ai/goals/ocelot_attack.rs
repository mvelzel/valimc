//! `OcelotAttackGoal` (`Goals.OcelotAttack`, a cat's): it goes for its
//! target while it lives within fifteen blocks, looking at it, sprinting
//! close by, creeping within fifteen blocks and walking otherwise, and
//! within twice its width hits it every 20 ticks (without a swing).

use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::Turn;
use crate::mobs::sensing::Ref;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct OcelotAttack {
    pub target: Option<Ref>,
    pub attack_time: i64,
}

impl OcelotAttack {
    pub fn new() -> OcelotAttack {
        OcelotAttack::default()
    }

    fn usable(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            None => false,
            Some(target) => {
                self.target = Some(target.reference);
                true
            }
        }
    }
}

impl Goal for OcelotAttack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.usable(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.entity(self.target.as_ref()) {
            Some(target) if target.alive => {
                if t.distance_sq(target.position) > 225.0 {
                    false
                } else if !t.mind.navigation.done() {
                    true
                } else {
                    self.usable(t)
                }
            }
            _ => false,
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        self.target = None;
        navigation::stop(t);
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(target) = t.entity(self.target.as_ref()) else {
            return;
        };
        t.look_at([target.x(), target.eye_y(), target.z()], 30.0, 30.0);
        let twice = f(t.width * 2.0);
        let melee = f(twice * twice);
        let distance = t.distance_sq(target.position);
        let speed = if distance > melee && distance < 16.0 {
            1.33
        } else if distance < 225.0 {
            0.6
        } else {
            0.8
        };
        navigation::move_to_entity(t, &target, speed, 1);
        self.attack_time = (self.attack_time - 1).max(0);
        if distance <= melee && self.attack_time <= 0 {
            t.effect(Effect::Attack(target.reference));
            self.attack_time = 20;
            let hooks = t.hooks;
            hooks.hit(t, &target);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.OcelotAttack"
    }
}
