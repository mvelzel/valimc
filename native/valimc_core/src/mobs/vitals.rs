//! A native mob's living rules around its move (VMC-081d), ported from
//! `Valimc.Entity.MobVitals` and `Valimc.AI.Daylight`, in vanilla's tick
//! order: `base_tick` before it thinks (`baseTick`'s burning a second at a
//! time, then `tickEffects`), `apply` after the kernel moved it (air and
//! drowning, the landing's fall damage, the move's fire, lava and water
//! contacts, water's hurt to a type sensitive to it) and `daylight` (rain
//! putting it out, the sun on undead). Each hurt goes through the one hurt
//! path (`combat::hurt_mob`).

use super::combat::{self, Event, Rules, SoundRef};
use super::level::Level;
use super::living::burning::{self, Operation};
use super::living::durability::{self, Wear};
use super::living::facts::entity_tag;
use super::living::mob::{self as living_mob, Type};
use super::living::{air, attributes, effects, f, fall, health};
use super::model::{NativeMob, Rung, Slot};
use super::random::LegacyRandom;
use crate::physics::mob::Ticked;
use crate::physics::player::contacts::{Source, Touched};

/// `LivingEntity.baseTick`'s burning and `tickEffects`, before the mob
/// thinks: a second's damage while burning outside lava (the lava its last
/// move left), counting down; then each periodic effect's heal or hurt from
/// its duration before it counts down (instant health heals as it ticks),
/// an ended one removed. An animal hurt loses its love.
pub fn base_tick(rules: &Rules, mob: &mut NativeMob) -> Vec<Event> {
    let mut events = Vec::new();
    if !living_mob::alive(&mob.body.mob) {
        return events;
    }
    let Some(ty) = rules.of(&mob.body.entity_type) else {
        return events;
    };
    let before = mob.body.mob.living.health.clone();
    let lava = mob.body.mob.motion.lava > 0.0;
    let (ticks, damage) = burning::tick(mob.body.mob.living.fire_ticks, ty.facts.fire_immune, lava);
    mob.body.mob.living.fire_ticks = ticks;
    if damage > 0.0 {
        hurt(rules, mob, &mut events, rules.living.damage.on_fire, damage);
    }
    tick_effects(rules, mob, &mut events);
    actually_hurt(rules, ty, mob, &before);
    events
}

fn actually_hurt(rules: &Rules, ty: Type, mob: &mut NativeMob, before: &super::model::Health) {
    if mob.body.mob.living.health != *before {
        rules.family(ty).actually_hurt(&mut mob.body.data);
    }
}

fn hurt(rules: &Rules, mob: &mut NativeMob, events: &mut Vec<Event>, source: u16, amount: f64) {
    let (more, _) = combat::hurt_mob(rules, mob, source, amount);
    events.extend(more);
}

fn tick_effects(rules: &Rules, mob: &mut NativeMob, events: &mut Vec<Event>) {
    let e = &rules.living.effects;
    if mob.body.mob.living.effects.0.is_empty() {
        return;
    }
    let periodic: Vec<(i32, Vec<Rung>)> = effects::periodic_ids(rules.living)
        .into_iter()
        .filter_map(|id| Some((id, mob.body.mob.living.effects.get(id)?.to_vec())))
        .collect();
    if let Some(&head) = mob
        .body
        .mob
        .living
        .effects
        .get(e.instant_health)
        .and_then(|r| r.first())
    {
        if head.ticks >= 1 {
            if let effects::Action::Heal(amount) =
                effects::instant(rules.living, e.instant_health, head.amplifier)
            {
                health::heal(&mut mob.body.mob.living.health, amount);
            }
        }
    }
    effects::tick(&mut mob.body.mob.living.effects);
    let age = mob.body.mob.ai.as_ref().map_or(0, |m| rules.mind.tick(m));
    for (id, instance) in periodic {
        match effects::periodic(
            rules.living,
            id,
            &instance,
            age,
            &mob.body.mob.living.health,
        ) {
            effects::Action::Heal(amount) => health::heal(&mut mob.body.mob.living.health, amount),
            effects::Action::Hurt(source, amount) => {
                if living_mob::alive(&mob.body.mob) {
                    hurt(rules, mob, events, source, amount);
                }
            }
            effects::Action::None => {}
        }
    }
}

