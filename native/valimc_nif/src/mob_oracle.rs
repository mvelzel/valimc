//! Helpers of the vanilla stages' native modes (VMC-081d), built only with
//! the `parity` feature: what the stages compare of a mob's mind and brain
//! (`mind_own`, `brain`), events as the owner takes them, and the scene
//! terms' difficulties and game modes.

use crate::mob_term;
use rustler::types::map::map_new;
use rustler::{Encoder, Env, NifResult, Term};
use valimc_core::mobs::ai::mind::MindState;
use valimc_core::mobs::animals::rabbit::HopState;
use valimc_core::mobs::combat::{Event, SoundRef};
use valimc_core::mobs::facts::MobFacts;
use valimc_core::mobs::sensing::{Kind, Ref};
use valimc_core::mobs::term::{Value, NIL};

mod atoms {
    rustler::atoms! {
        nil, player, mob, item, anger_end, anger_target, away, maybe, hurt, y_rot,
        jump_delay, aggressive, wanted, jump_ticks, jump_duration, was_on_ground, can_jump,
    }
}

pub(crate) fn reference<'a>(env: Env<'a>, r: &Ref) -> Term<'a> {
    let kind = match r.kind {
        Kind::Player => atoms::player(),
        Kind::Mob => atoms::mob(),
        Kind::Item => atoms::item(),
    };
    (kind, crate::binary(env, &r.uuid)).encode(env)
}

pub(crate) fn cell(c: [i32; 3]) -> (i32, i32, i32) {
    (c[0], c[1], c[2])
}

/// A mind's own fields as the Elixir's `own` map: nil when nothing was
/// kept; a neutral mob's anger (`anger_end`, `anger_target`) and a family's
/// own fields.
fn own<'a>(env: Env<'a>, own: &valimc_core::mobs::ai::mind::Own) -> NifResult<Term<'a>> {
    use valimc_core::mobs::monsters::cube::CubeOwn;
    use valimc_core::mobs::monsters::enderman::{EndermanOwn, Reaction};
    if own.is_empty() {
        return Ok(atoms::nil().encode(env));
    }
    let mut map = map_new(env);
    if let Some(o) = own.family::<valimc_core::mobs::brains::axolotl::AxolotlOwn>() {
        map = map.map_put(rustler::Atom::from_str(env, "find_liquid")?, o.find_liquid)?;
    }
    if let Some(anger) = &own.anger {
        let target = anger
            .target
            .as_ref()
            .map_or(atoms::nil().encode(env), |r| reference(env, r));
        map = map.map_put(atoms::anger_end(), anger.end)?;
        map = map.map_put(atoms::anger_target(), target)?;
    }
    if let Some(o) = own.family::<CubeOwn>() {
        map = map.map_put(atoms::y_rot(), o.y_rot)?;
        map = map.map_put(atoms::jump_delay(), o.jump_delay)?;
        map = map.map_put(atoms::aggressive(), o.aggressive)?;
        let wanted = o.wanted.map_or(atoms::nil().encode(env), |w| w.encode(env));
        map = map.map_put(atoms::wanted(), wanted)?;
    }
    let put = |map: Term<'a>, k: &str, v: &Value| -> NifResult<Term<'a>> {
        map.map_put(rustler::Atom::from_str(env, k)?, mob_term::encode(env, v)?)
    };
    for (k, v) in family_own(own) {
        map = put(map, k, &v)?;
    }
    if let Some(o) = own.family::<EndermanOwn>() {
        if let Some(reaction) = o.hurt {
            let reaction = match reaction {
                Reaction::Away => atoms::away(),
                Reaction::Maybe => atoms::maybe(),
            };
            map = map.map_put(atoms::hurt(), reaction)?;
        }
    }
    Ok(map)
}

