//! The native living rules against `Valimc.Entity.Combat`, `MobVitals`,
//! `Daylight`, `Body` and `Mob` (VMC-081d), built only with the `parity`
//! feature: `mob_parity_living` restores a store record into a native mob,
//! runs one operation and answers `{record, events, result}`, the record as
//! `Store.record/1` writes it and the events as the Elixir returns them
//! (sound seeds 0).
//!
//! The families are the parity family below: the hooks the tested types'
//! Elixir families give on these paths (a zombie's or animal's voice, an
//! animal's love lost to a hurt); minds are minds that never thought.

use crate::mob_term;
use crate::mobs::MobRecordFacts;
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use valimc_core::mobs::combat::{
    self, Attacker, Event, Families, Family, Hit, NoMind, Rules, SoundKind, SoundRef,
};
use valimc_core::mobs::facts::MobFacts;
use valimc_core::mobs::living::mob::{self as living_mob, Type};
use valimc_core::mobs::living::{body, effects};
use valimc_core::mobs::model::{Body, FamilyData, NativeMob, Rung};
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::record;
use valimc_core::mobs::term::{Map, Value, NIL};
use valimc_core::mobs::vitals::{self, Moved, Sky};
use valimc_core::physics::player::contacts::{Contact, Source, Touched};

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

/// The hooks the tested families give on these paths.
struct ParityFamily;

fn animal(data: &FamilyData) -> bool {
    data.in_love().is_some()
}

impl Family for ParityFamily {
    fn voice(&self, body: &Body) -> f32 {
        let data = &body.data;
        if animal(data) {
            return if data.age().unwrap_or(0) < 0 {
                1.5
            } else {
                1.0
            };
        }
        match (data.baby(), zombie(&body.entity_type)) {
            (Some(true), true) if body.entity_type == "minecraft:zombie_villager" => 2.0,
            (Some(true), true) => 1.5,
            _ => 1.0,
        }
    }

    // `Zombie.dimensions/1`: a baby's.
    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        if !zombie(&body.entity_type) || body.data.baby() != Some(true) {
            return None;
        }
        let facts = crate::mob_facts::facts().ok()?;
        let id = facts.entities.id(&body.entity_type)?;
        facts.hostile.babies.get(&id).copied()
    }

    fn hurt(&self, body: &mut Body, _hit: &Hit, _events: &mut Vec<Event>) {
        self.actually_hurt(&mut body.data);
    }

    fn actually_hurt(&self, data: &mut FamilyData) {
        if animal(data) {
            data.set_in_love(0);
        }
    }

    // `Animal.properties/1` of the farm animals.
    fn loot_properties(&self, body: &Body) -> Vec<(String, String)> {
        let kind = body.entity_type.strip_prefix("minecraft:").unwrap_or("");
        let text = |key: &str| {
            body.data
                .get(key)
                .and_then(Value::as_binary)
                .map(|b| String::from_utf8_lossy(b).into_owned())
        };
        match kind {
            "cow" | "pig" | "chicken" => text("variant")
                .map(|v| vec![(format!("minecraft:{kind}/variant"), v)])
                .unwrap_or_default(),
            "sheep" => {
                let color = body.data.get("color").and_then(Value::as_int).unwrap_or(0);
                let sheared = body.data.get("sheared").and_then(Value::as_bool) == Some(true);
                vec![
                    (
                        "minecraft:sheep/color".into(),
                        COLORS[color as usize].into(),
                    ),
                    ("sheep/sheared".into(), sheared.to_string()),
                ]
            }
            _ => Vec::new(),
        }
    }

    // `Variants.combat_sound/3` of a cow, pig or chicken.
    fn sound(&self, body: &Body, which: SoundKind) -> Option<SoundRef> {
        let kind = body.entity_type.strip_prefix("minecraft:")?;
        if !matches!(kind, "cow" | "pig" | "chicken") {
            return None;
        }
        let facts = crate::mob_facts::facts().ok()?;
        let variant = body.data.get("sound_variant")?.as_binary()?;
        let set = facts
            .animal
            .sound_variants
            .get(&format!("minecraft:{kind}_sound_variant"))?
            .get(std::str::from_utf8(variant).ok()?)?;
        let set = match &set.baby {
            Some(baby) if body.data.age().unwrap_or(0) < 0 => baby,
            _ => &set.adult,
        };
        let key = match which {
            SoundKind::Hurt => "hurt",
            SoundKind::Death => "death",
        };
        Some(SoundRef::Id(facts.sounds.id(set.get(key)?)?))
    }
}

