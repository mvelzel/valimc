//! `BreathAirGoal` (`Goals.BreathAir`): a mob low on air (under 140) swims
//! up to the first block above it (eight up, its column then the four
//! beside it) that gives air, else eight blocks up, looking again each tick,
//! and moves itself once more toward it each tick before its travel
//! (`MobMotion.pre_move`). It cannot be interrupted.

use crate::mobs::ai::fmath;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::Turn;
use crate::mobs::level::FluidKind;
use crate::path::LAND;

const COLUMNS: [(i32, i32); 5] = [(0, 0), (0, -1), (1, 0), (0, 1), (-1, 0)];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct BreathAir;

impl BreathAir {
    pub fn new() -> BreathAir {
        BreathAir
    }
}

fn gives_air(t: &Turn, pos: [i32; 3]) -> bool {
    match t.level.block(pos) {
        None => false,
        Some(state) => {
            (t.level.fluid(pos) == FluidKind::Empty
                || t.level.facts.blocks.is(state, "bubble_column"))
                && t.paths
                    .flags
                    .get(state as usize)
                    .is_some_and(|f| f & LAND != 0)
        }
    }
}

// `findAirPosition`: `BlockPos.neighborColumn` up eight blocks.
fn find_air(t: &mut Turn) {
    let [x, y, z] = t.block();
    let target = COLUMNS
        .iter()
        .find_map(|&(dx, dz)| {
            (y..=y + 8)
                .map(|cy| [x + dx, cy, z + dz])
                .find(|&p| gives_air(t, p))
        })
        .unwrap_or_else(|| {
            [
                fmath::floor(t.x()),
                fmath::floor(t.y() + 8.0),
                fmath::floor(t.z()),
            ]
        });
    let [tx, ty, tz] = target;
    navigation::move_to(t, [tx as f64, ty as f64 + 1.0, tz as f64], 1.0);
}

impl Goal for BreathAir {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.mob.body.mob.living.air_supply < 140
    }

    fn interruptable(&self) -> bool {
        false
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::stop(t);
        find_air(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        find_air(t);
        t.mob.body.mob.motion.pre_move = Some(t.yaw());
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.BreathAir"
    }
}
