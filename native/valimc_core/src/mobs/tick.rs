//! A section's mob turns over the physics `Ticker` (VMC-081d): every mob of
//! the section in network-id order, as vanilla's level ticks them.
//!
//! A mob's turn: its fluids sensed (`Entity.baseTick`), its base tick, its
//! thinking (`Thinker`: a pending `finalizeSpawn`, then its family's AI),
//! the kernel's step with its move control, the move written back, its
//! splash into water, turtle eggs and farmland it lands or steps on (the
//! level random), its family's settling, its vitals after the move and the
//! sun. Its events and the effects that leave it collect on its slot until
//! the tick ends; its velocity follows the ticker's (the pushes of later
//! mobs) until then.
//!
//! A mob whose step the kernel refused (a chunk it cannot read) keeps the
//! state it had when the tick began; so does one whose move out of the
//! section its owner does not carry out. Each slot keeps that state
//! (`Slot::before`) until the tick's end decides.

use super::ai::think::{self, Moves, SectionAi};
use super::ai::turn::Outside;
use super::ai::Effect as AiEffect;
use super::combat::{self, Event, Rules, SoundRef};
use super::kinds::Registry;
use super::living::body as living_body;
use super::living::f;
use super::living::mob::{self as living_mob, Type};
use super::model::{
    Control, Eye, FloatControl, Hop, HopOutcome, Impulse, MotionSet, NativeMob, Slot as EquipSlot,
};
use super::publish::Physical;
use super::random::LegacyRandom;
use super::section::{MobSection, Slot};
use super::sensing::{Kind as RefKind, Ref};
use super::term::Value;
use super::vitals::{self, Moved, Sky};
use crate::physics::fluid;
use crate::physics::mob::{self as kernel, Attributes, CubeJump, Ticked, Ticker, Travel};
use crate::physics::player::pose::Dimensions;
use crate::physics::player::World;
use crate::physics::Aabb;

/// What a mob's tick sends beyond its own events: farmland it landed on
/// and turtle eggs it cracked, for its owner to apply.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// `{:trample, cell}`.
    Trample([i32; 3]),
    /// `{:crack_egg, cell, state}`.
    CrackEgg([i32; 3], u16),
    /// What its AI made (`mobs::ai::Effect`) that leaves it.
    Ai(AiEffect),
    /// An effect already in its owner's terms (the dragon's
    /// `DragonEffect::value`).
    Raw(Value),
}

/// How a family's mobs move and push (`Valimc.AI.Kind.motion/0`) and the
/// motion hooks its family gives; every default is a family without them.
pub trait MotionHooks: Sync {
    /// `step_gap`, `fixed`, `pushable`, `pushes`, `fluid_pushed`, `travel`,
    /// `emits`, `lava_walker` of the type.
    fn kind(&self, _ty: Type) -> Kind {
        Kind::default()
    }
    /// `climbs?/1`: a wall climber's climbing, None for the others.
    fn climbs(&self, _mob: &NativeMob) -> Option<bool> {
        None
    }
    /// `jump/1`: a cube's own jumps.
    fn cube(&self, _mob: &NativeMob) -> Option<CubeJump> {
        None
    }
    /// `falls?/0`: false for a family that never takes fall damage from
    /// its landing (a bat's).
    fn falls(&self, _ty: Type) -> bool {
        true
    }
}

/// A type's movement kind (`MobMotion`'s `@default_kind` merged with the
/// family's `motion/0`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Kind {
    pub step_gap: Option<f32>,
    pub fixed: bool,
    pub pushable: bool,
    pub pushes: bool,
    pub fluid_pushed: bool,
    pub travel: Travel,
    pub emits: bool,
    pub lava_walker: bool,
}

impl Default for Kind {
    fn default() -> Kind {
        Kind {
            step_gap: None,
            fixed: false,
            pushable: true,
            pushes: true,
            fluid_pushed: true,
            travel: Travel::Ground,
            emits: true,
            lava_walker: false,
        }
    }
}

/// Every type with the default motion.
pub struct NoMotionHooks;

impl MotionHooks for NoMotionHooks {}

/// What a dragon's turn reads beyond its level and the section's mobs
/// (`RegionData.dragon_world/2`): the fight's alive crystals (None without
/// a fight) and whether it was won before (no fight counts as won), the
/// group's end crystals, the mobs it may touch outside its section as they
/// were when the tick began, and the uuid a breath started this tick takes.
#[derive(Clone, Debug, PartialEq)]
pub struct DragonWorld {
    pub crystals: Option<i64>,
    pub previous_kill: bool,
    pub crystal_bodies: Vec<super::boss::dragon::Crystal>,
    pub others: Vec<super::boss::dragon::MobTarget>,
    pub flame_uuid: [u8; 16],
}

impl Default for DragonWorld {
    fn default() -> DragonWorld {
        DragonWorld {
            crystals: None,
            previous_kill: true,
            crystal_bodies: Vec::new(),
            others: Vec::new(),
            flame_uuid: [0; 16],
        }
    }
}

/// `Arena.height/4`: a column's `MOTION_BLOCKING_NO_LEAVES` height (above
/// its highest such block), the bottom where it has none or is unreadable.
pub fn arena_height(level: &super::level::Level, x: i64, z: i64) -> i64 {
    /// `Heightmap.Types.MOTION_BLOCKING_NO_LEAVES`'s bit.
    const NO_LEAVES: u8 = 1 << 5;
    let (x, z) = (x as i32, z as i32);
    (level.min_y..=level.max_y)
        .rev()
        .find(|&y| {
            level.block([x, y, z]).is_some_and(|s| {
                level
                    .states
                    .heightmaps
                    .get(s as usize)
                    .copied()
                    .unwrap_or(0)
                    & NO_LEAVES
                    != 0
            })
        })
        .map_or(level.min_y as i64, |top| top as i64 + 1)
}

/// Whether a mob is the ender dragon, whose actor takes its whole turn.
pub fn dragon(mob: &NativeMob) -> bool {
    mob.body.entity_type == super::boss::dragon::DRAGON
}

/// What a turn reads: the rules, the motion hooks, the physics world of the
/// ticker, the players that push, the sky (light, rain, the sun and the
/// level random) and the game rules it applies.
pub struct TurnWorld<'a, 'w> {
    pub rules: &'a Rules<'a>,
    pub motion: &'a dyn MotionHooks,
    /// The native families.
    pub kinds: &'a Registry,
    pub world: &'a World<'w>,
    pub players: &'a [([f64; 3], Aabb)],
    pub mob_griefing: bool,
    /// The travel attributes of types whose mobs have no attribute
    /// overrides, as `MobTicks` shares them per type.
    pub travel: std::cell::RefCell<std::collections::HashMap<u16, Attributes>>,
    /// A dragon's arena, where the section holds one (else none's).
    pub dragon: Option<&'a DragonWorld>,
}

/// A slot's travel attributes (`Slot::travel`): its type, the attribute
/// overrides they were computed from (shared, so a change to the mob's
/// copies them and the two are no longer the same term) and the result.
pub type TravelCache = (u16, super::model::Attributes, Attributes);

impl TurnWorld<'_, '_> {
    /// `travel_attributes/3`, shared by the type's mobs without overrides.
    pub fn travel(&self, ty: Type, mob: &NativeMob) -> Attributes {
        if !mob.body.mob.attributes.0.is_empty() {
            return travel_attributes(self.rules, ty, mob);
        }
        *self
            .travel
            .borrow_mut()
            .entry(ty.id)
            .or_insert_with(|| travel_attributes(self.rules, ty, mob))
    }

    /// `travel/2` for a mob whose slot keeps `cache` (VMC-081j): the
    /// attributes depend on its type and overrides alone, so while those
    /// are the very term `cache` holds they are not computed again.
    pub fn travel_cached(
        &self,
        ty: Type,
        mob: &NativeMob,
        cache: &mut Option<TravelCache>,
    ) -> Attributes {
        let overrides = &mob.body.mob.attributes;
        if overrides.0.is_empty() {
            return self.travel(ty, mob);
        }
        if let Some((id, held, attributes)) = cache {
            if *id == ty.id && held.same(overrides) {
                return *attributes;
            }
        }
        let attributes = travel_attributes(self.rules, ty, mob);
        *cache = Some((ty.id, overrides.clone(), attributes));
        attributes
    }
}

