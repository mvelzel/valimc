//! `Valimc.Living.FallDamage` and `Landing`: `Block.fallOn`'s damage call
//! on the landing block and `calculateFallDamage`'s arithmetic.

use super::f;
use super::facts::LivingFacts;

/// A landing's damage call (`Landing.call/3` without sneaking): the scaled
/// distance, the block's multiplier and the damage type.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Call {
    pub distance: f64,
    pub multiplier: f64,
    pub source: u16,
}

/// `Landing.call(state, distance, false)`, or None where the block deals no
/// fall damage.
pub fn call(facts: &LivingFacts, state: u16, distance: f64) -> Option<Call> {
    facts.landing(state).map(|rule| Call {
        distance: distance * rule.distance_scale + rule.distance_offset,
        multiplier: rule.multiplier,
        source: rule.source,
    })
}

/// `FallDamage.calculate/3` (not immune): the signed damage, positive int
/// overflow saturating.
pub fn calculate(
    distance: f64,
    material: f64,
    safe_distance: f64,
    attribute_multiplier: f64,
) -> i64 {
    let rounded = f(material);
    let raw = (distance + 1.0e-6 - safe_distance) * rounded * attribute_multiplier;
    let floor = raw.floor();
    if floor >= i32::MAX as f64 {
        i32::MAX as i64
    } else {
        floor as i64
    }
}