/// What `apply` reads of the kernel's tick.
#[derive(Clone, Copy, Debug)]
pub struct Moved<'a> {
    pub eye_water: bool,
    pub eye_state: u16,
    /// The landing block and fall distance.
    pub landing: Option<(u16, f64)>,
    pub touched: &'a Touched,
    /// In water after the move.
    pub water: bool,
}

impl<'a> From<&'a Ticked> for Moved<'a> {
    fn from(t: &'a Ticked) -> Moved<'a> {
        Moved {
            eye_water: t.eye_water,
            eye_state: t.eye_state,
            landing: t.landing,
            touched: &t.touched,
            water: t.water,
        }
    }
}

/// `MobVitals.apply/3`: air (a type that does not keep its own), the
/// landing's fall damage, the move's contacts in order and water's hurt to a
/// type sensitive to it.
pub fn apply(rules: &Rules, mob: &mut NativeMob, moved: &Moved) -> Vec<Event> {
    let mut events = Vec::new();
    let Some(ty) = rules.of(&mob.body.entity_type) else {
        return events;
    };
    let before = mob.body.mob.living.health.clone();
    if !rules.family(ty).own_air() {
        breathe(rules, ty, mob, &mut events, moved);
    }
    if let Some((state, distance)) = moved.landing {
        landing(rules, ty, mob, &mut events, state, distance);
    }
    contacts(rules, ty, mob, &mut events, moved.touched);
    if moved.water
        && rules.facts.hostile.water_sensitive.contains(&ty.id)
        && living_mob::alive(&mob.body.mob)
    {
        hurt(rules, mob, &mut events, rules.living.damage.drown, 1.0);
    }
    actually_hurt(rules, ty, mob, &before);
    events
}

/// `MobVitals.set_air/4`: a family's own air and the drowning it takes.
pub fn set_air(rules: &Rules, mob: &mut NativeMob, air: i32, damage: f64) -> Vec<Event> {
    mob.body.mob.living.air_supply = air;
    let mut events = Vec::new();
    if damage > 0.0 {
        hurt(rules, mob, &mut events, rules.living.damage.drown, damage);
    }
    events
}

fn breathe(rules: &Rules, ty: Type, mob: &mut NativeMob, events: &mut Vec<Event>, moved: &Moved) {
    let l = rules.living;
    let submerged = air::submerged(l, &rules.facts.blocks, moved.eye_water, moved.eye_state);
    let breathes = l.entity_is(ty.id, entity_tag::CAN_BREATHE_UNDER_WATER)
        || l.entity_is(ty.id, entity_tag::WATER_BREATHER);
    let oxygen = living_mob::base(
        l,
        rules.facts,
        ty,
        &mob.body.mob.attributes,
        l.attributes.oxygen_bonus,
    );
    let policy = if breathes {
        air::Policy::Hold
    } else {
        air::policy(l, &mob.body.mob.living.effects)
    };
    let uuid = mob.uuid;
    let current = mob.body.mob.living.air_supply;
    let (supply, damage) = air::tick(current, submerged, oxygen, policy, || {
        combat::random(&mut mob.body.mob, &uuid).double()
    });
    mob.body.mob.living.air_supply = supply;
    if damage > 0.0 {
        hurt(rules, mob, events, l.damage.drown, damage);
    }
}