/// What a turn leaves: the mob's events and the effects leaving it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Turned {
    pub events: Vec<Event>,
    pub effects: Vec<Effect>,
}

/// The kernel's motion hooks of the native families (`mobs::kinds`).
pub struct Families<'a> {
    pub kinds: &'a Registry,
    pub facts: &'a super::facts::MobFacts,
}

impl<'a> Families<'a> {
    fn kind_of(&self, name: &str) -> Option<&'a dyn super::kinds::Kind> {
        self.kinds.kind(self.facts.entities.id(name)?)
    }
}

impl MotionHooks for Families<'_> {
    fn kind(&self, ty: Type) -> Kind {
        let Some(kind) = self.kinds.kind(ty.id) else {
            return Kind::default();
        };
        let m = kind.kernel_motion();
        Kind {
            step_gap: m.step_gap.map(|g| g as f32),
            fixed: m.fixed,
            pushable: m.pushable,
            pushes: m.pushes,
            fluid_pushed: m.fluid_pushed,
            travel: travel_of(super::model::Travel {
                kind: m.travel.0,
                sink: m.travel.1,
            }),
            emits: !matches!(m.emission, crate::mobs::kinds::Emission::None),
            lava_walker: m.lava_walker,
        }
    }

    fn climbs(&self, mob: &NativeMob) -> Option<bool> {
        self.kind_of(&mob.body.entity_type)?.climbs(&mob.body)
    }

    fn cube(&self, mob: &NativeMob) -> Option<CubeJump> {
        let kind = self.kind_of(&mob.body.entity_type)?;
        kind.jump(&mob.body).map(|(bonus, lava)| CubeJump {
            bonus: bonus as f32,
            lava: lava.map(|l| l as f32),
        })
    }

    fn falls(&self, ty: Type) -> bool {
        self.kinds.kind(ty.id).is_none_or(|k| k.falls())
    }
}

/// An AI effect that is the mob's event (`MobTicks.split/1`): its sounds,
/// entity events and swings.
fn ai_event(e: AiEffect) -> Result<Event, AiEffect> {
    use super::term::NIL;
    Ok(match e {
        AiEffect::Sound {
            id,
            source,
            volume,
            pitch,
            seed,
        } => Event::Other(Value::Tuple(vec![
            Value::atom("sound"),
            Value::Int(id as i64),
            Value::Int(source as i64),
            Value::Float(volume),
            Value::Float(pitch),
            Value::Int(seed),
        ])),
        AiEffect::SoundAt {
            id,
            source,
            at,
            volume,
            pitch,
        } => Event::Other(Value::Tuple(vec![
            Value::atom("sound_at"),
            Value::Int(id as i64),
            Value::Binary(source.as_bytes().to_vec()),
            Value::vec3(at),
            Value::Float(volume),
            Value::Float(pitch),
        ])),
        AiEffect::SoundBlock(v) => Event::Other(tagged("sound_block", v)),
        AiEffect::Event(n) => Event::Entity(n),
        AiEffect::Swing(hand) => Event::Other(Value::tuple([
            Value::atom("swing"),
            Value::atom(hand.name()),
        ])),
        AiEffect::Living(e) => e,
        other => {
            let _ = NIL;
            return Err(other);
        }
    })
}

/// `{tag, ...}`: a tuple payload's items after `tag`, else `{tag, payload}`.
pub fn tagged(tag: &'static str, v: Value) -> Value {
    match v {
        Value::Tuple(mut items) => {
            items.insert(0, Value::atom(tag));
            Value::Tuple(items)
        }
        v => Value::tuple([Value::atom(tag), v]),
    }
}

/// `MobTicks.extras/2` merged into a melee hit: what its family adds to a
/// hit on `target` (the first `{:attack_extra, target, extras}` it made: an
/// iron golem's amount and throw, a mob's extra knockback).
pub fn with_extras(mut hit: combat::Hit, made: &[AiEffect], target: &Ref) -> combat::Hit {
    let extras = made.iter().find_map(|e| match e {
        AiEffect::AttackExtra(r, Value::Map(m)) if r == target => Some(m),
        _ => None,
    });
    let Some(m) = extras else {
        return hit;
    };
    let number = |key: &str| m.get_atom(key).and_then(Value::as_number);
    if let Some(amount) = number("amount") {
        hit.amount = amount;
    }
    if let Some(v) = m.get_atom("lift") {
        hit.lift = v.as_number();
    }
    if let Some(effect) = m.get_atom("effect").and_then(combat::Hit::effect_of) {
        hit.effects.push(effect);
    }
    if let Some(v) = m.get_atom("extra_knockback") {
        hit.extra_knockback = v.as_tuple_n::<2>().and_then(|[power, direction]| {
            let [x, z] = direction.as_tuple_n::<2>()?;
            Some((power.as_number()?, [x.as_number()?, z.as_number()?]))
        });
    }
    hit
}

/// Splits AI effects into the mob's events and the effects leaving it.
fn split(made: Vec<AiEffect>, out: &mut Turned) -> Vec<Event> {
    let mut events = Vec::new();
    for e in made {
        match ai_event(e) {
            Ok(event) => events.push(event),
            Err(effect) => out.effects.push(Effect::Ai(effect)),
        }
    }
    events
}

/// `MobMotion.travel/2`: the travel attributes from the type's bases and
/// the overrides' modifiers (not the equipment's).
pub fn travel_attributes(rules: &Rules, ty: Type, mob: &NativeMob) -> Attributes {
    let value = |name: &str| -> f64 {
        let Some(id) = rules.facts.attributes.id(name) else {
            return 0.0;
        };
        let fact = &rules.facts.attributes.attributes[id as usize];
        let base = living_mob::base(rules.living, rules.facts, ty, &mob.body.mob.attributes, id);
        let modifiers: Vec<(f64, u8)> = mob
            .body
            .mob
            .attributes
            .get(&fact.name)
            .map(|o| {
                o.modifiers
                    .iter()
                    .map(|m| (m.amount.as_f64(), m.operation as u8))
                    .collect()
            })
            .unwrap_or_default();
        super::living::attributes::value(fact, base, &modifiers)
    };
    Attributes {
        movement_speed: value("minecraft:movement_speed"),
        jump_strength: value("minecraft:jump_strength"),
        gravity: value("minecraft:gravity"),
        step_height: value("minecraft:step_height"),
        water_efficiency: value("minecraft:water_movement_efficiency"),
        friction_modifier: value("minecraft:friction_modifier"),
        air_drag_modifier: value("minecraft:air_drag_modifier"),
    }
}

/// What the ticker reads of a mob before its own step (VMC-081j): its
/// place, motion and size, and whether it is alive and is pushed (the
/// grid, the pushes of the mobs before it, the players' pushes at the end).
/// Its other inputs are read only at its step, which takes its whole
/// `kernel_input` then; they stay at their defaults here, so a turn builds
/// one kernel input, not two.
pub fn kernel_body(
    rules: &Rules,
    hooks: &dyn MotionHooks,
    ty: Type,
    mob: &NativeMob,
) -> kernel::Mob {
    let body = &mob.body;
    let [width, height, eye] = living_body::dimensions(rules, ty, body);
    let kind = hooks.kind(ty);
    kernel::Mob {
        position: mob.position,
        velocity: body.velocity,
        size: Dimensions { width, height, eye },
        alive: living_mob::alive(&body.mob),
        fixed: kind.fixed || body.mob.no_ai,
        pushable: kind.pushable,
        pushes: kind.pushes,
        ..kernel::Mob::default()
    }
}