const COLORS: [&str; 16] = [
    "white",
    "orange",
    "magenta",
    "light_blue",
    "yellow",
    "lime",
    "pink",
    "gray",
    "light_gray",
    "cyan",
    "purple",
    "blue",
    "brown",
    "green",
    "red",
    "black",
];

fn zombie(entity_type: &str) -> bool {
    matches!(
        entity_type,
        "minecraft:zombie" | "minecraft:husk" | "minecraft:zombie_villager"
    )
}

struct ParityFamilies;

impl Families for ParityFamilies {
    /// A native family's own hooks; the stand-in for the others.
    fn family(&self, entity_type: u16) -> &dyn Family {
        match crate::mob_facts::kinds()
            .ok()
            .and_then(|kinds| kinds.kind(entity_type))
        {
            Some(kind) => kind,
            None => &ParityFamily,
        }
    }
}

fn rules() -> NifResult<Rules<'static>> {
    Ok(Rules {
        facts: crate::mob_facts::facts()?,
        living: crate::mob_living::facts()?,
        families: &ParityFamilies,
        mind: &NoMind,
    })
}

// ------------------------------------------------------------ term reading

fn atom_name(v: &Value) -> NifResult<&str> {
    v.as_atom().map(|a| a.as_str()).ok_or_else(bad)
}

fn field<'a>(map: &'a Map, key: &str) -> Option<&'a Value> {
    map.get_atom(key).filter(|v| !v.is_nil())
}

fn number(v: &Value) -> NifResult<f64> {
    v.as_number().ok_or_else(bad)
}

fn vec2(v: &Value) -> NifResult<[f64; 2]> {
    let [x, z] = v.as_tuple_n::<2>().ok_or_else(bad)?;
    Ok([number(x)?, number(z)?])
}

fn vec3(v: &Value) -> NifResult<[f64; 3]> {
    let [x, y, z] = v.as_tuple_n::<3>().ok_or_else(bad)?;
    Ok([number(x)?, number(y)?, number(z)?])
}

/// A damage type atom (`:in_fire`) or `%DamageSource{type: atom}`.
fn damage_type(facts: &MobFacts, v: &Value) -> NifResult<u16> {
    let name = match v.as_map() {
        Some(m) => atom_name(m.get_atom("type").ok_or_else(bad)?)?,
        None => atom_name(v)?,
    };
    facts.damage_types.id(name).ok_or_else(bad)
}

fn damage_name(facts: &MobFacts, id: u16) -> &str {
    let name = &facts.damage_types.types[id as usize].name;
    name.strip_prefix("minecraft:").unwrap_or(name)
}

fn uuid(v: &Value) -> NifResult<[u8; 16]> {
    v.as_binary()
        .and_then(|b| b.try_into().ok())
        .ok_or_else(bad)
}

fn attacker(v: &Value) -> NifResult<Attacker> {
    let m = v.as_map().ok_or_else(bad)?;
    Ok(Attacker {
        uuid: uuid(m.get_atom("uuid").ok_or_else(bad)?)?,
        entity_id: m
            .get_atom("entity_id")
            .and_then(Value::as_int)
            .ok_or_else(bad)? as i32,
        player: m
            .get_atom("player")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        entity_type: m
            .get_atom("type")
            .and_then(Value::as_binary)
            .map(|b| String::from_utf8_lossy(b).into_owned())
            .unwrap_or_default(),
        mainhand: field(m, "mainhand").cloned(),
    })
}

