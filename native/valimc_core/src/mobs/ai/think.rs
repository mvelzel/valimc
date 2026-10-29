//! A native mob's AI part of its tick (VMC-081d), ported from `Valimc.AI`:
//! the mind a mob of a thinking type gets (`mind_state`, `ensure`), what
//! others sense of it (`sensed`, `resensed`, `resense_state`), its think
//! before the kernel moves it (`think`: `think_one`, with `finalizeSpawn`
//! first), the move's splash (`move_sounds`), its settle after the move
//! (`settle`: swim and step sounds, its family's `aiStep` and `tick` after
//! their supers, looting, the body rotation control, the control flags) and
//! the changes one mob makes to another (`other`, `change_other`).
//!
//! The section runs these per mob in id order around the kernel's move, as
//! `MobTicks` does. A change one mob makes to another (an alert, a
//! breeding's partner, a family's change of another's own state or mind)
//! applies directly to the other mob, which the section's table holds: a
//! mob later in order thinks with it, as the Elixir applies it at that
//! mob's think; one earlier has it from now, where the Elixir applies it
//! after the last mob (`AI.finish`). Nothing reads an earlier mob's body
//! between the two, and what does (a hit landing on it) commutes with these
//! changes (a target, an age and love, a family's own state), so both give
//! the same bodies. Its sensed row changes at once in both.

use super::control::look;
use super::effect::Effect;
use super::fmath::{self, emax, emin, f};
use super::goals::Panic;
use super::leash;
use super::mind::MindState;
use super::navigation::{self, Navigation};
use super::random_pos;
use super::selector::{self, Which};
use super::turn::{Outside, Turn};
use super::Extra;
use crate::mobs::combat::Rules;
use crate::mobs::facts::ai::AiMob;
use crate::mobs::kinds::{self, Kind, Registry};
use crate::mobs::level::Level;
use crate::mobs::living::body as living_body;
use crate::mobs::living::mob::{self as living_mob, Type};
use crate::mobs::model::{Control, Mind, NativeMob, Slot};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{Kind as RefKind, Ref, SensedMob, Sensing, Uuid};
use crate::path::PathFacts;
use std::sync::OnceLock;

/// What the AI part of a tick reads beside the level and the sensing: the
/// living rules (their `families` the registry), the families and the
/// path facts.
#[derive(Clone, Copy)]
pub struct Ctx<'a> {
    pub rules: &'a Rules<'a>,
    pub kinds: &'a Registry,
    pub paths: &'a PathFacts,
}

impl<'a> Ctx<'a> {
    fn ty(&self, mob: &NativeMob) -> Option<Type<'a>> {
        Type::of(self.rules.facts, &mob.body.entity_type)
    }
}

/// AI facts for a family's type that has none (a turn still needs some).
fn blank() -> &'static AiMob {
    static BLANK: OnceLock<AiMob> = OnceLock::new();
    BLANK.get_or_init(|| AiMob {
        max_head_y_rot: 75.0,
        max_head_x_rot: 40.0,
        head_rot_speed: 10.0,
        ambient_sound: None,
        ambient_interval: 80,
        volume: 1.0,
        monster: false,
        malus: Vec::new(),
        goals: Vec::new(),
        targets: Vec::new(),
    })
}

/// A live mind: a mind that thought (`%Mind{}`).
pub fn live(mob: &NativeMob) -> bool {
    mob.body.mob.ai.as_ref().is_some_and(|m| m.state.is_some())
}

// ## Minds

/// `AI.mind/5` without a brain: a fresh mind's selectors and navigation (a
/// `FloatGoal` makes a ground or flying navigation float).
pub fn mind_state(
    kind: &dyn Kind,
    facts: &crate::mobs::facts::MobFacts,
    type_id: u16,
) -> MindState {
    let (goals, targets, floats) = kinds::selectors(kind, facts, type_id);
    let spec = kind.navigation(type_id);
    let mut nav = Navigation::new(spec.kind, spec.breaching);
    nav.climber = spec.climber;
    nav.can_open_doors = spec.can_open_doors;
    if floats
        && matches!(
            spec.kind,
            navigation::NavKind::Ground | navigation::NavKind::Fly
        )
    {
        nav.can_float = true;
    }
    MindState::new(goals, targets, nav)
}