/// `MobMotion.kernel/4`: the kernel's input of a mob at its position.
pub fn kernel_input(
    rules: &Rules,
    hooks: &dyn MotionHooks,
    ty: Type,
    mob: &NativeMob,
    attributes: Attributes,
) -> kernel::Mob {
    let body = &mob.body;
    let m = &body.mob;
    let motion = &m.motion;
    let effects = &m.living.effects;
    let e = &rules.living.effects;
    let alive = living_mob::alive(m);
    let control = if !alive {
        kernel::Control::Wait
    } else {
        match (&motion.set, &motion.control) {
            (Some(MotionSet::Hold), _) => kernel::Control::Hold,
            (Some(MotionSet::Speed { speed, lift }), _)
            | (Some(MotionSet::Inputs { speed, lift, .. }), _) => kernel::Control::Set {
                speed: *speed,
                lift: *lift,
            },
            (None, Control::Wait) => kernel::Control::Wait,
            (None, Control::MoveTo { target, speed }) => kernel::Control::MoveTo {
                target: *target,
                speed: *speed,
            },
            (None, Control::Jumping { speed }) => kernel::Control::Jumping { speed: *speed },
            (
                None,
                Control::Strafe {
                    forward,
                    right,
                    speed,
                },
            ) => kernel::Control::Strafe {
                forward: *forward as f32,
                right: *right as f32,
                speed: *speed,
            },
        }
    };
    let set_inputs = match (&motion.set, alive) {
        (Some(MotionSet::Inputs { inputs, .. }), true) => inputs.map(|i| i.map(|v| v as f32)),
        _ => [None; 3],
    };
    let [width, height, eye] = living_body::dimensions(rules, ty, body);
    let walkable = rules
        .facts
        .entity_tag(ty.id, "minecraft:powder_snow_walkable_mobs")
        || m.equipment
            .get(EquipSlot::Feet)
            .and_then(super::living::items::item_id)
            .is_some_and(|id| Some(id) == rules.facts.items.id("minecraft:leather_boots"));
    let hop = motion.hop.as_ref().map(|h| kernel::Hop {
        jumping: h.jumping,
        wanted: h.wanted.unwrap_or(mob.position),
        speed: h.speed,
        next_speed: h.next_speed,
        path_up: h.path_up.unwrap_or(false),
        baby: body.data.age().is_some_and(|age| age < 0),
        started: false,
        jumped: false,
        nav_speed: None,
    });
    let float = motion.float.as_ref().map(|fl| {
        let speed = rules
            .facts
            .attributes
            .id("minecraft:flying_speed")
            .map_or(0.0, |id| {
                living_mob::value(rules.living, rules.facts, ty, m, id)
            });
        kernel::Float {
            wanted: fl.wanted,
            duration: fl.duration,
            random: m.ai.as_ref().map_or(0, |mind| mind.random.seed),
            speed: speed * 5.0 / 3.0,
        }
    });
    let kind = hooks.kind(ty);
    let travel = match motion.travel {
        Some(t) => travel_of(t),
        None => kind.travel,
    };
    let swimming = body
        .data
        .get("swimming")
        .is_some_and(|v| v.as_bool() == Some(true));
    kernel::Mob {
        position: mob.position,
        yaw: body.yaw as f32,
        head_yaw: body.head_yaw as f32,
        velocity: body.velocity,
        on_ground: body.on_ground,
        horizontal_collision: motion.horizontal_collision,
        fall_distance: motion.fall_distance,
        no_jump_delay: motion.no_jump_delay,
        stuck_multiplier: motion.stuck_multiplier,
        strafe: if alive { motion.strafe as f32 } else { 0.0 },
        up: if alive { motion.up as f32 } else { 0.0 },
        forward: if alive { motion.forward as f32 } else { 0.0 },
        speed: motion.speed as f32,
        set_inputs,
        pre_move: if alive {
            motion.pre_move.map(|y| y as f32)
        } else {
            None
        },
        step_gap: kind.step_gap,
        stepped: false,
        control,
        size: Dimensions { width, height, eye },
        attributes,
        no_gravity: body.no_gravity,
        weaving: effects.get(e.weaving).is_some(),
        slow_falling: effects.amplifier(e.slow_falling).is_some(),
        levitation: effects.amplifier(e.levitation).map(|a| a as i32),
        jump_boost: effects.amplifier(e.jump_boost).map_or(-1, |a| a as i32),
        alive,
        jump: alive && motion.jump,
        fall_scale: if body.entity_type == "minecraft:blaze" {
            0.6
        } else {
            1.0
        },
        rise: alive && motion.rise,
        powder_snow_walkable: walkable,
        was_powder_snow: motion.powder_snow,
        fixed: kind.fixed || m.no_ai,
        pushable: kind.pushable,
        pushes: kind.pushes,
        wall_climb: hooks.climbs(mob),
        hop,
        travel,
        fluid_pushed: kind.fluid_pushed && !swimming,
        impulse: if alive {
            match &motion.impulse {
                Impulse::One(v) => vec![*v],
                Impulse::List(vs) => vs.clone(),
            }
        } else {
            Vec::new()
        },
        vertical_collision: motion.vertical_collision,
        emits: kind.emits,
        lava_walker: kind.lava_walker,
        move_dist: motion.move_dist as f32,
        next_step: motion.next_step as f32,
        float,
        cube: hooks.cube(mob),
    }
}

fn travel_of(t: super::model::Travel) -> Travel {
    use super::model::TravelKind as K;
    match t.kind {
        K::Ground => Travel::Ground,
        K::Flying => Travel::Flying,
        K::Fish => Travel::Fish { sink: t.sink },
        K::Guardian => Travel::Guardian { sink: t.sink },
        K::Squid => Travel::Squid,
        K::Dolphin => Travel::Dolphin { sink: t.sink },
    }
}

/// `MobMotion.apply/6` and the eye flag after it: the body and position
/// after the kernel's tick.
pub fn apply_ticked(mob: &mut NativeMob, t: &Ticked) {
    let m = &t.mob;
    let body = &mut mob.body;
    let previous = std::mem::take(&mut body.mob.motion);
    let control = match m.control {
        kernel::Control::Wait => Control::Wait,
        kernel::Control::MoveTo { target, speed } => Control::MoveTo { target, speed },
        kernel::Control::Jumping { speed } => Control::Jumping { speed },
        kernel::Control::Set { .. } | kernel::Control::Hold => previous.control,
        kernel::Control::Strafe {
            forward,
            right,
            speed,
        } => Control::Strafe {
            forward: forward as f64,
            right: right as f64,
            speed,
        },
    };
    body.mob.motion = super::model::MobMotion {
        fall_distance: m.fall_distance,
        no_jump_delay: m.no_jump_delay,
        stuck_multiplier: m.stuck_multiplier,
        strafe: m.strafe as f64,
        up: m.up as f64,
        forward: m.forward as f64,
        speed: m.speed as f64,
        control,
        horizontal_collision: m.horizontal_collision,
        water: t.depths.water,
        lava: t.depths.lava,
        powder_snow: t.powder_snow,
        eye: Eye {
            water: t.eye_after.0,
            state: t.eye_after.1 as i32,
        },
        hop: m.hop.as_ref().map(|h| Hop {
            jumping: h.jumping,
            wanted: Some(h.wanted),
            speed: h.speed,
            next_speed: h.next_speed,
            path_up: None,
            outcome: Some(HopOutcome {
                started: h.started,
                jumped: h.jumped,
                nav_speed: h.nav_speed,
            }),
        }),
        vertical_collision: m.vertical_collision,
        move_dist: m.move_dist as f64,
        next_step: m.next_step as f64,
        float: m.float.as_ref().map(|fl| FloatControl {
            wanted: fl.wanted,
            duration: fl.duration,
        }),
        support: Some(t.support as i32),
        eye_water: t.eye_water,
        ..Default::default()
    };
    // The float control drew on the mind's random.
    if let (Some(fl), Some(mind)) = (&m.float, body.mob.ai.as_mut()) {
        if let Some(random) = LegacyRandom::from_state(fl.random) {
            mind.random = random;
        }
    }
    body.yaw = m.yaw as f64;
    body.head_yaw = m.head_yaw as f64;
    body.velocity = m.velocity;
    body.on_ground = m.on_ground;
    mob.position = m.position;
}

