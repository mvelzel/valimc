//! Oracle helpers of the vanilla stages that drive one native mob's body
//! (VMC-081d), built only with the `parity` feature: the physics kernel's
//! input of a record (`mob_oracle_body_kernel`), a shulker's lid opening
//! (`mob_oracle_body_opening`), a family hook run on a mob
//! of an oracle section over supplied cells, players and items
//! (`mob_oracle_body_turn`), and zombie traces through the kernel with the
//! living rules around each move (`mob_oracle_body_travel`).

use crate::mob_section::{self, MobSectionRes};
use crate::mob_term;
use crate::physics::{self as physics_nif, Vec3};
use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use valimc_core::mobs::ai::think;
use valimc_core::mobs::level::{Level, Unknown};
use valimc_core::mobs::model::{Control, NativeMob};
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::sensing::{Entity, GameMode, SensedItem, SensedPlayer, Sensing};
use valimc_core::mobs::term::{Map, Value, NIL};
use valimc_core::mobs::tick;
use valimc_core::mobs::vitals::{self, Moved};
use valimc_core::physics::source::BlockSource;
use valimc_core::physics::Aabb;

mod atoms {
    rustler::atoms! {
        tick_start, after_ai, settle_ageable, voice, items, can_attack, none,
    }
}

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

/// A scene's supplied cells; every other cell holds `air`.
struct Cells {
    states: HashMap<[i32; 3], u16>,
    air: u16,
}

impl BlockSource for Cells {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        Some(self.states.get(&[x, y, z]).copied().unwrap_or(self.air))
    }
}

fn int(v: &Value) -> NifResult<i64> {
    v.as_int().ok_or_else(bad)
}

fn number(v: &Value) -> NifResult<f64> {
    v.as_number().ok_or_else(bad)
}

fn vec3(v: &Value) -> NifResult<[f64; 3]> {
    match v {
        Value::Tuple(items) | Value::List(items) if items.len() == 3 => {
            Ok([number(&items[0])?, number(&items[1])?, number(&items[2])?])
        }
        _ => Err(bad()),
    }
}

fn uuid(v: &Value) -> NifResult<[u8; 16]> {
    v.as_binary()
        .and_then(|b| b.try_into().ok())
        .ok_or_else(bad)
}

fn list<'v>(scene: &'v Map, key: &str) -> NifResult<&'v [Value]> {
    match scene.get_atom(key) {
        None => Ok(&[]),
        Some(v) if v.is_nil() => Ok(&[]),
        Some(v) => v.as_list().ok_or_else(bad),
    }
}

fn field<'v>(map: &'v Map, key: &str) -> NifResult<&'v Value> {
    map.get_atom(key).ok_or_else(bad)
}

/// `cells` (`[x, y, z, state]` rows) over `air`.
fn cells(scene: &Map) -> NifResult<Cells> {
    let mut states = HashMap::new();
    for row in list(scene, "cells")? {
        let items = match row {
            Value::Tuple(items) | Value::List(items) if items.len() == 4 => items,
            _ => return Err(bad()),
        };
        let at = |i: usize| int(&items[i]).map(|v| v as i32);
        states.insert([at(0)?, at(1)?, at(2)?], int(&items[3])? as u16);
    }
    let air = match scene.get_atom("air") {
        Some(v) if !v.is_nil() => int(v)? as u16,
        _ => 0,
    };
    Ok(Cells { states, air })
}

/// A sensed player: `%{uuid, position, mode}` with optional `width` and
/// `height`.
fn player(v: &Value) -> NifResult<SensedPlayer> {
    let m = v.as_map().ok_or_else(bad)?;
    let mode = match field(m, "mode")?.as_atom().map(|a| a.as_str()) {
        Some("survival") => GameMode::Survival,
        Some("creative") => GameMode::Creative,
        Some("adventure") => GameMode::Adventure,
        Some("spectator") => GameMode::Spectator,
        _ => return Err(bad()),
    };
    let size = |key: &str, default: f64| m.get_atom(key).map_or(Ok(default), number);
    Ok(SensedPlayer {
        uuid: uuid(field(m, "uuid")?)?,
        id: 0,
        position: vec3(field(m, "position")?)?,
        yaw: 0.0,
        pitch: 0.0,
        eye: 1.62f32 as f64,
        width: size("width", 0.6)?,
        height: size("height", 1.8)?,
        mode,
        invulnerable: mode == GameMode::Creative,
        alive: true,
        crouching: false,
        swimming: false,
        invisible: false,
        armor_cover: 0.0,
        equipment: [None; 6],
        movement: [0.0; 3],
        velocity: [0.0; 3],
        health: 20.0,
        effects: Vec::new(),
    })
}

