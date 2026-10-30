//! The dragon's brain as the Elixir keeps it in its body's `brain` field:
//! `%Valimc.AI.Dragon.Actor{}` holding `%Valimc.AI.Dragon.Phases{}` and
//! `%Valimc.AI.Dragon.Flight{}`, every field the term the Elixir writes
//! (integers where it keeps integers, floats where it keeps floats), so a
//! native dragon's record equals an Elixir one's.

use super::actor::Actor;
use super::flight::Flight;
use super::paths::Graph;
use super::phases::{PhaseEffect, Phases};
use crate::mobs::random::LegacyRandom;
use crate::mobs::term::{Map, Value, NIL};

pub const ACTOR: &str = "Elixir.Valimc.AI.Dragon.Actor";
pub const PHASES: &str = "Elixir.Valimc.AI.Dragon.Phases";
pub const FLIGHT: &str = "Elixir.Valimc.AI.Dragon.Flight";

fn opt_vec3(v: Option<[f64; 3]>) -> Value {
    Value::or_nil(v, Value::vec3)
}

fn binary(b: &Option<Vec<u8>>) -> Value {
    Value::or_nil(b.clone(), Value::Binary)
}

fn int(m: &Map, key: &str) -> Option<i64> {
    m.get_atom(key)?.as_int()
}

fn number(m: &Map, key: &str) -> Option<f64> {
    m.get_atom(key)?.as_number()
}

fn flag(m: &Map, key: &str) -> Option<bool> {
    m.get_atom(key)?.as_bool()
}

fn floats(v: &Value) -> Option<[f64; 3]> {
    let [x, y, z] = v.as_tuple_n::<3>()?;
    Some([x.as_number()?, y.as_number()?, z.as_number()?])
}

fn opt<T>(v: Option<&Value>, f: impl FnOnce(&Value) -> Option<T>) -> Option<Option<T>> {
    match v {
        None => Some(None),
        Some(v) if v.is_nil() => Some(None),
        Some(v) => f(v).map(Some),
    }
}

/// `%Flight{}`.
pub fn flight_value(flight: &Flight) -> Value {
    let history = match &flight.history {
        None => NIL,
        Some((head, samples)) => Value::tuple([
            Value::Int(*head),
            Value::Tuple(
                samples
                    .iter()
                    .map(|&(y, yaw)| Value::tuple([Value::Float(y), Value::Float(yaw)]))
                    .collect(),
            ),
        ]),
    };
    Value::Map(Map::from_atoms([
        ("__struct__", Value::atom(FLIGHT)),
        ("position", Value::vec3(flight.position)),
        ("velocity", Value::vec3(flight.velocity)),
        ("yaw", Value::Float(flight.yaw)),
        ("turn", Value::Float(flight.turn)),
        ("history", history),
        (
            "parts",
            Value::Tuple(flight.parts.iter().map(|&p| Value::vec3(p)).collect()),
        ),
    ]))
}

pub fn flight(v: &Value) -> Option<Flight> {
    if !v.is_struct(FLIGHT) {
        return None;
    }
    let m = v.as_map()?;
    let history = opt(m.get_atom("history"), |h| {
        let [head, samples] = h.as_tuple_n::<2>()?;
        let samples = samples
            .as_tuple()?
            .iter()
            .map(|s| {
                let [y, yaw] = s.as_tuple_n::<2>()?;
                Some((y.as_number()?, yaw.as_number()?))
            })
            .collect::<Option<Vec<_>>>()?;
        (samples.len() == 64).then_some((head.as_int()?, samples))
    })?;
    let parts = m.get_atom("parts")?.as_tuple()?;
    let mut out = [[0.0; 3]; 8];
    if parts.len() != 8 {
        return None;
    }
    for (o, p) in out.iter_mut().zip(parts) {
        *o = floats(p)?;
    }
    Some(Flight {
        position: floats(m.get_atom("position")?)?,
        velocity: floats(m.get_atom("velocity")?)?,
        yaw: number(m, "yaw")?,
        turn: number(m, "turn")?,
        history,
        parts: out,
    })
}

