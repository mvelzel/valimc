//! A section's mob turns over the physics `Ticker` (VMC-081d), ported from
//! `Valimc.Entity.MobTicks`: every mob of the section in network-id order,
//! a native mob's turn here, an Elixir mob's turn by yielding to its
//! owner's `MobTicks` at its index over the same ticker, then resuming, so
//! the order across both kinds is exactly id order.
//!
//! A native mob's turn is `MobTicks.ordered_step` for it: its fluids sensed
//! (`Entity.baseTick`), `MobVitals.base_tick`, its thinking (`Thinker`: a
//! pending `finalizeSpawn`, then its AI where its family's is native), the
//! kernel's step with its move control (`MobMotion.kernel`), the move
//! written back (`MobMotion.apply`), its splash into water, turtle eggs and
//! farmland it lands or steps on (the level random), its family's settling,
//! `MobVitals.apply` and `Daylight.tick`. Its events and the effects that
//! leave it collect on its slot until the tick ends; its velocity follows the
//! ticker's (the pushes of later mobs) until then.
//!
//! A mob whose step the kernel refused (a chunk it cannot read) keeps the
//! state it had when the tick began, as the Elixir keeps its entry when it
//! has no step; so does one whose move out of the section its owner does not
//! carry out. Each slot keeps that state (`Slot::before`) until the tick's
//! end decides.

use super::combat::{self, Event, Rules, SoundRef};
use super::living::body as living_body;
use super::living::f;
use super::living::mob::{self as living_mob, Type};
use super::model::{
    Control, Eye, FloatControl, Hop, HopOutcome, Impulse, MotionSet, NativeMob, Slot as EquipSlot,
};
use super::random::LegacyRandom;
use super::section::{MobSection, Slot};
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

/// What a turn reads: the rules, the motion hooks, the physics world of the
/// ticker, the players that push, the sky (light, rain, the sun and the
/// level random) and the game rules it applies.
pub struct TurnWorld<'a, 'w> {
    pub rules: &'a Rules<'a>,
    pub motion: &'a dyn MotionHooks,
    pub thinker: &'a dyn Thinker,
    pub world: &'a World<'w>,
    pub players: &'a [([f64; 3], Aabb)],
    pub mob_griefing: bool,
    /// The travel attributes of types whose mobs have no attribute
    /// overrides, as `MobTicks` shares them per type.
    pub travel: std::cell::RefCell<std::collections::HashMap<u16, Attributes>>,
}

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
}

/// A mob's AI around its move (`Valimc.AI.think_mob/4` and `settle/5`):
/// the hook native families' AI plugs into (`mobs::ai::Turn` and its
/// selectors). The default finishes a pending spawn (`Spawn.mob/2`, the
/// part every mob has) and thinks no further, as a mob without goals.
pub trait Thinker: Sync {
    /// Whether mobs of `ty` think natively.
    fn thinks(&self, _ty: Type) -> bool {
        false
    }

    /// The AI part of the turn before the move: `finalizeSpawn` first, then
    /// the mob's AI. `level` is the section's level random; the events go
    /// with the mob's, the effects leave it.
    fn think(
        &self,
        rules: &Rules,
        ty: Type,
        mob: &mut NativeMob,
        level: &mut LegacyRandom,
        out: &mut Turned,
    ) {
        let _ = (rules, ty, out);
        finalize_spawn(rules, mob, level);
    }

    /// After the move (`settle/5`): the body control and a family's ticks.
    fn settle(&self, _rules: &Rules, _ty: Type, _mob: &mut NativeMob, _out: &mut Turned) {}
}

/// Mobs without native AI.
pub struct NoThought;

impl Thinker for NoThought {}

/// What a turn leaves: the mob's events and the effects leaving it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Turned {
    pub events: Vec<Event>,
    pub effects: Vec<Effect>,
}

const FOLLOW_RANGE: &str = "minecraft:follow_range";
const SPAWN_BONUS: &str = "minecraft:random_spawn_bonus";

