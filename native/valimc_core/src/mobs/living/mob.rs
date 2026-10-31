//! `Valimc.Entity.Mob`'s rules: the `LivingEntity` and `Mob` state of a
//! body. A fresh mob, alive or not, its hurt and death timers and player
//! memory, `/kill`, `hurtServer` up to its death (immunities, the hurt
//! window, armour from its attributes, Resistance, enchantment protection,
//! absorption), attribute values with its equipment's stock modifiers, the
//! attributes a client is sent, equipment changes, drop chances, and
//! `addEffect` and `removeEffect` with the attribute modifiers effects give.

use super::super::combat::{Family, Hit, Outcome};
use super::super::facts::registry::EntityType;
use super::super::facts::MobFacts;
use super::super::model::{
    AttributeOverride, Attributes, Effects, Equipment, Health, Living, Mob, Modifier, Number, Rung,
    Slot,
};
use super::super::term::Value;
use super::damage::{self, Resolved};
use super::facts::{entity_tag, tag, LivingFacts};
use super::{effects, emax, f, health, FLOAT_MAX};

/// `@player_memory`: ticks a mob remembers the player who hurt it.
pub const PLAYER_MEMORY: i32 = 100;

/// An entity type as the rules read it: its registry id and facts.
#[derive(Clone, Copy, Debug)]
pub struct Type<'a> {
    pub id: u16,
    pub facts: &'a EntityType,
}

