//! The hooks: vanilla's `Enchantment` methods over the compiled effects.

use super::*;
use crate::mobs::facts::MobFacts;
use crate::mobs::model::Slot;
use crate::mobs::random::LegacyRandom;

/// The random draws effects take (an entity's or the level's random).
pub trait Draws {
    fn float(&mut self) -> f32;
    fn gaussian(&mut self) -> f64;
    fn int(&mut self, bound: i32) -> i32;
}

/// A legacy random with its held gaussian.
pub struct Legacy<'a> {
    pub random: &'a mut LegacyRandom,
    pub held: Option<f64>,
}

impl Draws for Legacy<'_> {
    fn float(&mut self) -> f32 {
        self.random.float()
    }
    fn gaussian(&mut self) -> f64 {
        self.random.gaussian(&mut self.held)
    }
    fn int(&mut self, bound: i32) -> i32 {
        self.random.int(bound)
    }
}

/// `Mth.randomBetween`.
fn between(draws: &mut dyn Draws, min: f32, max: f32) -> f32 {
    draws.float() * (max - min) + min
}

impl FloatProvider {
    pub fn sample(&self, draws: &mut dyn Draws) -> f32 {
        match self {
            FloatProvider::Constant(v) => *v,
            FloatProvider::Uniform(min, max) => between(draws, *min, *max),
        }
    }
}

impl ValueEffect {
    /// `EnchantmentValueEffect.process`.
    pub fn process(&self, level: i32, draws: &mut dyn Draws, value: f32) -> f32 {
        match self {
            ValueEffect::Add(v) => value + v.at(level),
            ValueEffect::Set(v) => v.at(level),
            ValueEffect::Multiply(v) => value * v.at(level),
            ValueEffect::AllOf(effects) => effects
                .iter()
                .fold(value, |v, e| e.process(level, draws, v)),
            ValueEffect::RemoveBinomial(chance) => {
                let p = chance.at(level);
                let n = value;
                let mut drop = 0i32;
                if n > 128.0 && n * p >= 20.0 && n * (1.0 - p) >= 20.0 {
                    let miu = (n * p).floor() as f64;
                    let sigma = ((n * p * (1.0 - p)) as f64).sqrt();
                    drop = (miu + draws.gaussian() * sigma).round() as i32;
                    drop = drop.clamp(0, n as i32);
                } else {
                    let mut y = 0;
                    while (y as f32) < n {
                        if draws.float() < p {
                            drop += 1;
                        }
                        y += 1;
                    }
                }
                n - drop as f32
            }
        }
    }
}

/// An entity as requirements read it.
#[derive(Clone, Debug, Default)]
pub struct EntityView {
    pub type_id: u16,
    pub on_ground: bool,
    pub in_water: bool,
    pub fall_flying: bool,
    /// A player's abilities' flying.
    pub flying: bool,
    pub vehicle: bool,
    /// The sky seen from its block position.
    pub can_see_sky: bool,
    /// `getBlockPosBelowThatAffectsMyMovement`'s block registry id.
    pub affected_by: Option<u16>,
    /// `MovementPredicate`'s horizontal speed (blocks per second).
    pub horizontal_speed: f64,
    pub fall_distance: f64,
    pub tick_count: i32,
    /// A player's game mode (`"survival"`...) and food level.
    pub player: Option<(String, i32)>,
}

/// A loot context as the enchantment contexts build it.
#[derive(Clone, Copy, Default)]
pub struct Context<'a> {
    pub this: Option<&'a EntityView>,
    pub attacker: Option<&'a EntityView>,
    pub direct: Option<&'a EntityView>,
    /// The damage type's registry id and whether its source is direct.
    pub damage: Option<(u16, bool)>,
    /// The tool's item id (`ENCHANTED_ITEM`).
    pub tool: Option<i32>,
    pub active: Option<bool>,
    pub thundering: bool,
    /// `location_check`'s block at the origin and its sky.
    pub block: Option<(u16, bool)>,
}

impl Engine {
    pub fn get(&self, name: &str) -> Option<&Definition> {
        self.definitions.get(name)
    }

    /// `matchingSlot`: whether enchantment `name` acts in `slot`.
    pub fn in_slot(&self, name: &str, slot: Slot) -> bool {
        self.get(name)
            .is_some_and(|d| d.slots & (1 << slot as usize) != 0)
    }

