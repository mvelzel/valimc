//! `Valimc.Living.Damage` as a mob takes it: after the hurt window,
//! enchantment and Fire Resistance immunity, armour and toughness (the
//! wearer's attribute values; a mob's armour never wears), Resistance,
//! enchantment protection, absorption, then health. Every decision asks the
//! damage type's tags (`LivingFacts::is`).

use super::super::facts::MobFacts;
use super::super::model::{Effects, Equipment, Health, Living};
use super::facts::{tag, LivingFacts};
use super::health::{self, Selected};
use super::{emax, emin, enchantments, f, FLOAT_MAX};

/// How a resolved hit ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolved {
    /// Dead already, or the window refused it.
    Ignored,
    /// An enchantment or Fire Resistance made it immune.
    Immune,
    /// Applied to the living state.
    Applied,
}

/// `Damage.resolve/5` with `infinite: true` and the wearer's armour:
/// `window` and `selected` are `Health.hurt_window/3`'s.
#[allow(clippy::too_many_arguments)]
pub fn resolve(
    facts: &LivingFacts,
    mob: &MobFacts,
    living: &mut Living,
    equipment: &Equipment,
    window: Health,
    selected: Selected,
    source: u16,
    armor: (f64, f64),
) -> Resolved {
    if living.health.value <= 0.0 || !selected.accepted {
        return Resolved::Ignored;
    }
    if enchantments::immune(facts, mob, equipment, source)
        || status_immune(facts, &living.effects, source)
    {
        return Resolved::Immune;
    }
    let damage = protect(
        facts,
        mob,
        equipment,
        source,
        selected.damage,
        &living.effects,
        armor,
    );
    let (pool, left) = health::spend_absorption(living.absorption, damage);
    let mut next = window;
    health::reduce(&mut next, left);
    living.health = next;
    living.absorption = pool;
    Resolved::Applied
}

/// `/kill`'s `resolve/5` (`genericKill`): Float.MAX_VALUE past
/// invulnerability, armour, effects and absorption.
pub fn resolve_kill(living: &mut Living, window: Health, selected: Selected) -> Resolved {
    if living.health.value <= 0.0 || !selected.accepted {
        return Resolved::Ignored;
    }
    let mut next = window;
    health::reduce(&mut next, FLOAT_MAX);
    living.health = next;
    living.absorption = 0.0;
    Resolved::Applied
}

/// `Damage.protect/5`: armour and toughness unless bypassed, then
/// Resistance and enchantment protection unless bypassed.
pub fn protect(
    facts: &LivingFacts,
    mob: &MobFacts,
    equipment: &Equipment,
    source: u16,
    amount: f64,
    effects: &Effects,
    armor: (f64, f64),
) -> f64 {
    let armored = if !facts.is(source, tag::BYPASSES_ARMOR) {
        armor_absorb(amount, armor.0, armor.1)
    } else {
        f(amount)
    };
    if facts.is(source, tag::BYPASSES_EFFECTS) {
        return armored;
    }
    let resisted = resistance(facts, armored, source, effects);
    if resisted <= 0.0 || facts.is(source, tag::BYPASSES_ENCHANTMENTS) {
        return resisted;
    }
    let points = enchantments::protection(facts, mob, equipment, source);
    let fraction = f(emin(points, 20.0) / 25.0);
    f(resisted * f(1.0 - fraction))
}

/// `Damage.armor_absorb/3` (`CombatRules.getDamageAfterAbsorb`).
pub fn armor_absorb(amount: f64, armor: f64, toughness: f64) -> f64 {
    let amount = f(amount);
    let armor = f(armor);
    let divisor = f(2.0 + f(f(toughness) / 4.0));
    let effective = emin(
        20.0,
        emax(f(armor * f(0.2)), f(armor - f(amount / divisor))),
    );
    f(amount * f(1.0 - f(effective / 25.0)))
}

/// `Damage.resistance/3`: Resistance's reduction by its active amplifier.
pub fn resistance(facts: &LivingFacts, amount: f64, source: u16, effects: &Effects) -> f64 {
    let amount = f(amount);
    match effects.amplifier(facts.effects.resistance) {
        None => amount,
        Some(amplifier) => {
            if facts.is(source, tag::BYPASSES_EFFECTS) || facts.is(source, tag::BYPASSES_RESISTANCE)
            {
                amount
            } else if amplifier >= 4 {
                0.0
            } else {
                let factor = 25 - (amplifier as i32 + 1) * 5;
                let product = (amount * factor as f64) as f32;
                if product == f32::INFINITY {
                    FLOAT_MAX
                } else {
                    emax(0.0, f(product as f64 / 25.0))
                }
            }
        }
    }
}

/// `Damage.status_immune?/2`: Fire Resistance (present at all) against
/// fire.
pub fn status_immune(facts: &LivingFacts, effects: &Effects, source: u16) -> bool {
    effects.get(facts.effects.fire_resistance).is_some() && facts.is(source, tag::IS_FIRE)
}