/// A sensed item: `%{uuid, position, count, pickup_delay, in_water}`.
fn item(v: &Value) -> NifResult<SensedItem> {
    let m = v.as_map().ok_or_else(bad)?;
    Ok(SensedItem {
        uuid: uuid(field(m, "uuid")?)?,
        position: vec3(field(m, "position")?)?,
        item: m.get_atom("item").map_or(Ok(0), int)? as i32,
        count: int(field(m, "count")?)? as i32,
        pickup_delay: int(field(m, "pickup_delay")?)? as i32,
        in_water: field(m, "in_water")?.as_bool().ok_or_else(bad)?,
        components: None,
    })
}

/// The physics kernel's input of the mob `record` holds at its position
/// (`tick::kernel_input` with its travel attributes), and the box it blocks
/// others with (a living shulker's), nil for the others: `{mob, box}`.
#[rustler::nif]
fn mob_oracle_body_kernel<'a>(env: Env<'a>, record: Term<'a>) -> NifResult<Term<'a>> {
    let rules = mob_section::rules()?;
    let families = mob_section::families(&rules)?;
    let mob = mob_section::restore(&mob_term::decode(record)?)?.map_err(|_| bad())?;
    let ty = rules.of(&mob.body.entity_type).ok_or_else(bad)?;
    let attributes = tick::travel_attributes(&rules, ty, &mob);
    let input = tick::kernel_input(&rules, &families, ty, &mob, attributes);
    let collider = families
        .kinds
        .kind(ty.id)
        .and_then(|kind| kind.collider(&mob.body, mob.position))
        .map(|b| (b[0], b[1], b[2], b[3], b[4], b[5]));
    Ok((physics_nif::mob_t(&input), collider).encode(env))
}

/// A shulker's lid opening from `previous` to `current` on its `face` at
/// `at` (`monsters::shulker::opening`): `{area, delta}`, nil while unchanged
/// or closing.
#[rustler::nif]
fn mob_oracle_body_opening(
    face: usize,
    previous: f64,
    current: f64,
    at: Vec3,
) -> Option<(physics_nif::BoxT, Vec3)> {
    valimc_core::mobs::monsters::shulker::opening(face, previous, current, physics_nif::v3(at))
        .map(|(a, d)| ((a[0], a[1], a[2], a[3], a[4], a[5]), physics_nif::t3(d)))
}

/// Runs `hook` on mob `id` of an oracle section (its mind made first) over
/// `scene`: `%{cells, air, border, players, items, random, inflate}`, each
/// optional (`random` seeds its mind's random first; `inflate` sets a
/// pufferfish's inflate counter, its deflate counter 0). Hooks:
/// `:tick_start` and `:after_ai` (its family's), `:settle_ageable`
/// (`AgeableMob.aiStep`), `:voice` (its voice pitch drawn from a copy of its
/// mind's random), `:items` (how many of the scene's items a dolphin would
/// play with), `:can_attack` (its family's test of the first player) and
/// `:none`. `{position, row, {width, height, eye}, effects, forced age
/// timer, answer}`, the dimensions the turn's after the hook.
#[rustler::nif]
fn mob_oracle_body_turn<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    hook: Atom,
    scene: Term<'a>,
) -> NifResult<Term<'a>> {
    use valimc_core::mobs::animals;
    use valimc_core::mobs::water::{dolphin, fish::PuffCounters};
    let rules = mob_section::rules()?;
    let ctx = mob_section::ctx(&rules)?;
    let physics = crate::facts::PHYSICS.get().ok_or_else(bad)?;
    let states = crate::facts::STATES.get().ok_or_else(bad)?;
    let scene = mob_term::decode(scene)?;
    let scene = scene.as_map().ok_or_else(bad)?;
    let blocks = cells(scene)?;
    let players = list(scene, "players")?
        .iter()
        .map(player)
        .collect::<NifResult<Vec<_>>>()?;
    let items = list(scene, "items")?
        .iter()
        .map(item)
        .collect::<NifResult<Vec<_>>>()?;
    let border = match scene.get_atom("border") {
        Some(v) if !v.is_nil() => {
            let b = v.as_tuple().filter(|b| b.len() == 4).ok_or_else(bad)?;
            Some([
                number(&b[0])?,
                number(&b[1])?,
                number(&b[2])?,
                number(&b[3])?,
            ])
        }
        _ => None,
    };
    let seed = scene.get_atom("random").map(int).transpose()?;
    let inflate = scene.get_atom("inflate").map(int).transpose()?;
    let mut inner = mob_section::owned(env, &res)?;
    let slot = inner.section.get_mut(id).ok_or_else(bad)?;
    think::ensure(&ctx, &mut slot.mob);
    if let (Some(seed), Some(mind)) = (seed, slot.mob.body.mob.ai.as_mut()) {
        mind.random = LegacyRandom::new(seed);
    }
    let mut level = Level::new(
        &blocks,
        &Unknown,
        rules.facts,
        physics,
        states,
        LegacyRandom::new(0),
    );
    level.border = border;
    let ran = think::on_turn(&ctx, &mut slot.mob, &mut level, |t, kind| {
        *t.sensing = Sensing::new(players, items, Vec::new());
        if let Some(inflate) = inflate {
            t.mind.own.family = Some(Box::new(PuffCounters {
                inflate,
                deflate: 0,
            }));
        }
        let answer = if hook == atoms::tick_start() {
            kind.tick_start(t);
            NIL
        } else if hook == atoms::after_ai() {
            kind.after_ai(t);
            NIL
        } else if hook == atoms::settle_ageable() {
            animals::settle_ageable(t);
            NIL
        } else if hook == atoms::voice() {
            let base = rules
                .of(&t.mob.body.entity_type)
                .map_or(1.0, |ty| rules.family(ty).voice(&t.mob.body));
            let mut random = t.random;
            Value::Float(random.voice_pitch(base) as f64)
        } else if hook == atoms::items() {
            Value::Int(dolphin::items(t).len() as i64)
        } else if hook == atoms::can_attack() {
            let hooks = t.hooks;
            let target = t.sensing.players.first().cloned();
            let (_, _, eyes) = t.split();
            Value::bool(target.is_some_and(|p| hooks.can_attack(&eyes, Entity::Player(&p))))
        } else {
            NIL
        };
        let effects = std::mem::take(&mut t.effects);
        (
            answer,
            [t.width, t.height, t.eye],
            effects,
            t.mind.forced_age_timer,
        )
    });
    let (answer, dims, effects, timer) = ran.ok_or_else(bad)?;
    slot.touched = true;
    let p = slot.mob.position;
    let row = mob_section::row(&rules, slot, true);
    inner.section.relocate(id);
    let effects = effects
        .iter()
        .filter_map(|e| crate::mob_section_level::effect(rules.facts, e))
        .map(|v| mob_term::encode(env, &v))
        .collect::<NifResult<Vec<_>>>()?;
    Ok((
        (p[0], p[1], p[2]),
        mob_term::encode(env, &row)?,
        (dims[0], dims[1], dims[2]),
        effects,
        timer,
        mob_term::encode(env, &answer)?,
    )
        .encode(env))
}