/// `AI.ensure/2`: a mob of a thinking type thinks with a mind, its random
/// the record's (else one seeded from its uuid).
pub fn ensure(ctx: &Ctx, mob: &mut NativeMob) {
    if live(mob) {
        return;
    }
    let Some(ty) = ctx.ty(mob) else { return };
    let Some(kind) = ctx.kinds.kind(ty.id) else {
        return;
    };
    if ctx.rules.facts.ai.mob(ty.id).is_none() {
        return;
    }
    let state = mind_state(kind, ctx.rules.facts, ty.id);
    let uuid = mob.uuid;
    let mind = mob.body.mob.ai.get_or_insert_with(|| Mind {
        random: LegacyRandom::from_uuid(&uuid),
        memories: None,
        state: None,
    });
    mind.state = Some(Box::new(state));
}

// ## Sensing

fn running_panic(mob: &NativeMob) -> bool {
    mob.body
        .mob
        .ai
        .as_ref()
        .and_then(|m| m.state.as_ref())
        .is_some_and(|s| s.goals.runs::<Panic>())
}

/// `AI.sensed/1`: what others read of mob `id` of the section.
pub fn sensed(ctx: &Ctx, id: i32, mob: &NativeMob) -> Option<SensedMob<Extra>> {
    let ty = ctx.ty(mob)?;
    let kind = ctx.kinds.kind(ty.id);
    let body = &mob.body;
    let [width, height, eye] = living_body::dimensions(ctx.rules, ty, body);
    let animal = kind.is_some_and(|k| k.animal());
    let state = mob.body.mob.ai.as_ref().and_then(|m| m.state.as_ref());
    let own_box = ctx
        .rules
        .family(ty)
        .bounding_box(body, mob.position)
        .map(|b| crate::physics::Aabb::new([b[0], b[1], b[2]], [b[3], b[4], b[5]]));
    Some(SensedMob {
        uuid: mob.uuid,
        id,
        type_id: ty.id,
        position: mob.position,
        yaw: body.yaw as f32,
        pitch: body.pitch as f32,
        eye,
        width,
        height,
        own_box,
        alive: living_mob::alive(&body.mob),
        recent_mob_hurt: false,
        baby: kind
            .and_then(|k| k.young(body))
            .unwrap_or_else(|| body.data.baby().unwrap_or(false)),
        huntable: body.data.get("cannot_be_hunted").and_then(|v| v.as_bool()) != Some(true),
        target: state.and_then(|s| s.target),
        in_love: if animal {
            body.data.in_love().unwrap_or(0) as i32
        } else {
            0
        },
        age: if animal {
            body.data.age().unwrap_or(0) as i32
        } else {
            0
        },
        in_water: body.mob.motion.water > 0.0,
        invulnerable: kind.is_some_and(|k| k.hidden(body)),
        killed_by: body.mob.hurt_by_player,
        panicking: running_panic(mob),
        extra: Extra {
            data: animal.then(|| body.data.clone()),
        },
    })
}

/// `AI.resense_entry/3`: a mob sensed again after it moved (its place,
/// rotations, life and target, and its own state).
pub fn resensed(ctx: &Ctx, mob: &NativeMob, sensing: &mut Sensing<Extra>) {
    let target = mob
        .body
        .mob
        .ai
        .as_ref()
        .and_then(|m| m.state.as_ref())
        .and_then(|s| s.target);
    let position = mob.position;
    let (yaw, pitch) = (mob.body.yaw as f32, mob.body.pitch as f32);
    let alive = living_mob::alive(&mob.body.mob);
    sensing.resense(&mob.uuid, |row| {
        row.position = position;
        row.yaw = yaw;
        row.pitch = pitch;
        row.alive = alive;
        row.recent_mob_hurt = false;
        row.target = target;
    });
    resense_state(ctx, mob, sensing);
}