    /// `LootItemCondition.test` of a requirement at enchantment `level`.
    pub fn matches(
        &self,
        mob: &MobFacts,
        condition: &Condition,
        level: i32,
        ctx: &Context,
        draws: &mut dyn Draws,
    ) -> bool {
        match condition {
            Condition::AllOf(terms) => terms
                .iter()
                .all(|t| self.matches(mob, t, level, ctx, draws)),
            Condition::AnyOf(terms) => terms
                .iter()
                .any(|t| self.matches(mob, t, level, ctx, draws)),
            Condition::Inverted(term) => !self.matches(mob, term, level, ctx, draws),
            Condition::Entity(who, predicate) => {
                let entity = match who {
                    Who::This => ctx.this,
                    Who::Attacker => ctx.attacker,
                    Who::DirectAttacker => ctx.direct,
                };
                entity.is_some_and(|e| entity_matches(mob, predicate, e))
            }
            Condition::Damage(tags, direct) => ctx.damage.is_some_and(|(source, is_direct)| {
                tags.iter()
                    .all(|(tag, expected)| mob.damage_tag(source, tag) == *expected)
                    && direct.is_none_or(|d| d == is_direct)
            }),
            Condition::MatchTool(items) => ctx.tool.is_some_and(|tool| match items {
                Ok(id) => tool == *id,
                Err(tag) => mob.item_tag(tool, tag),
            }),
            Condition::Chance(chance) => draws.float() < chance.at(level),
            Condition::Active(active) => ctx.active == Some(*active),
            Condition::Thundering(thundering) => ctx.thundering == *thundering,
            Condition::Location(tag, sky) => ctx.block.is_some_and(|(block, can_see)| {
                tag.as_ref().is_none_or(|t| mob.block_tag(block, t))
                    && sky.is_none_or(|s| s == can_see)
            }),
        }
    }

    fn holds(
        &self,
        mob: &MobFacts,
        condition: &Option<Condition>,
        level: i32,
        ctx: &Context,
        draws: &mut dyn Draws,
    ) -> bool {
        condition
            .as_ref()
            .is_none_or(|c| self.matches(mob, c, level, ctx, draws))
    }

    /// A value hook over `enchantments` (levels by name, in iteration
    /// order): `value` after each effect whose requirements hold. The caller
    /// filters by slot where vanilla iterates equipment.
    pub fn value(
        &self,
        mob: &MobFacts,
        hook: ValueHook,
        enchantments: &[(&str, i32)],
        ctx: &Context,
        draws: &mut dyn Draws,
        value: f32,
    ) -> f32 {
        let mut value = value;
        for (name, level) in enchantments {
            let Some(effects) = self.get(name).and_then(|d| d.values.get(&hook)) else {
                continue;
            };
            for (effect, condition) in effects {
                if self.holds(mob, condition, *level, ctx, draws) {
                    value = effect.process(*level, draws, value);
                }
            }
        }
        value
    }

    /// An unconditioned value hook (`modifyUnfilteredValue`).
    pub fn unconditioned(
        &self,
        hook: Unconditioned,
        enchantments: &[(&str, i32)],
        draws: &mut dyn Draws,
        value: f32,
    ) -> f32 {
        let mut value = value;
        for (name, level) in enchantments {
            if let Some(effect) = self.get(name).and_then(|d| d.unconditioned.get(&hook)) {
                value = effect.process(*level, draws, value);
            }
        }
        value
    }

    /// `processEquipmentDropChance`'s part for one equipment piece:
    /// effects enchanted on `enchanted` affecting the victim.
    pub fn equipment_drops(
        &self,
        mob: &MobFacts,
        enchanted: Target,
        enchantments: &[(&str, i32)],
        ctx: &Context,
        draws: &mut dyn Draws,
        chance: f32,
    ) -> f32 {
        let mut chance = chance;
        for (name, level) in enchantments {
            let Some(def) = self.get(name) else { continue };
            for (on, affected, effect, condition) in &def.equipment_drops {
                if *on == enchanted
                    && *affected == Target::Victim
                    && self.holds(mob, condition, *level, ctx, draws)
                {
                    chance = effect.process(*level, draws, chance);
                }
            }
        }
        chance
    }

    /// `isImmuneToDamage` for one piece's `enchantments`.
    pub fn immune(
        &self,
        mob: &MobFacts,
        enchantments: &[(&str, i32)],
        ctx: &Context,
        draws: &mut dyn Draws,
    ) -> bool {
        enchantments.iter().any(|(name, level)| {
            self.get(name).is_some_and(|d| {
                d.immunity
                    .iter()
                    .any(|c| self.holds(mob, c, *level, ctx, draws))
            })
        })
    }

