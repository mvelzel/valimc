//! A registered goal whose system is not modelled (`Goals.Idle`): it never
//! runs and draws nothing. `name` is the vanilla goal it stands for.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::Turn;

#[derive(Clone, Debug, PartialEq)]
pub struct Idle {
    pub vanilla: String,
}

impl Idle {
    pub fn new(vanilla: &str) -> Idle {
        Idle {
            vanilla: vanilla.to_owned(),
        }
    }
}

impl Goal for Idle {
    fn can_use(&mut self, _t: &mut Turn) -> bool {
        false
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.Idle"
    }
}