fn landing(
    rules: &Rules,
    ty: Type,
    mob: &mut NativeMob,
    events: &mut Vec<Event>,
    state: u16,
    distance: f64,
) {
    let l = rules.living;
    let Some(call) = fall::call(l, state, distance) else {
        return;
    };
    if l.entity_is(ty.id, entity_tag::FALL_DAMAGE_IMMUNE) {
        return;
    }
    let jump = attributes::jump_safe_distance(l, &mob.body.mob.living.effects);
    let attrs = &mob.body.mob.attributes;
    let safe = living_mob::base(l, rules.facts, ty, attrs, l.attributes.safe_fall_distance);
    let multiplier = living_mob::base(
        l,
        rules.facts,
        ty,
        attrs,
        l.attributes.fall_damage_multiplier,
    );
    let amount = fall::calculate(
        call.distance,
        call.multiplier,
        safe + jump - 3.0,
        multiplier,
    );
    if amount > 0 {
        hurt(rules, mob, events, call.source, amount as f64);
    }
}

fn contacts(
    rules: &Rules,
    ty: Type,
    mob: &mut NativeMob,
    events: &mut Vec<Event>,
    touched: &Touched,
) {
    let l = rules.living;
    let immune = ty.facts.fire_immune;
    let before = mob.body.mob.living.fire_ticks;
    let immediate = touched.immediate.iter().map(|&(source, amount)| {
        let source = match source {
            Source::HotFloor => l.damage.hot_floor,
            Source::Campfire => l.damage.campfire,
            Source::Cactus => l.damage.cactus,
            Source::SweetBerryBush => l.damage.sweet_berry_bush,
        };
        (source, amount)
    });
    let steps: Vec<Step> = immediate
        .map(|(source, amount)| Step::Damage(source, amount))
        .chain(
            burning::plan(&touched.steps)
                .into_iter()
                .map(Step::Operation),
        )
        .collect();
    for step in steps {
        if !living_mob::alive(&mob.body.mob) {
            continue;
        }
        let operation = match step {
            Step::Damage(source, amount) => {
                hurt(rules, mob, events, source, amount);
                continue;
            }
            Step::Operation(operation) => operation,
        };
        let burning = || {
            living_mob::base(
                l,
                rules.facts,
                ty,
                &mob.body.mob.attributes,
                l.attributes.burning_time,
            )
        };
        match operation {
            Operation::FireIgnite => {
                let factor = burning();
                let fire = &mut mob.body.mob.living.fire_ticks;
                *fire = burning::entity_fire(*fire, immune, factor);
            }
            Operation::LavaIgnite => {
                let factor = burning();
                let fire = &mut mob.body.mob.living.fire_ticks;
                *fire = burning::lava(*fire, immune, factor);
            }
            Operation::LavaHurt => {
                if !immune {
                    hurt(rules, mob, events, l.damage.lava, 4.0);
                }
            }
            Operation::InFire(amount) => hurt(rules, mob, events, l.damage.in_fire, amount),
            Operation::Extinguish => {
                let fire = &mut mob.body.mob.living.fire_ticks;
                *fire = burning::clear(*fire);
            }
            Operation::ClearFreeze => mob.body.mob.living.freezing.frozen_ticks = 0,
        }
    }
    let fire = &mut mob.body.mob.living.fire_ticks;
    *fire = burning::settle(*fire, before, immune);
    // Put out (`applyEffectsFromBlocks`): the hiss, pitched from its random.
    if before > 0 && !immune && mob.body.mob.living.fire_ticks <= 0 {
        let uuid = mob.uuid;
        let r = combat::random(&mut mob.body.mob, &uuid);
        let a = r.float() as f64;
        let b = r.float() as f64;
        let pitch = f(f(1.6) + f(f(a - b) * f(0.4)));
        let id = rules
            .facts
            .sounds
            .id("minecraft:entity.generic.extinguish_fire")
            .unwrap_or(-1);
        events.push(Event::Sound {
            sound: SoundRef::Id(id),
            source: rules.facts.combat.mob_sounds(ty.id).source,
            volume: f(0.7),
            pitch,
        });
    }
}

/// A contact's step: an immediate hurt or a burning operation.
enum Step {
    Damage(u16, f64),
    Operation(Operation),
}

