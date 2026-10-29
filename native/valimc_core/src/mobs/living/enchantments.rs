//! `Valimc.Protocol.EnchantmentEffects` as mobs use it: damage protection
//! and immunity from worn enchantments (each conditioned on damage type
//! tags), an attack's damage and knockback after the weapon's, and the
//! share of item wear Unbreaking removes.

use super::super::facts::MobFacts;
use super::super::model::{Equipment, Slot};
use super::facts::{EntityRequirement, LivingFacts, Requirement};
use super::{f, items};

/// `Armor.enchantments/1`'s slots, in vanilla's order.
const SLOTS: [Slot; 6] = [
    Slot::Mainhand,
    Slot::Offhand,
    Slot::Feet,
    Slot::Legs,
    Slot::Chest,
    Slot::Head,
];

fn matches(mob: &MobFacts, requirement: &Requirement, source: u16) -> bool {
    requirement
        .iter()
        .all(|(tag, expected)| mob.damage_tag(source, tag) == *expected)
}

/// `EnchantmentHelper.getDamageProtection`: the protection points of the
/// equipment against damage type `source` (`Damage.protection/2`).
pub fn protection(facts: &LivingFacts, mob: &MobFacts, equipment: &Equipment, source: u16) -> f64 {
    let mut total = 0.0;
    for slot in SLOTS {
        let Some(stack) = equipment.get(slot) else {
            continue;
        };
        for (name, level) in items::enchantments(stack) {
            let Some(def) = facts.enchantments.get(name) else {
                continue;
            };
            if def.slots & (1 << slot as usize) == 0 {
                continue;
            }
            for ((base, per), requirement) in &def.protection {
                if matches(mob, requirement, source) {
                    total = total + base + per * (level - 1) as f64;
                }
            }
        }
    }
    total
}

/// `EnchantmentHelper.isImmuneToDamage` (Frost Walker on hot floors).
pub fn immune(facts: &LivingFacts, mob: &MobFacts, equipment: &Equipment, source: u16) -> bool {
    SLOTS.into_iter().any(|slot| {
        equipment.get(slot).is_some_and(|stack| {
            items::enchantments(stack).into_iter().any(|(name, _)| {
                facts.enchantments.get(name).is_some_and(|def| {
                    def.slots & (1 << slot as usize) != 0
                        && def.immunity.iter().any(|r| matches(mob, r, source))
                })
            })
        })
    })
}

/// Which attack effect `attack` adds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttackKind {
    Damage,
    Knockback,
}

fn entity_matches(
    mob: &MobFacts,
    requirement: &Option<EntityRequirement>,
    target: u16,
    direct: u16,
) -> bool {
    match requirement {
        None => true,
        Some(r) => mob.entity_tag(if r.this { target } else { direct }, &r.tag),
    }
}

/// `EnchantmentHelper.modifyDamage` / `modifyKnockback`: `amount` after the
/// weapon's `enchantments` (levels by name, in map order) against entity
/// type `target`, dealt by entity type `direct`. Float.
pub fn attack(
    facts: &LivingFacts,
    mob: &MobFacts,
    kind: AttackKind,
    enchantments: &[(&str, i64)],
    target: u16,
    direct: u16,
    amount: f64,
) -> f64 {
    let mut total = f(amount);
    for (name, level) in enchantments {
        let Some(def) = facts.enchantments.get(*name) else {
            continue;
        };
        let effects = match kind {
            AttackKind::Damage => &def.damage,
            AttackKind::Knockback => &def.knockback,
        };
        for ((base, per), requirement) in effects {
            if entity_matches(mob, requirement, target, direct) {
                total = f(total + f(base + f(per * (level - 1) as f64)));
            }
        }
    }
    total
}

/// `EnchantmentEffects.item_damage_chance/2`: the chance that each point of
/// wear on item `item` is removed, as a float; 0.0 without Unbreaking.
pub fn item_damage_chance(
    facts: &LivingFacts,
    mob: &MobFacts,
    enchantments: &[(&str, i64)],
    item: i32,
) -> f64 {
    let mut chance = 0.0;
    for (name, level) in enchantments {
        let Some(def) = facts.enchantments.get(*name) else {
            continue;
        };
        if def.item_damage.is_empty() {
            continue;
        }
        for (((nb, np), (db, dp)), (tag, expected)) in &def.item_damage {
            if mob.item_tag(item, tag) == *expected && *level > 0 {
                let l = (level - 1) as f64;
                chance = f(f(nb + f(np * l)) / f(db + f(dp * l)));
                break;
            }
        }
    }
    chance
}