    /// `forEachModifier(stack, slot)`: the attribute modifiers of the
    /// enchantments acting in `slot` (`(attribute, id/slot, amount, op)`).
    pub fn attribute_modifiers(
        &self,
        enchantments: &[(&str, i32)],
        slot: Slot,
    ) -> Vec<(String, String, f32, u8)> {
        let mut out = Vec::new();
        for (name, level) in enchantments {
            let Some(def) = self.get(name) else { continue };
            if def.slots & (1 << slot as usize) == 0 {
                continue;
            }
            for a in &def.attributes {
                out.push((
                    a.attribute.clone(),
                    format!("{}/{}", a.id, slot.name()),
                    a.amount.at(*level),
                    a.operation,
                ));
            }
        }
        out
    }

    /// `doPostAttack` of one item's enchantments, held by the `enchanted`
    /// party (the victim's piece or the attacker's weapon): the actions,
    /// each on the party it affects.
    pub fn post_attack(
        &self,
        mob: &MobFacts,
        enchanted: Target,
        enchantments: &[(&str, i32)],
        ctx: &Context,
        draws: &mut dyn Draws,
    ) -> Vec<(Target, Action)> {
        let mut out = Vec::new();
        for (name, level) in enchantments {
            let Some(def) = self.get(name) else { continue };
            for t in &def.post_attack {
                if t.enchanted == enchanted && self.holds(mob, &t.condition, *level, ctx, draws) {
                    let mut actions = Vec::new();
                    apply(&t.effect, *level, draws, &mut actions);
                    out.extend(actions.into_iter().map(|a| (t.affected, a)));
                }
            }
        }
        out
    }

    /// An entity hook (`tick`, `onProjectileSpawned`, `onHitBlock`,
    /// `doPostPiercingAttack`) over one item: the actions on its entity.
    pub fn entity(
        &self,
        mob: &MobFacts,
        hook: EntityHook,
        enchantments: &[(&str, i32)],
        ctx: &Context,
        draws: &mut dyn Draws,
    ) -> Vec<Action> {
        let mut out = Vec::new();
        for (name, level) in enchantments {
            let Some(effects) = self.get(name).and_then(|d| d.entity.get(&hook)) else {
                continue;
            };
            for (effect, condition) in effects {
                if self.holds(mob, condition, *level, ctx, draws) {
                    apply(effect, *level, draws, &mut out);
                }
            }
        }
        out
    }

    /// `runLocationChangedEffects` for the item in `slot`: `active` holds
    /// the entity's active location effects (`(slot, enchantment, index)`)
    /// and is updated; the actions in order. `ctx.this` is the entity.
    pub fn location_changed(
        &self,
        mob: &MobFacts,
        slot: Slot,
        enchantments: &[(&str, i32)],
        active: &mut Vec<(Slot, String, usize)>,
        ctx: &Context,
        draws: &mut dyn Draws,
    ) -> Vec<Action> {
        let mut out = Vec::new();
        for (name, level) in enchantments {
            let Some(def) = self.get(name) else { continue };
            if def.slots & (1 << slot as usize) == 0 {
                // Effects active from before stop.
                for (index, (effect, _)) in def.location_changed.iter().enumerate() {
                    if take(active, slot, name, index) {
                        deactivate(effect, slot, &mut out);
                    }
                }
                continue;
            }
            for (index, (effect, condition)) in def.location_changed.iter().enumerate() {
                let was = active
                    .iter()
                    .any(|(s, n, i)| *s == slot && n == name && *i == index);
                let ctx = Context {
                    active: Some(was),
                    ..*ctx
                };
                if self.holds(mob, condition, *level, &ctx, draws) {
                    if !was {
                        active.push((slot, (*name).to_owned(), index));
                    }
                    changed(effect, *level, slot, !was, draws, &mut out);
                } else if take(active, slot, name, index) {
                    deactivate(effect, slot, &mut out);
                }
            }
        }
        out
    }

    /// `stopLocationBasedEffects` for the item leaving `slot`.
    pub fn stop_location(
        &self,
        slot: Slot,
        enchantments: &[(&str, i32)],
        active: &mut Vec<(Slot, String, usize)>,
    ) -> Vec<Action> {
        let mut out = Vec::new();
        for (name, _) in enchantments {
            let Some(def) = self.get(name) else { continue };
            for (index, (effect, _)) in def.location_changed.iter().enumerate() {
                if take(active, slot, name, index) {
                    deactivate(effect, slot, &mut out);
                }
            }
        }
        out
    }

    /// How many of `enchantments` acting in `slot` have value component
    /// `hook` (`getRandomItemWith` adds the item once for each).
    pub fn count_with(&self, hook: ValueHook, enchantments: &[(&str, i32)], slot: Slot) -> usize {
        enchantments
            .iter()
            .filter(|(name, _)| {
                self.get(name).is_some_and(|d| {
                    d.values.contains_key(&hook) && d.slots & (1 << slot as usize) != 0
                })
            })
            .count()
    }