fn hit(facts: &MobFacts, v: &Value) -> NifResult<Hit> {
    let m = v.as_map().ok_or_else(bad)?;
    let mut hit = Hit::new(
        damage_type(facts, m.get_atom("source").ok_or_else(bad)?)?,
        field(m, "amount").map(number).transpose()?.unwrap_or(0.0),
    );
    hit.attacker = field(m, "attacker").map(attacker).transpose()?;
    hit.direct = field(m, "direct").map(attacker).transpose()?;
    hit.position = field(m, "position").map(vec3).transpose()?;
    hit.direction = field(m, "direction").map(vec2).transpose()?;
    hit.extra_knockback = match field(m, "extra_knockback") {
        Some(v) => {
            let [power, direction] = v.as_tuple_n::<2>().ok_or_else(bad)?;
            Some((number(power)?, vec2(direction)?))
        }
        None => None,
    };
    hit.lift = field(m, "lift").map(number).transpose()?;
    hit.bypass_immunity = field(m, "bypass_immunity").and_then(Value::as_bool) == Some(true);
    hit.killer = field(m, "killer").cloned();
    hit.dragon_part = field(m, "dragon_part")
        .and_then(Value::as_int)
        .map(|p| p as u8);
    Ok(hit)
}

fn rung(v: &Value) -> NifResult<Rung> {
    let [ticks, amplifier, ambient, particles, icon] = v.as_tuple_n::<5>().ok_or_else(bad)?;
    let flag = |v: &Value| v.as_bool().ok_or_else(bad);
    Ok(Rung {
        ticks: ticks.as_int().ok_or_else(bad)? as i32,
        amplifier: amplifier.as_int().ok_or_else(bad)? as u8,
        ambient: flag(ambient)?,
        particles: flag(particles)?,
        icon: flag(icon)?,
    })
}

fn contact(v: &Value) -> NifResult<Contact> {
    Ok(match atom_name(v)? {
        "fire" => Contact::Fire,
        "soul_fire" => Contact::SoulFire,
        "lava" => Contact::Lava,
        "water" => Contact::Water,
        "powder_snow" => Contact::PowderSnow,
        _ => return Err(bad()),
    })
}

fn hazard(v: &Value) -> NifResult<Source> {
    Ok(match atom_name(v)? {
        "hot_floor" => Source::HotFloor,
        "campfire" => Source::Campfire,
        "cactus" => Source::Cactus,
        "sweet_berry_bush" => Source::SweetBerryBush,
        _ => return Err(bad()),
    })
}

fn list(v: &Value) -> NifResult<&[Value]> {
    v.as_list().ok_or_else(bad)
}

// ------------------------------------------------------------ term writing

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

fn attacker_value(a: &Attacker) -> Value {
    Value::Map(Map::from_atoms([
        ("uuid", Value::Binary(a.uuid.to_vec())),
        ("entity_id", Value::Int(a.entity_id as i64)),
        ("player", Value::bool(a.player)),
        ("type", Value::Binary(a.entity_type.as_bytes().to_vec())),
        ("mainhand", a.mainhand.clone().unwrap_or(NIL)),
    ]))
}

fn hit_value(facts: &MobFacts, h: &Hit) -> Value {
    let mut m = Map::from_atoms([
        ("source", atom(damage_name(facts, h.source))),
        ("amount", Value::Float(h.amount)),
    ]);
    if let Some(a) = &h.attacker {
        m.insert_atom("attacker", attacker_value(a));
    }
    if let Some(a) = &h.direct {
        m.insert_atom("direct", attacker_value(a));
    }
    if let Some(p) = h.position {
        m.insert_atom("position", Value::vec3(p));
    }
    if let Some((power, [x, z])) = h.extra_knockback {
        m.insert_atom(
            "extra_knockback",
            Value::tuple([
                Value::Float(power),
                Value::tuple([Value::Float(x), Value::Float(z)]),
            ]),
        );
    }
    if let Some(k) = &h.killer {
        m.insert_atom("killer", k.clone());
    }
    Value::Map(m)
}

/// The parity sky: constant answers, the light as `{sky, block}` with the
/// level's darkening.
struct ParitySky {
    monsters_burn: bool,
    light: Option<(u8, u8)>,
    darken: i32,
    rain: bool,
    random: LegacyRandom,
}

impl Sky for ParitySky {
    fn monsters_burn(&self) -> bool {
        self.monsters_burn
    }

    fn light(&self, _p: [i32; 3]) -> f64 {
        match self.light {
            None => 0.0,
            Some((sky, block)) => {
                let level = (sky as i32 - self.darken).max(block as i32);
                let v = (level as f64 / 15.0) as f32;
                (v / (4.0 - 3.0 * v)) as f64
            }
        }
    }