impl<'a> Type<'a> {
    /// The type named `name` (`EntityTypes.fetch/1`).
    pub fn of(mob: &'a MobFacts, name: &str) -> Option<Type<'a>> {
        let id = mob.entities.id(name)?;
        Some(Type {
            id,
            facts: mob.entities.get(id)?,
        })
    }
}

/// `Mob.alive?/1`.
#[inline]
pub fn alive(mob: &Mob) -> bool {
    mob.living.health.value > 0.0
}

/// `Mob.new/1`'s state: full health at its maximum (`max_health`'s base),
/// its family's air and motion.
pub fn fresh(facts: &LivingFacts, mob_facts: &MobFacts, ty: Type, family: &dyn Family) -> Mob {
    let maximum = base(
        facts,
        mob_facts,
        ty,
        &Attributes::default(),
        facts.attributes.max_health,
    );
    Mob {
        living: Living {
            health: Health {
                value: f(maximum),
                maximum: f(maximum),
                hurt_ticks: 0,
                death_ticks: 0,
                cooldown: 0,
                last_hurt: 0.0,
            },
            last_mob_hurt: None,
            absorption: 0.0,
            effects: Effects::default(),
            fire_ticks: 0,
            air_supply: family.max_air(),
            freezing: Default::default(),
        },
        equipment: Equipment::default(),
        attributes: Attributes::default(),
        ai: None,
        no_ai: false,
        motion: family.motion(),
        hurt_by_player: None,
        player_memory: 0,
        hurt_by: None,
        death: None,
        spawns: Vec::new(),
        persistent: false,
        left_handed: false,
        can_pick_up_loot: false,
        drop_chances: Default::default(),
        finalize: None,
        leash: None,
        home: None,
        using: None,
    }
}

/// `Mob.tick/1`: its hurt and death timers and player memory; true once the
/// death animation's 20 ticks passed (`tickDeath`).
pub fn tick(mob: &mut Mob) -> bool {
    health::tick(&mut mob.living.health);
    mob.player_memory = (mob.player_memory - 1).max(0);
    if mob.player_memory <= 0 {
        mob.hurt_by_player = None;
    }
    let h = &mob.living.health;
    h.value <= 0.0 && h.death_ticks >= 20
}

/// `Mob.kill/1` (`genericKill` of Float.MAX_VALUE): true when it starts
/// dying, false for one already dying.
pub fn kill(mob: &mut Mob) -> bool {
    let (window, selected) = health::hurt_window(&mob.living.health, FLOAT_MAX, true);
    match damage::resolve_kill(&mut mob.living, window, selected) {
        Resolved::Applied => {
            health::die(&mut mob.living);
            true
        }
        _ => false,
    }
}

/// `isInvulnerableToBase`: fire for fire-immune types, falls for immune
/// ones.
pub fn immune(facts: &LivingFacts, ty: Type, source: u16) -> bool {
    (facts.is(source, tag::IS_FIRE) && ty.facts.fire_immune)
        || (facts.is(source, tag::IS_FALL)
            && facts.entity_is(ty.id, entity_tag::FALL_DAMAGE_IMMUNE))
}

/// `Mob.stirs?/3`: a hurt that gets past the first checks restarts the
/// idle time even when the cooldown then turns it away.
pub fn stirs(facts: &LivingFacts, ty: Type, mob: &Mob, source: u16) -> bool {
    alive(mob) && !immune(facts, ty, source)
}

/// `Mob.hurt/3` (`LivingEntity.hurtServer` up to its death): the outcome,
/// or None (nothing changed) when it takes nothing.
pub fn hurt(
    facts: &LivingFacts,
    mob_facts: &MobFacts,
    ty: Type,
    mob: &mut Mob,
    hit: &Hit,
) -> Option<Outcome> {
    let source = hit.source;
    if !alive(mob) || (!hit.bypass_immunity && immune(facts, ty, source)) {
        return None;
    }
    let mut amount = emax(0.0, f(hit.amount));
    if facts.is(source, tag::IS_FREEZING) && facts.entity_is(ty.id, entity_tag::FREEZE_HURTS_EXTRA)
    {
        amount = f(amount * 5.0);
    }
    // Helmet wear is the wearer's (`hurtHelmet`), which mobs do not wear.
    if facts.is(source, tag::DAMAGES_HELMET) && mob.equipment.get(Slot::Head).is_some() {
        amount = f(amount * 0.75);
    }
    let armor = (
        value(facts, mob_facts, ty, mob, facts.attributes.armor),
        value(facts, mob_facts, ty, mob, facts.attributes.armor_toughness),
        breach(facts, mob_facts, ty, hit),
    );
    let (window, selected) = health::hurt_window(
        &mob.living.health,
        amount,
        facts.is(source, tag::BYPASSES_COOLDOWN),
    );
    let resolved = damage::resolve(
        facts,
        mob_facts,
        &mut mob.living,
        &mob.equipment,
        window,
        selected,
        source,
        armor,
    );
    if resolved != Resolved::Applied {
        return None;
    }
    let died = mob.living.health.value <= 0.0;
    if died {
        health::die(&mut mob.living);
    }
    if let Some(attacker) = &hit.attacker {
        if !facts.is(source, tag::NO_ANGER) {
            mob.hurt_by = Some(attacker.uuid);
        }
        if attacker.player {
            mob.hurt_by_player = Some(attacker.uuid);
            mob.player_memory = PLAYER_MEMORY;
        }
    }
    Some(Outcome {
        full: selected.notify,
        died,
    })
}

/// A melee weapon's `armor_effectiveness` effects on the mob's armour share
/// (`EnchantmentHelper.modifyArmorEffectiveness` from 0: Breach, VMC-037q).
fn breach(facts: &LivingFacts, mob_facts: &MobFacts, ty: Type, hit: &Hit) -> f64 {
    let Some(attacker) = hit.attacker.as_ref() else {
        return 0.0;
    };
    let melee = hit.post_attack && hit.direct.as_ref().is_some_and(|d| d.uuid == attacker.uuid);
    let Some(weapon) = attacker.mainhand.as_ref().filter(|_| melee) else {
        return 0.0;
    };
    let levels: Vec<(&str, i32)> = super::items::enchantments(weapon)
        .into_iter()
        .map(|(n, l)| (n, l as i32))
        .collect();
    if levels.is_empty() {
        return 0.0;
    }
    let this = super::enchant::EntityView {
        type_id: ty.id,
        ..Default::default()
    };
    let ctx = super::enchant::Context {
        this: Some(&this),
        damage: Some((hit.source, true)),
        ..Default::default()
    };
    let mut random = crate::mobs::random::LegacyRandom::new(0);
    let mut draws = super::enchant::Legacy {
        random: &mut random,
        held: None,
    };
    facts.enchant.value(
        mob_facts,
        super::enchant::ValueHook::ArmorEffectiveness,
        &levels,
        &ctx,
        &mut draws,
        0.0,
    ) as f64
}

/// `Mob.base/3`: attribute `attribute`'s base (the override's, else the
/// type's default, else the attribute's).
pub fn base(
    facts: &LivingFacts,
    mob_facts: &MobFacts,
    ty: Type,
    attributes: &Attributes,
    attribute: u16,
) -> f64 {
    let _ = facts;
    let fact = &mob_facts.attributes.attributes[attribute as usize];
    if let Some(base) = attributes.get(&fact.name).and_then(|o| o.base) {
        return base;
    }
    ty.facts.attribute(&fact.name).unwrap_or(fact.default)
}

/// The equipment slots in the order the Elixir map iterates them (atom
/// order).
const MAP_ORDER: [Slot; 8] = [
    Slot::Body,
    Slot::Chest,
    Slot::Feet,
    Slot::Head,
    Slot::Legs,
    Slot::Mainhand,
    Slot::Offhand,
    Slot::Saddle,
];

/// `Mob.value/3` (`getAttributeValue`): the base, its override's modifiers
/// and the stock modifiers of the equipment in its slots.
pub fn value(
    facts: &LivingFacts,
    mob_facts: &MobFacts,
    ty: Type,
    mob: &Mob,
    attribute: u16,
) -> f64 {
    let fact = &mob_facts.attributes.attributes[attribute as usize];
    let mut modifiers: Vec<(f64, u8)> = Vec::new();
    if let Some(o) = mob.attributes.get(&fact.name) {
        modifiers.extend(
            o.modifiers
                .iter()
                .map(|m| (m.amount.as_f64(), m.operation as u8)),
        );
    }
    for slot in MAP_ORDER {
        let Some(stack) = mob.equipment.get(slot) else {
            continue;
        };
        let Some(id) = super::items::item_id(stack) else {
            continue;
        };
        for m in &facts.item(id).modifiers {
            if m.attribute == attribute && m.slots & (1 << slot as usize) != 0 {
                modifiers.push((m.amount, m.operation));
            }
        }
    }
    let base = base(facts, mob_facts, ty, &mob.attributes, attribute);
    super::attributes::value(fact, base, &modifiers)
}

/// A synced attribute: `{id, base, modifiers}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Synced {
    pub id: u16,
    pub base: f64,
    pub modifiers: Vec<Modifier>,
}