/// `MobTicks.sense_fluids/2`: the fluid depths and eye state `baseTick`
/// refreshes before the AI, over the ticker's view; unchanged where the
/// view cannot read them.
pub fn sense(rules: &Rules, ty: Type, world: &World, mob: &mut NativeMob) {
    let [width, height, eye] = living_body::dimensions(rules, ty, &mob.body);
    let [x, y, z] = mob.position;
    let half = width / 2.0;
    let body = Aabb::new([x - half, y, z - half], [x + half, y + height, z + half]);
    let found = match fluid::contacts(world.source, world.facts, &body) {
        Ok(Some(found)) => found,
        _ => return,
    };
    let depths = fluid::depths(&found);
    let eye_at = [x, y + eye, z];
    let Ok((water, _)) = fluid::eyes_in(world.source, world.facts, &found, eye_at) else {
        return;
    };
    let p = eye_at.map(|v| v.floor() as i32);
    let Some(state) = world.source.state(p[0], p[1], p[2]) else {
        return;
    };
    let motion = &mut mob.body.mob.motion;
    motion.water = depths.water;
    motion.lava = depths.lava;
    motion.eye = Eye {
        water,
        state: state as i32,
    };
}

/// `AI.move_sounds/2`: the splash of a mob that fell into water during its
/// move (`doWaterSplashEffect`), pitched from its own random, with the
/// particles' draws.
pub fn splash(rules: &Rules, ty: Type, mob: &mut NativeMob, velocity: [f64; 3]) -> Event {
    let [width, _, _] = living_body::dimensions(rules, ty, &mob.body);
    let [vx, vy, vz] = velocity;
    let speed = (vx * vx * f(0.2) + vy * vy + vz * vz * f(0.2)).sqrt();
    let volume = 1.0f64.min(f(f(speed) * f(0.2)));
    let uuid = mob.uuid;
    let random = combat::random(&mut mob.body.mob, &uuid);
    let a = random.float() as f64;
    let b = random.float() as f64;
    let pitch = f(1.0 + f(f(a - b) * f(0.4)));
    let bound = f(1.0 + f(width * 20.0));
    let count = if bound == bound.trunc() {
        bound as i64
    } else {
        bound as i64 + 1
    };
    for _ in 0..count.max(0) {
        for _ in 0..3 {
            random.double();
        }
    }
    for _ in 0..count.max(0) {
        for _ in 0..2 {
            random.double();
        }
    }
    let name = if ty.facts.category == "monster" {
        "minecraft:entity.hostile.splash"
    } else {
        "minecraft:entity.generic.splash"
    };
    Event::Sound {
        sound: SoundRef::Id(rules.facts.sounds.id(name).unwrap_or(-1)),
        source: rules.facts.combat.mob_sounds(ty.id).source,
        volume,
        pitch,
    }
}

/// `Zombie.class` and its kinds never crack eggs falling (`fallOn`).
const ZOMBIES: [&str; 5] = [
    "minecraft:zombie",
    "minecraft:husk",
    "minecraft:drowned",
    "minecraft:zombie_villager",
    "minecraft:zombified_piglin",
];

/// `TurtleEggBlock.fallOn` (one in three, not a zombie) and `stepOn` (one
/// in a hundred on the ground) for a mob that may break eggs (not a turtle
/// or bat, while mobs may grief), from the level's random.
fn eggs(
    rules: &Rules,
    mob: &NativeMob,
    t: &Ticked,
    griefing: bool,
    sky: &mut dyn Sky,
    out: &mut Turned,
) {
    let ty = mob.body.entity_type.as_str();
    if ty == "minecraft:turtle" || ty == "minecraft:bat" || !griefing {
        return;
    }
    if let (Some((state, _)), Some(cell)) = (t.landing, t.landing_pos) {
        if !ZOMBIES.contains(&ty) {
            crack(rules, cell, state, 3, sky, out);
        }
    }
    if let Some((cell, state)) = t.on_block {
        crack(rules, cell, state, 100, sky, out);
    }
}

fn crack(
    rules: &Rules,
    cell: [i32; 3],
    state: u16,
    chance: i32,
    sky: &mut dyn Sky,
    out: &mut Turned,
) {
    if !rules.facts.blocks.is(state, "turtle_egg") {
        return;
    }
    let random = sky.random();
    if random.int(chance) != 0 {
        return;
    }
    let roll = random.float() as f64;
    let pitch = f(f(0.9) + f(roll * f(0.2)));
    let id = rules
        .facts
        .sounds
        .id("minecraft:entity.turtle.egg_break")
        .unwrap_or(-1);
    let at = [
        cell[0] as f64 + 0.5,
        cell[1] as f64 + 0.5,
        cell[2] as f64 + 0.5,
    ];
    out.events.push(Event::Other(Value::Tuple(vec![
        Value::atom("sound_at"),
        Value::Int(id as i64),
        Value::Binary(b"block".to_vec()),
        Value::vec3(at),
        Value::Float(f(0.7)),
        Value::Float(pitch),
    ])));
    out.effects.push(Effect::CrackEgg(cell, state));
}

/// `FarmlandBlock.fallOn`: farmland a living body lands on turns to dirt
/// when a level float falls below the distance less half a block and it is
/// big enough; the owner applies it while mobs may grief.
fn trample(
    rules: &Rules,
    ty: Type,
    mob: &NativeMob,
    t: &Ticked,
    sky: &mut dyn Sky,
    out: &mut Turned,
) {
    let (Some((state, distance)), Some(cell)) = (t.landing, t.landing_pos) else {
        return;
    };
    if !rules.facts.blocks.is(state, "farmland") {
        return;
    }
    let roll = sky.random().float() as f64;
    let [w, h, _] = living_body::dimensions(rules, ty, &mob.body);
    if roll < distance - 0.5 && f(f(w * w) * h) > f(0.512) {
        out.effects.push(Effect::Trample(cell));
    }
}

/// Who takes each ticker index's turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Entrant {
    /// A mob of the section, by network id.
    Native(i32),
    /// Another section's solid mob, a fixed collider that takes no turn.
    Fixed,
}

/// A section's tick in progress: who takes each turn and the next one.
#[derive(Debug, Default)]
pub struct Tick {
    pub order: Vec<Entrant>,
    pub next: usize,
    /// Per native mob in the tick: its events and effects so far, and
    /// whether its step went through.
    pub turns: std::collections::BTreeMap<i32, TurnState>,
    /// Where each native mob's tick began.
    pub starts: std::collections::HashMap<i32, [f64; 3]>,
}

/// A native mob's part of the tick.
#[derive(Clone, Debug)]
pub struct TurnState {
    pub index: usize,
    pub stepped: bool,
    pub refused: bool,
    pub out: Turned,
    /// Its physical state when the tick began (what its owner holds).
    pub start: Physical,
}

impl Tick {
    /// The tick of `order` (one entry per ticker index) at game tick
    /// `tick`. A native mob whose turn may leave the section or meet a
    /// chunk it cannot read (`keep`) keeps its state from now as its
    /// fallback; the others keep only where they began.
    pub fn begin(
        section: &mut MobSection,
        order: Vec<Entrant>,
        tick: Option<i64>,
        keep: impl Fn(i32) -> bool,
    ) -> Tick {
        let mut turns = std::collections::BTreeMap::new();
        let mut starts = std::collections::HashMap::new();
        for (index, e) in order.iter().enumerate() {
            if let Entrant::Native(id) = *e {
                if let Some(slot) = section.peek_kept(id) {
                    slot.stepped = false;
                    // The mob alone: its family data, equipment and
                    // attribute overrides are shared, not copied, and what
                    // observers were shown, which no turn changes, is kept
                    // only for a move out that waits (`finish`).
                    slot.before = keep(id).then(|| Box::new((slot.mob.clone(), None)));
                    slot.ticked = tick;
                    starts.insert(id, slot.mob.position);
                    turns.insert(
                        id,
                        TurnState {
                            index,
                            stepped: false,
                            refused: false,
                            out: Turned::default(),
                            start: Physical::of(&slot.mob),
                        },
                    );
                }
            }
        }
        Tick {
            order,
            next: 0,
            turns,
            starts,
        }
    }