/// `Spawn.finalize/1` of a family without its own finalizer (`Spawn.mob/2`):
/// a follow range bonus (a triangle of two level doubles) unless it has one,
/// left-handedness one time in twenty (a level float). Clears the pending
/// reason.
pub fn finalize_spawn(_rules: &Rules, mob: &mut NativeMob, level: &mut LegacyRandom) {
    let m = &mut mob.body.mob;
    if m.finalize.take().is_none() {
        return;
    }
    let has = m
        .attributes
        .get(FOLLOW_RANGE)
        .is_some_and(|o| o.modifiers.iter().any(|x| x.id == SPAWN_BONUS));
    if !has {
        let a = level.double();
        let b = level.double();
        let entry = m.attributes.entry(FOLLOW_RANGE);
        entry.modifiers.retain(|x| x.id != SPAWN_BONUS);
        entry.modifiers.push(super::model::Modifier {
            id: SPAWN_BONUS.to_owned(),
            amount: super::model::Number::Float(0.11485000000000001 * (a - b)),
            operation: 1,
        });
    }
    let roll = level.float() as f64;
    m.left_handed = roll < f(0.05);
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
        Value::Binary(b"blocks".to_vec()),
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

/// One native mob's turn at ticker index `i` (`MobTicks.ordered_step/6`).
/// `pushed` collects the mobs its step pushed; false when the kernel
/// refused its step (it keeps its state from before the tick).
pub fn turn(
    tw: &TurnWorld,
    sky: &mut dyn Sky,
    ticker: &mut Ticker,
    i: usize,
    mob: &mut NativeMob,
    out: &mut Turned,
    pushed: &mut Vec<(usize, [f64; 3])>,
) -> bool {
    let rules = tw.rules;
    let Some(ty) = rules.of(&mob.body.entity_type) else {
        return false;
    };
    // The pushes of the mobs before it, and hits, are in the ticker.
    mob.body.velocity = ticker.current[i].velocity;
    sense(rules, ty, tw.world, mob);
    // `baseTick`'s burning comes first (VMC-043b).
    out.events.extend(vitals::base_tick(rules, mob));
    tw.thinker.think(rules, ty, mob, sky.random(), out);
    let attributes = tw.travel(ty, mob);
    let input = kernel_input(rules, tw.motion, ty, mob, attributes);
    let (result, by) = ticker.step(tw.world, i, input, tw.players);
    pushed.extend(by);
    let Ok(mut t) = result else {
        return false;
    };
    // A family that never falls (a bat's `checkFallDamage`) lands softly.
    if !tw.motion.falls(ty) {
        t.landing = None;
    }
    apply_ticked(mob, &t);
    // The move's splash into water comes before the rest of its tick.
    let mut splashed = Vec::new();
    if let Some(v) = t.splash {
        splashed.push(splash(rules, ty, mob, v));
    }
    // What it landed and stepped on (the level random): farmland, eggs.
    let mut ground = Turned::default();
    trample(rules, ty, mob, &t, sky, &mut ground);
    eggs(rules, mob, &t, tw.mob_griefing, sky, &mut ground);
    let mut settled = Turned::default();
    tw.thinker.settle(rules, ty, mob, &mut settled);
    // A family that set its motion after the move (a squid's stroke) tells
    // the ticker, so later pushes add to it.
    if mob.body.velocity != t.mob.velocity {
        ticker.current[i].velocity = mob.body.velocity;
    }
    out.events.extend(splashed);
    out.events
        .extend(vitals::apply(rules, mob, &Moved::from(&t)));
    // The sun on undead mobs and rain on burning ones (VMC-043b).
    let position = mob.position;
    out.events
        .extend(vitals::daylight(rules, mob, position, sky));
    out.events.extend(settled.events);
    out.events.extend(ground.events);
    out.effects.extend(settled.effects);
    out.effects.extend(ground.effects);
    true
}

/// Who takes each ticker index's turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Entrant {
    /// A native mob of the section, by network id.
    Native(i32),
    /// A mob its owner ticks in Elixir.
    Elixir,
    /// Another section's solid mob, a fixed collider that takes no turn.
    Fixed,
}

/// A section's tick in progress: who takes each turn, the next one, and
/// what Elixir needs at its next yield.
#[derive(Debug, Default)]
pub struct Tick {
    pub order: Vec<Entrant>,
    pub next: usize,
    /// The native mobs whose turns ran since the last yield, for the
    /// Elixir AI's sensing.
    pub moved: Vec<i32>,
    /// Pushes native steps gave Elixir mobs since the last yield.
    pub pushed: Vec<(usize, [f64; 3])>,
    /// Per native mob in the tick: its events and effects so far, and
    /// whether its step went through.
    pub turns: std::collections::BTreeMap<i32, TurnState>,
}

/// A native mob's part of the tick.
#[derive(Clone, Debug, Default)]
pub struct TurnState {
    pub index: usize,
    pub stepped: bool,
    pub refused: bool,
    pub out: Turned,
}

/// Where a run stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ran {
    /// At an Elixir mob's index: its owner ticks it, then resumes after it.
    Yield(usize),
    /// Every turn ran.
    Done,
}

