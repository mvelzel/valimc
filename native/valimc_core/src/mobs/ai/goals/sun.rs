//! `RestrictSunGoal` and `FleeSunGoal` (`Goals.RestrictSun`,
//! `Goals.FleeSun`, skeletons and zombies by day).

use super::super::navigation::NavKind;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::navigation;
use crate::mobs::ai::random_pos::walk_value;
use crate::mobs::ai::turn::Turn;
use crate::mobs::model::Slot;

fn bare_head(t: &Turn) -> bool {
    t.mob.body.mob.equipment.get(Slot::Head).is_none()
}

/// `RestrictSunGoal`: by day, a mob with a bare head and ground navigation
/// keeps its paths out of the sun.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RestrictSun;

impl RestrictSun {
    pub fn new() -> RestrictSun {
        RestrictSun
    }
}

impl Goal for RestrictSun {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.level.bright && bare_head(t) && t.mind.navigation.kind == NavKind::Ground
    }

    fn start(&mut self, t: &mut Turn) {
        navigation::avoid_sun(t, true);
    }

    fn stop(&mut self, t: &mut Turn) {
        if t.mind.navigation.kind == NavKind::Ground {
            navigation::avoid_sun(t, false);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.RestrictSun"
    }
}

/// `FleeSunGoal`: by day, a burning mob with no target and a bare head under
/// the open sky walks to a random spot within ten blocks out of the sky's
/// sight where the light keeps it off its usual walks (ten tries).
#[derive(Clone, Debug, PartialEq)]
pub struct FleeSun {
    pub speed: f64,
    pub wanted: Option<[f64; 3]>,
}

impl FleeSun {
    pub fn new(speed: f64) -> FleeSun {
        FleeSun {
            speed,
            wanted: None,
        }
    }
}

// `getHidePos`.
fn hide(t: &mut Turn) -> Option<[f64; 3]> {
    for _ in 0..10 {
        let [x, y, z] = t.block();
        let dx = t.int(20);
        let dy = t.int(6);
        let dz = t.int(20);
        let pos = [x + dx - 10, y + dy - 3, z + dz - 10];
        if !t.level.sees_sky(pos) && walk_value(t, pos) < 0.0 {
            return Some([pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5]);
        }
    }
    None
}

impl Goal for FleeSun {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.mind.target.is_none()
            && t.level.bright
            && t.mob.body.mob.living.fire_ticks > 0
            && t.level.sees_sky(t.block())
            && bare_head(t)
        {
            self.wanted = hide(t);
            self.wanted.is_some()
        } else {
            false
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !t.mind.navigation.done()
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(p) = self.wanted {
            navigation::move_to(t, p, self.speed);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.FleeSun"
    }
}