/// `sensed_state/1`: what others sense of its own state (an animal's love,
/// age and data).
pub fn resense_state(ctx: &Ctx, mob: &NativeMob, sensing: &mut Sensing<Extra>) {
    let Some(ty) = ctx.ty(mob) else { return };
    if !ctx.kinds.kind(ty.id).is_some_and(|k| k.animal()) {
        return;
    }
    let data = &mob.body.data;
    sensing.resense(&mob.uuid, |row| {
        row.in_love = data.in_love().unwrap_or(0) as i32;
        row.age = data.age().unwrap_or(0) as i32;
        if row.extra.data.as_ref() != Some(data) {
            row.extra.data = Some(data.clone());
        }
    });
}

// ## Changes to others

/// The mob an effect changes beside its maker (`other_change/2`).
pub fn other(effect: &Effect) -> Option<Uuid> {
    match effect {
        Effect::Alert { mob, .. } => Some(*mob),
        Effect::Bred(r) if r.kind == RefKind::Mob => Some(r.uuid),
        Effect::Own { mob, .. } | Effect::Remote { mob, .. } => Some(*mob),
        _ => None,
    }
}

/// What `effect` changes in mob `target` (network id `id`) of the section,
/// and in what others sense of it: an alert sets its target through its
/// type's `setTarget`, a breeding its partner's age and love, a family's
/// change its own state or mind. A mob without a live mind keeps an alert.
pub fn change_other<'w>(
    ctx: &Ctx<'w>,
    effect: &Effect,
    target: &mut NativeMob,
    id: i32,
    level: &mut Level<'w>,
    sensing: &mut Sensing<Extra>,
) {
    let Some(ty) = ctx.ty(target) else { return };
    let kinds: &'w Registry = ctx.kinds;
    let kind = kinds.kind(ty.id);
    match effect {
        Effect::Alert { target: to, .. } => {
            if !live(target) {
                return;
            }
            let Some(kind) = kind else {
                if let Some(s) = target.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) {
                    s.target = Some(*to);
                }
                return;
            };
            let facts = level.facts;
            let ai = facts.ai.mob(ty.id).unwrap_or_else(|| blank());
            let dims = living_body::dimensions(ctx.rules, ty, &target.body);
            let mut t = Turn::new(target, id, ty.id, ai, dims, level, sensing, ctx.paths, kind);
            t.set_target(Some(*to));
        }
        Effect::Bred(_) => {
            crate::mobs::animals::bred(&mut target.body.data);
            resense_state(ctx, target, sensing);
        }
        Effect::Own { change, .. } => {
            if let (Some(kind), Some(state)) = (
                kind,
                target.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()),
            ) {
                kind.own_change(&mut state.own, change.as_ref());
            }
        }
        Effect::Remote { change, .. } => {
            if let (Some(kind), Some(state)) = (
                kind,
                target.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()),
            ) {
                kind.remote_change(state, change.as_ref());
            }
        }
        _ => {}
    }
}

// ## Think