/// `Mob.synced/2`: the syncable attributes the type has, in id order.
pub fn synced(
    facts: &LivingFacts,
    mob_facts: &MobFacts,
    ty: Type,
    attributes: &Attributes,
) -> Vec<Synced> {
    let mut out: Vec<Synced> = ty
        .facts
        .attributes
        .iter()
        .flatten()
        .filter_map(|(name, _)| {
            let fact = mob_facts.attributes.fetch(name)?;
            fact.syncable.then(|| Synced {
                id: fact.id,
                base: base(facts, mob_facts, ty, attributes, fact.id),
                modifiers: attributes
                    .get(&fact.name)
                    .map(|o| o.modifiers.clone())
                    .unwrap_or_default(),
            })
        })
        .collect();
    out.sort_by_key(|s| s.id);
    out
}

/// `Mob.equipment_changes/2`: `(slot id, stack or none)` of each slot whose
/// stack changed (by count and item; the components compared as terms).
pub fn equipment_changes(current: &Equipment, previous: &Equipment) -> Vec<(i32, Option<Value>)> {
    Slot::ALL
        .into_iter()
        .filter(|&slot| current.get(slot) != previous.get(slot))
        .map(|slot| (slot as i32, current.get(slot).cloned()))
        .collect()
}

/// `Mob.drop_chance/2`.
pub fn drop_chance(facts: &LivingFacts, mob: &Mob, slot: Slot) -> f64 {
    mob.drop_chances.get(slot).unwrap_or(facts.drop_chance)
}

/// `Mob.put_drop_chance/3`: kept only where it differs from the default.
pub fn put_drop_chance(facts: &LivingFacts, mob: &mut Mob, slot: Slot, chance: f64) {
    mob.drop_chances.0[slot as usize] = (chance != facts.drop_chance).then_some(chance);
}

/// `canBeAffected`: whether a mob of type `ty` takes effect `id` (the
/// generated immunities: the type tags and the spiders', withers',
/// nautiluses' and parched's own rules).
pub fn affected(mob_facts: &MobFacts, ty: u16, id: i32) -> bool {
    !mob_facts.hostile.immune(ty, id)
}

