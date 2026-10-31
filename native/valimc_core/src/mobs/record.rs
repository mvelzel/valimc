//! The record codec of a native mob (VMC-081d): `record` builds the term
//! `Valimc.Entity.Store` saves for a mob's entry (`%{kind: :mob, uuid, x,
//! y, z}` merged with `Body.record/1`, plus `hops` when above 0), and
//! `restore` reads what `Body.restore/1` (with `Mob.restore/2`,
//! `Living.restore/1`, `Health.restore/2` and the store's entry checks)
//! accepts, with the same validation, defaults and normalisations (health
//! clamped to the type's maximum, absorption to its effect's, a leash
//! restored to look for its holder, `hurt_by_player` dropped without
//! memory) and the dolphin/squid `restore_data` migration. A record the
//! Elixir side builds (a fresh, spawned or generated mob) and one a native
//! mob writes are the same terms, so logs, checkpoints, handoff digests
//! (`term_to_binary(_, [:deterministic])`) and exports read alike.
//!
//! What it needs to know of types (whether one exists and is living, its
//! `max_health` default, its family data's key set) and of effects comes in
//! `RecordFacts`.
//!
//! The native model is typed, so a few records Elixir accepts but no
//! Elixir code writes are refused as `Unsupported` rather than carried
//! loosely: integers past a Java `int` in int fields, fields Elixir does
//! not check holding other shapes than its code writes (a `MobMotion`'s
//! `eye`, `set`, `pre_move`, `impulse`, `travel`, `support`; attribute
//! modifiers), a `%MobMotion{}` lacking a current field, extra keys in a
//! mind record, an attribute override, a hop or a float control. An integer
//! entry coordinate (Elixir accepts any number) is read as a float and
//! written back as one.

use std::collections::HashMap;
use std::hash::Hasher;

use super::model::*;
use super::random::LegacyRandom;
use super::term::{Atom, Map, Value};

const MOB_MOTION: &str = "Elixir.Valimc.Entity.MobMotion";
const ITEM_STACK: &str = "Elixir.Valimc.Protocol.ItemStack";
const FLOAT_MAX: f64 = 3.4028234663852886e38;
const RANDOM_MASK: i64 = (1 << 48) - 1;
const PLAYER_MEMORY: i64 = 100;

/// What the codec knows of entity types and effects.
#[derive(Clone, Debug, Default)]
pub struct RecordFacts {
    types: HashMap<String, TypeFacts>,
    /// The number of status effect types (`EffectTypes.count/0`): ids are
    /// below it.
    pub effect_count: i32,
    /// Absorption's effect id.
    pub absorption_effect: i32,
    /// `minecraft:max_absorption`'s maximum.
    pub max_absorption: f64,
}

/// What a record needs of one entity type.
#[derive(Clone, Debug, PartialEq)]
pub struct TypeFacts {
    /// `EntityTypes.living?/1`: a mob type.
    pub living: bool,
    /// Its `minecraft:max_health` default (the type's, else the
    /// attribute's).
    pub max_health: f64,
    /// The keys of its family data (`Body.data/1`), any order.
    pub data_keys: Vec<Atom>,
}

impl RecordFacts {
    pub fn new(effect_count: i32, absorption_effect: i32, max_absorption: f64) -> RecordFacts {
        RecordFacts {
            types: HashMap::new(),
            effect_count,
            absorption_effect,
            max_absorption,
        }
    }

    /// Adds entity type `name`.
    pub fn insert_type(&mut self, name: &str, mut facts: TypeFacts) {
        facts
            .data_keys
            .sort_by(|a, b| a.as_str().as_bytes().cmp(b.as_str().as_bytes()));
        self.types.insert(name.to_owned(), facts);
    }

    pub fn entity_type(&self, name: &str) -> Option<&TypeFacts> {
        self.types.get(name)
    }
}

/// Why a record was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordError {
    /// Elixir refuses it too: the store entry (`Store.valid_record?`), the
    /// body (`{:error, :invalid_body}`) or its mob (`:invalid_mob`); the
    /// text names the check.
    Invalid(&'static str),
    /// Elixir would accept it, but its shape is one no Elixir code writes
    /// and the native model does not represent (see the module docs).
    Unsupported(&'static str),
}

type Result<T> = std::result::Result<T, RecordError>;

fn invalid<T>(what: &'static str) -> Result<T> {
    Err(RecordError::Invalid(what))
}

fn check(ok: bool, what: &'static str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        invalid(what)
    }
}

fn unsupported<T>(what: &'static str) -> Result<T> {
    Err(RecordError::Unsupported(what))
}

/// `(float) value` as a double.
fn f32r(value: f64) -> f64 {
    value as f32 as f64
}

/// `erlang:max/2` and `min/2` on numbers: the first argument when equal.
fn erl_max(a: f64, b: f64) -> f64 {
    if a < b {
        b
    } else {
        a
    }
}

fn erl_min(a: f64, b: f64) -> f64 {
    if a > b {
        b
    } else {
        a
    }
}

fn int32(value: i64, what: &'static str) -> Result<i32> {
    i32::try_from(value).or_else(|_| unsupported(what))
}

// ---------------------------------------------------------------- record

/// The store record of `mob` (`Store.record/1` of its entry).
pub fn record(mob: &NativeMob) -> Value {
    record_with(mob, true)
}

/// `record/1` without its travel fields (`RegionStorage.travelled/1`'s:
/// position, rotation, velocity, ground, and the mob's motion and mind).
/// Only the tests use it: a cut hashes the same fields in place
/// (`hash_stationary`).
#[cfg(test)]
pub fn stationary(mob: &NativeMob) -> Value {
    record_with(mob, false)
}

/// The family data fields that count ticks (`AgeableMob`'s age and love,
/// a chicken's egg timer, a zombie's or skeleton's time in water or powder
/// snow, a conversion, an enderman's stare timers, a glow squid's dark
/// ticks, a dolphin's moisture, a trader's despawn delay, a creeper's
/// swell): a settled hash (`hash_stationary` with `settled`) keeps only
/// their sign.
pub const COUNTERS: [&str; 13] = [
    "age",
    "conversion",
    "dark",
    "despawn_delay",
    "egg_time",
    "in_love",
    "in_snow",
    "in_water",
    "moistness",
    "swell",
    "target_time",
    "ticks",
    "using_time",
];

