//! `ClimbOnTopOfPowderSnowGoal` (`Goals.ClimbPowderSnow`): a mob that walks
//! on powder snow, inside powder snow after its last move, jumps while the
//! block above it is powder snow or has no collision.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::turn::Turn;
use crate::physics::table::Entry;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClimbPowderSnow;

impl ClimbPowderSnow {
    pub fn new() -> ClimbPowderSnow {
        ClimbPowderSnow
    }
}

impl Goal for ClimbPowderSnow {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let facts = t.level.facts;
        if !(t.mob.body.mob.motion.powder_snow
            && facts.entity_tag(t.type_id, "minecraft:powder_snow_walkable_mobs"))
        {
            return false;
        }
        let [x, y, z] = t.block();
        match t.level.block([x, y + 1, z]) {
            None => false,
            Some(above) => {
                facts.blocks.default_state("powder_snow") == Some(above) || empty(t, above)
            }
        }
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        t.jump();
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.ClimbPowderSnow"
    }
}

// `getCollisionShape(level, pos) == Shapes.empty()` with no entity context.
fn empty(t: &Turn, state: u16) -> bool {
    let table = &t.level.physics.shapes;
    match table
        .states
        .get(state as usize)
        .and_then(|&e| table.entries.get(e as usize))
    {
        Some(Entry::Fixed(i) | Entry::Offset(i, _)) => table.shapes[*i].is_empty(),
        _ => false,
    }
}