fn effect_value(e: &PhaseEffect) -> Value {
    match e {
        PhaseEffect::ScanCrystals => Value::atom("scan_crystals"),
        PhaseEffect::Health(v) => Value::tuple([Value::atom("health"), Value::Float(*v)]),
        PhaseEffect::Fireball { at, direction } => Value::Tuple(vec![
            Value::atom("fireball"),
            Value::vec3(*at),
            Value::vec3(*direction),
        ]),
        PhaseEffect::Flame(at) => Value::tuple([Value::atom("flame"), Value::vec3(*at)]),
        PhaseEffect::EndFlame => Value::atom("end_flame"),
    }
}

fn effect(v: &Value) -> Option<PhaseEffect> {
    if v.is_atom("scan_crystals") {
        return Some(PhaseEffect::ScanCrystals);
    }
    if v.is_atom("end_flame") {
        return Some(PhaseEffect::EndFlame);
    }
    let items = v.as_tuple()?;
    match items {
        [tag, value] if tag.is_atom("health") => Some(PhaseEffect::Health(value.as_number()?)),
        [tag, at] if tag.is_atom("flame") => Some(PhaseEffect::Flame(floats(at)?)),
        [tag, at, direction] if tag.is_atom("fireball") => Some(PhaseEffect::Fireball {
            at: floats(at)?,
            direction: floats(direction)?,
        }),
        _ => None,
    }
}

/// `%Phases{}`.
pub fn phases_value(p: &Phases) -> Value {
    let leaving = match p.leaving {
        None => NIL,
        Some((phase, target)) => Value::tuple([Value::Int(phase), opt_vec3(target)]),
    };
    let path = Value::or_nil(p.path.as_ref(), |path| {
        Value::List(path.iter().map(|&n| Value::ivec3(n)).collect())
    });
    let clockwise = Map::from_pairs(
        p.clockwise
            .iter()
            .map(|&(k, v)| (Value::Int(k), Value::bool(v)))
            .collect(),
    )
    .unwrap_or_default();
    Value::Map(Map::from_atoms([
        ("__struct__", Value::atom(PHASES)),
        ("phase", Value::Int(p.phase)),
        ("flight", flight_value(&p.flight)),
        ("random", Value::Int(p.random.seed as i64)),
        ("target", opt_vec3(p.target)),
        ("leaving", leaving),
        ("path", path),
        ("clockwise", Value::Map(clockwise)),
        ("ticks", Value::Int(p.ticks)),
        ("flames", Value::Int(p.flames)),
        ("attack", p.attack.clone().unwrap_or(NIL)),
        ("charge", Value::Int(p.charge)),
        ("first", Value::bool(p.first)),
        ("flame_live", Value::bool(p.flame_live)),
        ("head_yaw", Value::Float(p.head_yaw)),
        ("pitch", Value::Float(p.pitch)),
        (
            "effects",
            Value::List(p.effects.iter().map(effect_value).collect()),
        ),
    ]))
}