/// Hashes exactly what `stationary/1` would hold, from the mob in place
/// (no term is built): two mobs hash alike when their stationary records
/// are equal by Elixir's `==` (numbers by value). A cut compares this with
/// what the last frame wrote to learn whether a change may wait for the
/// motion pass, for every mob that changed, so it must stay cheap. With
/// `settled`, the counters that move every tick (hurt, death, fire, air,
/// freezing and effect ticks, the portal cooldown, the player memory, a
/// held item's use, the data's `COUNTERS`) count only by their sign, as an
/// item's age and a furnace's burn do (`RegionStorage.wait/4`): a change of
/// them alone may wait, one crossing zero may not. Keep it field for field
/// with `record_with`; `stationary_hash_follows_the_record` checks each
/// field.
pub fn hash_stationary<H: Hasher>(mob: &NativeMob, settled: bool, h: &mut H) {
    let counter = |n: i64| if settled { n.signum() } else { n };
    let body = &mob.body;
    h.write(&mob.uuid);
    h.write(body.entity_type.as_bytes());
    h.write_u8(0xff);
    h.write_u8(body.no_gravity as u8);
    let fields = body.data.fields();
    h.write_usize(fields.len());
    for (k, v) in fields {
        h.write(k.as_str().as_bytes());
        h.write_u8(0xff);
        match v {
            Value::Int(n) if settled && COUNTERS.contains(&k.as_str()) => {
                hash_value(&Value::Int(n.signum()), h)
            }
            v => hash_value(v, h),
        }
    }
    match body.custom_name.as_ref().filter(|n| n.truthy()) {
        Some(name) => {
            h.write_u8(1);
            hash_value(name, h);
        }
        None => h.write_u8(0),
    }
    match &body.preserved {
        Some(p) => {
            h.write_u8(1);
            h.write_usize(p.len());
            h.write(p);
        }
        None => h.write_u8(0),
    }
    h.write_i64(counter(body.portal_cooldown.max(0).into()));
    h.write_u64(mob.hops);
    let m = &body.mob;
    let living = &m.living;
    hash_float(f32r(living.health.value), h);
    h.write_i64(counter(living.health.hurt_ticks.into()));
    h.write_i64(counter(living.health.death_ticks.into()));
    hash_float(living.absorption, h);
    h.write_usize(living.effects.0.len());
    for (id, rungs) in &living.effects.0 {
        h.write_i32(*id);
        h.write_usize(rungs.len());
        for r in rungs {
            h.write_i64(counter(r.ticks.into()));
            h.write_u8(r.amplifier);
            h.write_u8(r.ambient as u8 | (r.particles as u8) << 1 | (r.icon as u8) << 2);
        }
    }
    h.write_i64(counter(living.fire_ticks.into()));
    h.write_i64(counter(living.air_supply.into()));
    h.write_i64(counter(living.freezing.frozen_ticks.into()));
    for stack in m.equipment.slots() {
        match stack {
            Some(v) => {
                h.write_u8(1);
                hash_value(v, h);
            }
            None => h.write_u8(0),
        }
    }
    h.write_usize(m.attributes.0.len());
    for (id, entry) in m.attributes.0.iter() {
        h.write(id.as_bytes());
        h.write_u8(0xff);
        match entry.base {
            Some(b) => {
                h.write_u8(1);
                hash_float(b, h);
            }
            None => h.write_u8(0),
        }
        h.write_usize(entry.modifiers.len());
        for md in &entry.modifiers {
            h.write(md.id.as_bytes());
            h.write_u8(0xff);
            match md.amount {
                Number::Int(i) => hash_number(i as f64, Some(i), h),
                Number::Float(f) => hash_number(f, None, h),
            }
            h.write_i32(md.operation);
        }
    }
    h.write_u8(m.no_ai as u8);
    match &m.hurt_by_player {
        Some(uuid) => {
            h.write_u8(1);
            h.write(uuid);
        }
        None => h.write_u8(0),
    }
    h.write_i64(counter(m.player_memory.into()));
    h.write_u8(m.persistent as u8 | (m.left_handed as u8) << 1 | (m.can_pick_up_loot as u8) << 2);
    for chance in &m.drop_chances.0 {
        match chance {
            Some(c) => {
                h.write_u8(1);
                hash_float(*c, h);
            }
            None => h.write_u8(0),
        }
    }
    match &m.finalize {
        Some(reason) => {
            h.write_u8(1);
            h.write(reason.as_str().as_bytes());
            h.write_u8(0xff);
        }
        None => h.write_u8(0),
    }
    match m.leash.as_ref().map(|l| &l.holder) {
        Some(LeashHolder::Player(uuid)) => {
            h.write_u8(1);
            h.write(uuid);
        }
        Some(LeashHolder::Knot([x, y, z])) => {
            h.write_u8(2);
            h.write_i32(*x);
            h.write_i32(*y);
            h.write_i32(*z);
        }
        None => h.write_u8(0),
    }
    match &m.home {
        Some(home) => {
            h.write_u8(1);
            home.center.iter().for_each(|c| h.write_i32(*c));
            h.write_i32(home.radius);
        }
        None => h.write_u8(0),
    }
    match &m.using {
        Some(using) => {
            h.write_u8(1);
            h.write(using.hand.name().as_bytes());
            h.write_i64(counter(using.ticks.into()));
        }
        None => h.write_u8(0),
    }
}

/// Hashing as Elixir's `==` compares: integers and floats by value (`1 ==
/// 1.0`, `0.0 == -0.0`), everything else exactly.
pub fn hash_value<H: Hasher>(v: &Value, h: &mut H) {
    match v {
        Value::Atom(a) => {
            h.write_u8(1);
            h.write(a.as_str().as_bytes());
            h.write_u8(0xff);
        }
        Value::Int(i) => hash_number(*i as f64, Some(*i), h),
        Value::Float(f) => hash_number(*f, None, h),
        Value::Binary(b) => {
            h.write_u8(3);
            h.write_usize(b.len());
            h.write(b);
        }
        Value::List(items) => {
            h.write_u8(4);
            h.write_usize(items.len());
            items.iter().for_each(|i| hash_value(i, h));
        }
        Value::Tuple(items) => {
            h.write_u8(5);
            h.write_usize(items.len());
            items.iter().for_each(|i| hash_value(i, h));
        }
        Value::Map(m) => {
            h.write_u8(6);
            h.write_usize(m.len());
            for (k, v) in m.iter() {
                hash_value(k, h);
                hash_value(v, h);
            }
        }
        Value::Opaque(b) => {
            h.write_u8(7);
            h.write(b);
        }
    }
}

fn hash_float<H: Hasher>(f: f64, h: &mut H) {
    hash_number(f, None, h)
}

fn hash_number<H: Hasher>(f: f64, int: Option<i64>, h: &mut H) {
    h.write_u8(2);
    // An integer too large for a double compares by its own value.
    match int {
        Some(i) if (i as f64) as i64 != i || i.unsigned_abs() > 1 << 53 => {
            h.write_u8(1);
            h.write_i64(i);
        }
        _ => {
            h.write_u8(0);
            let f = if f == 0.0 { 0.0 } else { f };
            h.write_u64(f.to_bits());
        }
    }
}

fn record_with(mob: &NativeMob, travel: bool) -> Value {
    let body = &mob.body;
    let mut record = Map::with_capacity(16);
    record.insert_atom("kind", Value::atom("mob"));
    record.insert_atom("uuid", Value::Binary(mob.uuid.to_vec()));
    if travel {
        record.insert_atom("x", Value::Float(mob.position[0]));
        record.insert_atom("y", Value::Float(mob.position[1]));
        record.insert_atom("z", Value::Float(mob.position[2]));
    }
    record.insert_atom("type", Value::Binary(body.entity_type.as_bytes().to_vec()));
    if travel {
        record.insert_atom(
            "rotation",
            Value::tuple([
                Value::Float(body.yaw),
                Value::Float(body.pitch),
                Value::Float(body.head_yaw),
            ]),
        );
        record.insert_atom("velocity", Value::vec3(body.velocity));
        record.insert_atom("on_ground", Value::bool(body.on_ground));
    }
    record.insert_atom("no_gravity", Value::bool(body.no_gravity));
    record.insert_atom("data", data_record(&body.data));
    if let Some(name) = body.custom_name.as_ref().filter(|n| n.truthy()) {
        record.insert_atom("custom_name", name.clone());
    }
    if let Some(preserved) = &body.preserved {
        record.insert_atom("preserved", Value::Binary(preserved.clone()));
    }
    if body.portal_cooldown > 0 {
        record.insert_atom("portal_cooldown", Value::Int(body.portal_cooldown.into()));
    }
    record.insert_atom("mob", mob_record(&body.mob, travel));
    if mob.hops > 0 {
        record.insert_atom("hops", Value::Int(mob.hops as i64));
    }
    Value::Map(record)
}

fn data_record(data: &FamilyData) -> Value {
    let pairs = data
        .fields()
        .iter()
        .map(|(k, v)| (Value::Atom(k.clone()), v.clone()))
        .collect();
    Value::Map(Map::from_pairs(pairs).expect("family data keys are distinct"))
}