/// `LivingEntity.addEffect`: refused where its type is immune; otherwise
/// merged in (`MobEffectInstance.update`), its attribute modifiers
/// refreshed when it changed (`onEffectAdded`, `onEffectUpdated`), and
/// Absorption's pool filled to the dose's (`onEffectStarted`, on every add).
/// Whether the effect changed.
pub fn add_effect(mob_facts: &MobFacts, ty: u16, mob: &mut Mob, id: i32, rung: Rung) -> bool {
    if !affected(mob_facts, ty, id) {
        return false;
    }
    let changed = effects::add(&mut mob.living.effects, id, rung);
    if changed {
        refresh_modifiers(mob_facts, mob, id);
    }
    if mob_facts.effects.id("absorption") == Some(id as u32) {
        let dose = f((f64::from(rung.amplifier) + 1.0) * 4.0);
        let maximum = absorption_maximum(mob_facts, mob, id);
        mob.living.absorption = emax(0.0, mob.living.absorption.max(dose).min(maximum));
    }
    changed
}

/// `getMaxAbsorption` while effect `absorption` is as it is now.
fn absorption_maximum(mob_facts: &MobFacts, mob: &Mob, absorption: i32) -> f64 {
    let max = mob_facts
        .attributes
        .id("max_absorption")
        .map_or(0.0, |a| mob_facts.attributes.attributes[a as usize].max);
    super::attributes::absorption_pool_maximum(&mob.living.effects, absorption, max)
}

/// `removeEffect`: whether it was there; its modifiers go with it.
pub fn remove_effect(mob_facts: &MobFacts, mob: &mut Mob, id: i32) -> bool {
    let removed = effects::remove(&mut mob.living.effects, id);
    if removed {
        refresh_modifiers(mob_facts, mob, id);
    }
    removed
}

/// `removeAllEffects` (milk): whether any went.
pub fn clear_effects(mob_facts: &MobFacts, mob: &mut Mob) -> bool {
    let ids: Vec<i32> = mob.living.effects.0.iter().map(|(id, _)| *id).collect();
    for &id in &ids {
        remove_effect(mob_facts, mob, id);
    }
    !ids.is_empty()
}

/// `MobEffect.removeAttributeModifiers`, then `addAttributeModifiers` at
/// the active amplifier while it lasts: effect `id`'s generated modifiers
/// on the mob's attribute overrides.
pub fn refresh_modifiers(mob_facts: &MobFacts, mob: &mut Mob, id: i32) {
    let amplifier = mob.living.effects.amplifier(id).map_or(0, i32::from);
    let rows = mob_facts.hostile.effect_modifiers(id as u16, amplifier);
    let active = mob.living.effects.get(id).is_some();
    // A lower maximum clamps the pool (`onAttributeUpdated`).
    if mob_facts.effects.id("absorption") == Some(id as u32) {
        let maximum = absorption_maximum(mob_facts, mob, id);
        mob.living.absorption = mob.living.absorption.min(maximum);
    }
    for (attribute, mid, amount, operation) in rows {
        let name = &mob_facts.attributes.attributes[attribute as usize].name;
        let entry: &mut AttributeOverride = mob.attributes.entry(name);
        entry.modifiers.retain(|m| m.id != mid);
        if active {
            entry.modifiers.push(Modifier {
                id: mid.to_owned(),
                amount: Number::Float(amount),
                operation: operation as i32,
            });
        }
    }
}

/// Health Boost's maximum health (`onAttributeUpdated`): the maximum
/// follows `max_health`'s value, and health above it is clamped. Only a mob
/// whose `max_health` an effect has touched is looked at.
pub fn reconcile_max_health(facts: &LivingFacts, mob_facts: &MobFacts, ty: Type, mob: &mut Mob) {
    if mob.attributes.get("minecraft:max_health").is_none() {
        return;
    }
    let maximum = f(value(
        facts,
        mob_facts,
        ty,
        mob,
        facts.attributes.max_health,
    ));
    let health = &mut mob.living.health;
    if health.maximum != maximum {
        health.maximum = maximum;
        health.value = health.value.min(maximum);
    }
}