/// What the sun and rain read of the world (`Valimc.AI.World`'s sky).
pub trait Sky {
    /// The overworld day's `monsters_burn`.
    fn monsters_burn(&self) -> bool;
    /// `World.light/2`: the brightness at a block.
    fn light(&self, p: [i32; 3]) -> f64;
    /// `World.sees_sky?/2`.
    fn sees_sky(&self, p: [i32; 3]) -> bool;
    /// Rain at a body's feet `position` or head height `top`.
    fn rain(&self, position: [f64; 3], top: f64) -> bool;
    /// The level's random (`World.random`): Unbreaking's draws.
    fn random(&mut self) -> &mut LegacyRandom;
}

impl Sky for Level<'_> {
    fn monsters_burn(&self) -> bool {
        self.monsters_burn
    }

    fn light(&self, p: [i32; 3]) -> f64 {
        Level::light(self, p) as f64
    }

    fn sees_sky(&self, p: [i32; 3]) -> bool {
        Level::sees_sky(self, p)
    }

    fn rain(&self, position: [f64; 3], top: f64) -> bool {
        Level::rain(self, position, top)
    }

    fn random(&mut self) -> &mut LegacyRandom {
        Level::random(self)
    }
}

/// `Daylight.tick/3`: after its move, at `position`, rain puts a burning
/// mob out; while monsters burn, an undead mob whose eyes are in light above
/// half brightness draws whether the sun takes it this tick (unless in
/// water or rain or under a roof): a helmet wears instead (0 or 1 points), a
/// bare head catches fire for eight seconds.
pub fn daylight(
    rules: &Rules,
    mob: &mut NativeMob,
    position: [f64; 3],
    sky: &mut dyn Sky,
) -> Vec<Event> {
    let mut events = Vec::new();
    if !living_mob::alive(&mob.body.mob) {
        return events;
    }
    let Some(ty) = rules.of(&mob.body.entity_type) else {
        return events;
    };
    let [_, height, eye] = super::living::body::dimensions(rules, ty, &mob.body);
    let raining = |sky: &dyn Sky| sky.rain(position, position[1] + height);
    if mob.body.mob.living.fire_ticks > 0 && raining(sky) {
        mob.body.mob.living.fire_ticks = 0;
    }
    if !(sky.monsters_burn() && rules.living.entity_is(ty.id, entity_tag::BURN_IN_DAYLIGHT)) {
        return events;
    }
    let at = [
        position[0].floor() as i32,
        (position[1] + eye).floor() as i32,
        position[2].floor() as i32,
    ];
    let brightness = sky.light(at);
    if brightness <= 0.5 {
        return events;
    }
    let uuid = mob.uuid;
    let draw = combat::random(&mut mob.body.mob, &uuid).float() as f64;
    let burns = f(draw * 30.0) < f(f(brightness - 0.4) * 2.0)
        && mob.body.mob.motion.water <= 0.0
        && !raining(sky)
        && sky.sees_sky(at);
    if !burns {
        return events;
    }
    match mob.body.mob.equipment.get(Slot::Head).cloned() {
        None => {
            let factor = living_mob::value(
                rules.living,
                rules.facts,
                ty,
                &mob.body.mob,
                rules.living.attributes.burning_time,
            );
            let ticks = (160.0 * factor).ceil() as i64;
            let fire = &mut mob.body.mob.living.fire_ticks;
            if (*fire as i64) < ticks {
                *fire = ticks.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
            }
        }
        Some(helmet) => {
            let n = combat::random(&mut mob.body.mob, &uuid).int(2);
            let wear =
                durability::hurt_and_break(rules.living, rules.facts, &helmet, n as i64, || {
                    sky.random().float() as f64
                });
            match wear {
                Wear::Broken(_) => {
                    mob.body.mob.equipment.set(Slot::Head, None);
                    events.push(Event::Entity(49));
                }
                Wear::Worn(stack) => mob.body.mob.equipment.set(Slot::Head, Some(stack)),
                Wear::Unchanged => {}
            }
        }
    }
    events
}