/// `Mob.record/1`.
fn mob_record(mob: &Mob, travel: bool) -> Value {
    let mut record = Map::with_capacity(16);
    record.insert_atom("living", living_record(&mob.living));
    record.insert_atom("equipment", equipment_record(&mob.equipment));
    record.insert_atom("attributes", attributes_record(&mob.attributes));
    if travel {
        record.insert_atom("ai", Value::or_nil(mob.ai.as_ref(), mind_record));
    }
    record.insert_atom("no_ai", Value::bool(mob.no_ai));
    if travel {
        record.insert_atom("motion", motion_record(&mob.motion));
    }
    record.insert_atom(
        "hurt_by_player",
        Value::or_nil(mob.hurt_by_player, |uuid| Value::Binary(uuid.to_vec())),
    );
    record.insert_atom("player_memory", Value::Int(mob.player_memory.into()));
    if mob.persistent {
        record.insert_atom("persistent", Value::bool(true));
    }
    if mob.left_handed {
        record.insert_atom("left_handed", Value::bool(true));
    }
    if mob.can_pick_up_loot {
        record.insert_atom("can_pick_up_loot", Value::bool(true));
    }
    if !mob.drop_chances.is_empty() {
        let pairs = Slot::ALL
            .into_iter()
            .filter_map(|slot| {
                let chance = mob.drop_chances.get(slot)?;
                Some((Value::atom(slot.name()), Value::Float(chance)))
            })
            .collect();
        record.insert_atom("drop_chances", Value::Map(Map::from_pairs(pairs).unwrap()));
    }
    if let Some(reason) = &mob.finalize {
        record.insert_atom("finalize", Value::Atom(reason.clone()));
    }
    if let Some(leash) = &mob.leash {
        let holder = match &leash.holder {
            LeashHolder::Player(uuid) => {
                Value::tuple([Value::atom("player"), Value::Binary(uuid.to_vec())])
            }
            LeashHolder::Knot([x, y, z]) => Value::tuple([
                Value::atom("knot"),
                Value::ivec3([(*x).into(), (*y).into(), (*z).into()]),
            ]),
        };
        record.insert_atom("leash", Map::from_atoms([("holder", holder)]).into());
    }
    if let Some(home) = &mob.home {
        let [x, y, z] = home.center;
        record.insert_atom(
            "home",
            Value::tuple([
                Value::ivec3([x.into(), y.into(), z.into()]),
                Value::Int(home.radius.into()),
            ]),
        );
    }
    if let Some(using) = &mob.using {
        record.insert_atom(
            "using",
            Value::tuple([
                Value::atom(using.hand.name()),
                Value::Int(using.ticks.into()),
            ]),
        );
    }
    Value::Map(record)
}

/// `Living.saved/1`.
fn living_record(living: &Living) -> Value {
    let health = Map::from_atoms([
        ("value", Value::Float(f32r(living.health.value))),
        ("hurt_ticks", Value::Int(living.health.hurt_ticks.into())),
        ("death_ticks", Value::Int(living.health.death_ticks.into())),
    ]);
    Map::from_atoms([
        ("health", health.into()),
        ("absorption", Value::Float(living.absorption)),
        ("effects", effects_record(&living.effects)),
        ("fire_ticks", Value::Int(living.fire_ticks.into())),
        ("air_supply", Value::Int(living.air_supply.into())),
        (
            "frozen_ticks",
            Value::Int(living.freezing.frozen_ticks.into()),
        ),
    ])
    .into()
}

fn effects_record(effects: &Effects) -> Value {
    let pairs = effects
        .0
        .iter()
        .map(|(id, rungs)| {
            let rungs = rungs
                .iter()
                .map(|r| {
                    Value::tuple([
                        Value::Int(r.ticks.into()),
                        Value::Int(r.amplifier.into()),
                        Value::bool(r.ambient),
                        Value::bool(r.particles),
                        Value::bool(r.icon),
                    ])
                })
                .collect();
            (Value::Int((*id).into()), Value::List(rungs))
        })
        .collect();
    Value::Map(Map::from_pairs(pairs).expect("effect ids are distinct"))
}

fn equipment_record(equipment: &Equipment) -> Value {
    let pairs = Slot::ALL
        .into_iter()
        .filter_map(|slot| Some((Value::atom(slot.name()), equipment.get(slot)?.clone())))
        .collect();
    Value::Map(Map::from_pairs(pairs).unwrap())
}

fn attributes_record(attributes: &Attributes) -> Value {
    let pairs = attributes
        .0
        .iter()
        .map(|(id, entry)| {
            let modifiers = entry
                .modifiers
                .iter()
                .map(|m| {
                    Value::tuple([
                        Value::Binary(m.id.as_bytes().to_vec()),
                        match m.amount {
                            Number::Int(i) => Value::Int(i),
                            Number::Float(f) => Value::Float(f),
                        },
                        Value::Int(m.operation.into()),
                    ])
                })
                .collect();
            let entry = Map::from_atoms([
                ("base", Value::or_nil(entry.base, Value::Float)),
                ("modifiers", Value::List(modifiers)),
            ]);
            (Value::Binary(id.as_bytes().to_vec()), entry.into())
        })
        .collect();
    Value::Map(Map::from_pairs(pairs).expect("attribute ids are distinct"))
}

/// `Mind.record/1`: its random, and a live brain's saved memories (what a
/// record gave while it has none).
fn mind_record(mind: &Mind) -> Value {
    let mut record = Map::from_atoms([("random", Value::Int(mind.random.seed as i64))]);
    let brain = mind.state.as_ref().and_then(|s| s.brain.as_deref());
    let memories = match brain {
        Some(brain) => brain.saved_record(None),
        None => mind.memories.clone(),
    };
    if let Some(memories) = memories {
        record.insert_atom("memories", memories);
    }
    record.into()
}

/// The whole `%MobMotion{}`, `jump` and `rise` cleared.
fn motion_record(m: &MobMotion) -> Value {
    let control = match &m.control {
        Control::Wait => Value::atom("wait"),
        Control::MoveTo { target, speed } => Value::tuple([
            Value::atom("move_to"),
            Value::vec3(*target),
            Value::Float(*speed),
        ]),
        Control::Jumping { speed } => Value::tuple([Value::atom("jumping"), Value::Float(*speed)]),
        Control::Strafe {
            forward,
            right,
            speed,
        } => Value::tuple([
            Value::atom("strafe"),
            Value::Float(*forward),
            Value::Float(*right),
            Value::Float(*speed),
        ]),
    };
    let set = Value::or_nil(m.set.as_ref(), |set| match set {
        MotionSet::Hold => Value::atom("hold"),
        MotionSet::Speed { speed, lift } => {
            Value::tuple([Value::Float(*speed), Value::bool(*lift)])
        }
        MotionSet::Inputs {
            speed,
            lift,
            inputs,
        } => Value::tuple([
            Value::Float(*speed),
            Value::bool(*lift),
            Value::Tuple(
                inputs
                    .iter()
                    .map(|i| Value::or_nil(*i, Value::Float))
                    .collect(),
            ),
        ]),
    });
    let impulse = match &m.impulse {
        Impulse::One(v) => Value::vec3(*v),
        Impulse::List(vs) => Value::List(vs.iter().map(|v| Value::vec3(*v)).collect()),
    };
    let hop = Value::or_nil(m.hop.as_ref(), |hop| {
        let mut map = Map::from_atoms([
            ("jumping", Value::bool(hop.jumping)),
            ("wanted", Value::or_nil(hop.wanted, Value::vec3)),
            ("speed", Value::Float(hop.speed)),
            ("next_speed", Value::Float(hop.next_speed)),
        ]);
        if let Some(up) = hop.path_up {
            map.insert_atom("path_up", Value::bool(up));
        }
        if let Some(outcome) = &hop.outcome {
            map.insert_atom("started", Value::bool(outcome.started));
            map.insert_atom("jumped", Value::bool(outcome.jumped));
            map.insert_atom("nav_speed", Value::or_nil(outcome.nav_speed, Value::Float));
        }
        map.into()
    });
    let float = Value::or_nil(m.float.as_ref(), |float| {
        Map::from_atoms([
            ("wanted", Value::or_nil(float.wanted, Value::vec3)),
            ("duration", Value::Int(float.duration.into())),
        ])
        .into()
    });
    Map::from_atoms([
        ("__struct__", Value::atom(MOB_MOTION)),
        ("fall_distance", Value::Float(m.fall_distance)),
        ("no_jump_delay", Value::Int(m.no_jump_delay.into())),
        ("stuck_multiplier", Value::vec3(m.stuck_multiplier)),
        ("strafe", Value::Float(m.strafe)),
        ("up", Value::Float(m.up)),
        ("forward", Value::Float(m.forward)),
        ("speed", Value::Float(m.speed)),
        ("control", control),
        ("horizontal_collision", Value::bool(m.horizontal_collision)),
        ("jump", Value::bool(false)),
        ("rise", Value::bool(false)),
        ("water", Value::Float(m.water)),
        ("lava", Value::Float(m.lava)),
        ("powder_snow", Value::bool(m.powder_snow)),
        (
            "eye",
            Value::tuple([Value::bool(m.eye.water), Value::Int(m.eye.state.into())]),
        ),
        ("hop", hop),
        ("vertical_collision", Value::bool(m.vertical_collision)),
        ("set", set),
        ("pre_move", Value::or_nil(m.pre_move, Value::Float)),
        ("impulse", impulse),
        (
            "travel",
            Value::or_nil(m.travel, |t| {
                Value::tuple([Value::atom(t.kind.name()), Value::bool(t.sink)])
            }),
        ),
        ("move_dist", Value::Float(m.move_dist)),
        ("next_step", Value::Float(m.next_step)),
        ("float", float),
        ("eye_water", Value::bool(m.eye_water)),
        (
            "support",
            Value::or_nil(m.support, |s| Value::Int(s.into())),
        ),
    ])
    .into()
}