/// `think_one/3` of mob `id`: a pending `finalizeSpawn` first, then (for a
/// type with an AI, alive or of a family that ticks dying) its tick before
/// the move: `checkDespawn`'s idle reset, its family's `tick` start, the
/// base tick, its own air, its item in use, its family's `aiStep` start and
/// `serverAiStep` (not for a `NoAI` mob or while goals are off). A tick
/// start that converted or discarded it ends its tick there. Its jump and
/// lift go to its motion for the kernel. The effects it made, oldest first.
#[allow(clippy::too_many_arguments)]
pub fn think<'t, 'w>(
    ctx: &Ctx<'w>,
    mob: &'t mut NativeMob,
    id: i32,
    level: &'t mut Level<'w>,
    sensing: &'t mut Sensing<Extra>,
    outside: Option<&'t mut (dyn Outside + 't)>,
) -> Vec<Effect> {
    let Some(ty) = ctx.ty(mob) else {
        return Vec::new();
    };
    let kinds: &'w Registry = ctx.kinds;
    let kind = kinds.kind(ty.id);
    let mut made = finalize(ctx, ty, kind, mob, id, level, sensing);
    let Some(kind) = kind else { return made };
    let facts = level.facts;
    let Some(ai) = facts.ai.mob(ty.id) else {
        return made;
    };
    if !live(mob) {
        return made;
    }
    let alive = living_mob::alive(&mob.body.mob);
    if !(alive || kind.dying()) {
        return made;
    }
    let dims = living_body::dimensions(ctx.rules, ty, &mob.body);
    let mut t = Turn::new(mob, id, ty.id, ai, dims, level, sensing, ctx.paths, kind);
    t.outside = outside;
    if alive {
        despawn_check(&mut t, ty);
        kind.tick_start(&mut t);
        let gone = t
            .effects
            .iter()
            .any(|e| matches!(e, Effect::Convert(_) | Effect::Discard));
        if !gone {
            base_tick(ctx, kind, &mut t);
            own_air(ctx, kind, &mut t);
            using_item(kind, &mut t);
            if !living_mob::alive(&t.mob.body.mob) || t.mob.body.mob.no_ai || !t.level.goals {
                kind.before_ai(&mut t);
            } else {
                kind.before_ai(&mut t);
                ai_step(ctx, kind, &mut t);
            }
        }
    } else {
        kind.tick_start(&mut t);
        kind.before_ai(&mut t);
    }
    let motion = &mut t.mob.body.mob.motion;
    motion.jump = t.mind.jump;
    motion.rise = t.mind.rise;
    t.mind.jump = false;
    t.mind.rise = false;
    made.append(&mut t.effects);
    made
}

/// `finalize/4`: the mob's pending `finalizeSpawn` (`Spawn.finalize/1`),
/// its family's or `Mob`'s, with its mind's random where it thought, else
/// one seeded from its uuid that it does not keep.
fn finalize<'w>(
    ctx: &Ctx<'w>,
    ty: Type,
    kind: Option<&'w dyn Kind>,
    mob: &mut NativeMob,
    id: i32,
    level: &mut Level<'w>,
    sensing: &mut Sensing<Extra>,
) -> Vec<Effect> {
    let Some(reason) = mob.body.mob.finalize.take() else {
        return Vec::new();
    };
    let Some(kind) = kind else {
        super::spawn::mob_parts(&mut mob.body.mob, &mut level.random);
        return Vec::new();
    };
    let fresh = !live(mob);
    let kept = if fresh {
        let uuid = mob.uuid;
        mob.body.mob.ai.replace(Mind {
            random: LegacyRandom::from_uuid(&uuid),
            memories: None,
            state: Some(Box::default()),
        })
    } else {
        None
    };
    let facts = level.facts;
    let ai = facts.ai.mob(ty.id).unwrap_or_else(|| blank());
    let dims = living_body::dimensions(ctx.rules, ty, &mob.body);
    let effects = {
        let mut t = Turn::new(mob, id, ty.id, ai, dims, level, sensing, ctx.paths, kind);
        kind.finalize(&mut t, &reason);
        std::mem::take(&mut t.effects)
    };
    if fresh {
        mob.body.mob.ai = kept;
    }
    effects
}