    /// Whether any of `enchantments` has the flag component.
    pub fn prevents_armor_change(&self, enchantments: &[(&str, i32)]) -> bool {
        enchantments
            .iter()
            .any(|(n, _)| self.get(n).is_some_and(|d| d.prevent_armor_change))
    }

    pub fn prevents_equipment_drop(&self, enchantments: &[(&str, i32)]) -> bool {
        enchantments
            .iter()
            .any(|(n, _)| self.get(n).is_some_and(|d| d.prevent_equipment_drop))
    }
}

fn take(active: &mut Vec<(Slot, String, usize)>, slot: Slot, name: &str, index: usize) -> bool {
    match active
        .iter()
        .position(|(s, n, i)| *s == slot && n == name && *i == index)
    {
        Some(at) => {
            active.remove(at);
            true
        }
        None => false,
    }
}

fn entity_matches(mob: &MobFacts, p: &EntityPredicate, e: &EntityView) -> bool {
    let flag = |want: Option<bool>, have: bool| want.is_none_or(|w| w == have);
    p.entity_type.as_ref().is_none_or(|t| match t {
        Ok(id) => e.type_id == *id,
        Err(tag) => mob.entity_tag(e.type_id, tag),
    }) && flag(p.on_ground, e.on_ground)
        && flag(p.in_water, e.in_water)
        && flag(p.fall_flying, e.fall_flying)
        && flag(p.flying, e.flying)
        && (!p.vehicle || e.vehicle)
        && flag(p.can_see_sky, e.can_see_sky)
        && p.affected_by
            .as_ref()
            .is_none_or(|tag| e.affected_by.is_some_and(|b| mob.block_tag(b, tag)))
        && p.min_horizontal_speed
            .is_none_or(|m| e.horizontal_speed >= m)
        && p.min_fall_distance.is_none_or(|m| e.fall_distance >= m)
        && p.periodic_tick.is_none_or(|n| e.tick_count % n == 0)
        && p.player.as_ref().is_none_or(|(modes, food)| {
            e.player.as_ref().is_some_and(|(mode, level)| {
                (modes.is_empty() || modes.iter().any(|m| m == mode))
                    && food.is_none_or(|f| *level >= f)
            })
        })
}

/// What an effect does, for its entity's owner to apply. Positions are the
/// entity's unless an effect names its own.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    /// `addEffect` of `effect` for `ticks` at `amplifier`.
    MobEffect {
        effect: String,
        ticks: i32,
        amplifier: i32,
    },
    /// `igniteForSeconds`.
    Ignite(f32),
    /// `hurtServer` with a source of `damage_type` caused by the item's
    /// owner.
    Damage(f32, String),
    /// `hurtAndBreak` of the enchanted item.
    ItemDamage(i32),
    /// `causeFoodExhaustion` (players only).
    Exhaustion(f32),
    /// `addDeltaMovement` of the look-transformed direction times scale and
    /// magnitude.
    Impulse([f64; 3], [f64; 3], f32),
    /// `playSound` at the entity unless it is silent.
    Sound(String, f32, f32),
    Particles(Box<Particles>),
    /// Spawn one of the types at the entity's position (`TRIGGERED`).
    Summon(Vec<String>, bool),
    /// `ServerLevel.explode` with the radius and knockback multiplier.
    Explode(Box<Explode>, f32, Option<f32>),
    /// `replace_disk`: radius and height (blocks), offset, the predicate
    /// the positions must pass, the state and game event.
    ReplaceDisk {
        radius: i32,
        height: i32,
        offset: [i32; 3],
        predicate: Option<BlockPredicate>,
        state: (String, Vec<(String, String)>),
        event: Option<String>,
    },
    /// Add a transient attribute modifier (attribute, id/slot, amount, op).
    AddModifier(String, String, f32, u8),
    /// Remove it.
    RemoveModifier(String, String),
}

