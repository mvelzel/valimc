//! A mob picking up loot (VMC-081d), ported from `Valimc.AI.Pickup`
//! (`Mob.aiStep`'s looting): while mob griefing is on, a living mob that can
//! pick up loot takes the items beside it (its box widened a block
//! sideways) it wants, in the section's order, as `Mob.pickUpItem` and
//! `equipItemIfPossible` decide: an item goes to the slot it is worn in
//! (else the main hand), only if it beats what is there (armour by defense
//! then toughness, weapons by the family's preferred kind then damage, then
//! by enchantments, wear and name), and what it replaces drops by its drop
//! chance. A picked-up item always drops on death and the mob stays.
//!
//! Effects: `Pickup` for what it takes (the section's item has fewer for
//! the mobs after it) and `Drop` for what it lets go. A family may take an
//! item its own way (`Kind::pick_up`).

use super::effect::Effect;
use super::fmath::{emax, f};
use super::turn::Turn;
use crate::mobs::combat::Rules;
use crate::mobs::facts::Slot as FactSlot;
use crate::mobs::kinds::Kind;
use crate::mobs::living::items;
use crate::mobs::living::mob as living_mob;
use crate::mobs::model::Slot;
use crate::mobs::sensing::{inflate, intersects, SensedItem};
use crate::mobs::term::Value;
use crate::physics::Aabb;

const ARMOUR: [Slot; 4] = [Slot::Head, Slot::Chest, Slot::Legs, Slot::Feet];

fn slot_of(slot: FactSlot) -> Slot {
    match slot {
        FactSlot::MainHand => Slot::Mainhand,
        FactSlot::OffHand => Slot::Offhand,
        FactSlot::Feet => Slot::Feet,
        FactSlot::Legs => Slot::Legs,
        FactSlot::Chest => Slot::Chest,
        FactSlot::Head => Slot::Head,
        FactSlot::Body => Slot::Body,
        FactSlot::Saddle => Slot::Saddle,
    }
}

/// The mob's looting this tick.
pub fn tick(rules: &Rules, kind: &dyn Kind, t: &mut Turn) {
    if !t.mob.body.mob.can_pick_up_loot
        || !t.level.rules.mob_griefing
        || !living_mob::alive(&t.mob.body.mob)
    {
        return;
    }
    let b = inflate(&t.bbox(), 1.0, 0.0, 1.0);
    for i in 0..t.sensing.items.len() {
        let item = t.sensing.items[i].clone();
        let half = SensedItem::WIDTH / 2.0;
        let [x, y, z] = item.position;
        let item_box = Aabb::new(
            [x - half, y, z - half],
            [x + half, y + SensedItem::HEIGHT, z + half],
        );
        if item.count > 0
            && item.pickup_delay == 0
            && intersects(&item_box, &b)
            && kind.wants(t, item.item)
            && !kind.pick_up(t, &item)
        {
            pick_up(rules, kind, t, i, &item);
        }
    }
}

// `Mob.pickUpItem`.
fn pick_up(rules: &Rules, kind: &dyn Kind, t: &mut Turn, i: usize, item: &SensedItem) {
    let stack = items::new_stack(item.item, item.count, item.components.clone());
    let count = equip(rules, kind, t, stack);
    if count > 0 {
        t.effect(Effect::Pickup {
            item: item.uuid,
            count,
        });
        t.sensing.items[i].count -= count;
    }
}

fn equippable<'w>(t: &Turn<'_, 'w>, item: i32) -> Option<&'w (FactSlot, Option<Vec<u16>>, String)> {
    let facts: &'w crate::mobs::facts::MobFacts = t.level.facts;
    facts.hostile.equippable.get(&item)
}

// `equipItemIfPossible`: how many it took.
fn equip(rules: &Rules, kind: &dyn Kind, t: &mut Turn, stack: Value) -> i32 {
    let Some(item) = items::item_id(&stack) else {
        return 0;
    };
    let worn = equippable(t, item).cloned();
    let slot = worn
        .as_ref()
        .map_or(Slot::Mainhand, |(s, _, _)| slot_of(*s));
    let fits = match &worn {
        None => slot == Slot::Mainhand,
        Some((_, None, _)) => true,
        Some((_, Some(types), _)) => types.contains(&t.type_id),
    };
    if !fits {
        return 0;
    }
    let current = t.mob.body.mob.equipment.get(slot).cloned();
    let replace = replace(kind, t, &stack, current.as_ref(), slot);
    let (slot, current, replace) = if ARMOUR.contains(&slot) && !replace {
        let current = t.mob.body.mob.equipment.get(Slot::Mainhand).cloned();
        let replace = current.is_none();
        (Slot::Mainhand, current, replace)
    } else {
        (slot, current, replace)
    };
    if !(replace && kind.can_hold(t, item)) {
        return 0;
    }
    let chance = living_mob::drop_chance(rules.living, &t.mob.body.mob, slot);
    if let Some(current) = current {
        let roll = t.float();
        if emax(f(roll - f(0.1)), 0.0) < chance {
            t.effect(Effect::Drop(current));
        }
    }
    let equipped = if ARMOUR.contains(&slot) {
        items::with_count(&stack, 1)
    } else {
        stack
    };
    equip_sound(t, item, slot, worn.as_ref());
    let count = items::count(&equipped);
    let mob = &mut t.mob.body.mob;
    mob.equipment.set(slot, Some(equipped));
    living_mob::put_drop_chance(rules.living, mob, slot, 2.0);
    mob.persistent = true;
    count
}