pub fn phases(v: &Value) -> Option<Phases> {
    if !v.is_struct(PHASES) {
        return None;
    }
    let m = v.as_map()?;
    let leaving = opt(m.get_atom("leaving"), |l| {
        let [phase, target] = l.as_tuple_n::<2>()?;
        Some((phase.as_int()?, opt(Some(target), floats)?))
    })?;
    let path = opt(m.get_atom("path"), |p| {
        p.as_list()?
            .iter()
            .map(Value::as_ivec3)
            .collect::<Option<Vec<_>>>()
    })?;
    let clockwise = m
        .get_atom("clockwise")?
        .as_map()?
        .iter()
        .map(|(k, v)| Some((k.as_int()?, v.as_bool()?)))
        .collect::<Option<Vec<_>>>()?;
    let random = u64::try_from(int(m, "random")?).ok()?;
    Some(Phases {
        phase: int(m, "phase")?,
        flight: flight(m.get_atom("flight")?)?,
        random: LegacyRandom::from_state(random)?,
        target: opt(m.get_atom("target"), floats)?,
        leaving,
        path,
        clockwise,
        ticks: int(m, "ticks")?,
        flames: int(m, "flames")?,
        attack: m.get_atom("attack").filter(|a| !a.is_nil()).cloned(),
        charge: int(m, "charge")?,
        first: flag(m, "first")?,
        flame_live: flag(m, "flame_live")?,
        head_yaw: number(m, "head_yaw")?,
        pitch: number(m, "pitch")?,
        effects: m
            .get_atom("effects")?
            .as_list()?
            .iter()
            .map(effect)
            .collect::<Option<Vec<_>>>()?,
    })
}

/// The graph term (`{{{x, y, z}, mask}, ...}`).
pub fn graph_value(graph: &Graph) -> Value {
    Value::Tuple(
        graph
            .iter()
            .map(|&(at, mask)| Value::tuple([Value::ivec3(at), Value::Int(mask)]))
            .collect(),
    )
}

pub fn graph(v: &Value) -> Option<Graph> {
    let nodes = v
        .as_tuple()?
        .iter()
        .map(|n| {
            let [at, mask] = n.as_tuple_n::<2>()?;
            Some((at.as_ivec3()?, mask.as_int()?))
        })
        .collect::<Option<Graph>>()?;
    (nodes.len() == 24).then_some(nodes)
}

/// `%Actor{}`.
pub fn actor_value(a: &Actor) -> Value {
    Value::Map(Map::from_atoms([
        ("__struct__", Value::atom(ACTOR)),
        ("phases", phases_value(&a.phases)),
        ("tick", Value::Int(a.tick)),
        ("ambient", Value::Int(a.ambient)),
        ("body_yaw", Value::Float(a.body_yaw)),
        ("stable_head", Value::Float(a.stable_head)),
        ("stable_time", Value::Int(a.stable_time)),
        ("wall", Value::bool(a.wall)),
        ("crystal", binary(&a.crystal)),
        ("flame", binary(&a.flame)),
        ("graph", Value::or_nil(a.graph.as_ref(), graph_value)),
        ("world_tick", Value::or_nil(a.world_tick, Value::Int)),
    ]))
}

pub fn actor(v: &Value) -> Option<Actor> {
    if !v.is_struct(ACTOR) {
        return None;
    }
    let m = v.as_map()?;
    let bytes = |key: &str| opt(m.get_atom(key), |b| b.as_binary().map(<[u8]>::to_vec));
    Some(Actor {
        phases: phases(m.get_atom("phases")?)?,
        tick: int(m, "tick")?,
        ambient: int(m, "ambient")?,
        body_yaw: number(m, "body_yaw")?,
        stable_head: number(m, "stable_head")?,
        stable_time: int(m, "stable_time")?,
        wall: flag(m, "wall")?,
        crystal: bytes("crystal")?,
        flame: bytes("flame")?,
        graph: opt(m.get_atom("graph"), graph)?,
        world_tick: opt(m.get_atom("world_tick"), Value::as_int)?,
    })
}

/// What a body's `brain` holds: an actor, phases alone (an older brain), or
/// nothing it knows.
pub enum Brain {
    Actor(Box<Actor>),
    Phases(Box<Phases>),
    None,
}

pub fn brain(v: Option<&Value>) -> Brain {
    match v {
        Some(v) if v.is_struct(ACTOR) => {
            actor(v).map_or(Brain::None, |a| Brain::Actor(Box::new(a)))
        }
        Some(v) if v.is_struct(PHASES) => {
            phases(v).map_or(Brain::None, |p| Brain::Phases(Box::new(p)))
        }
        _ => Brain::None,
    }
}