/// The own fields of the families that keep them as optional keys, as
/// `(key, value)` (an absent key is one the Elixir map lacks).
fn family_own(own: &valimc_core::mobs::ai::mind::Own) -> Vec<(&'static str, Value)> {
    use valimc_core::mobs::monsters::blaze::BlazeOwn;
    use valimc_core::mobs::monsters::shulker::{Reaction, ShulkerOwn};
    use valimc_core::mobs::monsters::silverfish::SilverfishOwn;
    use valimc_core::mobs::monsters::zombified_piglin::PiglinOwn;
    use valimc_core::mobs::village::iron_golem::GolemOwn;
    let mut out = Vec::new();
    let mut opt = |k: &'static str, v: Option<i64>| {
        if let Some(v) = v {
            out.push((k, Value::Int(v)));
        }
    };
    if let Some(o) = own.family::<PiglinOwn>() {
        opt("first_sound", o.first_sound);
        opt("next_alert", o.next_alert);
    }
    if let Some(o) = own.family::<SilverfishOwn>() {
        opt("friends", o.friends);
    }
    if let Some(o) = own.family::<GolemOwn>() {
        opt("attack", o.attack);
        opt("flower", o.flower);
    }
    if let Some(o) = own.family::<ShulkerOwn>() {
        if let Some(r) = o.hurt {
            let r = match r {
                Reaction::Teleport => "teleport",
                Reaction::Bullet => "bullet",
            };
            out.push(("hurt", Value::atom(r)));
        }
    }
    if let Some(o) = own.family::<BlazeOwn>() {
        out.push(("offset", Value::Float(o.offset)));
        out.push(("next_change", Value::Int(o.next_change)));
        out.push(("charged", Value::bool(o.charged)));
    }
    water_own(own, &mut out);
    animal_own(own, &mut out);
    out
}

/// The animals' own fields beyond the shared ones (a turtle's).
fn animal_own(own: &valimc_core::mobs::ai::mind::Own, out: &mut Vec<(&'static str, Value)>) {
    use valimc_core::mobs::animals::turtle::TurtleOwn;
    if let Some(o) = own.family::<TurtleOwn>() {
        out.push(("going_home", Value::bool(o.going_home)));
        let travel = o.travel.map_or(Value::atom("nil"), |[x, y, z]| {
            Value::ivec3([x as i64, y as i64, z as i64])
        });
        out.push(("travel", travel));
        out.push(("lay", Value::Int(o.lay)));
    }
}

/// The water families' own fields (`Mobs.Fish`' school, a pufferfish's
/// counters).
fn water_own(own: &valimc_core::mobs::ai::mind::Own, out: &mut Vec<(&'static str, Value)>) {
    use valimc_core::mobs::water::fish::{PuffCounters, School};
    use valimc_core::mobs::water::guardian::GuardianOwn;
    use valimc_core::mobs::water::squid::SquidOwn;
    if let Some(o) = own.family::<GuardianOwn>() {
        let refs = o
            .thorns
            .iter()
            .map(|r| {
                let kind = match r.kind {
                    Kind::Player => "player",
                    Kind::Mob => "mob",
                    Kind::Item => "item",
                };
                Value::Tuple(vec![
                    Value::Atom(valimc_core::mobs::term::Atom::new(kind)),
                    Value::Binary(r.uuid.to_vec()),
                ])
            })
            .collect();
        out.push(("thorns", Value::List(refs)));
    }
    if let Some(o) = own.family::<SquidOwn>() {
        out.push(("tentacle", Value::Float(o.tentacle)));
        out.push(("tentacle_speed", Value::Float(o.tentacle_speed)));
        out.push(("rotate_speed", Value::Float(o.rotate_speed)));
        out.push(("x_rot", Value::Float(o.x_rot)));
        out.push(("z_rot", Value::Float(o.z_rot)));
        out.push(("movement", Value::vec3(o.movement)));
        out.push(("in_water", Value::bool(o.in_water)));
    }
    if let Some(o) = own.family::<School>() {
        let leader = o
            .leader
            .map_or(Value::atom("nil"), |u| Value::Binary(u.to_vec()));
        out.push(("leader", leader));
        out.push(("school", Value::Int(o.school)));
    }
    if let Some(o) = own.family::<PuffCounters>() {
        out.push(("inflate", Value::Int(o.inflate)));
        out.push(("deflate", Value::Int(o.deflate)));
    }
}

/// A mind's own state as the Elixir's `own` (a bat's spot, a rabbit's
/// hops, a family's fields), for the oracle stages' native modes too.
pub(crate) fn mind_own<'a>(env: Env<'a>, s: &MindState) -> NifResult<Term<'a>> {
    let bat = s
        .own
        .family::<valimc_core::mobs::ambient::bat::BatSpot>()
        .map(|b| cell(b.0));
    Ok(match s.own.family::<HopState>() {
        // A bat's spot is its own state itself, a tuple.
        None if bat.is_some() => bat.encode(env),
        None => own(env, &s.own)?,
        Some(h) => {
            let mut map = map_new(env);
            for (k, v) in [
                (atoms::jump_ticks(), h.jump_ticks.encode(env)),
                (atoms::jump_duration(), h.jump_duration.encode(env)),
                (atoms::was_on_ground(), h.was_on_ground.encode(env)),
                (atoms::jump_delay(), h.jump_delay.encode(env)),
                (atoms::can_jump(), h.can_jump.encode(env)),
            ] {
                map = map.map_put(k, v)?;
            }
            map
        }
    })
}

