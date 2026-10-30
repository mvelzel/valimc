//! `Mob.finalizeSpawn` (VMC-081d), ported from `Valimc.AI.Spawn`: what a mob
//! decides as it enters the world, run before anything else in its first
//! tick (`think::think`) for the reason it was made. The level's random
//! draws what vanilla draws from `level.getRandom()`, the mob's own what it
//! draws from `this.random`. `mob` is `Mob`'s own part (a follow range
//! bonus, handedness); families add theirs (`Kind::finalize`).

use super::effect::Effect;
use super::turn::Turn;
use crate::mobs::ai::fmath::f;
use crate::mobs::facts::Slot as FactSlot;
use crate::mobs::level::Difficulty;
use crate::mobs::living::difficulty::LocalDifficulty;
use crate::mobs::living::items;
use crate::mobs::model::{Mob, Modifier, Number, Slot};
use crate::mobs::random::LegacyRandom;
use crate::mobs::term::{Atom, Map, Value};

pub const FOLLOW: &str = "minecraft:follow_range";
pub const BONUS: &str = "minecraft:random_spawn_bonus";

/// `Spawn.mob/2` on a turn: `mob_parts` with the level's random.
pub fn mob(t: &mut Turn, _reason: &Atom) {
    mob_parts(&mut t.mob.body.mob, &mut t.level.random);
}

/// `Spawn.mob/2`: a follow range bonus (a triangle of two doubles) unless
/// it has one, and left-handedness one time in twenty, from the level's
/// `random`.
pub fn mob_parts(mob: &mut Mob, random: &mut LegacyRandom) {
    if !has_modifier(mob, FOLLOW, BONUS) {
        let a = random.double();
        let b = random.double();
        add_modifier(mob, FOLLOW, BONUS, 0.11485000000000001 * (a - b), 1);
    }
    let roll = random.float() as f64;
    mob.left_handed = roll < f(0.05);
}

/// `has_modifier?/3`: attribute `name` has modifier `id`.
pub fn has_modifier(mob: &Mob, name: &str, id: &str) -> bool {
    mob.attributes
        .get(name)
        .is_some_and(|o| o.modifiers.iter().any(|m| m.id == id))
}

/// `addOrReplacePermanentModifier`: `{id, amount, operation}` on attribute
/// `name`, after its others.
pub fn add_modifier(mob: &mut Mob, name: &str, id: &str, amount: f64, operation: i32) {
    let entry = mob.attributes.entry(name);
    entry.modifiers.retain(|m| m.id != id);
    entry.modifiers.push(Modifier {
        id: id.to_owned(),
        amount: Number::Float(amount),
        operation,
    });
}

/// `setBaseValue` of attribute `name`.
pub fn set_base(mob: &mut Mob, name: &str, base: f64) {
    mob.attributes.entry(name).base = Some(base);
}

/// `level.getRandom().nextInt(bound)` (`Spawn.level_int/2`).
pub fn level_int(t: &mut Turn, bound: i32) -> i32 {
    t.level.random.int(bound)
}

/// `level.getRandom().nextFloat()`, widened.
pub fn level_float(t: &mut Turn) -> f64 {
    t.level.random.float() as f64
}

/// `level.getRandom().nextDouble()`.
pub fn level_double(t: &mut Turn) -> f64 {
    t.level.random.double()
}

/// `level.getRandom().nextBoolean()`.
pub fn level_boolean(t: &mut Turn) -> bool {
    t.level.random.boolean()
}

/// `Spawn.local/1`: the local difficulty at the mob (`getCurrentDifficultyAt`;
/// the level's own where it holds everywhere).
pub fn local(t: &Turn) -> LocalDifficulty {
    match t.level.local {
        Some(effective) => LocalDifficulty {
            difficulty: t.level.difficulty,
            effective,
        },
        None => LocalDifficulty::at(t.level.difficulty, t.level.day, 0),
    }
}

/// `getSpecialMultiplier` of the mob's local difficulty.
pub fn special(t: &Turn) -> f64 {
    local(t).special()
}

/// `setItemSlot`.
pub fn equip(t: &mut Turn, slot: Slot, stack: Option<Value>) {
    t.mob.body.mob.equipment.set(slot, stack);
}