impl Tick {
    /// The tick of `order` (one entry per ticker index); each native mob
    /// keeps its state from now as its fallback.
    pub fn begin(section: &mut MobSection, order: Vec<Entrant>) -> Tick {
        let mut turns = std::collections::BTreeMap::new();
        for (index, e) in order.iter().enumerate() {
            if let Entrant::Native(id) = *e {
                if let Some(slot) = section.peek_mut(id) {
                    slot.stepped = false;
                    slot.before = Some(Box::new((slot.mob.clone(), slot.shown.clone())));
                    turns.insert(
                        id,
                        TurnState {
                            index,
                            ..TurnState::default()
                        },
                    );
                }
            }
        }
        Tick {
            order,
            next: 0,
            moved: Vec::new(),
            pushed: Vec::new(),
            turns,
        }
    }

    /// Runs turns from `from` on until an Elixir mob's or the end.
    pub fn run(
        &mut self,
        section: &mut MobSection,
        tw: &TurnWorld,
        sky: &mut dyn Sky,
        ticker: &mut Ticker,
        from: usize,
    ) -> Ran {
        self.next = from;
        while self.next < self.order.len() {
            let i = self.next;
            match self.order[i] {
                Entrant::Elixir => return Ran::Yield(i),
                Entrant::Fixed => {}
                Entrant::Native(id) => {
                    if let (Some(slot), Some(state)) =
                        (section.peek_mut(id), self.turns.get_mut(&id))
                    {
                        let mut pushed = Vec::new();
                        let ok = turn(
                            tw,
                            sky,
                            ticker,
                            i,
                            &mut slot.mob,
                            &mut state.out,
                            &mut pushed,
                        );
                        state.stepped = ok;
                        state.refused = !ok;
                        slot.stepped = ok;
                        self.pushed.extend(
                            pushed
                                .into_iter()
                                .filter(|(j, _)| self.order.get(*j) == Some(&Entrant::Elixir)),
                        );
                        self.moved.push(id);
                        section.relocate(id);
                    }
                }
            }
            self.next += 1;
        }
        Ran::Done
    }
}

/// A native mob's step at the tick's end: its new state for the store.
#[derive(Clone, Debug)]
pub struct Step {
    pub id: i32,
    pub events: Vec<Event>,
    pub effects: Vec<Effect>,
    /// Its state differs from the tick's start (or it has events).
    pub changed: bool,
    /// It left the section: its owner moves it on, or keeps it where it was.
    pub outside: bool,
}

/// The tick's end (`MobTicks.steps/5` after its turns): every mob's motion
/// with the pushes after its turn (`velocities`, by ticker index); each
/// native mob's step, or its state from before the tick where the kernel
/// refused it. Mobs whose move out of the section is pending keep their
/// fallback until `settle`.
pub fn finish(section: &mut MobSection, tick: Tick, velocities: &[[f64; 3]]) -> Vec<Step> {
    let mut steps = Vec::new();
    for (id, state) in tick.turns {
        let Some(slot) = section.peek_mut(id) else {
            continue;
        };
        slot.stepped = false;
        let before = slot.before.take();
        if !state.stepped {
            if let Some(before) = before {
                let (mob, shown) = *before;
                slot.mob = mob;
                slot.shown = shown;
            }
            section.relocate(id);
            continue;
        }
        if let Some(v) = velocities.get(state.index) {
            slot.mob.body.velocity = *v;
        }
        let changed =
            !state.out.events.is_empty() || before.as_ref().is_none_or(|b| b.0 != slot.mob);
        let outside = !section.holds(slot_position(section, id));
        if changed {
            section.revision += 1;
        }
        let slot = section.peek_mut(id).expect("slot");
        if outside {
            slot.before = before;
        }
        if changed {
            slot.touched = true;
        }
        steps.push(Step {
            id,
            events: state.out.events,
            effects: state.out.effects,
            changed,
            outside,
        });
    }
    steps
}

fn slot_position(section: &MobSection, id: i32) -> [f64; 3] {
    section.get(id).map_or([0.0; 3], |s| s.mob.position)
}

/// Settles the mobs whose move out of the section was pending: those in
/// `gone` left (their owner withdrew them); the others go back to their
/// state before the tick, as the Elixir keeps an entry whose step it did not
/// carry out.
pub fn settle(section: &mut MobSection, kept: &[i32]) {
    let pending: Vec<i32> = section
        .slots()
        .filter(|(_, s)| s.before.is_some())
        .map(|(id, _)| id)
        .collect();
    for id in pending {
        let Some(slot) = section.peek_mut(id) else {
            continue;
        };
        let before = slot.before.take();
        if kept.contains(&id) {
            continue;
        }
        if let Some(before) = before {
            let (mob, shown) = *before;
            slot.mob = mob;
            slot.shown = shown;
        }
        section.relocate(id);
    }
}

/// Whether slot `slot` is a mob a store would see as alive.
pub fn alive(slot: &Slot) -> bool {
    living_mob::alive(&slot.mob.body.mob)
}
