//! `Valimc.Living.Durability`: item wear (`ItemStack.hurtAndBreak`). The
//! stack's damage grows by the cost less the points Unbreaking removes
//! (`RemoveBinomial`, one float draw per point from the level's random, as
//! `EnchantmentHelper.processDurabilityChange` draws), clamped to its
//! maximum; at the maximum it breaks.

use super::super::facts::MobFacts;
use super::super::term::Value;
use super::facts::LivingFacts;
use super::{enchantments, items};

/// What a wear did: the stack left (None when it broke) and the broken
/// stack.
#[derive(Clone, Debug, PartialEq)]
pub enum Wear {
    Unchanged,
    Worn(Value),
    Broken(Value),
}

/// `Durability.hurt_and_break(stack, cost, false, random)`: `draw` gives a
/// float in [0, 1) per point while Unbreaking can remove it.
pub fn hurt_and_break(
    facts: &LivingFacts,
    mob: &MobFacts,
    stack: &Value,
    cost: i64,
    mut draw: impl FnMut() -> f64,
) -> Wear {
    let Some(id) = items::item_id(stack) else {
        return Wear::Unchanged;
    };
    let item = facts.item(id);
    let max_default = item.max_damage.map(Value::Int);
    let maximum = items::component_or(stack, "minecraft:max_damage", max_default.as_ref());
    let damage_default = item.damage_default.then_some(Value::Int(0));
    let damage = items::component_or(stack, "minecraft:damage", damage_default.as_ref());
    let unbreakable = items::component_or(stack, "minecraft:unbreakable", None).is_some();
    let (Some(maximum), Some(damage)) = (
        maximum.and_then(Value::as_int),
        damage.and_then(Value::as_int),
    ) else {
        return Wear::Unchanged;
    };
    if cost == 0 || unbreakable {
        return Wear::Unchanged;
    }
    let levels = items::enchantments(stack);
    let chance = enchantments::item_damage_chance(facts, mob, &levels, id);
    let wear = if chance == 0.0 && chance.is_sign_positive() {
        cost
    } else {
        (1..=cost).filter(|_| draw() >= chance).count() as i64
    };
    if wear == 0 {
        return Wear::Unchanged;
    }
    // Native signed-int addition precedes clamping.
    let mut value = damage.min(maximum) + wear;
    if value > i32::MAX as i64 {
        value -= 4_294_967_296;
    }
    let value = value.max(0).min(maximum);
    let mut next = stack.clone();
    items::put_component(&mut next, "minecraft:damage", Value::Int(value));
    if value >= maximum {
        Wear::Broken(next)
    } else {
        Wear::Worn(next)
    }
}
