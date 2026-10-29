//! `FollowPlayerRiddenEntityGoal` (`Goals.FollowRidden`): ridden entities
//! are not modelled, so none is ever near enough to follow; it draws
//! nothing.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FollowRidden;

impl FollowRidden {
    pub fn new() -> FollowRidden {
        FollowRidden
    }
}

impl Goal for FollowRidden {
    fn can_use(&mut self, _t: &mut Turn) -> bool {
        false
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.FollowRidden"
    }
}
