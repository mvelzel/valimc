//! `Valimc.Living.Air`: a living entity's air supply under water, its
//! breathing effects, drowning and refilling.

use super::super::model::Effects;
use super::facts::LivingFacts;

/// `Air.maximum/0`.
pub const MAXIMUM: i32 = 300;

/// The breathing effects' policy (`Air.policy/1`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    None,
    /// No drain.
    Hold,
    Refill,
}

/// `Air.submerged?/2`: eyes under water at a block of `state` that is no
/// bubble column.
pub fn submerged(
    facts: &LivingFacts,
    blocks: &super::super::facts::BlockRegistry,
    eye_water: bool,
    state: u16,
) -> bool {
    eye_water && (facts.bubble_column.is_none() || blocks.block_id(state) != facts.bubble_column)
}

/// `Air.policy/1`.
pub fn policy(facts: &LivingFacts, effects: &Effects) -> Policy {
    let e = &facts.effects;
    let has = |id| effects.get(id).is_some();
    let breathes = has(e.water_breathing) || has(e.conduit_power) || has(e.breath_of_the_nautilus);
    let refills = !has(e.breath_of_the_nautilus) || has(e.water_breathing) || has(e.conduit_power);
    if !breathes {
        Policy::None
    } else if refills {
        Policy::Refill
    } else {
        Policy::Hold
    }
}

/// `Air.decrease/3`: Respiration's oxygen bonus keeps the air on a draw
/// past `1 / (bonus + 1)`.
pub fn decrease(air: i32, oxygen: f64, draw: f64) -> i32 {
    if oxygen > 0.0 && draw >= 1.0 / (oxygen + 1.0) {
        air
    } else {
        air - 1
    }
}

/// `Air.increase/1`.
pub fn increase(air: i32) -> i32 {
    MAXIMUM.min(air + 4)
}

/// `Air.tick/6` (not immune): `(air, drowning damage)`; `draw` is asked
/// only where the air decreases with an oxygen bonus.
pub fn tick(
    air: i32,
    submerged: bool,
    oxygen: f64,
    policy: Policy,
    draw: impl FnOnce() -> f64,
) -> (i32, f64) {
    match (submerged, policy) {
        (true, Policy::None) => {
            let draw = if oxygen > 0.0 { draw() } else { 0.0 };
            let decreased = decrease(air, oxygen, draw);
            if decreased <= -20 {
                (0, 2.0)
            } else {
                (decreased, 0.0)
            }
        }
        (true, Policy::Hold) => (air, 0.0),
        _ => (increase(air), 0.0),
    }
}