/// `EnchantmentEntityEffect.apply`.
fn apply(effect: &Effect, level: i32, draws: &mut dyn Draws, out: &mut Vec<Action>) {
    match effect {
        Effect::AllOf(effects) => {
            for e in effects {
                apply(e, level, draws, out);
            }
        }
        Effect::MobEffect {
            effects,
            min_duration,
            max_duration,
            min_amplifier,
            max_amplifier,
        } => {
            // `HolderSet.getRandomElement` (`Util.getRandomSafe`): a draw
            // even for one.
            if effects.is_empty() {
                return;
            }
            let effect = effects[draws.int(effects.len() as i32) as usize].clone();
            let ticks = (between(draws, min_duration.at(level), max_duration.at(level)) * 20.0)
                .round() as i32;
            let amplifier = (between(draws, min_amplifier.at(level), max_amplifier.at(level)))
                .round()
                .max(0.0) as i32;
            out.push(Action::MobEffect {
                effect,
                ticks,
                amplifier,
            });
        }
        Effect::Ignite(duration) => out.push(Action::Ignite(duration.at(level))),
        Effect::DamageEntity(min, max, damage_type) => out.push(Action::Damage(
            between(draws, min.at(level), max.at(level)),
            damage_type.clone(),
        )),
        Effect::ChangeItemDamage(amount) => out.push(Action::ItemDamage(amount.at(level) as i32)),
        Effect::Exhaustion(amount) => out.push(Action::Exhaustion(amount.at(level))),
        Effect::Impulse(direction, scale, magnitude) => {
            out.push(Action::Impulse(*direction, *scale, magnitude.at(level)))
        }
        Effect::Sound(sounds, volume, pitch) => {
            let index = (level - 1).clamp(0, sounds.len() as i32 - 1) as usize;
            let volume = volume.sample(draws);
            let pitch = pitch.sample(draws);
            out.push(Action::Sound(sounds[index].clone(), volume, pitch));
        }
        Effect::Particles(p) => out.push(Action::Particles(p.clone())),
        Effect::Summon(types, team) => out.push(Action::Summon(types.clone(), *team)),
        Effect::Explode(e) => out.push(Action::Explode(
            e.clone(),
            e.radius.at(level).max(0.0),
            e.knockback_multiplier.as_ref().map(|k| k.at(level)),
        )),
        Effect::ReplaceDisk {
            radius,
            height,
            offset,
            predicate,
            state,
            event,
        } => out.push(Action::ReplaceDisk {
            radius: radius.at(level) as i32,
            height: height.at(level) as i32,
            offset: *offset,
            predicate: predicate.clone(),
            state: state.clone(),
            event: event.clone(),
        }),
        // A location effect applied as an entity effect does nothing more.
        Effect::Attribute(..) => {}
    }
}

/// `EnchantmentLocationBasedEffect.onChangedBlock`.
fn changed(
    effect: &Effect,
    level: i32,
    slot: Slot,
    became_active: bool,
    draws: &mut dyn Draws,
    out: &mut Vec<Action>,
) {
    match effect {
        Effect::AllOf(effects) => {
            for e in effects {
                changed(e, level, slot, became_active, draws, out);
            }
        }
        Effect::Attribute(attribute, id, amount, op) => {
            if became_active {
                out.push(Action::AddModifier(
                    attribute.clone(),
                    format!("{id}/{}", slot.name()),
                    amount.at(level),
                    *op,
                ));
            }
        }
        other => apply(other, level, draws, out),
    }
}

/// `EnchantmentLocationBasedEffect.onDeactivated`.
fn deactivate(effect: &Effect, slot: Slot, out: &mut Vec<Action>) {
    match effect {
        Effect::AllOf(effects) => {
            for e in effects {
                deactivate(e, slot, out);
            }
        }
        Effect::Attribute(attribute, id, _, _) => out.push(Action::RemoveModifier(
            attribute.clone(),
            format!("{id}/{}", slot.name()),
        )),
        _ => {}
    }
}

/// `replace_disk`'s positions around `position` (before its predicate):
/// `betweenClosed` from the centre's corner, within the radius of the
/// position's column.
pub fn disk_positions(
    position: [f64; 3],
    offset: [i32; 3],
    radius: i32,
    height: i32,
) -> Vec<[i32; 3]> {
    let center = [
        position[0].floor() as i32 + offset[0],
        position[1].floor() as i32 + offset[1],
        position[2].floor() as i32 + offset[2],
    ];
    let top = (height - 1).min(0);
    let r2 = (radius * radius) as f64;
    let mut out = Vec::new();
    // `BlockPos.betweenClosed` runs x fastest, then y, then z.
    for z in center[2] - radius..=center[2] + radius {
        for y in center[1]..=center[1] + top {
            for x in center[0] - radius..=center[0] + radius {
                let dx = x as f64 + 0.5 - position[0];
                let dz = z as f64 + 0.5 - position[2];
                // The height is the position's own row (`pos.getY() + 0.5`).
                if dx * dx + dz * dz < r2 {
                    out.push([x, y, z]);
                }
            }
        }
    }
    out
}
