//! `Valimc.Living.Attributes` as mobs use it: an attribute's value from its
//! base and modifiers (`AttributeInstance.calculateValue`, in doubles), and
//! what effects derive (Jump Boost's safe fall distance, Absorption's
//! maximum).

use super::super::facts::registry::Attribute;
use super::super::model::Effects;
use super::facts::LivingFacts;
use super::{emax, emin, f};

/// `Attributes.value/3`: `base` plus the additions, plus the
/// base-multiplied additions of that sum, times each total multiplier,
/// clamped to the attribute's range. `modifiers` are `(amount, operation)`
/// in order.
pub fn value(attribute: &Attribute, base: f64, modifiers: &[(f64, u8)]) -> f64 {
    let added = modifiers
        .iter()
        .filter(|m| m.1 == 0)
        .fold(base, |acc, m| acc + m.0);
    let result = modifiers
        .iter()
        .filter(|m| m.1 == 1)
        .fold(added, |acc, m| acc + added * m.0);
    let result = modifiers
        .iter()
        .filter(|m| m.1 == 2)
        .fold(result, |acc, m| acc * (1.0 + m.0));
    emin(attribute.max, emax(attribute.min, result))
}

/// Jump Boost's safe fall distance (`Attributes.jump_boost/1`'s
/// `safe_distance`): 3, plus the amplifier and one.
pub fn jump_safe_distance(facts: &LivingFacts, effects: &Effects) -> f64 {
    match effects.amplifier(facts.effects.jump_boost) {
        None => 3.0,
        Some(amplifier) => 3.0 + (amplifier as i32 + 1) as f64,
    }
}

/// Absorption's maximum (`Attributes.absorption/2` with base 0).
pub fn absorption_maximum(facts: &LivingFacts, effects: &Effects, max: f64) -> f64 {
    absorption_pool_maximum(effects, facts.effects.absorption, max)
}

/// The absorption pool's cap while effect `absorption` is as it is now
/// (`getMaxAbsorption`): its amplifier's, clamped to the attribute's
/// maximum `max`.
pub fn absorption_pool_maximum(effects: &Effects, absorption: i32, max: f64) -> f64 {
    let value = match effects.amplifier(absorption) {
        None => 0.0,
        Some(amplifier) => (amplifier as i32 + 1) as f64 * 4.0,
    };
    f(emin(max, value))
}