/// `Mob.checkDespawn` without despawning: near a player it is not idle;
/// idle for over 600 ticks it draws its chance to go.
fn despawn_check(t: &mut Turn, ty: Type) {
    let pos = t.pos();
    let nearest = t
        .sensing
        .players
        .iter()
        .filter(|p| p.mode != crate::mobs::sensing::GameMode::Spectator)
        .map(|p| fmath::distance_sq(pos, p.position))
        .reduce(|a, b| if b < a { b } else { a });
    let Some(nearest) = nearest else { return };
    let distance = t
        .level
        .facts
        .entities
        .categories
        .get(&ty.facts.category)
        .map_or(32, |c| c.no_despawn_distance) as f64;
    let d2 = distance * distance;
    if t.mind.no_action > 600 {
        let n = t.int(800);
        if !(n == 0 && nearest > d2) && nearest < d2 {
            t.mind.no_action = 0;
        }
    } else if nearest < d2 {
        t.mind.no_action = 0;
    }
}

/// `tickCount++`, `LivingEntity.baseTick` (its swing, the water splash, the
/// lead, a family's own air, the expiry of who hurt it) and `Mob.baseTick`'s
/// ambient sound.
fn base_tick(ctx: &Ctx, kind: &dyn Kind, t: &mut Turn) {
    t.mind.tick += 1;
    t.mind.swing = super::turn::swing_tick(t.mind.swing);
    splash(kind, t);
    leash::tick(kind, t);
    let breath = kind.breath(t);
    put_air(ctx, t, breath);
    if let Some((r, at)) = t.mind.hurt_by {
        let keep = t.mind.tick - at <= 100 && t.entity(Some(&r)).is_some_and(|e| e.alive);
        if !keep {
            t.mind.hurt_by = None;
        }
    }
    let n = t.int(1000) as i64;
    let ambient = t.mind.ambient;
    t.mind.ambient = ambient + 1;
    if n < ambient {
        t.mind.ambient = -(t.facts.ambient_interval as i64);
        if let Some(sound) = kind.ambient_sound(t) {
            make_sound(t, sound);
        }
    }
}

/// `AI.make_sound/2`: a sound at the mob's volume and voice pitch.
pub fn make_sound(t: &mut Turn, sound: i32) {
    let base = t.hooks.voice(t.type_id, &t.mob.body.data);
    let pitch = t.random.voice_pitch(base) as f64;
    let volume = t.facts.volume;
    t.sound_id(sound, volume, pitch);
}

/// `updateFluidInteraction`'s splash: into water after its first tick.
fn splash(kind: &dyn Kind, t: &mut Turn) {
    let wet = t.in_water();
    let was = t.mind.wet;
    t.mind.wet = wet;
    if wet && !was && t.mind.tick > 1 {
        let velocity = t.velocity();
        let width = t.width;
        let category = &t
            .level
            .facts
            .entities
            .get(t.type_id)
            .map(|e| e.category.clone());
        let effect = splash_sound(
            t.level.facts,
            kind,
            t.type_id,
            category.as_deref(),
            &mut t.random,
            velocity,
            width,
        );
        if let Some(e) = effect {
            let seed = t.next_seed();
            t.effect(with_seed(e, seed));
        }
    }
}

fn with_seed(e: Effect, s: i64) -> Effect {
    match e {
        Effect::Sound {
            id,
            source,
            volume,
            pitch,
            ..
        } => Effect::Sound {
            id,
            source,
            volume,
            pitch,
            seed: s,
        },
        other => other,
    }
}