// `LivingEntity.onEquipItem`: an item worn where it belongs plays its equip
// sound, seeded from the mob's random.
fn equip_sound(
    t: &mut Turn,
    _item: i32,
    slot: Slot,
    worn: Option<&(FactSlot, Option<Vec<u16>>, String)>,
) {
    let Some((at, _, sound)) = worn else { return };
    if slot_of(*at) != slot {
        return;
    }
    let seed = t.long();
    let source = t.level.facts.combat.mob_sounds(t.type_id).source;
    if let Some(id) = t.level.facts.sounds.id(sound) {
        t.effect(Effect::Sound {
            id,
            source,
            volume: 1.0,
            pitch: 1.0,
            seed,
        });
    }
}

// `canReplaceCurrentItem`.
fn replace(kind: &dyn Kind, t: &Turn, new: &Value, current: Option<&Value>, slot: Slot) -> bool {
    let Some(current) = current else {
        return true;
    };
    if ARMOUR.contains(&slot) {
        if items::enchantment(current, "minecraft:binding_curse").is_some() {
            return false;
        }
        let defense = (
            value(t, new, "minecraft:armor", slot),
            value(t, current, "minecraft:armor", slot),
        );
        let toughness = (
            value(t, new, "minecraft:armor_toughness", slot),
            value(t, current, "minecraft:armor_toughness", slot),
        );
        if defense.0 != defense.1 {
            defense.0 > defense.1
        } else if toughness.0 != toughness.1 {
            toughness.0 > toughness.1
        } else {
            equal_better(new, current)
        }
    } else if slot == Slot::Mainhand {
        let preferred = kind.preferred_weapons(t.type_id);
        let is = |s: &Value| {
            preferred.is_some_and(|p| items::item_id(s).is_some_and(|id| p.contains(&id)))
        };
        let (new_preferred, current_preferred) = (is(new), is(current));
        if current_preferred && !new_preferred {
            false
        } else if new_preferred && !current_preferred {
            true
        } else {
            let a = value(t, new, "minecraft:attack_damage", Slot::Mainhand);
            let b = value(t, current, "minecraft:attack_damage", Slot::Mainhand);
            if a != b {
                a > b
            } else {
                equal_better(new, current)
            }
        }
    } else {
        false
    }
}

// `Weapons`' slot groups.
fn covers(group: &str, slot: Slot) -> bool {
    match group {
        "any" => true,
        "hand" => matches!(slot, Slot::Mainhand | Slot::Offhand),
        "armor" => ARMOUR.contains(&slot),
        other => other == slot.name(),
    }
}

// `getApproximateAttributeWith`: the mob's base of the attribute (0 without
// it) through the item's modifiers in that slot.
fn value(t: &Turn, stack: &Value, name: &str, slot: Slot) -> f64 {
    let facts = t.level.facts;
    let Some(fact) = facts.attributes.fetch(name) else {
        return 0.0;
    };
    let base = match facts
        .entities
        .get(t.type_id)
        .and_then(|e| e.attribute(&fact.name))
    {
        Some(own) => t
            .mob
            .body
            .mob
            .attributes
            .get(&fact.name)
            .and_then(|o| o.base)
            .unwrap_or(own),
        None => 0.0,
    };
    let Some(id) = items::item_id(stack) else {
        return base;
    };
    let mut acc = base;
    for m in facts.combat.items.get(&id).into_iter().flatten() {
        if m.attribute != fact.id || !covers(&m.slot, slot) {
            continue;
        }
        acc = match m.operation {
            0 => acc + m.amount,
            1 => acc + m.amount * base,
            _ => acc + m.amount * acc,
        };
    }
    acc
}

// `canReplaceEqualItem`: more enchantments, then less wear, then a name.
fn equal_better(new: &Value, current: &Value) -> bool {
    let count = |s: &Value| {
        items::component(s, "minecraft:enchantments")
            .and_then(Value::as_map)
            .map_or(0, |m| m.len())
    };
    let damage = |s: &Value| {
        items::component(s, "minecraft:damage")
            .and_then(Value::as_int)
            .unwrap_or(0)
    };
    let (a, b) = (count(new), count(current));
    let (da, db) = (damage(new), damage(current));
    if a != b {
        a > b
    } else if da != db {
        da < db
    } else {
        items::component(new, "minecraft:custom_name").is_some()
            && items::component(current, "minecraft:custom_name").is_none()
    }
}