// --------------------------------------------------------------- restore

/// The native mob of a store record, or why it is refused.
pub fn restore(record: &Value, facts: &RecordFacts) -> Result<NativeMob> {
    let map = record.as_map().ok_or(RecordError::Invalid("record"))?;
    let get = |key| map.get_atom(key);
    check(get("kind").is_some_and(|k| k.is_atom("mob")), "kind")?;
    let uuid: [u8; 16] = get("uuid")
        .and_then(Value::as_binary)
        .and_then(|b| b.try_into().ok())
        .ok_or(RecordError::Invalid("uuid"))?;
    // `Store.valid_position?`.
    let coordinate = |key, bound: f64| -> Result<f64> {
        match get(key).and_then(Value::as_number) {
            Some(value) if value.abs() <= bound => Ok(value),
            _ => invalid("position"),
        }
    };
    let position = [
        coordinate("x", 29_999_984.0)?,
        coordinate("y", 1_000_000.0)?,
        coordinate("z", 29_999_984.0)?,
    ];
    let hops = match get("hops") {
        None => 0,
        Some(Value::Int(hops)) if *hops >= 0 => *hops as u64,
        Some(_) => return invalid("hops"),
    };
    let body = restore_body(map, facts)?;
    Ok(NativeMob {
        uuid,
        position,
        hops,
        body,
    })
}

/// `Body.restore/1` of a mob.
fn restore_body(record: &Map, facts: &RecordFacts) -> Result<Body> {
    let get = |key| record.get_atom(key);
    let field = |key| get(key).ok_or(RecordError::Invalid("body field"));
    let entity_type = field("type")?;
    let rotation = field("rotation")?
        .as_tuple_n::<3>()
        .ok_or(RecordError::Invalid("rotation"))?;
    let velocity = field("velocity")?
        .as_tuple_n::<3>()
        .ok_or(RecordError::Invalid("velocity"))?;
    let on_ground = field("on_ground")?;
    let no_gravity = field("no_gravity")?;
    let data = field("data")?;

    let entity_type = entity_type
        .as_binary()
        .and_then(|b| std::str::from_utf8(b).ok())
        .ok_or(RecordError::Invalid("type"))?;
    let type_facts = facts
        .entity_type(entity_type)
        .ok_or(RecordError::Invalid("type"))?;
    let float = |v: &Value| {
        v.as_float()
            .ok_or(RecordError::Invalid("rotation or velocity"))
    };
    let [yaw, pitch, head_yaw] = [
        float(&rotation[0])?,
        float(&rotation[1])?,
        float(&rotation[2])?,
    ];
    let velocity = [
        float(&velocity[0])?,
        float(&velocity[1])?,
        float(&velocity[2])?,
    ];
    let preserved = match get("preserved") {
        None => None,
        Some(v) if v.is_nil() => None,
        Some(Value::Binary(b)) => Some(b.clone()),
        Some(_) => return invalid("preserved"),
    };
    let on_ground = on_ground
        .as_bool()
        .ok_or(RecordError::Invalid("on_ground"))?;
    let no_gravity = no_gravity
        .as_bool()
        .ok_or(RecordError::Invalid("no_gravity"))?;
    let data = restore_data(entity_type, data, type_facts)?;
    let portal_cooldown = match get("portal_cooldown") {
        None => 0,
        Some(Value::Int(c)) if (0..=32_767).contains(c) => *c as i32,
        Some(_) => return invalid("portal_cooldown"),
    };
    // `restore_mob`: a living type needs its mob; the store's kind check
    // needs a living type.
    check(type_facts.living, "kind")?;
    let mob = match get("mob") {
        Some(mob) if !mob.is_nil() => restore_mob(mob, type_facts, facts)?,
        _ => return invalid("mob"),
    };
    let custom_name = get("custom_name").filter(|n| !n.is_nil()).cloned();
    Ok(Body {
        entity_type: entity_type.to_owned(),
        yaw,
        pitch,
        head_yaw,
        velocity,
        on_ground,
        no_gravity,
        data,
        mob,
        custom_name,
        preserved,
        portal_cooldown,
    })
}

const WATER_AGEABLE: [&str; 3] = [
    "minecraft:dolphin",
    "minecraft:squid",
    "minecraft:glow_squid",
];

/// The data map, migrated (`restore_data`) and checked against the type's
/// key set and `valid_water_age?`.
fn restore_data(entity_type: &str, data: &Value, facts: &TypeFacts) -> Result<FamilyData> {
    let map = data.as_map().ok_or(RecordError::Invalid("data"))?;
    let mut fields = Vec::with_capacity(map.len() + 3);
    for (key, value) in map.iter() {
        // Keys must equal the type's, which are atoms.
        let key = key.as_atom().ok_or(RecordError::Invalid("data keys"))?;
        fields.push((key.clone(), value.clone()));
    }
    // VMC-043e10: the former ocean mob shapes gain `AgeableMob`'s fields.
    let old: &[&str] = match entity_type {
        "minecraft:dolphin" => &["got_fish", "moistness", "treasure"],
        "minecraft:squid" => &["age"],
        "minecraft:glow_squid" => &["age", "dark"],
        _ => &[],
    };
    if !old.is_empty()
        && fields
            .iter()
            .map(|(k, _)| k.as_str())
            .eq(old.iter().copied())
    {
        for (key, value) in [
            ("age", Value::Int(0)),
            ("forced_age", Value::Int(0)),
            ("age_locked", Value::bool(false)),
        ] {
            if !fields.iter().any(|(k, _)| k.as_str() == key) {
                fields.push((Atom::from_static(key), value));
            }
        }
        fields.sort_by(|a, b| a.0.as_str().as_bytes().cmp(b.0.as_str().as_bytes()));
    }
    check(
        fields.iter().map(|(k, _)| k).eq(facts.data_keys.iter()),
        "data keys",
    )?;
    // VMC-044b2: a merchant restored trades with nobody (vanilla never
    // saves its trading players).
    if matches!(
        entity_type,
        "minecraft:villager" | "minecraft:wandering_trader"
    ) {
        for (key, value) in fields.iter_mut() {
            match key.as_str() {
                "trading" | "last_traded" | "trading_hero" => *value = Value::atom("nil"),
                "restock_day" => *value = Value::Int(0),
                _ => {}
            }
        }
    }
    let data = FamilyData::new(fields).ok_or(RecordError::Invalid("data keys"))?;
    if WATER_AGEABLE.contains(&entity_type) {
        check(
            data.age().is_some() && data.forced_age().is_some() && data.age_locked().is_some(),
            "water age",
        )?;
    }
    Ok(data)
}