/// `doWaterSplashEffect` from `velocity`: the sound by its motion, pitched
/// from the mob's random, and its bubbles' and splashes' draws.
fn splash_sound(
    facts: &crate::mobs::facts::MobFacts,
    kind: &dyn Kind,
    type_id: u16,
    category: Option<&str>,
    random: &mut LegacyRandom,
    [vx, vy, vz]: [f64; 3],
    width: f64,
) -> Option<Effect> {
    let speed = (vx * vx * f(0.2) + vy * vy + vz * vz * f(0.2)).sqrt();
    let volume = emin(1.0, f(f(speed) * f(0.2)));
    let a = random.float() as f64;
    let b = random.float() as f64;
    let pitch = f(1.0 + f(f(a - b) * f(0.4)));
    let bound = f(1.0 + f(width * 20.0));
    let count = if bound == bound.trunc() {
        bound as i64
    } else {
        bound.trunc() as i64 + 1
    };
    for _ in 0..count.max(0) * 3 {
        random.double();
    }
    for _ in 0..count.max(0) * 2 {
        random.double();
    }
    let name = kind
        .splash_sound()
        .unwrap_or(if category == Some("monster") {
            "minecraft:entity.hostile.splash"
        } else {
            "minecraft:entity.generic.splash"
        });
    let id = facts.sounds.id(name)?;
    Some(Effect::Sound {
        id,
        source: facts.combat.mob_sounds(type_id).source,
        volume,
        pitch,
        seed: 0,
    })
}

/// `put_air/2`: a family's own air and the drowning it takes, through the
/// one hurt path (the mind attached).
fn put_air(ctx: &Ctx, t: &mut Turn, air: Option<(i32, f64)>) {
    let Some((air, damage)) = air else { return };
    let rules = ctx.rules;
    let events = t.attached(|mob| crate::mobs::vitals::set_air(rules, mob, air, damage));
    t.effects.extend(events.into_iter().map(Effect::Living));
}

/// A water animal's air after its base tick (`own_air/1`).
fn own_air(ctx: &Ctx, kind: &dyn Kind, t: &mut Turn) {
    let wet = kind.wet(t);
    let air = kind.air(t.mob.body.mob.living.air_supply, wet);
    put_air(ctx, t, air);
}

/// `updatingUsingItem`: an item still in its hand counts another tick of
/// use, one that left it stops; its family's use of it (a drink) runs.
fn using_item(kind: &dyn Kind, t: &mut Turn) {
    let Some(using) = t.mob.body.mob.using.clone() else {
        return;
    };
    let slot = match using.hand {
        crate::mobs::model::Hand::OffHand => Slot::Offhand,
        crate::mobs::model::Hand::MainHand => Slot::Mainhand,
    };
    if t.mob.body.mob.equipment.get(slot).is_none() {
        t.stop_using();
        return;
    }
    if let Some(u) = &mut t.mob.body.mob.using {
        u.ticks = using.ticks + 1;
    }
    kind.use_tick(t, slot, using.ticks);
}

/// `LivingEntity.aiStep` up to the move: a `Monster`'s idle time in light,
/// then `serverAiStep`: its selectors (a full update on alternate ticks by
/// its id), a goal's own move, navigation, its family's
/// `customServerAiStep` and move control, the strafe check and the look
/// control.
fn ai_step(_ctx: &Ctx, kind: &dyn Kind, t: &mut Turn) {
    if t.facts.monster && light(t) > 0.5 {
        t.mind.no_action += 2;
    }
    t.mind.no_action += 1;
    t.mind.sight.clear();
    let tick = t.mind.tick;
    if (tick + t.id as i64) % 2 != 0 && tick > 1 {
        selector::tick_running(t, Which::Targets, false);
        selector::tick_running(t, Which::Goals, false);
    } else {
        selector::tick(t, Which::Targets);
        selector::tick(t, Which::Goals);
    }
    // A goal that moved the mob itself (`BreathAirGoal`): the rest of its
    // AI reads where that move took it; the kernel moves it from where it
    // was.
    let at = predicted(t).map(|p| std::mem::replace(&mut t.mob.position, p));
    navigation::tick(t);
    kind.custom_step(t);
    kind.move_control(t);
    strafe(t);
    if t.hooks.looks(t.type_id) {
        look::tick(t);
    }
    if let Some(at) = at {
        t.mob.position = at;
    }
}