    /// Runs every turn, the section's AI (`ai`, its level random the
    /// sky's) thinking for its mobs.
    pub fn run(
        &mut self,
        section: &mut MobSection,
        tw: &TurnWorld,
        ai: &mut SectionAi,
        ticker: &mut Ticker,
    ) {
        self.next = 0;
        while self.next < self.order.len() {
            let i = self.next;
            match self.order[i] {
                Entrant::Fixed => {}
                Entrant::Native(id) => {
                    if self.turns.contains_key(&id) {
                        if let Some(mut slot) = section.take(id) {
                            let ok = if dragon(&slot.mob) {
                                self.dragon_turn(tw, ai, section, ticker, i, id, &mut slot.mob)
                            } else {
                                self.turn(
                                    tw,
                                    ai,
                                    section,
                                    ticker,
                                    i,
                                    id,
                                    &mut slot.mob,
                                    &mut slot.travel,
                                )
                            };
                            slot.stepped = ok;
                            section.put(id, slot);
                            let state = self.turns.get_mut(&id).expect("turn");
                            state.stepped = ok;
                            state.refused = !ok;
                            section.relocate(id);
                        }
                    }
                }
            }
            self.next += 1;
        }
    }

    /// One native mob's turn at ticker index `i` (`MobTicks.ordered_step/6`),
    /// the mob out of its section meanwhile; false when the kernel refused
    /// its step (it keeps its state from before the tick).
    #[allow(clippy::too_many_arguments)]
    fn turn(
        &mut self,
        tw: &TurnWorld,
        ai: &mut SectionAi,
        section: &mut MobSection,
        ticker: &mut Ticker,
        i: usize,
        id: i32,
        mob: &mut NativeMob,
        travel: &mut Option<TravelCache>,
    ) -> bool {
        let rules = tw.rules;
        let Some(ty) = rules.of(&mob.body.entity_type) else {
            return false;
        };
        let mut out = std::mem::take(&mut self.turns.get_mut(&id).expect("turn").out);
        // The pushes of the mobs before it, and hits, are in the ticker.
        mob.body.velocity = ticker.current[i].velocity;
        // Where its tick began (`old[id]`): its body turns from there.
        let from = self.starts.get(&id).copied().unwrap_or(mob.position);
        sense(rules, ty, tw.world, mob);
        // `baseTick`'s burning comes first (VMC-043b).
        out.events.extend(vitals::base_tick(rules, mob));
        let made = {
            let mut outside = SectionOutside {
                tw,
                ticker: &*ticker,
                section: &*section,
                i,
            };
            ai.think(mob, id, Some(&mut outside))
        };
        // Others it changed now (an alert, a partner bred): those of the
        // section's native mobs.
        for e in &made {
            if let Some(uuid) = think::other(e) {
                if uuid == mob.uuid {
                    ai.change_other(e, mob, id);
                } else if let Some(tid) = section.id_of(&uuid) {
                    if let Some(target) = section.get_mut(tid) {
                        ai.change_other(e, &mut target.mob, tid);
                    }
                }
            }
        }
        let made = self.melee(tw, ai, section, ticker, id, mob, made);
        let made_events = split(made, &mut out);
        let attributes = tw.travel_cached(ty, mob, travel);
        let input = kernel_input(rules, tw.motion, ty, mob, attributes);
        let (result, _) = ticker.step(tw.world, i, input, tw.players);
        let Ok(mut t) = result else {
            self.turns.get_mut(&id).expect("turn").out = out;
            return false;
        };
        // A family that never falls (a bat's `checkFallDamage`) lands softly.
        if !tw.motion.falls(ty) {
            t.landing = None;
        }
        apply_ticked(mob, &t);
        // The move's splash into water comes before the rest of its tick.
        let splashed: Vec<Event> = if tw.kinds.kind(ty.id).is_some() {
            let mut sink = Turned::default();
            split(ai.move_sounds(mob, t.splash), &mut sink)
        } else {
            t.splash
                .map(|v| splash(rules, ty, mob, v))
                .into_iter()
                .collect()
        };
        // What it landed and stepped on (the level random): farmland, eggs.
        let mut ground = Turned::default();
        trample(rules, ty, mob, &t, ai.level, &mut ground);
        eggs(rules, mob, &t, tw.mob_griefing, ai.level, &mut ground);
        let moves = Moves {
            swims: [t.pre_swim.map(|v| v as f64), t.swim.map(|v| v as f64)],
            step: t.step,
        };
        let settled = {
            let mut outside = SectionOutside {
                tw,
                ticker: &*ticker,
                section: &*section,
                i,
            };
            ai.settle(mob, id, [from[0], from[2]], moves, Some(&mut outside))
        };
        // A family that set its motion after the move (a squid's stroke)
        // tells the ticker, so later pushes add to it.
        if mob.body.velocity != t.mob.velocity {
            ticker.current[i].velocity = mob.body.velocity;
        }
        let position = mob.position;
        let mut moved = Moved::from(&t);
        if !moved.water && vitals::water_sensitive(rules, ty) {
            let [_, height, _] = super::living::body::dimensions(rules, ty, &mob.body);
            moved.rain = ai.level.rain(position, position[1] + height);
        }
        let vital = vitals::apply(rules, mob, &moved);
        // The sun on undead mobs and rain on burning ones (VMC-043b).
        let sunned = vitals::daylight(rules, mob, position, ai.level);
        // A family's own tick after the move (a zombie drowning).
        let own = match tw.kinds.kind(ty.id) {
            Some(kind) => kind.after_move(mob, &t),
            None => Vec::new(),
        };
        let mut later = Turned::default();
        let later_events = split(settled.into_iter().chain(own).collect(), &mut later);
        // An opening lid moves the section's mobs it meets before the next
        // turn (`MobTicks.lid_pushes/3`); its owner moves the rest.
        let later_effects = std::mem::take(&mut later.effects);
        for e in later_effects {
            later.effects.push(match e {
                Effect::Ai(AiEffect::ShulkerPush(v)) => {
                    Effect::Ai(AiEffect::ShulkerPush(self.lid_push(tw, section, ticker, v)))
                }
                other => other,
            });
        }
        out.events.extend(made_events);
        out.events.extend(splashed);
        out.events.extend(vital);
        out.events.extend(sunned);
        out.events.extend(later_events);
        out.events.extend(ground.events);
        out.effects.extend(later.effects);
        out.effects.extend(ground.effects);
        ai.moved(mob);
        self.turns.get_mut(&id).expect("turn").out = out;
        true
    }