/// `Mob.restore/2`.
fn restore_mob(record: &Value, type_facts: &TypeFacts, facts: &RecordFacts) -> Result<Mob> {
    let record = record.as_map().ok_or(RecordError::Invalid("mob"))?;
    let get = |key| record.get_atom(key).filter(|v| !v.is_nil());
    let living = record
        .get_atom("living")
        .and_then(Value::as_map)
        .ok_or(RecordError::Invalid("living"))?;
    let equipment = record
        .get_atom("equipment")
        .ok_or(RecordError::Invalid("equipment"))?;
    let attributes = record
        .get_atom("attributes")
        .ok_or(RecordError::Invalid("attributes"))?;

    let equipment = restore_equipment(equipment)?;
    let attributes = restore_attributes(attributes)?;
    let motion = match record.get_atom("motion") {
        None => MobMotion::default(),
        Some(motion) => restore_motion(motion)?,
    };
    let ai = get("ai").map(restore_mind).transpose()?;
    let bool_or = |key, default| match record.get_atom(key) {
        None => Ok(default),
        Some(v) => v.as_bool().ok_or(RecordError::Invalid("flag")),
    };
    let no_ai = bool_or("no_ai", false)?;
    let player_memory = match record.get_atom("player_memory") {
        None => 0,
        Some(Value::Int(m)) if (0..=PLAYER_MEMORY).contains(m) => *m as i32,
        Some(_) => return invalid("player_memory"),
    };
    let hurt_by_player = match get("hurt_by_player") {
        None => None,
        Some(v) => Some(
            v.as_binary()
                .and_then(|b| <[u8; 16]>::try_from(b).ok())
                .ok_or(RecordError::Invalid("hurt_by_player"))?,
        ),
    };
    let persistent = bool_or("persistent", false)?;
    let left_handed = bool_or("left_handed", false)?;
    let can_pick_up_loot = bool_or("can_pick_up_loot", false)?;
    let drop_chances = match record.get_atom("drop_chances") {
        None => DropChances::default(),
        Some(chances) => restore_chances(chances)?,
    };
    let finalize = match get("finalize") {
        None => None,
        Some(Value::Atom(reason)) => Some(reason.clone()),
        Some(_) => return invalid("finalize"),
    };
    let leash = get("leash").map(restore_leash).transpose()?;
    let home = get("home").map(restore_home).transpose()?;
    let using = get("using").map(restore_using).transpose()?;

    let max_health = match attributes.get("minecraft:max_health") {
        Some(AttributeOverride {
            base: Some(base), ..
        }) => *base,
        _ => type_facts.max_health,
    };
    let living = restore_living(living, max_health, facts)?;

    Ok(Mob {
        living,
        equipment,
        attributes,
        ai,
        no_ai,
        motion,
        hurt_by_player: if player_memory > 0 {
            hurt_by_player
        } else {
            None
        },
        player_memory,
        hurt_by: None,
        death: None,
        spawns: Vec::new(),
        persistent,
        left_handed,
        can_pick_up_loot,
        drop_chances,
        finalize,
        leash,
        home,
        using,
    })
}

fn restore_equipment(equipment: &Value) -> Result<Equipment> {
    let map = equipment
        .as_map()
        .ok_or(RecordError::Invalid("equipment"))?;
    let mut slots = Equipment::default();
    for (slot, stack) in map.iter() {
        let slot = slot
            .as_atom()
            .and_then(|a| Slot::from_name(a.as_str()))
            .ok_or(RecordError::Invalid("equipment slot"))?;
        check(stack.is_struct(ITEM_STACK), "equipment stack")?;
        slots.set(slot, Some(stack.clone()));
    }
    Ok(slots)
}

fn restore_chances(chances: &Value) -> Result<DropChances> {
    let map = chances
        .as_map()
        .ok_or(RecordError::Invalid("drop_chances"))?;
    let mut out = DropChances::default();
    for (slot, chance) in map.iter() {
        let slot = slot
            .as_atom()
            .and_then(|a| Slot::from_name(a.as_str()))
            .ok_or(RecordError::Invalid("drop_chances"))?;
        match chance.as_float() {
            Some(chance) if chance >= 0.0 => out.0[slot as usize] = Some(chance),
            _ => return invalid("drop_chances"),
        }
    }
    Ok(out)
}