/// `BreathAir.predicted/1`.
fn predicted(t: &mut Turn) -> Option<[f64; 3]> {
    t.mob.body.mob.motion.pre_move?;
    let outside = t.outside.take()?;
    let at = outside.goal_position(t);
    t.outside = Some(outside);
    at
}

/// `getLightLevelDependentMagicValue` at the eyes (a blaze is always lit).
fn light(t: &Turn) -> f64 {
    if t.level
        .facts
        .entities
        .get(t.type_id)
        .map(|e| e.name.as_str())
        == Some("minecraft:blaze")
    {
        return 1.0;
    }
    let [x, _, z] = t.pos();
    t.level
        .light([fmath::floor(x), fmath::floor(t.eye_y()), fmath::floor(z)]) as f64
}

/// `MoveControl.tick`'s strafe check: a step that would not land on a
/// walkable block goes straight ahead instead.
fn strafe(t: &mut Turn) {
    let Control::Strafe {
        forward,
        right,
        speed: modifier,
    } = t.mob.body.mob.motion.control
    else {
        return;
    };
    let speed = f(t.attribute("minecraft:movement_speed"));
    let modified = f(f(modifier) * speed);
    let dist = emax(f(f(forward * forward + right * right).sqrt()), 1.0);
    let dist = f(modified / dist);
    let (xa, za) = (f(forward * dist), f(right * dist));
    let radians = f(t.yaw() * f(std::f64::consts::PI / 180.0));
    let (sin, cos) = (fmath::sin(radians), fmath::cos(radians));
    let dx = f(f(xa * cos) - f(za * sin));
    let dz = f(f(za * cos) + f(xa * sin));
    let cell = [
        fmath::floor(t.x() + dx),
        fmath::floor(t.y()),
        fmath::floor(t.z() + dz),
    ];
    if random_pos::static_type(t.level, t.paths, cell) != crate::path::types::WALKABLE {
        t.strafe(1.0, 0.0);
    }
}

// ## After the move

/// What the kernel's move made that the settle plays: the swims' volumes
/// (a goal's own move's first) and whether it stepped.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Moves {
    pub swims: [Option<f64>; 2],
    pub step: bool,
}

/// `AI.settle/5` of mob `id` after the kernel moved it from `from` (`{x,
/// z}` before the move) to where it is now: its swim and step sounds, its
/// family's `aiStep` after its super with looting, the body rotation
/// control, its family's `tick` after its super and the control flags; a
/// mob that does not think (`NoAI`) still ages (`still/4`). The effects it
/// made, oldest first.
#[allow(clippy::too_many_arguments)]
pub fn settle<'t, 'w>(
    ctx: &Ctx<'w>,
    mob: &'t mut NativeMob,
    id: i32,
    from: [f64; 2],
    level: &'t mut Level<'w>,
    sensing: &'t mut Sensing<Extra>,
    moves: Moves,
    outside: Option<&'t mut (dyn Outside + 't)>,
) -> Vec<Effect> {
    if !live(mob) {
        return Vec::new();
    }
    let Some(ty) = ctx.ty(mob) else {
        return Vec::new();
    };
    let kinds: &'w Registry = ctx.kinds;
    let Some(kind) = kinds.kind(ty.id) else {
        return Vec::new();
    };
    let facts = level.facts;
    let alive = living_mob::alive(&mob.body.mob);
    let thinking = facts.ai.mob(ty.id).is_some() && !mob.body.mob.no_ai;
    let dims = living_body::dimensions(ctx.rules, ty, &mob.body);
    let ai = facts.ai.mob(ty.id).unwrap_or_else(|| blank());
    if thinking && (alive || kind.dying()) {
        let motion = kind.kernel_motion();
        let mut t = Turn::new(mob, id, ty.id, ai, dims, level, sensing, ctx.paths, kind);
        t.outside = outside;
        let snapped = t.mind.snapped;
        for volume in moves.swims.into_iter().flatten() {
            swim(kind, &motion, &mut t, volume);
        }
        if moves.step {
            kind.step_sound(&mut t);
        }
        if alive {
            kind.after_ai(&mut t);
            super::pickup::tick(ctx.rules, kind, &mut t);
            look::body(&mut t, snapped.unwrap_or(from));
            t.mind.snapped = None;
            kind.after_tick(&mut t);
            leash::control_flags(&mut t);
        } else {
            kind.after_ai(&mut t);
            kind.after_tick(&mut t);
        }
        std::mem::take(&mut t.effects)
    } else if alive && kind.still() {
        let mut t = Turn::new(mob, id, ty.id, ai, dims, level, sensing, ctx.paths, kind);
        t.outside = outside;
        kind.after_ai(&mut t);
        kind.after_tick(&mut t);
        std::mem::take(&mut t.effects)
    } else {
        Vec::new()
    }
}