    /// The dragon's turn (`MobTicks.dragon_step/4`): none of an ordinary
    /// mob's, only its actor's tick over its arena (`Actor.environment/3`),
    /// or its mind made again where a handoff brought it here within the
    /// tick it already took. Its wings and head land at once on the
    /// section's mobs of this tick; on players and other mobs they go to its
    /// owner, with the rest of its effects and events as the Elixir actor's
    /// terms. The ticker takes its velocity; its kernel row is fixed.
    #[allow(clippy::too_many_arguments)]
    fn dragon_turn(
        &mut self,
        tw: &TurnWorld,
        ai: &mut SectionAi,
        section: &mut MobSection,
        ticker: &mut Ticker,
        i: usize,
        id: i32,
        mob: &mut NativeMob,
    ) -> bool {
        use super::boss::dragon::{self as dragon_mod, actor, Arena, DragonEffect, MobTarget};
        let rules = tw.rules;
        let Some(facts) = rules.facts.dragon.as_ref() else {
            return false;
        };
        let mut out = std::mem::take(&mut self.turns.get_mut(&id).expect("turn").out);
        // Hits before its turn are in the ticker.
        mob.body.velocity = ticker.current[i].velocity;
        if actor::ticked_at(&mob.body, ai.level.time) {
            actor::resume(mob);
            ticker.current[i].velocity = mob.body.velocity;
            self.turns.get_mut(&id).expect("turn").out = out;
            ai.moved(mob);
            return true;
        }
        let step = {
            let level: &super::level::Level = ai.level;
            let none = DragonWorld::default();
            let dw = tw.dragon.unwrap_or(&none);
            let height = |x: i64, z: i64| arena_height(level, x, z);
            // The mobs it may touch: the section's where they are now, the
            // others where they were.
            let mut mobs: Vec<MobTarget> = Vec::new();
            for (_, slot) in section.slots() {
                let m = &slot.mob;
                let Some(ty) = rules.of(&m.body.entity_type) else {
                    continue;
                };
                let [width, height, _] = living_body::dimensions(rules, ty, &m.body);
                mobs.push(MobTarget {
                    uuid: m.uuid,
                    position: m.position,
                    width,
                    height,
                    bbox: rules.family(ty).bounding_box(&m.body, m.position),
                    recent: dragon_mod::recent(&m.body.mob),
                });
            }
            mobs.extend(dw.others.iter().cloned());
            let arena = Arena {
                height: &height,
                podium: [0, height(0, 0), 0],
                crystals: dw.crystals,
                crystal_bodies: dw.crystal_bodies.clone(),
                mobs,
                previous_kill: dw.previous_kill,
                flame_uuid: dw.flame_uuid,
            };
            let players = &ai.sensing.players;
            let mut env = dragon_mod::environment(facts, rules.facts, level, mob, &arena, players);
            actor::tick(rules, mob, &mut env)
        };
        mob.position = step.position;
        ticker.current[i].velocity = mob.body.velocity;
        out.events
            .extend(step.events.iter().map(|e| Event::Other(e.value())));
        for effect in step.effects {
            if let DragonEffect::Contact {
                target,
                push,
                amount,
                wing,
            } = &effect
            {
                let tid = (target.kind == RefKind::Mob)
                    .then(|| section.id_of(&target.uuid))
                    .flatten()
                    .filter(|t| self.turns.contains_key(t));
                if let Some(slot) = tid.and_then(|t| section.get_mut(t)) {
                    let state = self.turns.get_mut(&tid.expect("target")).expect("turn");
                    slot.mob.body.velocity = ticker.current[state.index].velocity;
                    living_body::push(&mut slot.mob.body, *push);
                    let recent = *wing && dragon_mod::recent(&slot.mob.body.mob);
                    let source = rules.facts.damage_types.id("minecraft:mob_attack");
                    if let Some(source) = source.filter(|_| *amount > 0.0 && !recent) {
                        let me = combat::Attacker {
                            uuid: mob.uuid,
                            entity_id: id,
                            player: false,
                            entity_type: dragon_mod::DRAGON.to_owned(),
                            mainhand: None,
                            luck: 0.0,
                        };
                        let hit = combat::Hit {
                            attacker: Some(me.clone()),
                            direct: Some(me),
                            position: Some(mob.position),
                            ..combat::Hit::new(source, *amount)
                        };
                        let (events, hurt) = combat::hit_body(rules, &mut slot.mob, &hit);
                        if hurt && !state.stepped && !state.refused {
                            super::living::health::tick(&mut slot.mob.body.mob.living.health);
                        }
                        state.out.events.extend(events);
                    }
                    ticker.current[state.index].velocity = slot.mob.body.velocity;
                    ai.moved(&slot.mob);
                    continue;
                }
            }
            out.effects.push(Effect::Raw(effect.value()));
        }
        self.turns.get_mut(&id).expect("turn").out = out;
        ai.moved(mob);
        true
    }

    /// `MobTicks.lid_pushes/3` of a lid's push `{area, delta}`: each native
    /// mob of the tick it meets (not a shulker or the dragon) moves by
    /// `delta` over the ticker without its own turn, in id order. The push
    /// as its owner forwards it: `{area, delta, [ids moved here]}`.
    fn lid_push(
        &mut self,
        tw: &TurnWorld,
        section: &mut MobSection,
        ticker: &mut Ticker,
        v: Value,
    ) -> Value {
        let parse = || -> Option<([f64; 6], [f64; 3])> {
            let items = v.as_tuple()?;
            let area = items.first()?.as_tuple()?;
            let area: Vec<f64> = area.iter().map(Value::as_number).collect::<Option<_>>()?;
            let delta = items.get(1)?.as_tuple()?;
            let delta: Vec<f64> = delta.iter().map(Value::as_number).collect::<Option<_>>()?;
            Some((area.try_into().ok()?, delta.try_into().ok()?))
        };
        let Some((area, delta)) = parse() else {
            return v;
        };
        let rules = tw.rules;
        let area_box = Aabb::new([area[0], area[1], area[2]], [area[3], area[4], area[5]]);
        let mut moved = Vec::new();
        let ids: Vec<(i32, usize)> = self.turns.iter().map(|(&id, t)| (id, t.index)).collect();
        for (id, index) in ids {
            let Some(slot) = section.get(id) else {
                continue;
            };
            let ty_name = slot.mob.body.entity_type.as_str();
            if ty_name == "minecraft:shulker" || ty_name == "minecraft:ender_dragon" {
                continue;
            }
            let Some(ty) = rules.of(ty_name) else {
                continue;
            };
            let [w, h, _] = living_body::dimensions(rules, ty, &slot.mob.body);
            let [x, y, z] = slot.mob.position;
            let own = Aabb::new(
                [x - w / 2.0, y, z - w / 2.0],
                [x + w / 2.0, y + h, z + w / 2.0],
            );
            if !own.intersects(&area_box) {
                continue;
            }
            let attributes = tw.travel(ty, &slot.mob);
            let input = kernel_input(rules, tw.motion, ty, &slot.mob, attributes);
            let Ok(m) = ticker.displace(tw.world, index, input, delta) else {
                continue;
            };
            if let Some(slot) = section.get_mut(id) {
                slot.mob.position = m.position;
                slot.mob.body.velocity = m.velocity;
                slot.mob.body.on_ground = m.on_ground;
            }
            section.relocate(id);
            moved.push(Value::Int(id as i64));
        }
        Value::Tuple(vec![
            Value::Tuple(area.iter().map(|&a| Value::Float(a)).collect()),
            Value::vec3(delta),
            Value::List(moved),
        ])
    }

    /// `MobTicks.melee/5`: its melee hits on the section's native mobs land
    /// now, as `doHurtTarget` lands them mid-tick (the target's hurt timers
    /// run when it is still to tick; its knockback goes to the ticker); a
    /// hit on any other mob stays an effect for its owner.
    #[allow(clippy::too_many_arguments)]
    fn melee(
        &mut self,
        tw: &TurnWorld,
        ai: &mut SectionAi,
        section: &mut MobSection,
        ticker: &mut Ticker,
        id: i32,
        mob: &NativeMob,
        made: Vec<AiEffect>,
    ) -> Vec<AiEffect> {
        let rules = tw.rules;
        let all = made.clone();
        let mut kept = Vec::with_capacity(made.len());
        for e in made {
            let AiEffect::Attack(r) = &e else {
                kept.push(e);
                continue;
            };
            let target = (r.kind == RefKind::Mob)
                .then(|| section.id_of(&r.uuid))
                .flatten()
                .filter(|t| self.turns.contains_key(t));
            let Some(tid) = target else {
                kept.push(e);
                continue;
            };
            let Some(slot) = section.get_mut(tid) else {
                kept.push(e);
                continue;
            };
            let Some(tty) = rules.of(&slot.mob.body.entity_type) else {
                kept.push(e);
                continue;
            };
            let Some(hit) = combat::mob_hit(rules, mob, id, tty.id) else {
                kept.push(e);
                continue;
            };
            let hit = with_extras(hit, &all, r);
            let state = self.turns.get_mut(&tid).expect("turn");
            slot.mob.body.velocity = ticker.current[state.index].velocity;
            let (events, hurt) = combat::hit_body(rules, &mut slot.mob, &hit);
            // Its weapon's and the target's post-attack effects on the
            // target (VMC-037q); those on an attacking mob are not run.
            if hurt {
                combat::post_attack(rules, &mut slot.mob, &hit);
            }
            if hurt && !state.stepped && !state.refused {
                super::living::health::tick(&mut slot.mob.body.mob.living.health);
            }
            ticker.current[state.index].velocity = slot.mob.body.velocity;
            state.out.events.extend(events);
            ai.moved(&slot.mob);
        }
        kept
    }
}