fn restore_attributes(attributes: &Value) -> Result<Attributes> {
    let map = attributes
        .as_map()
        .ok_or(RecordError::Invalid("attributes"))?;
    let mut out = Vec::with_capacity(map.len());
    for (id, entry) in map.iter() {
        let id = id
            .as_binary()
            .filter(|b| b.starts_with(b"minecraft:"))
            .ok_or(RecordError::Invalid("attribute id"))?;
        let id = std::str::from_utf8(id).or_else(|_| unsupported("attribute id"))?;
        let entry = entry.as_map().ok_or(RecordError::Invalid("attribute"))?;
        let base = entry
            .get_atom("base")
            .ok_or(RecordError::Invalid("attribute"))?;
        let modifiers = entry
            .get_atom("modifiers")
            .ok_or(RecordError::Invalid("attribute"))?;
        let base = match base {
            Value::Float(f) => Some(*f),
            v if v.is_nil() => None,
            _ => return invalid("attribute base"),
        };
        let modifiers = modifiers
            .as_list()
            .ok_or(RecordError::Invalid("attribute modifiers"))?;
        if entry.len() != 2 {
            return unsupported("attribute entry keys");
        }
        let modifiers = modifiers
            .iter()
            .map(|m| {
                let [id, amount, operation] = m
                    .as_tuple_n::<3>()
                    .ok_or(RecordError::Unsupported("modifier"))?;
                let id = id
                    .as_binary()
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .ok_or(RecordError::Unsupported("modifier id"))?;
                let amount = match amount {
                    Value::Int(i) => Number::Int(*i),
                    Value::Float(f) => Number::Float(*f),
                    _ => return unsupported("modifier amount"),
                };
                let operation = operation
                    .as_int()
                    .ok_or(RecordError::Unsupported("modifier operation"))?;
                Ok(Modifier {
                    id: id.to_owned(),
                    amount,
                    operation: int32(operation, "modifier operation")?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        out.push((id.to_owned(), AttributeOverride { base, modifiers }));
    }
    Ok(Attributes(std::sync::Arc::new(out)))
}

/// `Mind.valid?/1` (a map with a valid random) of a kept mind record.
fn restore_mind(record: &Value) -> Result<Mind> {
    let map = record.as_map().ok_or(RecordError::Invalid("ai"))?;
    let random = match map.get_atom("random") {
        Some(Value::Int(r)) if (0..=RANDOM_MASK).contains(r) => *r as u64,
        _ => return invalid("ai random"),
    };
    let memories = map.get_atom("memories").cloned();
    if map.len() != 1 + usize::from(memories.is_some()) {
        return unsupported("ai record keys");
    }
    Ok(Mind {
        random: LegacyRandom::from_state(random).expect("checked 48-bit state"),
        memories,
        state: None,
    })
}

fn restore_leash(leash: &Value) -> Result<Leash> {
    // `leash[:holder]` then `leash.holder`: a map with a valid holder.
    let holder = leash
        .as_map()
        .and_then(|m| m.get_atom("holder"))
        .ok_or(RecordError::Invalid("leash"))?;
    let holder = match holder.as_tuple_n::<2>() {
        Some([kind, uuid]) if kind.is_atom("player") => LeashHolder::Player(
            uuid.as_binary()
                .and_then(|b| b.try_into().ok())
                .ok_or(RecordError::Invalid("leash holder"))?,
        ),
        Some([kind, pos]) if kind.is_atom("knot") => {
            let [x, y, z] = pos.as_ivec3().ok_or(RecordError::Invalid("leash holder"))?;
            LeashHolder::Knot([
                int32(x, "leash knot")?,
                int32(y, "leash knot")?,
                int32(z, "leash knot")?,
            ])
        }
        _ => return invalid("leash holder"),
    };
    Ok(Leash {
        holder,
        id: None,
        momentum: 0.0,
        restored: true,
    })
}

fn restore_home(home: &Value) -> Result<Home> {
    let [center, radius] = home.as_tuple_n::<2>().ok_or(RecordError::Invalid("home"))?;
    let [x, y, z] = center.as_ivec3().ok_or(RecordError::Invalid("home"))?;
    let radius = radius.as_int().ok_or(RecordError::Invalid("home"))?;
    Ok(Home {
        center: [int32(x, "home")?, int32(y, "home")?, int32(z, "home")?],
        radius: int32(radius, "home")?,
    })
}

fn restore_using(using: &Value) -> Result<Using> {
    let [hand, ticks] = using
        .as_tuple_n::<2>()
        .ok_or(RecordError::Invalid("using"))?;
    let hand = match hand.as_atom().map(Atom::as_str) {
        Some("main_hand") => Hand::MainHand,
        Some("off_hand") => Hand::OffHand,
        _ => return invalid("using"),
    };
    let ticks = ticks.as_int().ok_or(RecordError::Invalid("using"))?;
    Ok(Using {
        hand,
        ticks: int32(ticks, "using")?,
    })
}

/// `Living.restore/1`, then `Health.restore/2` at the type's maximum.
fn restore_living(saved: &Map, max_health: f64, facts: &RecordFacts) -> Result<Living> {
    // `living.health` must exist; nil restores full health.
    let health = saved
        .get_atom("health")
        .ok_or(RecordError::Invalid("health"))?;
    check((1.0..=1024.0).contains(&max_health), "max_health")?;
    let maximum = f32r(max_health);
    let (value, hurt_ticks, death_ticks) = if health.is_nil() {
        (maximum, 0, 0)
    } else {
        let health = health.as_map().ok_or(RecordError::Invalid("health"))?;
        let field = |key| health.get_atom(key).ok_or(RecordError::Invalid("health"));
        let value = field("value")?
            .as_number()
            .filter(|v| (0.0..=1024.0).contains(v) && f32r(*v) == *v)
            .ok_or(RecordError::Invalid("health value"))?;
        let ticks = |v: &Value| match v {
            Value::Int(t) if (0..=32_767).contains(t) => Ok(*t as i32),
            _ => invalid("health ticks"),
        };
        let hurt = ticks(field("hurt_ticks")?)?;
        let death = ticks(field("death_ticks")?)?;
        // `Health.set`: clamped to the maximum.
        (erl_min(erl_max(f32r(value), 0.0), maximum), hurt, death)
    };

    let effects = match saved.get_atom("effects") {
        None => Effects::default(),
        Some(effects) => restore_effects(effects, facts)?,
    };
    // `Health.reconcile_absorption`: clamped to the Absorption effect's
    // maximum.
    let pool = match saved.get_atom("absorption") {
        None => 0.0,
        Some(pool) => pool
            .as_number()
            .filter(|p| (-FLOAT_MAX..=FLOAT_MAX).contains(p))
            .ok_or(RecordError::Invalid("absorption"))?,
    };
    let derived = match effects.amplifier(facts.absorption_effect) {
        None => 0.0,
        Some(amplifier) => (f64::from(amplifier) + 1.0) * 4.0,
    };
    let derived = f32r(erl_min(facts.max_absorption, derived));
    let absorption = erl_min(f32r(derived), erl_max(0.0, f32r(pool)));

    let int = |key, default: i32| match saved.get_atom(key) {
        None => Ok(default),
        Some(Value::Int(i)) => int32(*i, "living ticks"),
        Some(_) => unsupported("living ticks"),
    };
    Ok(Living {
        health: Health {
            value,
            maximum,
            hurt_ticks,
            death_ticks,
            cooldown: 0,
            last_hurt: 0.0,
        },
        last_mob_hurt: None,
        absorption,
        effects,
        fire_ticks: int("fire_ticks", 0)?,
        air_supply: int("air_supply", 300)?,
        freezing: Freezing {
            frozen_ticks: int("frozen_ticks", 0)?,
            ..Freezing::default()
        },
    })
}

/// `Effects.valid?/1`.
fn restore_effects(effects: &Value, facts: &RecordFacts) -> Result<Effects> {
    let map = effects.as_map().ok_or(RecordError::Invalid("effects"))?;
    check(map.len() <= 40, "effects")?;
    let mut out = Vec::with_capacity(map.len());
    for (id, instance) in map.iter() {
        let id = match id {
            Value::Int(id) if (0..i64::from(facts.effect_count)).contains(id) => *id as i32,
            _ => return invalid("effect id"),
        };
        let rungs = instance
            .as_list()
            .filter(|r| !r.is_empty())
            .ok_or(RecordError::Invalid("effect"))?;
        let mut higher = 256;
        let mut stack = Vec::with_capacity(rungs.len());
        for rung in rungs {
            let [ticks, level, ambient, particles, icon] = rung
                .as_tuple_n::<5>()
                .ok_or(RecordError::Invalid("effect"))?;
            let ticks = match ticks {
                Value::Int(t) if (-1..=i64::from(i32::MAX)).contains(t) => *t as i32,
                _ => return invalid("effect ticks"),
            };
            let level = match level {
                Value::Int(l) if (0..higher).contains(l) => *l,
                _ => return invalid("effect amplifier"),
            };
            higher = level;
            let flag = |v: &Value| v.as_bool().ok_or(RecordError::Invalid("effect flags"));
            stack.push(Rung {
                ticks,
                amplifier: level as u8,
                ambient: flag(ambient)?,
                particles: flag(particles)?,
                icon: flag(icon)?,
            });
        }
        out.push((id, stack));
    }
    Ok(Effects(out))
}

const MOTION_FIELDS: usize = 26;

/// `MobMotion.valid?/1` of a `%MobMotion{}`, read into the typed motion.
fn restore_motion(motion: &Value) -> Result<MobMotion> {
    check(motion.is_struct(MOB_MOTION), "motion")?;
    let map = motion.as_map().expect("a struct is a map");
    let field = |key| {
        map.get_atom(key)
            .ok_or(RecordError::Invalid("motion field"))
    };
    let float = |key| {
        field(key)?
            .as_float()
            .ok_or(RecordError::Invalid("motion float"))
    };
    let flag = |key| {
        field(key)?
            .as_bool()
            .ok_or(RecordError::Invalid("motion flag"))
    };
    let vec3 = |v: &Value| v.as_vec3().ok_or(RecordError::Invalid("motion vector"));

    let no_jump_delay = match field("no_jump_delay")? {
        Value::Int(d) if (0..=10).contains(d) => *d as i32,
        _ => return invalid("no_jump_delay"),
    };
    let control = restore_control(field("control")?)?;
    let hop = match field("hop")? {
        v if v.is_nil() => None,
        hop => Some(restore_hop(hop)?),
    };
    let float_control = match map.get_atom("float") {
        None => return invalid("float"),
        Some(v) if v.is_nil() => None,
        Some(v) => Some(restore_float(v)?),
    };
    let motion = MobMotion {
        fall_distance: float("fall_distance")?,
        no_jump_delay,
        stuck_multiplier: vec3(field("stuck_multiplier")?)?,
        strafe: float("strafe")?,
        up: float("up")?,
        forward: float("forward")?,
        speed: float("speed")?,
        control,
        horizontal_collision: flag("horizontal_collision")?,
        jump: flag("jump")?,
        rise: flag("rise")?,
        water: float("water")?,
        lava: float("lava")?,
        powder_snow: flag("powder_snow")?,
        eye: Eye::default(),
        hop,
        vertical_collision: flag("vertical_collision")?,
        set: None,
        pre_move: None,
        impulse: Impulse::One([0.0; 3]),
        travel: None,
        move_dist: float("move_dist")?,
        next_step: float("next_step")?,
        float: float_control,
        eye_water: false,
        support: None,
    };
    // Fields `valid?` does not check, in the shapes Elixir code writes.
    let unchecked = |key| {
        map.get_atom(key)
            .ok_or(RecordError::Unsupported("motion without a current field"))
    };
    if map.len() != MOTION_FIELDS + 1 {
        return unsupported("motion keys");
    }
    let eye = match unchecked("eye")?.as_tuple_n::<2>() {
        Some([water, Value::Int(state)]) if water.as_bool().is_some() => Eye {
            water: water.as_bool().unwrap(),
            state: int32(*state, "eye state")?,
        },
        _ => return unsupported("motion eye"),
    };
    let set = restore_set(unchecked("set")?)?;
    let pre_move = match unchecked("pre_move")? {
        v if v.is_nil() => None,
        Value::Float(yaw) => Some(*yaw),
        _ => return unsupported("motion pre_move"),
    };
    let impulse = match unchecked("impulse")? {
        Value::List(items) => Impulse::List(
            items
                .iter()
                .map(|v| {
                    v.as_vec3()
                        .ok_or(RecordError::Unsupported("motion impulse"))
                })
                .collect::<Result<_>>()?,
        ),
        v => Impulse::One(
            v.as_vec3()
                .ok_or(RecordError::Unsupported("motion impulse"))?,
        ),
    };
    let travel = match unchecked("travel")? {
        v if v.is_nil() => None,
        v => match v.as_tuple_n::<2>() {
            Some([Value::Atom(kind), sink]) => Some(Travel {
                kind: TravelKind::from_name(kind.as_str())
                    .ok_or(RecordError::Unsupported("motion travel"))?,
                sink: sink
                    .as_bool()
                    .ok_or(RecordError::Unsupported("motion travel"))?,
            }),
            _ => return unsupported("motion travel"),
        },
    };
    let eye_water = unchecked("eye_water")?
        .as_bool()
        .ok_or(RecordError::Unsupported("motion eye_water"))?;
    let support = match unchecked("support")? {
        v if v.is_nil() => None,
        Value::Int(state) => Some(int32(*state, "motion support")?),
        _ => return unsupported("motion support"),
    };
    Ok(MobMotion {
        eye,
        set,
        pre_move,
        impulse,
        travel,
        eye_water,
        support,
        ..motion
    })
}

fn restore_control(control: &Value) -> Result<Control> {
    if control.is_atom("wait") {
        return Ok(Control::Wait);
    }
    let items = control.as_tuple().ok_or(RecordError::Invalid("control"))?;
    let f = |v: &Value| v.as_float().ok_or(RecordError::Invalid("control"));
    match items {
        [op, target, speed] if op.is_atom("move_to") => Ok(Control::MoveTo {
            target: target.as_vec3().ok_or(RecordError::Invalid("control"))?,
            speed: f(speed)?,
        }),
        [op, speed] if op.is_atom("jumping") => Ok(Control::Jumping { speed: f(speed)? }),
        [op, forward, right, speed] if op.is_atom("strafe") => Ok(Control::Strafe {
            forward: f(forward)?,
            right: f(right)?,
            speed: f(speed)?,
        }),
        _ => invalid("control"),
    }
}

fn restore_set(set: &Value) -> Result<Option<MotionSet>> {
    if set.is_nil() {
        return Ok(None);
    }
    if set.is_atom("hold") {
        return Ok(Some(MotionSet::Hold));
    }
    match set.as_tuple() {
        Some([Value::Float(speed), lift]) if lift.as_bool().is_some() => {
            Ok(Some(MotionSet::Speed {
                speed: *speed,
                lift: lift.as_bool().unwrap(),
            }))
        }
        Some([Value::Float(speed), lift, inputs]) if lift.as_bool().is_some() => {
            let [x, y, z] = inputs
                .as_tuple_n::<3>()
                .ok_or(RecordError::Unsupported("motion set"))?;
            let input = |v: &Value| match v {
                v if v.is_nil() => Ok(None),
                Value::Float(f) => Ok(Some(*f)),
                _ => unsupported("motion set"),
            };
            Ok(Some(MotionSet::Inputs {
                speed: *speed,
                lift: lift.as_bool().unwrap(),
                inputs: [input(x)?, input(y)?, input(z)?],
            }))
        }
        _ => unsupported("motion set"),
    }
}

/// `hop?/1`: a map with `jumping`, `wanted`, `speed` and `next_speed`.
fn restore_hop(hop: &Value) -> Result<Hop> {
    let map = hop.as_map().ok_or(RecordError::Invalid("hop"))?;
    let field = |key| map.get_atom(key).ok_or(RecordError::Invalid("hop"));
    let jumping = field("jumping")?
        .as_bool()
        .ok_or(RecordError::Invalid("hop"))?;
    let wanted = match field("wanted")? {
        v if v.is_nil() => None,
        v => Some(v.as_vec3().ok_or(RecordError::Invalid("hop"))?),
    };
    let speed = field("speed")?
        .as_float()
        .ok_or(RecordError::Invalid("hop"))?;
    let next_speed = field("next_speed")?
        .as_float()
        .ok_or(RecordError::Invalid("hop"))?;
    let path_up = match map.get_atom("path_up") {
        None => None,
        Some(v) => Some(v.as_bool().ok_or(RecordError::Unsupported("hop path_up"))?),
    };
    let outcome = match (
        map.get_atom("started"),
        map.get_atom("jumped"),
        map.get_atom("nav_speed"),
    ) {
        (None, None, None) => None,
        (Some(started), Some(jumped), Some(nav_speed)) => Some(HopOutcome {
            started: started
                .as_bool()
                .ok_or(RecordError::Unsupported("hop outcome"))?,
            jumped: jumped
                .as_bool()
                .ok_or(RecordError::Unsupported("hop outcome"))?,
            nav_speed: match nav_speed {
                v if v.is_nil() => None,
                Value::Float(f) => Some(*f),
                _ => return unsupported("hop outcome"),
            },
        }),
        _ => return unsupported("hop outcome"),
    };
    let expected = 4 + usize::from(path_up.is_some()) + 3 * usize::from(outcome.is_some());
    if map.len() != expected {
        return unsupported("hop keys");
    }
    Ok(Hop {
        jumping,
        wanted,
        speed,
        next_speed,
        path_up,
        outcome,
    })
}

/// `float?/1`: `%{wanted, duration}`.
fn restore_float(float: &Value) -> Result<FloatControl> {
    let map = float.as_map().ok_or(RecordError::Invalid("float"))?;
    let wanted = match map.get_atom("wanted") {
        Some(v) if v.is_nil() => None,
        Some(v) => Some(v.as_vec3().ok_or(RecordError::Invalid("float"))?),
        None => return invalid("float"),
    };
    let duration = match map.get_atom("duration") {
        Some(Value::Int(d)) => int32(*d, "float duration")?,
        _ => return invalid("float"),
    };
    if map.len() != 2 {
        return unsupported("float keys");
    }
    Ok(FloatControl { wanted, duration })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mobs::term::{compare, NIL};

    fn facts() -> RecordFacts {
        let mut facts = RecordFacts::new(40, 21, 2048.0);
        let ageable = ["age", "forced_age", "age_locked", "in_love", "love_cause"];
        let mut cow: Vec<Atom> = ageable.iter().map(|k| Atom::new(k)).collect();
        cow.extend([Atom::new("variant"), Atom::new("sound_variant")]);
        facts.insert_type(
            "minecraft:cow",
            TypeFacts {
                living: true,
                max_health: 10.0,
                data_keys: cow,
            },
        );
        facts.insert_type(
            "minecraft:squid",
            TypeFacts {
                living: true,
                max_health: 10.0,
                data_keys: ["age", "forced_age", "age_locked"]
                    .iter()
                    .map(|k| Atom::new(k))
                    .collect(),
            },
        );
        facts.insert_type(
            "minecraft:tnt",
            TypeFacts {
                living: false,
                max_health: 20.0,
                data_keys: vec![Atom::new("fuse"), Atom::new("block_state")],
            },
        );
        facts
    }

    fn cow_data() -> Value {
        Map::from_atoms([
            ("age", Value::Int(-24000)),
            ("forced_age", Value::Int(0)),
            ("age_locked", Value::bool(false)),
            ("in_love", Value::Int(0)),
            ("love_cause", NIL),
            ("variant", Value::Binary(b"minecraft:temperate".to_vec())),
            (
                "sound_variant",
                Value::Binary(b"minecraft:classic".to_vec()),
            ),
        ])
        .into()
    }

    fn living() -> Value {
        Map::from_atoms([
            (
                "health",
                Map::from_atoms([
                    ("value", Value::Float(7.5)),
                    ("hurt_ticks", Value::Int(3)),
                    ("death_ticks", Value::Int(0)),
                ])
                .into(),
            ),
            ("absorption", Value::Float(0.0)),
            ("effects", Map::new().into()),
            ("fire_ticks", Value::Int(-1)),
            ("air_supply", Value::Int(300)),
            ("frozen_ticks", Value::Int(0)),
        ])
        .into()
    }

    fn record_of(data: Value, mob: Value) -> Value {
        Map::from_atoms([
            ("kind", Value::atom("mob")),
            ("uuid", Value::Binary(vec![7; 16])),
            ("x", Value::Float(1.5)),
            ("y", Value::Float(64.0)),
            ("z", Value::Float(-3.25)),
            ("type", Value::Binary(b"minecraft:cow".to_vec())),
            (
                "rotation",
                Value::tuple([Value::Float(90.0), Value::Float(-0.0), Value::Float(12.5)]),
            ),
            ("velocity", Value::vec3([0.0, -0.0784000015258789, 0.0])),
            ("on_ground", Value::bool(true)),
            ("no_gravity", Value::bool(false)),
            ("data", data),
            ("mob", mob),
        ])
        .into()
    }

    fn mob(motion: Value) -> Value {
        Map::from_atoms([
            ("living", living()),
            ("equipment", Map::new().into()),
            ("attributes", Map::new().into()),
            (
                "ai",
                Map::from_atoms([("random", Value::Int(123_456_789))]).into(),
            ),
            ("no_ai", Value::bool(false)),
            ("motion", motion),
            ("hurt_by_player", NIL),
            ("player_memory", Value::Int(0)),
        ])
        .into()
    }

    #[test]
    fn default_motion_round_trips() {
        let mob_motion = MobMotion::default();
        let term = motion_record(&mob_motion);
        assert_eq!(restore_motion(&term).unwrap(), mob_motion);
        assert_eq!(term.as_map().unwrap().len(), MOTION_FIELDS + 1);
    }

    #[test]
    fn a_cow_round_trips() {
        let saved = record_of(cow_data(), mob(motion_record(&MobMotion::default())));
        let native = restore(&saved, &facts()).unwrap();
        assert_eq!(native.body.data.age(), Some(-24000));
        assert_eq!(native.body.mob.living.health.value, 7.5);
        assert_eq!(native.body.mob.living.health.maximum, 10.0);
        assert_eq!(
            native.body.mob.ai.as_ref().unwrap().random.seed,
            123_456_789
        );
        assert_eq!(record(&native), saved);
        assert_eq!(compare(&record(&native), &saved), std::cmp::Ordering::Equal);
    }

    #[test]
    fn rich_motion_round_trips() {
        let motion = MobMotion {
            control: Control::Strafe {
                forward: 0.5,
                right: -0.5,
                speed: 1.0,
            },
            eye: Eye {
                water: true,
                state: 86,
            },
            hop: Some(Hop {
                jumping: true,
                wanted: None,
                speed: 1.0,
                next_speed: 0.6,
                path_up: Some(false),
                outcome: Some(HopOutcome {
                    started: true,
                    jumped: false,
                    nav_speed: None,
                }),
            }),
            set: Some(MotionSet::Inputs {
                speed: 0.1,
                lift: false,
                inputs: [None, Some(0.0), None],
            }),
            pre_move: Some(45.0),
            impulse: Impulse::List(vec![[0.0, 0.1, 0.0], [0.2, 0.0, 0.0]]),
            travel: Some(Travel {
                kind: TravelKind::Guardian,
                sink: true,
            }),
            float: Some(FloatControl {
                wanted: Some([1.0, 2.0, 3.0]),
                duration: 4,
            }),
            support: Some(9),
            ..MobMotion::default()
        };
        let term = motion_record(&motion);
        assert_eq!(restore_motion(&term).unwrap(), motion);
    }

    #[test]
    fn restore_normalises_as_elixir_does() {
        let mut mob_map = mob(motion_record(&MobMotion::default()))
            .as_map()
            .unwrap()
            .clone();
        // A player uuid without memory is dropped; health above the
        // maximum is clamped; a leash keeps only its holder.
        mob_map.insert_atom("hurt_by_player", Value::Binary(vec![1; 16]));
        let mut living = living().as_map().unwrap().clone();
        living.insert_atom(
            "health",
            Map::from_atoms([
                ("value", Value::Int(15)),
                ("hurt_ticks", Value::Int(0)),
                ("death_ticks", Value::Int(0)),
            ])
            .into(),
        );
        living.insert_atom("absorption", Value::Float(4.0));
        mob_map.insert_atom("living", living.into());
        mob_map.insert_atom(
            "leash",
            Map::from_atoms([
                (
                    "holder",
                    Value::tuple([Value::atom("knot"), Value::ivec3([1, 2, 3])]),
                ),
                ("id", Value::Int(5)),
            ])
            .into(),
        );
        let record = record_of(cow_data(), mob_map.into());
        let native = restore(&record, &facts()).unwrap();
        assert_eq!(native.body.mob.hurt_by_player, None);
        assert_eq!(native.body.mob.living.health.value, 10.0);
        assert_eq!(native.body.mob.living.absorption, 0.0);
        let leash = native.body.mob.leash.as_ref().unwrap();
        assert!(leash.restored && leash.id.is_none());
        assert_eq!(leash.holder, LeashHolder::Knot([1, 2, 3]));
    }

    #[test]
    fn squid_data_migrates() {
        let mut record = record_of(
            Map::from_atoms([("age", Value::Int(5))]).into(),
            mob(motion_record(&MobMotion::default())),
        )
        .as_map()
        .unwrap()
        .clone();
        record.insert_atom("type", Value::Binary(b"minecraft:squid".to_vec()));
        let native = restore(&Value::Map(record), &facts()).unwrap();
        assert_eq!(native.body.data.age(), Some(5));
        assert_eq!(native.body.data.forced_age(), Some(0));
        assert_eq!(native.body.data.age_locked(), Some(false));
    }

    #[test]
    fn invalid_records_are_refused() {
        let facts = facts();
        let good = record_of(cow_data(), mob(motion_record(&MobMotion::default())));
        let with = |key: &'static str, value: Value| {
            let mut map = good.as_map().unwrap().clone();
            map.insert_atom(key, value);
            restore(&Value::Map(map), &facts)
        };
        assert!(with("type", Value::Binary(b"minecraft:tnt".to_vec())).is_err());
        assert!(with("type", Value::Binary(b"minecraft:nothing".to_vec())).is_err());
        assert!(with("data", Map::from_atoms([("age", Value::Int(0))]).into()).is_err());
        assert!(with("velocity", Value::ivec3([0, 0, 0])).is_err());
        assert!(with("portal_cooldown", Value::Int(40_000)).is_err());
        assert!(with("mob", NIL).is_err());
        assert!(with("x", Value::Float(3.0e7)).is_err());
        assert!(with("hops", Value::Int(-1)).is_err());
        let mut mob_map = mob(motion_record(&MobMotion::default()))
            .as_map()
            .unwrap()
            .clone();
        mob_map.insert_atom("player_memory", Value::Int(101));
        assert!(with("mob", mob_map.into()).is_err());
    }
}