/// `Mob.populateDefaultEquipmentSlots`: by chance (scaled by the special
/// multiplier) a material, upgraded three times by chance, then a piece for
/// each armour slot from the head down until a draw stops it (each after
/// the first; more often on hard); an occupied slot keeps its item.
pub fn armour(t: &mut Turn) {
    let roll = level_float(t);
    if roll >= f(f(0.15) * special(t)) {
        return;
    }
    let mut material = level_int(t, 3);
    for _ in 0..3 {
        if level_float(t) < f(0.1087) {
            material += 1;
        }
    }
    let partial = f(if t.level.difficulty == Difficulty::Hard {
        0.1
    } else {
        0.25
    });
    let slots = [
        (Slot::Head, FactSlot::Head),
        (Slot::Chest, FactSlot::Chest),
        (Slot::Legs, FactSlot::Legs),
        (Slot::Feet, FactSlot::Feet),
    ];
    for (i, (slot, fact)) in slots.into_iter().enumerate() {
        if i > 0 && level_float(t) < partial {
            break;
        }
        if t.mob.body.mob.equipment.get(slot).is_none() {
            let item = t.level.facts.hostile.armour(fact, material as usize);
            equip(t, slot, item.map(|id| items::new_stack(id, 1, None)));
        }
    }
}

/// `Mob.populateDefaultEquipmentEnchantments`: the main hand's item a
/// quarter of the time and each armour piece half of it (scaled by the
/// special multiplier), feet first, enchanted by cost
/// (`EnchantmentsByCostWithDifficulty`) from the level's random.
pub fn enchant_equipment(t: &mut Turn) {
    let special = special(t);
    for (slot, chance) in [
        (Slot::Mainhand, 0.25),
        (Slot::Feet, 0.5),
        (Slot::Legs, 0.5),
        (Slot::Chest, 0.5),
        (Slot::Head, 0.5),
    ] {
        let Some(stack) = t.mob.body.mob.equipment.get(slot).cloned() else {
            continue;
        };
        if level_float(t) < f(f(chance) * special) {
            let stack = enchant(t, stack, special);
            equip(t, slot, Some(stack));
        }
    }
}

// The level random's draws happen in the loot engine's enchanting.
fn enchant(t: &mut Turn, stack: Value, special: f64) -> Value {
    let Some(loot) = t.level.loot else {
        return stack;
    };
    let facts = t.level.facts;
    let (min, span, tag) = &facts.hostile.enchanting;
    let Some(name) = items::item_id(&stack).and_then(|id| facts.items.name(id)) else {
        return stack;
    };
    let current: Vec<(String, i32)> = items::enchantments(&stack)
        .into_iter()
        .map(|(n, l)| (n.to_owned(), l as i32))
        .collect();
    let mut random = crate::worldgen::random::Random::legacy_at(t.level.random.seed);
    let Ok(enchantments) = loot.enchant_by_cost(
        name,
        &current,
        *min,
        *span,
        special as f32,
        tag,
        &mut random,
    ) else {
        return stack;
    };
    if let Some(state) = random.legacy_state().and_then(LegacyRandom::from_state) {
        t.level.random = state;
    }
    if enchantments.is_empty() {
        return stack;
    }
    let map = Map::from_pairs(
        enchantments
            .into_iter()
            .map(|(n, l)| (Value::Binary(n.into_bytes()), Value::Int(l as i64)))
            .collect(),
    );
    let mut stack = stack;
    if let Some(map) = map {
        items::put_component(&mut stack, "minecraft:enchantments", Value::Map(map));
    }
    stack
}

/// `Spawn.companion/3`: a mob of type `name` this one's spawn makes and
/// finalizes at once, for `reason`, from the same level random (a spider
/// jockey's skeleton): a fresh body facing as this one does, with a fresh
/// uuid (from the turn's own stream, the Elixir's `:crypto`) and a mind of
/// its own; what its finalize made stays its own. It leaves as a
/// `SpawnBody` effect the owner adopts where this one stands. Nothing
/// outside a section's tick (no families to make it with).
pub fn companion(t: &mut Turn, name: &str, reason: &Atom) {
    let Some(ctx) = t.ctx else { return };
    let facts = t.level.facts;
    let Some(ty) = crate::mobs::living::mob::Type::of(facts, name) else {
        return;
    };
    let (Some(kind), Some(ai)) = (ctx.kinds.kind(ty.id), facts.ai.mob(ty.id)) else {
        return;
    };
    let mut body = crate::mobs::living::body::fresh(ctx.rules, ty);
    body.yaw = t.yaw();
    body.head_yaw = t.yaw();
    let mut uuid = [0u8; 16];
    uuid[..8].copy_from_slice(&t.next_seed().to_be_bytes());
    uuid[8..].copy_from_slice(&t.next_seed().to_be_bytes());
    let mut mob = crate::mobs::model::NativeMob {
        uuid,
        position: t.pos(),
        hops: 0,
        body,
    };
    let dims = crate::mobs::living::body::dimensions(ctx.rules, ty, &mob.body);
    {
        let mut made = Turn::new(
            &mut mob, 0, ty.id, ai, dims, t.level, t.sensing, t.paths, kind,
        );
        made.ctx = Some(ctx);
        kind.finalize(&mut made, reason);
    }
    t.effect(Effect::SpawnBody(Box::new(mob)));
}