/// What a native turn gives its AI beyond the level and sensing: the
/// kernel's probe of a goal's own move and whether a melee hit would kill
/// one of the section's mobs (`MobTicks.goal_position/5`, `kills?/5`).
struct SectionOutside<'s, 'a, 'w> {
    tw: &'s TurnWorld<'a, 'w>,
    ticker: &'s Ticker,
    section: &'s MobSection,
    i: usize,
}

impl Outside for SectionOutside<'_, '_, '_> {
    fn goal_position(&mut self, t: &super::ai::Turn) -> Option<[f64; 3]> {
        let rules = self.tw.rules;
        let ty = rules.of(&t.mob.body.entity_type)?;
        let attributes = self.tw.travel(ty, t.mob);
        let input = kernel_input(rules, self.tw.motion, ty, t.mob, attributes);
        self.ticker
            .goal_position(self.tw.world, self.i, &input)
            .ok()
    }

    fn melee(&mut self, t: &mut super::ai::Turn, target: &Ref) -> bool {
        let rules = self.tw.rules;
        let Some(slot) = self
            .section
            .id_of(&target.uuid)
            .and_then(|tid| self.section.get(tid))
        else {
            return false;
        };
        let Some(tty) = rules.of(&slot.mob.body.entity_type) else {
            return false;
        };
        let Some(hit) = combat::mob_hit(rules, t.mob, t.id, tty.id) else {
            return false;
        };
        let hit = with_extras(hit, &t.effects, target);
        let mut target = slot.mob.clone();
        let (_, hurt) = combat::hit_body(rules, &mut target, &hit);
        hurt && !living_mob::alive(&target.body.mob)
    }
}

/// A native mob's step at the tick's end: what its owner is told.
#[derive(Clone, Debug)]
pub struct Step {
    pub id: i32,
    pub events: Vec<Event>,
    pub effects: Vec<Effect>,
    /// Its physical state differs from where the tick began.
    pub moved: bool,
    /// It left the section: its owner moves it on, or keeps it where it was.
    pub outside: bool,
    /// Where it began (a portal's sweep starts there).
    pub from: [f64; 3],
}

/// The tick's end (`MobTicks.steps/5` after its turns): every mob's motion
/// with the pushes after its turn (`velocities`, by ticker index); each
/// native mob's step. One whose step the kernel refused takes back its state
/// from before the tick where it kept one (and otherwise keeps its turn's
/// state where it stood). Mobs whose move out of the section is pending wait
/// for `settle`.
pub fn finish(
    section: &mut MobSection,
    tick: Tick,
    velocities: &[[f64; 3]],
    void: f64,
) -> Vec<Step> {
    let mut steps = Vec::new();
    let mut changed = false;
    for (id, state) in tick.turns {
        let Some(slot) = section.peek_kept(id) else {
            continue;
        };
        slot.stepped = false;
        let before = slot.before.take();
        if !state.stepped {
            if let Some(before) = before {
                // What observers were shown is as the tick began.
                slot.mob = before.0;
                let resting = resting(&slot.mob, void);
                section.relocate(id);
                set_timed(section, id, resting);
                continue;
            }
        }
        // The dragon's actor owns its velocity; its fixed row only kept it
        // out of pushing.
        if !dragon(&slot.mob) {
            if let Some(v) = velocities.get(state.index) {
                slot.mob.body.velocity = *v;
            }
        }
        // A thinking mob's idle time is its mind's (`noActionTime`).
        if let Some(s) = slot.mob.body.mob.ai.as_ref().and_then(|m| m.state.as_ref()) {
            slot.idle = s.no_action;
        }
        let moved = !Physical::of(&slot.mob).same(&state.start);
        slot.touched = true;
        changed = true;
        let position = slot.mob.position;
        let resting = resting(&slot.mob, void);
        let outside = !section.holds(position);
        set_timed(section, id, resting);
        let slot = section.peek_kept(id).expect("slot");
        if outside {
            slot.pending = true;
            match before {
                Some(mut before) => {
                    // What observers were shown until the tick's report.
                    before.1 = slot.shown.clone();
                    slot.before = Some(before);
                }
                None => slot.start = Some(state.start.position),
            }
        }
        section.relocate(id);
        // What its hurts released this tick or since the last (Infested).
        let mut effects = state.out.effects;
        let spawns = std::mem::take(&mut section.get_mut(id).expect("slot").mob.body.mob.spawns);
        effects.extend(
            spawns
                .into_iter()
                .map(|v| Effect::Ai(AiEffect::SpawnMob(v))),
        );
        steps.push(Step {
            id,
            events: state.out.events,
            effects,
            moved,
            outside,
            from: state.start.position,
        });
    }
    if changed {
        section.revision += 1;
    }
    steps
}

/// Settles the mobs whose move out of the section was pending: those in
/// `kept` left (their owner withdrew them); the others go back to their
/// state before the tick, as the Elixir keeps an entry whose step it did not
/// carry out (or, where that state was not kept, to where they began).
pub fn settle(section: &mut MobSection, kept: &[i32]) {
    let pending: Vec<i32> = section
        .slots()
        .filter(|(_, s)| s.pending)
        .map(|(id, _)| id)
        .collect();
    for id in pending {
        let Some(slot) = section.peek_mut(id) else {
            continue;
        };
        slot.pending = false;
        let before = slot.before.take();
        let start = slot.start.take();
        if kept.contains(&id) {
            continue;
        }
        if let Some(before) = before {
            let (mob, shown) = *before;
            slot.mob = mob;
            slot.shown = shown;
        } else if let Some(start) = start {
            slot.mob.position = start;
        }
        section.relocate(id);
    }
}

/// One mob's timers aged (`Store.age_chunks/4`'s `Body.tick/1` of a native
/// mob): its events, and whether its death animation ended.
#[derive(Clone, Debug)]
pub struct Aged {
    pub id: i32,
    pub events: Vec<Event>,
    pub done: bool,
    /// Its record may have changed.
    pub changed: bool,
}

/// Whether a mob's timers rest (VMC-081j): `Body.tick/1` would change
/// nothing of it (no portal cooldown, hurt time, hurt cooldown or player
/// memory running, alive, no death animation) and it is above `void` (the
/// world's floor less 64, where it is gone). The dragon's timers run on
/// its own clock and never rest.
pub fn resting(mob: &NativeMob, void: f64) -> bool {
    let body = &mob.body;
    let h = &body.mob.living.health;
    body.entity_type != super::boss::dragon::DRAGON
        && body.portal_cooldown <= 0
        && h.hurt_ticks == 0
        && h.cooldown == 0
        && h.value > 0.0
        && body.mob.player_memory == 0
        && body.mob.hurt_by_player.is_none()
        && mob.position[1] >= void
}

fn set_timed(section: &mut MobSection, id: i32, resting: bool) {
    if resting {
        section.rest(id);
    } else {
        section.time(id);
    }
}