/// A brain as the harness views it: `{[{name, value, ttl}], active,
/// running, sensor countdowns}`, the memories by name.
pub(crate) fn brain<'a>(
    env: Env<'a>,
    brain: Option<&valimc_core::mobs::ai::brain::Brain>,
) -> NifResult<Term<'a>> {
    use valimc_core::mobs::ai::brain;
    let Some(b) = brain else {
        return Ok(atoms::nil().encode(env));
    };
    let facts = crate::mob_facts::facts()?;
    let mut memories = b
        .memories
        .0
        .iter()
        .map(|(m, slot)| (m.name(), slot))
        .collect::<Vec<_>>();
    memories.sort_by_key(|(name, _)| *name);
    let memories = memories
        .into_iter()
        .map(|(name, (value, ttl))| {
            let ttl = match ttl {
                None => rustler::Atom::from_str(env, "never")?.encode(env),
                Some(t) => t.encode(env),
            };
            Ok((
                name,
                mob_term::encode(env, &brain::value(value, Some(facts)))?,
                ttl,
            )
                .encode(env))
        })
        .collect::<NifResult<Vec<Term>>>()?;
    let active = b
        .active
        .iter()
        .map(|a| rustler::Atom::from_str(env, a.name()))
        .collect::<NifResult<Vec<_>>>()?;
    let sensors: Vec<i32> = b.sensors.iter().map(|s| s.time).collect();
    Ok((memories, active, b.running(), sensors).encode(env))
}

pub(crate) fn event(facts: &MobFacts, e: &Event) -> Value {
    let int = |i: Option<i32>| i.map_or(NIL, |i| Value::Int(i as i64));
    match e {
        Event::Entity(n) => Value::tuple([Value::atom("event"), Value::Int(*n as i64)]),
        Event::Damage {
            source,
            cause,
            direct,
        } => Value::Tuple(vec![
            Value::atom("damage"),
            atom(damage_name(facts, *source)),
            int(*cause),
            int(*direct),
            NIL,
        ]),
        Event::Killed => Value::tuple([Value::atom("damage"), Value::atom("generic_kill")]),
        Event::Sound {
            sound,
            source,
            volume,
            pitch,
        } => Value::Tuple(vec![
            Value::atom("sound"),
            match sound {
                SoundRef::Name(n) => Value::Binary(n.as_bytes().to_vec()),
                SoundRef::Id(i) => Value::Int(*i as i64),
            },
            Value::Int(*source as i64),
            Value::Float(*volume),
            Value::Float(*pitch),
            Value::Int(0),
        ]),
        Event::Other(v) => v.clone(),
    }
}

fn atom(name: &str) -> Value {
    Value::Atom(valimc_core::mobs::term::Atom::new(name))
}

fn damage_name(facts: &MobFacts, id: u16) -> &str {
    let name = &facts.damage_types.types[id as usize].name;
    name.strip_prefix("minecraft:").unwrap_or(name)
}
