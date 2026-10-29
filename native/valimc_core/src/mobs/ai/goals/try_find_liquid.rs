//! `TryFindLiquidGoal` (`Goals.TryFindLiquid`): a mob on the ground outside
//! water sets its move control's wanted position on the first water within
//! two blocks around and below it.

use crate::mobs::ai::fmath;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::Turn;
use crate::mobs::level::FluidKind;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TryFindLiquid;

impl TryFindLiquid {
    pub fn new() -> TryFindLiquid {
        TryFindLiquid
    }
}

impl Goal for TryFindLiquid {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.on_ground() && t.level.fluid(t.block()) != FluidKind::Water
    }

    fn start(&mut self, t: &mut Turn) {
        let [x, y, z] = t.pos();
        let lo = fmath::block([x - 2.0, y - 2.0, z - 2.0]);
        let hi = fmath::block([x + 2.0, y, z + 2.0]);
        // `BlockPos.betweenClosed`: x fastest, then y, then z.
        let found = (lo[2]..=hi[2]).find_map(|z| {
            (lo[1]..=hi[1]).find_map(|y| {
                (lo[0]..=hi[0])
                    .find(|&x| t.level.fluid([x, y, z]) == FluidKind::Water)
                    .map(|x| [x, y, z])
            })
        });
        if let Some([x, y, z]) = found {
            t.move_to([x as f64, y as f64, z as f64], 1.0);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.TryFindLiquid"
    }
}