/// `playSwimSound(volume)`: pitched from the mob's random, louder for a
/// family that scales it.
fn swim(kind: &dyn Kind, motion: &kinds::KindMotion, t: &mut Turn, volume: f64) {
    if !motion.sounds() {
        return;
    }
    let a = t.float();
    let b = t.float();
    let pitch = f(1.0 + f(f(a - b) * f(0.4)));
    let monster = t
        .level
        .facts
        .entities
        .get(t.type_id)
        .is_some_and(|e| e.category == "monster");
    let name = kind.swim_sound().unwrap_or(if monster {
        "minecraft:entity.hostile.swim"
    } else {
        "minecraft:entity.generic.swim"
    });
    let volume = f(volume * kind.swim_volume());
    if let Some(id) = t.level.facts.sounds.id(name) {
        let seed = t.next_seed();
        let source = t.level.facts.combat.mob_sounds(t.type_id).source;
        t.effect(Effect::Sound {
            id,
            source,
            volume,
            pitch,
            seed,
        });
    }
}

/// `AI.move_sounds/2`: the move's splash into water (`checkFallDamage`'s),
/// `splash` its motion then, pitched from its mind's random, before the
/// rest of its tick.
pub fn move_sounds(ctx: &Ctx, mob: &mut NativeMob, splash: Option<[f64; 3]>) -> Vec<Effect> {
    let Some(velocity) = splash else {
        return Vec::new();
    };
    if !live(mob) {
        return Vec::new();
    }
    let Some(ty) = ctx.ty(mob) else {
        return Vec::new();
    };
    let Some(kind) = ctx.kinds.kind(ty.id) else {
        return Vec::new();
    };
    let [width, _, _] = living_body::dimensions(ctx.rules, ty, &mob.body);
    let facts = ctx.rules.facts;
    let Some(mind) = mob.body.mob.ai.as_mut() else {
        return Vec::new();
    };
    if let Some(state) = mind.state.as_mut() {
        state.wet = true;
    }
    let category = Some(ty.facts.category.as_str());
    let seed = mob_seed(&mob.uuid, mind.random.seed);
    let Some(mind) = mob.body.mob.ai.as_mut() else {
        return Vec::new();
    };
    splash_sound(
        facts,
        kind,
        ty.id,
        category,
        &mut mind.random,
        velocity,
        width,
    )
    .map(|e| with_seed(e, seed))
    .into_iter()
    .collect()
}

// A sound seed outside a turn (no gameplay reads it).
fn mob_seed(uuid: &Uuid, state: u64) -> i64 {
    let a = u64::from_be_bytes(uuid[0..8].try_into().unwrap_or([0; 8]));
    (a ^ state.rotate_left(17)).wrapping_mul(0x9E37_79B9_7F4A_7C15) as i64
}

/// `AI.hurt/3` on a mob's live mind (`combat::AiMind` runs it on hurts).
pub fn hurt(mob: &mut NativeMob, attacker: Option<Ref>, source: u16) {
    if let Some(s) = mob.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) {
        s.hurt(attacker, source);
    }
}