    fn sees_sky(&self, _p: [i32; 3]) -> bool {
        matches!(self.light, Some((15, _)))
    }

    fn rain(&self, _position: [f64; 3], _top: f64) -> bool {
        self.rain
    }

    fn random(&mut self) -> &mut LegacyRandom {
        &mut self.random
    }
}

fn result_map(pairs: Vec<(&'static str, Value)>) -> Value {
    let mut m = Map::new();
    for (k, v) in pairs {
        m.insert_atom(k, v);
    }
    Value::Map(m)
}

fn ty<'a>(rules: &Rules<'a>, mob: &NativeMob) -> NifResult<Type<'a>> {
    rules.of(&mob.body.entity_type).ok_or_else(bad)
}

/// Runs `op` on `mob`: its events and result.
fn run(rules: &Rules, mob: &mut NativeMob, op: &Value) -> NifResult<(Vec<Event>, Value)> {
    let facts = rules.facts;
    let items = op.as_tuple().ok_or_else(bad)?;
    let name = atom_name(items.first().ok_or_else(bad)?)?;
    let arg = |i: usize| items.get(i).ok_or_else(bad);
    let mut events = Vec::new();
    let result = match name {
        // `Combat.resolve/2` of each hit in turn.
        "hurt" => {
            let mut outcomes = Vec::new();
            for h in list(arg(1)?)? {
                let (more, r) = combat::resolve(rules, mob, &hit(facts, h)?);
                events.extend(more);
                let mut out = vec![("hurt", Value::bool(r.hurt))];
                if r.hurt {
                    out.extend([
                        ("full", Value::bool(r.full)),
                        ("died", Value::bool(r.died)),
                        ("previous", Value::Float(r.previous)),
                        ("health", Value::Float(r.health)),
                    ]);
                }
                outcomes.push(result_map(out));
            }
            Value::List(outcomes)
        }
        // `Combat.hurt_mob/5` of `[{source, amount}]` in turn.
        "hurt_mob" => {
            let mut hurts = Vec::new();
            for pair in list(arg(1)?)? {
                let [source, amount] = pair.as_tuple_n::<2>().ok_or_else(bad)?;
                let (more, hurt) =
                    combat::hurt_mob(rules, mob, damage_type(facts, source)?, number(amount)?);
                events.extend(more);
                hurts.push(Value::bool(hurt));
            }
            Value::List(hurts)
        }
        "hit_body" => {
            let (more, hurt) = combat::hit_body(rules, mob, &hit(facts, arg(1)?)?);
            events.extend(more);
            Value::bool(hurt)
        }
        "kill" => Value::bool(body::kill(rules, mob, &mut events)),
        "knockback" => {
            combat::knockback(rules, mob, number(arg(1)?)?, vec2(arg(2)?)?);
            NIL
        }
        "mob_hit" => {
            let target = arg(1)?.as_binary().ok_or_else(bad)?;
            let target = facts
                .entities
                .id(std::str::from_utf8(target).map_err(|_| bad())?)
                .ok_or_else(bad)?;
            let entity_id = arg(2)?.as_int().ok_or_else(bad)? as i32;
            match combat::mob_hit(rules, mob, entity_id, target) {
                Some(h) => hit_value(facts, &h),
                None => NIL,
            }
        }
        // `MobVitals.base_tick/2`, `n` times.
        "base_tick" => {
            for _ in 0..arg(1)?.as_int().ok_or_else(bad)? {
                events.extend(vitals::base_tick(rules, mob));
            }
            NIL
        }
        // `MobVitals.apply/3` of each kernel tick in turn.
        "apply" => {
            for m in list(arg(1)?)? {
                let m = m.as_map().ok_or_else(bad)?;
                let touched = Touched {
                    immediate: list(m.get_atom("immediate").ok_or_else(bad)?)?
                        .iter()
                        .map(|p| {
                            let [s, a] = p.as_tuple_n::<2>().ok_or_else(bad)?;
                            Ok((hazard(s)?, number(a)?))
                        })
                        .collect::<NifResult<_>>()?,
                    steps: list(m.get_atom("steps").ok_or_else(bad)?)?
                        .iter()
                        .map(|s| list(s)?.iter().map(contact).collect())
                        .collect::<NifResult<_>>()?,
                    active: false,
                };
                let landing = match field(m, "landing") {
                    Some(v) => {
                        let [state, distance] = v.as_tuple_n::<2>().ok_or_else(bad)?;
                        Some((state.as_int().ok_or_else(bad)? as u16, number(distance)?))
                    }
                    None => None,
                };
                let moved = Moved {
                    eye_water: m.get_atom("eye_water").and_then(Value::as_bool) == Some(true),
                    eye_state: m.get_atom("eye_state").and_then(Value::as_int).unwrap_or(0) as u16,
                    landing,
                    touched: &touched,
                    water: m.get_atom("water").and_then(Value::as_bool) == Some(true),
                };
                events.extend(vitals::apply(rules, mob, &moved));
            }
            NIL
        }
        // `LocalDifficulty.at/3`: `{effective, special}`.
        "difficulty" => {
            use valimc_core::mobs::level::Difficulty;
            let difficulty = match atom_name(arg(1)?)? {
                "peaceful" => Difficulty::Peaceful,
                "easy" => Difficulty::Easy,
                "normal" => Difficulty::Normal,
                "hard" => Difficulty::Hard,
                _ => return Err(bad()),
            };
            let at = valimc_core::mobs::living::difficulty::LocalDifficulty::at(
                difficulty,
                arg(2)?.as_int().ok_or_else(bad)?,
                arg(3)?.as_int().ok_or_else(bad)?,
            );
            Value::tuple([Value::Float(at.effective), Value::Float(at.special())])
        }
        // `Explosions`: `{reach, distance, damage, knockback}` of an
        // explosion of `radius` at `center` on `position`.
        "explosion" => {
            use valimc_core::mobs::living::explosions;
            let radius = number(arg(1)?)?;
            let center = vec3(arg(2)?)?;
            let position = vec3(arg(3)?)?;
            let seen = number(arg(4)?)?;
            let resistance = number(arg(5)?)?;
            let reach = explosions::reach(radius, center);
            let distance = explosions::distance(radius, center, position);
            Value::tuple([
                Value::Tuple(reach.iter().map(|&v| Value::Float(v)).collect()),
                distance.map_or(NIL, Value::Float),
                Value::Float(explosions::damage(radius, center, position, seen)),
                distance.map_or(NIL, |d| {
                    Value::vec3(explosions::knockback(center, position, d, seen, resistance))
                }),
            ])
        }
        // Operations in turn: their results.
        "seq" => {
            let mut results = Vec::new();
            for op in list(arg(1)?)? {
                let (more, result) = run(rules, mob, op)?;
                events.extend(more);
                results.push(result);
            }
            Value::List(results)
        }
        // `Daylight.tick/3` at `position` under a constant sky.
        "daylight" => {
            let position = vec3(arg(1)?)?;
            let m = arg(2)?.as_map().ok_or_else(bad)?;
            let light = match field(m, "light") {
                Some(v) => {
                    let [s, b] = v.as_tuple_n::<2>().ok_or_else(bad)?;
                    Some((
                        s.as_int().ok_or_else(bad)? as u8,
                        b.as_int().ok_or_else(bad)? as u8,
                    ))
                }
                None => None,
            };
            let mut sky = ParitySky {
                monsters_burn: m.get_atom("monsters_burn").and_then(Value::as_bool) == Some(true),
                light,
                darken: m.get_atom("darken").and_then(Value::as_int).unwrap_or(0) as i32,
                rain: m.get_atom("rain").and_then(Value::as_bool) == Some(true),
                random: LegacyRandom::new(m.get_atom("seed").and_then(Value::as_int).unwrap_or(0)),
            };
            events.extend(vitals::daylight(rules, mob, position, &mut sky));
            NIL
        }
        // `Body.tick/1`, `n` times: whether each ended the death animation.
        "tick" => {
            let mut done = Vec::new();
            for _ in 0..arg(1)?.as_int().ok_or_else(bad)? {
                done.push(Value::bool(body::tick(&mut mob.body, &mut events)));
            }
            Value::List(done)
        }
        // `Body.values/1`.
        // The common, living and mob fields (the test's `Enum.take(10)`;
        // a family's own are its scenes').
        "values" => {
            let t = ty(rules, mob)?;
            Value::List(
                body::values(rules, t, &mob.body)
                    .into_iter()
                    .take(10)
                    .map(|(k, v, d)| Value::Tuple(vec![Value::Atom(k), v, d]))
                    .collect(),
            )
        }
        // `Body.dimensions/1` and `Body.box/2` at the entry's position.
        "dimensions" => {
            let t = ty(rules, mob)?;
            let [w, h, e] = body::dimensions(rules, t, &mob.body);
            let b = body::bounding_box(rules, t, &mob.body, mob.position);
            Value::tuple([
                Value::vec3([w, h, e]),
                Value::Tuple(b.iter().map(|&v| Value::Float(v)).collect()),
            ])
        }
        // `Mob.add_effect/3`.
        "add_effect" => {
            let id = arg(1)?.as_int().ok_or_else(bad)? as i32;
            living_mob::add_effect(facts, &mut mob.body.mob, id, rung(arg(2)?)?);
            NIL
        }
        // `Effects.add/3` (a refresh): whether the client is told.
        "refresh_effect" => {
            let id = arg(1)?.as_int().ok_or_else(bad)? as i32;
            Value::bool(effects::add(
                &mut mob.body.mob.living.effects,
                id,
                rung(arg(2)?)?,
            ))
        }
        // `Effects.tick/1`, `n` times.
        "effects_tick" => {
            for _ in 0..arg(1)?.as_int().ok_or_else(bad)? {
                effects::tick(&mut mob.body.mob.living.effects);
            }
            NIL
        }
        // `Mob.value/3` and `Mob.base/3` of an attribute.
        "value" => {
            let t = ty(rules, mob)?;
            let name =
                std::str::from_utf8(arg(1)?.as_binary().ok_or_else(bad)?).map_err(|_| bad())?;
            let id = facts.attributes.id(name).ok_or_else(bad)?;
            Value::tuple([
                Value::Float(living_mob::value(rules.living, facts, t, &mob.body.mob, id)),
                Value::Float(living_mob::base(
                    rules.living,
                    facts,
                    t,
                    &mob.body.mob.attributes,
                    id,
                )),
            ])
        }
        // `Mob.synced/2`.
        "synced" => {
            let t = ty(rules, mob)?;
            Value::List(
                living_mob::synced(rules.living, facts, t, &mob.body.mob.attributes)
                    .into_iter()
                    .map(|s| {
                        Value::tuple([
                            Value::Int(s.id as i64),
                            Value::Float(s.base),
                            Value::List(
                                s.modifiers
                                    .iter()
                                    .map(|m| {
                                        Value::tuple([
                                            Value::Binary(m.id.as_bytes().to_vec()),
                                            match m.amount {
                                                valimc_core::mobs::model::Number::Int(i) => {
                                                    Value::Int(i)
                                                }
                                                valimc_core::mobs::model::Number::Float(f) => {
                                                    Value::Float(f)
                                                }
                                            },
                                            Value::Int(m.operation as i64),
                                        ])
                                    })
                                    .collect(),
                            ),
                        ])
                    })
                    .collect(),
            )
        }
        _ => return Err(bad()),
    };
    Ok((events, result))
}

/// Restores `record`, runs `op` and answers `{record, events, %{result,
/// death, hurt_by}}`; `{:error, reason}` for a record the codec refuses.
#[rustler::nif]
fn mob_parity_living<'a>(
    env: Env<'a>,
    record_facts: ResourceArc<MobRecordFacts>,
    store_record: Term<'a>,
    op: Term<'a>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let value = mob_term::decode(store_record)?;
    let mut mob = match record::restore(&value, &record_facts.0) {
        Ok(mob) => mob,
        Err(e) => return Ok((rustler::types::atom::error(), format!("{e:?}")).encode(env)),
    };
    let op = mob_term::decode(op)?;
    let (events, result) = run(&rules, &mut mob, &op)?;
    let extra = result_map(vec![
        ("result", result),
        ("death", mob.body.mob.death.clone().unwrap_or(NIL)),
        (
            "hurt_by",
            mob.body
                .mob
                .hurt_by
                .map_or(NIL, |u| Value::Binary(u.to_vec())),
        ),
    ]);
    let events = Value::List(events.iter().map(|e| event(rules.facts, e)).collect());
    let out = Value::tuple([record::record(&mob), events, extra]);
    mob_term::encode(env, &out)
}