/// A move control's wanted position and speed, each tick.
type Target = Option<([f64; 3], f64)>;

/// Mobs (`[{record, target}]`, `target` nil or `{wanted, speed}`: what its
/// navigation asks of its move control every tick) ticking `ticks` times
/// through the kernel together over `view` (`physics::mob::tick_all`: every
/// mob's move, then each one's living rules): `baseTick`'s burning before
/// the move, the move applied, then `MobVitals.apply`'s contacts, landing
/// and air (whose hurts leave its health as `baseTick` left it). Per tick
/// per mob `{ticked, fire ticks}`, `ticked` as a mob ticker's step reports
/// it.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_oracle_body_travel<'a>(
    env: Env<'a>,
    view: Term<'a>,
    entries: Vec<(Term<'a>, Option<(Vec3, f64)>)>,
    ticks: usize,
) -> NifResult<Vec<Vec<Term<'a>>>> {
    let rules = mob_section::rules()?;
    let families = mob_section::families(&rules)?;
    let facts = physics_nif::facts()?;
    let mut mobs: Vec<(NativeMob, Target)> = Vec::with_capacity(entries.len());
    for (record, target) in entries {
        let mob = mob_section::restore(&mob_term::decode(record)?)?.map_err(|_| bad())?;
        mobs.push((mob, target.map(|(t, s)| (physics_nif::v3(t), s))));
    }
    let region = Aabb::new([-64.0, -64.0, -64.0], [64.0, 320.0, 64.0]);
    let view = physics_nif::view(view, facts, &region)?;
    let world = valimc_core::physics::player::World {
        source: &view,
        facts,
        border: None,
        entities: &[],
    };
    let mut out = Vec::with_capacity(ticks);
    for _ in 0..ticks {
        let mut inputs = Vec::with_capacity(mobs.len());
        for (mob, target) in &mut mobs {
            let motion = &mut mob.body.mob.motion;
            if let Some((wanted, speed)) = *target {
                motion.control = match motion.control {
                    Control::Jumping { .. } => Control::Jumping { speed },
                    _ => Control::MoveTo {
                        target: wanted,
                        speed,
                    },
                };
            }
            let ty = rules.of(&mob.body.entity_type).ok_or_else(bad)?;
            let attributes = tick::travel_attributes(&rules, ty, mob);
            inputs.push(tick::kernel_input(&rules, &families, ty, mob, attributes));
        }
        let results = valimc_core::physics::mob::tick_all(&world, &inputs, &[]);
        let mut row = Vec::with_capacity(mobs.len());
        for ((mob, _), result) in mobs.iter_mut().zip(results) {
            let t = result.map_err(|_| bad())?;
            vitals::base_tick(&rules, mob);
            let health = mob.body.mob.living.health.clone();
            tick::apply_ticked(mob, &t);
            vitals::apply(&rules, mob, &Moved::from(&t));
            mob.body.mob.living.health = health;
            row.push((physics_nif::ticked_t(&t), mob.body.mob.living.fire_ticks).encode(env));
        }
        out.push(row);
    }
    Ok(out)
}
