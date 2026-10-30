//! Hostile families (VMC-081d), ported from `Valimc.AI.Mobs`' monster
//! modules: zombies (husks, zombie villagers) and drowned, skeletons
//! (strays, bogged), creepers, spiders (cave spiders), endermen, witches,
//! and the cubes (slimes, magma cubes). Each is a `Kind` built as the
//! farm animals are (`animals`), its own data the Elixir family's
//! atom-keyed map.
//!
//! What several share lives here: reading and writing their data, a
//! Halloween head, the drop chance of a slot and the protocol ids they
//! look up once.

pub mod zombie;

use crate::mobs::ai::fmath::f;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::Turn;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::Kind;
use crate::mobs::living::items;
use crate::mobs::model::{FamilyData, Mob, Slot};
use crate::mobs::term::{Atom, Value};

/// Every ported hostile family.
pub fn kinds(facts: &MobFacts) -> Result<Vec<Box<dyn Kind>>, String> {
    Ok(vec![Box::new(zombie::Zombie::new(facts)?)])
}

/// An entity type's id, which the families' facts must hold.
pub fn entity(facts: &MobFacts, name: &str) -> Result<u16, String> {
    facts
        .entities
        .id(name)
        .ok_or_else(|| format!("unknown entity type {name}"))
}

/// An item's protocol id, which the facts must hold.
pub fn item(facts: &MobFacts, name: &str) -> Result<i32, String> {
    facts
        .items
        .id(name)
        .ok_or_else(|| format!("unknown item {name}"))
}

/// An effect's id, which the facts must hold.
pub fn effect(facts: &MobFacts, name: &str) -> Result<i32, String> {
    facts
        .effects
        .id(name)
        .map(|id| id as i32)
        .ok_or_else(|| format!("unknown effect {name}"))
}

/// A sound's id, which the facts must hold.
pub fn sound(facts: &MobFacts, name: &str) -> Result<i32, String> {
    facts
        .sounds
        .id(name)
        .ok_or_else(|| format!("unknown sound {name}"))
}

/// Every state of block `name` (`Blocks.states/1`).
pub fn states(facts: &MobFacts, name: &str) -> Result<Vec<u16>, String> {
    let id = facts
        .blocks
        .id(name)
        .ok_or_else(|| format!("unknown block {name}"))?;
    let block = facts.blocks.block(id).ok_or("bad block id")?;
    Ok((block.first..=block.last).collect())
}

/// The ids of item tag `tag`.
pub fn item_tag(facts: &MobFacts, tag: &str) -> Vec<i32> {
    facts
        .tags
        .get("minecraft:item", tag)
        .map(<[i32]>::to_vec)
        .unwrap_or_default()
}

/// A field of the data, as `data` lists it.
pub fn fields(pairs: &[(&'static str, Value)]) -> Vec<(Atom, Value)> {
    pairs
        .iter()
        .map(|(k, v)| (Atom::from_static(k), v.clone()))
        .collect()
}

/// An integer field (0 when absent).
pub fn int(data: &FamilyData, key: &str) -> i64 {
    data.get(key).and_then(Value::as_int).unwrap_or(0)
}

/// A boolean field (false when absent).
pub fn flag(data: &FamilyData, key: &str) -> bool {
    data.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// A field's value as an entity data value `(field, value, default)`.
pub fn value(field: &'static str, value: Value, default: Value) -> (Atom, Value, Value) {
    (Atom::from_static(field), value, default)
}

/// `Mob.put_drop_chance/3`: a slot's drop chance, kept only where it
/// differs from the default.
pub fn put_drop_chance(facts: &MobFacts, mob: &mut Mob, slot: Slot, chance: f64) {
    let default = facts.hostile.drop_chance as f64;
    mob.drop_chances.0[slot as usize] = if chance == default {
        None
    } else {
        Some(chance)
    };
}

/// A fresh stack of one item.
pub fn stack(id: i32) -> Value {
    items::new_stack(id, 1, None)
}

/// The Halloween head of zombies and skeletons: at Halloween, a quarter of
/// those with a bare head wear a carved pumpkin (a jack o'lantern one time
/// in ten) that never drops, drawn from the level's random.
pub fn halloween(t: &mut Turn) {
    if t.mob.body.mob.equipment.get(Slot::Head).is_some() || !t.level.halloween {
        return;
    }
    if spawn::level_float(t) < f(0.25) {
        let name = if spawn::level_float(t) < f(0.1) {
            "minecraft:jack_o_lantern"
        } else {
            "minecraft:carved_pumpkin"
        };
        let id = t.level.facts.items.id(name);
        spawn::equip(t, Slot::Head, id.map(stack));
        let facts = t.level.facts;
        put_drop_chance(facts, &mut t.mob.body.mob, Slot::Head, 0.0);
    }
}

/// `setCanPickUpLoot(f < 0.55 * special)` from a level random draw `roll`.
pub fn loot(t: &mut Turn, roll: f64, special: f64) {
    t.mob.body.mob.can_pick_up_loot = roll < f(f(0.55) * special);
}

/// The sound source of a type's sounds.
pub fn source(facts: &MobFacts, type_id: u16) -> i32 {
    facts.combat.mob_sounds(type_id).source
}
