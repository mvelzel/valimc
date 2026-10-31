//! A villager's food (VMC-044c2): its eight-slot inventory (vanilla's
//! `SimpleContainer`, family data `inventory`: eight stacks or nil, saved)
//! and its food level (`food_level`, saved): the items it picks up, the
//! food points it holds (`VILLAGER_FOOD`'s nutrition), whether it can breed,
//! what it eats before a birth and the half stacks it throws to another
//! villager.

use crate::mobs::facts::MobFacts;
use crate::mobs::living::items;
use crate::mobs::model::FamilyData;
use crate::mobs::term::{Value, NIL};

pub const SLOTS: usize = 8;
/// `Container.getMaxStackSize`.
const CONTAINER_MAX: i32 = 99;

/// Its eight slots.
pub fn inventory(data: &FamilyData) -> Vec<Option<Value>> {
    let mut slots: Vec<Option<Value>> = data
        .get("inventory")
        .and_then(Value::as_list)
        .unwrap_or(&[])
        .iter()
        .map(|s| (!s.is_nil()).then(|| s.clone()))
        .collect();
    slots.resize(SLOTS, None);
    slots
}

pub fn set_inventory(data: &mut FamilyData, slots: Vec<Option<Value>>) {
    data.set(
        "inventory",
        Value::List(slots.into_iter().map(|s| s.unwrap_or(NIL)).collect()),
    );
}

/// The fresh inventory: eight empty slots.
pub fn empty() -> Value {
    Value::List(vec![NIL; SLOTS])
}

/// `ItemStack.getMaxStackSize`.
pub fn max_stack(facts: &MobFacts, stack: &Value) -> i32 {
    match items::component(stack, "minecraft:max_stack_size").and_then(Value::as_int) {
        Some(n) => n as i32,
        None => items::item_id(stack)
            .and_then(|id| facts.items.max_stack.get(id as usize).copied())
            .unwrap_or(64),
    }
}

/// `isSameItemSameComponents`.
fn same(a: &Value, b: &Value) -> bool {
    let part = |s: &Value, k: &str| s.as_map().and_then(|m| m.get_atom(k)).cloned();
    items::item_id(a) == items::item_id(b)
        && part(a, "components") == part(b, "components")
        && part(a, "removed") == part(b, "removed")
}

/// `SimpleContainer.canAddItem`.
pub fn can_add(facts: &MobFacts, slots: &[Option<Value>], stack: &Value) -> bool {
    slots.iter().any(|s| match s {
        None => true,
        Some(s) => same(s, stack) && items::count(s) < max_stack(facts, s).min(CONTAINER_MAX),
    })
}

/// `SimpleContainer.addItem`: into stacks of the same item, then the first
/// empty slot; what is left over.
pub fn add(facts: &MobFacts, slots: &mut [Option<Value>], stack: &Value) -> i32 {
    let mut left = items::count(stack);
    for s in slots.iter_mut().flatten() {
        if left == 0 {
            break;
        }
        if same(s, stack) {
            let room = (max_stack(facts, s).min(CONTAINER_MAX) - items::count(s)).max(0);
            let moved = room.min(left);
            if moved > 0 {
                *s = items::with_count(s, items::count(s) + moved);
                left -= moved;
            }
        }
    }
    if left > 0 {
        if let Some(slot) = slots.iter_mut().find(|s| s.is_none()) {
            *slot = Some(items::with_count(stack, left));
            left = 0;
        }
    }
    left
}

/// Its food's nutrition by item id.
pub fn nutrition(facts: &MobFacts, stack: &Value) -> Option<i32> {
    let id = items::item_id(stack)?;
    let name = facts.items.name(id)?;
    facts.village.food.get(name).copied()
}

/// `countFoodPointsInInventory`.
pub fn points(facts: &MobFacts, data: &FamilyData) -> i32 {
    inventory(data)
        .iter()
        .flatten()
        .filter_map(|s| nutrition(facts, s).map(|n| n * items::count(s)))
        .sum()
}

fn int(data: &FamilyData, key: &str) -> i64 {
    data.get(key).and_then(Value::as_int).unwrap_or(0)
}

/// `Villager.canBreed`: twelve food points between its food level and its
/// inventory, awake, and an adult not waiting to breed again.
pub fn can_breed(facts: &MobFacts, data: &FamilyData) -> bool {
    int(data, "food_level") + points(facts, data) as i64 >= 12
        && data.get("sleeping").is_none_or(Value::is_nil)
        && int(data, "age") == 0
}

/// `wantsToPickUp`: food, `#villager_picks_up` or what its profession
/// asks for, with room for it.
pub fn wants(facts: &MobFacts, data: &FamilyData, profession: &str, stack: &Value) -> bool {
    let Some(name) = items::item_id(stack).and_then(|id| facts.items.name(id)) else {
        return false;
    };
    let requested = facts
        .village
        .profession(profession)
        .is_some_and(|p| p.requested.iter().any(|r| r == name));
    (facts.village.picks_up.iter().any(|p| p == name)
        || facts.village.food.contains_key(name)
        || requested)
        && can_add(facts, &inventory(data), stack)
}

/// `eatAndDigestFood`: food from its inventory, slot by slot and one item
/// at a time, until its level reaches 12; then 12 digested.
pub fn eat_and_digest(facts: &MobFacts, data: &mut FamilyData) {
    let mut level = int(data, "food_level");
    if level < 12 {
        let mut slots = inventory(data);
        'eat: for slot in slots.iter_mut() {
            let Some(stack) = slot.clone() else { continue };
            let Some(n) = nutrition(facts, &stack) else {
                continue;
            };
            let count = items::count(&stack);
            let mut eaten = 0;
            for _ in 0..count {
                level += n as i64;
                eaten += 1;
                if level >= 12 {
                    *slot = (count > eaten).then(|| items::with_count(&stack, count - eaten));
                    break 'eat;
                }
            }
            *slot = (count > eaten).then(|| items::with_count(&stack, count - eaten));
        }
        set_inventory(data, slots);
    }
    data.set("food_level", Value::Int(level - 12));
}

/// `TradeWithVillager.throwHalfStack`: from the first matching slot with
/// more than half its stack (half of it) or more than 24 (the rest past
/// 24), the stack it throws.
pub fn half_stack(
    facts: &MobFacts,
    data: &mut FamilyData,
    matches: impl Fn(&Value) -> bool,
) -> Option<Value> {
    let mut slots = inventory(data);
    for slot in slots.iter_mut() {
        let Some(stack) = slot.clone() else { continue };
        if !matches(&stack) {
            continue;
        }
        let count = items::count(&stack);
        let take = if count > max_stack(facts, &stack) / 2 {
            count / 2
        } else if count > 24 {
            count - 24
        } else {
            continue;
        };
        *slot = (count > take).then(|| items::with_count(&stack, count - take));
        set_inventory(data, slots);
        return Some(items::with_count(&stack, take));
    }
    None
}
