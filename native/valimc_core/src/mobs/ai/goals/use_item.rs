//! `UseItemGoal` (`Goals.UseItem`, a wandering trader's drinks): when its
//! test holds of the mob it takes `stack` in its main hand and uses it; once
//! it no longer uses it, its hand is emptied and it plays `sound` (at a
//! pitch of 0.9 to 1.1).

use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::turn::Turn;
use crate::mobs::model::{Hand, Slot};
use crate::mobs::term::Value;

#[derive(Clone, Debug, PartialEq)]
pub struct UseItem {
    pub stack: Value,
    pub sound: Option<String>,
    /// The family's `can_use` test of the mob.
    pub test: Tag,
}

impl UseItem {
    pub fn new(stack: Value, sound: Option<&str>, test: Tag) -> UseItem {
        UseItem {
            stack,
            sound: sound.map(str::to_owned),
            test,
        }
    }
}

impl Goal for UseItem {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let hooks = t.hooks;
        hooks.test(t, self.test)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        t.using()
    }

    fn start(&mut self, t: &mut Turn) {
        t.mob
            .body
            .mob
            .equipment
            .set(Slot::Mainhand, Some(self.stack.clone()));
        t.start_using(Hand::MainHand);
    }

    fn stop(&mut self, t: &mut Turn) {
        t.mob.body.mob.equipment.set(Slot::Mainhand, None);
        if let Some(sound) = &self.sound {
            let r = t.float();
            let pitch = f(f(r * f(0.2)) + f(0.9));
            t.sound(sound, 1.0, pitch);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.UseItem"
    }
}