/// The timers of the section's mobs in chunks with a tick budget
/// (`budget`: chunk => ticks owed), once per game tick `tick` and not for
/// one that already took its turn in it (it came from a sibling section):
/// `Body.tick/1` up to 40 times, stopping when its death animation ends,
/// and its idle and lived counts. In id order.
///
/// Deadline-based (VMC-081j): only the mobs whose timers may be due
/// (`MobSection::timed`) are visited; a mob whose timers rest would change
/// nothing but its counts, which its chunk's clock keeps (`Slot::clock`).
/// One whose timers come to rest here leaves the visited set. `void` is
/// the world's floor less 64.
pub fn age(
    section: &mut MobSection,
    budget: &std::collections::HashMap<(i32, i32), u32>,
    tick: Option<i64>,
    void: f64,
) -> Vec<Aged> {
    let due: Vec<i32> = section
        .timed()
        .filter(|id| {
            section
                .get(*id)
                .is_some_and(|s| budget.get(&s.chunk).is_some_and(|&t| t > 0))
        })
        .collect();
    // Their counts as the clocks stood before this tick's.
    for &id in &due {
        section.peek_kept(id);
    }
    if section.age_clocks(budget, tick) {
        section.revision += 1;
    }
    let mut ids = Vec::with_capacity(due.len());
    for id in due {
        let slot = section.get(id).expect("slot");
        if tick.is_none() || (slot.aged != tick && slot.ticked != tick) {
            ids.push(id);
        } else {
            // It aged in this tick already: this one's clock passes it by.
            section.skip_clock(id);
        }
    }
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        // Its counts take the clock's advance: `ticks` more, aged now.
        let slot = section.peek_kept(id).expect("slot");
        let ticks = budget[&slot.chunk];
        let body = &mut slot.mob.body;
        let before = (
            body.portal_cooldown,
            body.mob.living.health.clone(),
            body.mob.player_memory,
            body.mob.hurt_by_player,
        );
        let mut events = Vec::new();
        let mut done = false;
        if body.entity_type == super::boss::dragon::DRAGON {
            // Its living timers once a game tick, the tick kept with its body
            // as it moves on (`aged_tick`); its death actor ends it.
            let aged = tick.map(Value::Int);
            if aged.is_none() || body.data.get("aged_tick") != aged.as_ref() {
                super::boss::dragon::timers(body);
                if let Some(t) = aged {
                    body.data.set("aged_tick", t);
                }
            }
        } else {
            for _ in 0..ticks.clamp(1, 40) {
                done = living_body::tick(body, &mut events);
                if done {
                    break;
                }
            }
        }
        let changed = before
            != (
                body.portal_cooldown,
                body.mob.living.health.clone(),
                body.mob.player_memory,
                body.mob.hurt_by_player,
            );
        if changed || !events.is_empty() {
            slot.touched = true;
        }
        if resting(&slot.mob, void) {
            section.rest(id);
        }
        out.push(Aged {
            id,
            events,
            done,
            changed,
        });
    }
    out
}

/// The portals: `Valimc.World.Portal.Contact`'s kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Portal {
    Nether,
    End,
    Gateway,
}

impl Portal {
    pub fn name(self) -> &'static str {
        match self {
            Portal::Nether => "nether_portal",
            Portal::End => "end_portal",
            Portal::Gateway => "end_gateway",
        }
    }

    pub fn of(facts: &super::facts::MobFacts, state: u16) -> Option<Portal> {
        let blocks = &facts.blocks;
        if blocks.is(state, "nether_portal") {
            Some(Portal::Nether)
        } else if blocks.is(state, "end_portal") {
            Some(Portal::End)
        } else if blocks.is(state, "end_gateway") {
            Some(Portal::Gateway)
        } else {
            None
        }
    }
}

const DEFLATE: f64 = 1.0e-5;

/// The cooldown a portal's touch renews (`getDimensionChangingDelay`).
pub const PORTAL_COOLDOWN: i32 = 300;

/// `Contact.touched/4`: the first portal block whose inside shape a box of
/// `size` (width, height) met moving from `from` to `to`, sampled at most
/// half a block apart (16 points at most); `read` gives the states of cells
/// (None where the owner does not hold them).
pub fn portal_touch(
    facts: &super::facts::MobFacts,
    physics: &crate::physics::facts::Facts,
    size: (f64, f64),
    from: [f64; 3],
    to: [f64; 3],
    read: impl FnOnce(&[[i32; 3]]) -> Vec<Option<u16>>,
) -> Option<(Portal, [i32; 3])> {
    use crate::physics::facts::InsideShape;
    let (w, h) = size;
    let points: Vec<[f64; 3]> = if from == to {
        vec![to]
    } else {
        let d = ((to[0] - from[0]).powi(2) + (to[1] - from[1]).powi(2) + (to[2] - from[2]).powi(2))
            .sqrt();
        let steps = ((d * 2.0).ceil() as i64).clamp(1, 16);
        (1..=steps)
            .map(|i| {
                let t = i as f64 / steps as f64;
                [
                    from[0] + (to[0] - from[0]) * t,
                    from[1] + (to[1] - from[1]) * t,
                    from[2] + (to[2] - from[2]) * t,
                ]
            })
            .collect()
    };
    let mut cells: Vec<([i32; 3], [f64; 6])> = Vec::new();
    for [x, y, z] in points {
        let b = [x - w / 2.0, y, z - w / 2.0, x + w / 2.0, y + h, z + w / 2.0];
        let lo = |v: f64| (v + DEFLATE).floor() as i32;
        let hi = |v: f64| (v - DEFLATE).floor() as i32;
        for cx in lo(b[0])..=hi(b[3]) {
            for cy in lo(b[1])..=hi(b[4]) {
                for cz in lo(b[2])..=hi(b[5]) {
                    cells.push(([cx, cy, cz], b));
                }
            }
        }
    }
    let positions: Vec<[i32; 3]> = cells.iter().map(|(c, _)| *c).collect();
    let states = read(&positions);
    for ((cell, b), state) in cells.iter().zip(states) {
        let Some(state) = state else { continue };
        let Some(kind) = Portal::of(facts, state) else {
            continue;
        };
        let [x, y, z] = cell.map(|v| v as f64);
        let inside = match &physics.player.inside(state).shape {
            InsideShape::Full => true,
            InsideShape::Boxes(boxes) => boxes.iter().any(|a| {
                b[0] + DEFLATE < x + a.max[0]
                    && b[3] - DEFLATE > x + a.min[0]
                    && b[1] + DEFLATE < y + a.max[1]
                    && b[4] - DEFLATE > y + a.min[1]
                    && b[2] + DEFLATE < z + a.max[2]
                    && b[5] - DEFLATE > z + a.min[2]
            }),
            InsideShape::Context => false,
        };
        if inside {
            return Some((kind, *cell));
        }
    }
    None
}

/// Whether slot `slot` is a mob a store would see as alive.
pub fn alive(slot: &Slot) -> bool {
    living_mob::alive(&slot.mob.body.mob)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mobs::term::Map;

    #[test]
    fn a_hit_takes_its_attackers_extras_for_its_target_only() {
        let golem_target = Ref {
            kind: RefKind::Mob,
            uuid: [3; 16],
        };
        let other = Ref {
            kind: RefKind::Mob,
            uuid: [4; 16],
        };
        let made = vec![
            AiEffect::Attack(golem_target),
            AiEffect::AttackExtra(
                other,
                Value::Map(Map::from_atoms([("amount", Value::Float(1.0))])),
            ),
            AiEffect::AttackExtra(
                golem_target,
                Value::Map(Map::from_atoms([
                    ("amount", Value::Float(12.5)),
                    ("lift", Value::Float(0.4)),
                    ("extra_knockback", Value::atom("nil")),
                ])),
            ),
        ];
        let hit = with_extras(combat::Hit::new(0, 7.5), &made, &golem_target);
        assert_eq!(hit.amount, 12.5);
        assert_eq!(hit.lift, Some(0.4));
        assert_eq!(hit.extra_knockback, None);
        let plain = with_extras(combat::Hit::new(0, 7.5), &made[..1], &golem_target);
        assert_eq!((plain.amount, plain.lift), (7.5, None));
    }
}
