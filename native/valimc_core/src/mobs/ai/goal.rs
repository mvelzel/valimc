//! The goal contract (`Valimc.AI.Goal`, vanilla's `Goal`): a goal is a
//! value holding its own state, asked and changed over the mob's turn. The
//! defaults are vanilla's: continue while usable, interruptable, nothing on
//! start, stop or tick, updated every other tick. A draw of the mob's random
//! is a change of the turn, so every callback takes it mutably.
//!
//! Goals are boxed trait objects so a family's own goals sit beside the
//! common ones in one selector; a selector finds goals of a type by
//! downcasting (`Selector::change`, `running`), as the Elixir finds them by
//! module.

use super::fmath::reduced;
use super::turn::Turn;
use std::any::Any;
use std::fmt::Debug;

/// `Goal.Flag` bits, in `EnumSet` order.
pub const MOVE: u8 = 1;
pub const LOOK: u8 = 2;
pub const JUMP: u8 = 4;
pub const TARGET: u8 = 8;

pub trait Goal: GoalBox + Debug + Send + Sync {
    /// `canUse`.
    fn can_use(&mut self, t: &mut Turn) -> bool;

    /// `canContinueToUse`.
    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.can_use(t)
    }

    fn start(&mut self, _t: &mut Turn) {}

    fn stop(&mut self, _t: &mut Turn) {}

    fn tick(&mut self, _t: &mut Turn) {}

    /// `requiresUpdateEveryTick`.
    fn every_tick(&self) -> bool {
        false
    }

    /// `isInterruptable`.
    fn interruptable(&self) -> bool {
        true
    }

    /// The Elixir module it ports (for parity checks and debugging).
    fn name(&self) -> &'static str;

    /// `adjustedTickDelay`: a goal updated every other tick halves delays.
    fn adjusted(&self, ticks: i64) -> i64 {
        if self.every_tick() {
            ticks
        } else {
            reduced(ticks)
        }
    }
}

/// Cloning, comparing and downcasting boxed goals.
pub trait GoalBox: Any {
    fn clone_goal(&self) -> Box<dyn Goal>;
    fn eq_goal(&self, other: &dyn Goal) -> bool;
    fn as_any(&self) -> &dyn Any;
    fn as_any_mut(&mut self) -> &mut dyn Any;
}

impl<T: Goal + Clone + PartialEq> GoalBox for T {
    fn clone_goal(&self) -> Box<dyn Goal> {
        Box::new(self.clone())
    }

    fn eq_goal(&self, other: &dyn Goal) -> bool {
        other.as_any().downcast_ref::<T>() == Some(self)
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}

impl Clone for Box<dyn Goal> {
    fn clone(&self) -> Self {
        (**self).clone_goal()
    }
}

impl PartialEq for Box<dyn Goal> {
    fn eq(&self, other: &Self) -> bool {
        (**self).eq_goal(&**other)
    }
}

impl dyn Goal {
    /// Whether the goal is a `T`.
    pub fn is<T: 'static>(&self) -> bool {
        self.as_any().is::<T>()
    }

    pub fn downcast_ref<T: 'static>(&self) -> Option<&T> {
        self.as_any().downcast_ref()
    }

    pub fn downcast_mut<T: 'static>(&mut self) -> Option<&mut T> {
        self.as_any_mut().downcast_mut()
    }
}
