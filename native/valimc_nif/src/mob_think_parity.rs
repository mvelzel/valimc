//! The native think step and farm animals (VMC-081d, `mobs::ai::think`,
//! `mobs::kinds`, `mobs::animals`) against `Valimc.AI` and
//! `Valimc.Entity.Animal`, built only with the `parity` feature.
//!
//! `mob_parity_think` runs a section's mobs (store records, in id order)
//! tick by tick over a region's store as the ExUnit test runs the Elixir:
//! the scene's acts (love, a baby fed), every mob's mind made
//! (`AI.prepare`), then per mob its think, the changes it made to others, a
//! scripted move toward its wanted position, its settle and its sensing
//! again. Each tick answers every mob's record, its mind and its effects,
//! and the level random. `mob_parity_interact` runs one interaction on a
//! mob.

use crate::mob_ai_parity::{difficulty, mode, over_region};
use crate::mob_term;
use crate::mobs::MobRecordFacts;
use crate::region::Region;
use rustler::types::map::map_new;
use rustler::{Atom, Binary, Encoder, Env, NifMap, NifResult, ResourceArc, Term};
use valimc_core::mobs::ai::effect::{Eaten, Effect};
use valimc_core::mobs::ai::leash::Holder;
use valimc_core::mobs::ai::mind::MindState;
use valimc_core::mobs::ai::think::{self, Ctx, Moves, SectionAi};
use valimc_core::mobs::animals::rabbit::HopState;
use valimc_core::mobs::combat::{AiMind, Event, Hit, Rules, SoundRef};
use valimc_core::mobs::kinds::interact::{
    At, Hand, InteractEvent, Interaction, Outcome, Request, Source,
};
use valimc_core::mobs::kinds::{self, leads};
use valimc_core::mobs::model::{Control, NativeMob};
use valimc_core::mobs::record;
use valimc_core::mobs::sensing::{Kind, Ref, SensedPlayer};
use valimc_core::mobs::term::Value;

mod atoms {
    rustler::atoms! {
        nil, love, feed, hurt, fire, sound, sound_at, event, eat_block, dirt, destroy, offspring,
        bred, orb, lay, lead, knot_free, make_knot, raid_carrot, other, living, player,
        mob, item, keep, fill, wear, pass, consume, done, animal, sound_block,
        jump_ticks, jump_duration, was_on_ground, jump_delay, can_jump, move_to, wait,
        jumping, strafe, pickup, drop, swing, attack, alert, attack_extra, convert,
        level_event, spawn, spawn_body, jockey, shoot, explode, discard, throw_potion,
        throw_trident, touch, take_block, place_carried, remove_block, anger_end, anger_target,
        away, maybe, shot, poked, y_rot, aggressive, wanted, effect, struck, elder_curse, infest, wake_infested,
        magic, projectile, lay_eggs, gift, throw, shoot_bullet, spawn_mob, shulker_push, bullet
    }
}

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

type V3 = (f64, f64, f64);

fn uuid(b: &Binary) -> NifResult<[u8; 16]> {
    b.as_slice().try_into().map_err(|_| bad())
}

#[derive(NifMap)]
struct PlayerT<'a> {
    uuid: Binary<'a>,
    id: i32,
    position: V3,
    yaw: f64,
    pitch: f64,
    mode: Atom,
    mainhand: Option<i32>,
    movement: V3,
    swimming: bool,
}

/// A sensed item row (`%{kind: :item, uuid, x, y, z, item, count,
/// pickup_delay, in_water}`; its components are empty).
#[derive(NifMap)]
struct ItemT<'a> {
    uuid: Binary<'a>,
    x: f64,
    y: f64,
    z: f64,
    item: i32,
    count: i32,
    pickup_delay: i32,
    in_water: bool,
}

/// A structure query's fixed answer (`world.locate`).
struct Fixed(Option<[i32; 3]>);

impl valimc_core::mobs::level::Locator for Fixed {
    fn locate(&self, _query: &valimc_core::mobs::level::Query) -> Option<[i32; 3]> {
        self.0
    }
}

#[derive(NifMap)]
struct RulesT {
    mob_griefing: bool,
    mob_drops: bool,
    entity_drops: bool,
    universal_anger: bool,
}

#[derive(NifMap)]
struct SceneT<'a> {
    mobs: Vec<(i32, Term<'a>)>,
    players: Vec<PlayerT<'a>>,
    time: i64,
    day: i64,
    ticks: i32,
    step: f64,
    difficulty: Atom,
    bright: bool,
    rules: RulesT,
    knots: Vec<(i32, i32, i32, i32)>,
    /// `{tick, mob index, :love | :feed | :hurt}` (a hurt by the first
    /// player).
    acts: Vec<(i32, usize, Atom)>,
    /// Each tick's player positions and movements (none: they stand).
    moves: Vec<Vec<(V3, V3)>>,
    level_seed: u64,
    /// Sensed-only mobs (types not native yet), after the mobs in id order.
    statues: Vec<(i32, Term<'a>)>,
    /// Whether the sun and each family's part after the move run.
    post: bool,
    monsters_burn: bool,
    halloween: bool,
    /// The sky's darkening (`World.darken`: 11 at night).
    darken: i32,
    /// Per tick, the indices of the mobs whose move bumped into a wall.
    collide: Vec<Vec<usize>>,
    /// The loot registry spawn enchanting rolls in.
    loot: Option<ResourceArc<crate::loot::LootRegistry>>,
    /// The items the mobs sense, as each tick begins.
    items: Vec<ItemT<'a>>,
    /// Where structure queries find treasure (nil: deferred).
    treasure: Option<(i32, i32, i32)>,
    /// The sections holding an occupied village POI (`World.villages`).
    villages: Option<Vec<(i32, i32, i32)>>,
    /// `{tick, player index, seen}`: a player angering piglins.
    events: Vec<(i32, usize, bool)>,
    /// Each tick's loot roll seeds, in turn.
    loot_seeds: Vec<i64>,
}

fn player_of(p: &PlayerT) -> NifResult<SensedPlayer> {
    let mut equipment = [None; 6];
    equipment[4] = p.mainhand;
    let m = mode(p.mode)?;
    Ok(SensedPlayer {
        uuid: uuid(&p.uuid)?,
        id: p.id,
        position: [p.position.0, p.position.1, p.position.2],
        yaw: p.yaw,
        pitch: p.pitch,
        eye: 1.62f32 as f64,
        width: 0.6f32 as f64,
        height: 1.8f32 as f64,
        mode: m,
        invulnerable: m == valimc_core::mobs::sensing::GameMode::Creative,
        alive: true,
        crouching: false,
        swimming: p.swimming,
        invisible: false,
        armor_cover: 0.0,
        equipment,
        movement: [p.movement.0, p.movement.1, p.movement.2],
        velocity: [0.0; 3],
        health: 20.0,
        effects: vec![],
    })
}

static RULES: std::sync::OnceLock<Rules<'static>> = std::sync::OnceLock::new();

/// The living rules over the native families and the AI's minds.
fn rules() -> NifResult<&'static Rules<'static>> {
    if let Some(rules) = RULES.get() {
        return Ok(rules);
    }
    let rules = Rules {
        facts: crate::mob_facts::facts()?,
        living: crate::mob_living::facts()?,
        families: crate::mob_facts::kinds()?,
        mind: &AiMind,
    };
    Ok(RULES.get_or_init(|| rules))
}

fn reference<'a>(env: Env<'a>, r: &Ref) -> Term<'a> {
    let kind = match r.kind {
        Kind::Player => atoms::player(),
        Kind::Mob => atoms::mob(),
        Kind::Item => atoms::item(),
    };
    (kind, crate::binary(env, &r.uuid)).encode(env)
}

fn cell(c: [i32; 3]) -> (i32, i32, i32) {
    (c[0], c[1], c[2])
}

fn v3(v: [f64; 3]) -> V3 {
    (v[0], v[1], v[2])
}

/// An effect as the test normalizes the Elixir's.
fn effect<'a>(env: Env<'a>, e: &Effect) -> NifResult<Term<'a>> {
    Ok(match e {
        Effect::Sound {
            id,
            source,
            volume,
            pitch,
            ..
        } => (atoms::sound(), *id, *source, *volume, *pitch).encode(env),
        Effect::SoundAt {
            id,
            at,
            volume,
            pitch,
            ..
        } => (atoms::sound_at(), *id, v3(*at), *volume, *pitch).encode(env),
        Effect::Event(n) => (atoms::event(), *n).encode(env),
        Effect::EatBlock { cell: c, how } => {
            let how = match how {
                Eaten::Dirt => atoms::dirt(),
                Eaten::Destroy => atoms::destroy(),
            };
            (atoms::eat_block(), cell(*c), how).encode(env)
        }
        Effect::Offspring { type_id, data, at } => {
            let facts = crate::mob_facts::facts()?;
            let name = facts.entities.name(*type_id).unwrap_or("");
            let mut data = data.clone();
            if let Value::Map(m) = &mut data {
                m.remove(&Value::atom("egg_time"));
            }
            (
                atoms::offspring(),
                name,
                mob_term::encode(env, &data)?,
                v3(*at),
            )
                .encode(env)
        }
        Effect::Bred(r) => (atoms::bred(), reference(env, r)).encode(env),
        Effect::Orb { value, at } => (atoms::orb(), *value, v3(*at)).encode(env),
        Effect::Lay(v) => (atoms::lay(), v3(*v)).encode(env),
        Effect::Lead(at) => (atoms::lead(), v3(*at)).encode(env),
        Effect::KnotFree(c) => (atoms::knot_free(), cell(*c)).encode(env),
        Effect::MakeKnot(c) => (atoms::make_knot(), cell(*c)).encode(env),
        Effect::RaidCarrot(c) => (atoms::raid_carrot(), cell(*c)).encode(env),
        Effect::Swing(_) => (atoms::swing(),).encode(env),
        Effect::Attack(r) => (atoms::attack(), reference(env, r)).encode(env),
        Effect::Alert { mob, target } => (
            atoms::alert(),
            crate::binary(env, mob),
            reference(env, target),
        )
            .encode(env),
        Effect::Pickup { item, count } => {
            (atoms::pickup(), crate::binary(env, item), *count).encode(env)
        }
        Effect::Drop(stack) => (atoms::drop(), mob_term::encode(env, stack)?).encode(env),
        // The living rules' events the AI made (a family's air drowning
        // it), as the Elixir's raw events normalize.
        Effect::Living(event) => match event {
            Event::Sound {
                sound,
                source,
                volume,
                pitch,
            } => {
                let id = match sound {
                    SoundRef::Id(id) => *id,
                    SoundRef::Name(name) => {
                        crate::mob_facts::facts()?.sounds.id(name).unwrap_or(-1)
                    }
                };
                (atoms::sound(), id, *source, *volume, *pitch).encode(env)
            }
            Event::Entity(n) => (atoms::event(), *n).encode(env),
            _ => (atoms::other(),).encode(env),
        },
        Effect::AttackExtra(r, extras) => (
            atoms::attack_extra(),
            reference(env, r),
            mob_term::encode(env, extras)?,
        )
            .encode(env),
        Effect::Convert(to) => {
            let facts = crate::mob_facts::facts()?;
            (atoms::convert(), facts.entities.name(*to).unwrap_or("")).encode(env)
        }
        Effect::LevelEvent {
            cell: c,
            kind,
            data,
        } => (atoms::level_event(), cell(*c), *kind, *data).encode(env),
        Effect::Spawn { type_id, options } => {
            let facts = crate::mob_facts::facts()?;
            (
                atoms::spawn(),
                facts.entities.name(*type_id).unwrap_or(""),
                mob_term::encode(env, options)?,
            )
                .encode(env)
        }
        Effect::SpawnBody(mob) => {
            // Its type and equipment (its uuid and mind are its own).
            let record = record::record(mob);
            let equipment = record
                .as_map()
                .and_then(|m| m.get_atom("mob"))
                .and_then(Value::as_map)
                .and_then(|m| m.get_atom("equipment"))
                .cloned()
                .unwrap_or(Value::Map(Default::default()));
            (
                atoms::spawn_body(),
                mob.body.entity_type.as_str(),
                mob_term::encode(env, &equipment)?,
            )
                .encode(env)
        }
        Effect::Jockey(uuid) => (atoms::jockey(), crate::binary(env, uuid)).encode(env),
        Effect::Shoot(shot) => {
            let mut map = map_new(env);
            for (k, v) in [
                ("target", reference(env, &shot.target)),
                (
                    "at",
                    (shot.at[0], shot.at[1], shot.at[2], shot.at[3]).encode(env),
                ),
                ("from", v3(shot.from).encode(env)),
                ("power", shot.power.encode(env)),
                ("pitch", shot.pitch.encode(env)),
            ] {
                map = map.map_put(rustler::Atom::from_str(env, k)?, v)?;
            }
            (atoms::shoot(), map).encode(env)
        }
        Effect::Explode(v) => (atoms::explode(), mob_term::encode(env, v)?).encode(env),
        Effect::ThrowPotion(v) => (atoms::throw_potion(), mob_term::encode(env, v)?).encode(env),
        Effect::ThrowTrident(v) => (atoms::throw_trident(), mob_term::encode(env, v)?).encode(env),
        Effect::Touch {
            target,
            amount,
            sound,
        } => (
            atoms::touch(),
            reference(env, target),
            *amount,
            mob_term::encode(env, sound)?,
        )
            .encode(env),
        Effect::TakeBlock(v) => {
            let v = mob_term::encode(env, v)?;
            let items = rustler::types::tuple::get_tuple(v)?;
            let mut all = vec![atoms::take_block().encode(env)];
            all.extend(items);
            rustler::types::tuple::make_tuple(env, &all)
        }
        Effect::PlaceCarried { cell: c, state } => {
            (atoms::place_carried(), cell(*c), *state).encode(env)
        }
        Effect::RemoveBlock(c) => (atoms::remove_block(), cell(*c)).encode(env),
        Effect::Infest { cell: c, state } => (atoms::infest(), cell(*c), *state).encode(env),
        Effect::WakeInfested(v) => tagged(env, atoms::wake_infested(), v)?,
        Effect::Projectile(v) => tagged(env, atoms::projectile(), v)?,
        Effect::ShootBullet(v) => tagged(env, atoms::shoot_bullet(), v)?,
        Effect::SpawnMob(v) => tagged(env, atoms::spawn_mob(), v)?,
        Effect::ShulkerPush(v) => tagged(env, atoms::shulker_push(), v)?,
        Effect::Discard => (atoms::discard(),).encode(env),
        Effect::Hurt {
            target,
            kind,
            amount,
            actions,
        } => (
            atoms::hurt(),
            reference(env, target),
            mob_term::encode(env, kind)?,
            *amount,
            mob_term::encode(env, actions)?,
        )
            .encode(env),
        Effect::SoundBlock(Value::Tuple(v)) if v.len() >= 4 => (
            atoms::sound_block(),
            mob_term::encode(env, &v[0])?,
            mob_term::encode(env, &v[1])?,
            mob_term::encode(env, &v[2])?,
            mob_term::encode(env, &v[3])?,
        )
            .encode(env),
        Effect::LayEggs(Value::Tuple(v)) if v.len() == 2 => (
            atoms::lay_eggs(),
            mob_term::encode(env, &v[0])?,
            mob_term::encode(env, &v[1])?,
        )
            .encode(env),
        Effect::Gift { table, velocity } => {
            (atoms::gift(), table.as_str(), v3(*velocity)).encode(env)
        }
        Effect::ElderCurse(at) => (atoms::elder_curse(), v3(*at)).encode(env),
        Effect::GiveEffect { target, actions } => (
            atoms::effect(),
            reference(env, target),
            mob_term::encode(env, actions)?,
        )
            .encode(env),
        Effect::Throw(v) => {
            let v = mob_term::encode(env, v)?;
            let items = rustler::types::tuple::get_tuple(v)?;
            let mut all = vec![atoms::throw().encode(env)];
            all.extend(items);
            rustler::types::tuple::make_tuple(env, &all)
        }
        _ => (atoms::other(),).encode(env),
    })
}

/// `{tag, ...}` of a tuple payload's items (the Elixir's flat tuple).
fn tagged<'a>(env: Env<'a>, tag: Atom, v: &Value) -> NifResult<Term<'a>> {
    let v = mob_term::encode(env, v)?;
    let items = rustler::types::tuple::get_tuple(v)?;
    let mut all = vec![tag.encode(env)];
    all.extend(items);
    Ok(rustler::types::tuple::make_tuple(env, &all))
}

fn control<'a>(env: Env<'a>, c: &Control) -> Term<'a> {
    match c {
        Control::Wait => atoms::wait().encode(env),
        Control::MoveTo { target, speed } => (atoms::move_to(), v3(*target), *speed).encode(env),
        Control::Jumping { speed } => (atoms::jumping(), *speed).encode(env),
        Control::Strafe {
            forward,
            right,
            speed,
        } => (atoms::strafe(), *forward, *right, *speed).encode(env),
    }
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

/// What the record leaves out of a mind: `{tick, no_action, ambient,
/// running goals, target, look, body_yaw, path, own, forced_age_timer,
/// age_lock_timer, disabled, wet, control}`.
fn mind<'a>(env: Env<'a>, mob: &NativeMob) -> NifResult<Term<'a>> {
    let Some(s) = mob.body.mob.ai.as_ref().and_then(|m| m.state.as_deref()) else {
        return Ok(atoms::nil().encode(env));
    };
    let s: &MindState = s;
    let running: Vec<&str> = s.goals.running().map(|g| g.name()).collect();
    let target = s
        .target
        .as_ref()
        .map_or(atoms::nil().encode(env), |r| reference(env, r));
    let look = match &s.look {
        None => atoms::nil().encode(env),
        Some(l) => (l.x, l.y, l.z, l.y_max, l.x_max, l.cooldown).encode(env),
    };
    let path = match &s.navigation.path {
        None => atoms::nil().encode(env),
        Some(p) => {
            let nodes: Vec<(i32, i32, i32)> = p.nodes.iter().map(|n| cell(*n)).collect();
            (p.index, nodes, s.navigation.speed).encode(env)
        }
    };
    let bat = s
        .own
        .family::<valimc_core::mobs::ambient::bat::BatSpot>()
        .map(|b| cell(b.0));
    let own = match s.own.family::<HopState>() {
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
    };
    Ok(rustler::types::tuple::make_tuple(
        env,
        &[
            s.tick.encode(env),
            s.no_action.encode(env),
            s.ambient.encode(env),
            running.encode(env),
            target,
            look,
            s.body_yaw.encode(env),
            path,
            own,
            s.forced_age_timer.encode(env),
            s.age_lock_timer.encode(env),
            (s.disabled as i32).encode(env),
            s.wet.encode(env),
            control(env, &mob.body.mob.motion.control),
            brain(env, s.brain.as_deref())?,
        ],
    ))
}

/// A brain as the harness views it: `{[{name, value, ttl}], active,
/// running, sensor countdowns}`, the memories by name.
fn brain<'a>(
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

/// What `MobTicks` runs after the settle that a scene can (the harness's
/// `post/4`): the sun (`Daylight.tick`) and the family's part after the
/// move, its move as the record's fluids left it (`collided`: it bumped
/// into a wall).
fn post(
    rules: &Rules,
    kinds: &kinds::Registry,
    mob: &mut NativeMob,
    level: &mut valimc_core::mobs::level::Level,
    collided: bool,
) -> Vec<Effect> {
    let position = mob.position;
    valimc_core::mobs::vitals::daylight(rules, mob, position, level);
    mob.body.mob.motion.horizontal_collision = collided;
    let motion = &mob.body.mob.motion;
    let ticked = valimc_core::physics::mob::Ticked {
        mob: valimc_core::physics::mob::Mob {
            horizontal_collision: collided,
            ..Default::default()
        },
        water: motion.water > 0.0,
        lava: motion.lava > 0.0,
        eye_water: motion.eye_water,
        eye_state: motion.eye.state as u16,
        eye_after: (motion.eye.water, motion.eye.state as u16),
        pre_swim: None,
        step: false,
        on_block: None,
        landing: None,
        landing_pos: None,
        touched: Default::default(),
        climbing: false,
        powder_snow: motion.powder_snow,
        depths: Default::default(),
        swim: None,
        support: 0,
        splash: None,
    };
    let Some(kind) = rules
        .facts
        .entities
        .id(&mob.body.entity_type)
        .and_then(|id| kinds.kind(id))
    else {
        return Vec::new();
    };
    kind.after_move(mob, &ticked)
}

/// `{ticks: [{records, minds, effects, level seed}]}` of `scene` over the
/// region's store.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_parity_think<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    zoom_seed: i64,
    record_facts: ResourceArc<MobRecordFacts>,
    scene: SceneT<'a>,
) -> NifResult<Vec<Term<'a>>> {
    let rules = rules()?;
    let kinds = crate::mob_facts::kinds()?;
    let paths = crate::path::path_facts().ok_or(bad())?;
    let ctx = Ctx {
        rules,
        kinds,
        paths,
    };
    let mut ids = Vec::new();
    let mut mobs = Vec::new();
    for (id, record) in &scene.mobs {
        let value = mob_term::decode(*record)?;
        let mob = record::restore(&value, &record_facts.0).map_err(|_| bad())?;
        ids.push(*id);
        mobs.push(mob);
    }
    let mut statues = Vec::new();
    for (id, record) in &scene.statues {
        let value = mob_term::decode(*record)?;
        let mob = record::restore(&value, &record_facts.0).map_err(|_| bad())?;
        statues.push((*id, mob));
    }
    let mut players = scene
        .players
        .iter()
        .map(player_of)
        .collect::<NifResult<Vec<_>>>()?;
    let difficulty = difficulty(scene.difficulty)?;
    let items = scene
        .items
        .iter()
        .map(|i| {
            Ok(valimc_core::mobs::sensing::SensedItem {
                uuid: uuid(&i.uuid)?,
                position: [i.x, i.y, i.z],
                item: i.item,
                count: i.count,
                pickup_delay: i.pickup_delay,
                in_water: i.in_water,
                components: None,
            })
        })
        .collect::<NifResult<Vec<_>>>()?;
    // The level borrows the registry for as long as any level lives: a
    // parity run keeps its handle (the Elixir's is a persistent term too).
    let loot: Option<&'static valimc_core::loot::Loot> = scene
        .loot
        .as_ref()
        .map(|r| &**Box::leak(Box::new(r.loot.clone())));
    let mut out = Vec::new();
    over_region(&region, zoom_seed, |level| {
        level.difficulty = difficulty;
        level.bright = scene.bright;
        level.monsters_burn = scene.monsters_burn;
        level.halloween = scene.halloween;
        level.darken = scene.darken;
        level.day = scene.day;
        level.rules.mob_griefing = scene.rules.mob_griefing;
        level.rules.mob_drops = scene.rules.mob_drops;
        level.rules.entity_drops = scene.rules.entity_drops;
        level.rules.universal_anger = scene.rules.universal_anger;
        level.villages = scene
            .villages
            .as_ref()
            .map(|v| v.iter().map(|&(x, y, z)| [x, y, z]).collect());
        level.loot = loot;
        if let Some((x, y, z)) = scene.treasure {
            level.locator = Some(&*Box::leak(Box::new(Fixed(Some([x, y, z])))));
        }
        level.knots = scene
            .knots
            .iter()
            .map(|&(x, y, z, id)| ([x, y, z], id))
            .collect();
        level.random =
            valimc_core::mobs::random::LegacyRandom::from_state(scene.level_seed).ok_or(bad())?;
        for tick in 0..scene.ticks {
            level.time = scene.time + tick as i64;
            if let Some(moved) = scene.moves.get(tick as usize) {
                for (p, (at, movement)) in players.iter_mut().zip(moved) {
                    p.position = [at.0, at.1, at.2];
                    p.movement = [movement.0, movement.1, movement.2];
                }
            }
            for &(at, i, what) in &scene.acts {
                if at == tick {
                    let mob = mobs.get_mut(i).ok_or(bad())?;
                    if what == atoms::love() {
                        valimc_core::mobs::animals::feed_love(mob, None);
                    } else if what == atoms::feed() {
                        valimc_core::mobs::animals::feed_baby(mob);
                    } else if what == atoms::fire() {
                        mob.body.mob.living.fire_ticks = 160;
                    } else if what == atoms::bullet() {
                        // A shulker bullet's hit, as its family takes it.
                        let facts = crate::mob_facts::facts()?;
                        let type_id = facts.entities.id(&mob.body.entity_type).ok_or(bad())?;
                        let kind = kinds.kind(type_id).ok_or(bad())?;
                        let source = facts
                            .damage_types
                            .id("minecraft:mob_projectile")
                            .ok_or(bad())?;
                        let mut hit = Hit::new(source, 4.0);
                        hit.direct = Some(valimc_core::mobs::combat::Attacker {
                            uuid: [0; 16],
                            entity_id: 0,
                            player: false,
                            entity_type: "minecraft:shulker_bullet".to_owned(),
                            mainhand: None,
                        });
                        kind.hurt_with(rules, &mut mob.body, &hit, &mut Vec::new());
                    } else if what == atoms::shot()
                        || what == atoms::poked()
                        || what == atoms::magic()
                    {
                        // A family's part of a hurt it turned away (an
                        // arrow) or took without a living attacker (a
                        // cactus).
                        let facts = crate::mob_facts::facts()?;
                        let type_id = facts.entities.id(&mob.body.entity_type).ok_or(bad())?;
                        let kind = kinds.kind(type_id).ok_or(bad())?;
                        if what == atoms::shot() {
                            let arrow = facts.damage_types.id("minecraft:arrow").ok_or(bad())?;
                            kind.repelled(&mut mob.body, &Hit::new(arrow, 4.0));
                        } else {
                            let name = if what == atoms::magic() {
                                "minecraft:magic"
                            } else {
                                "minecraft:cactus"
                            };
                            let source = facts.damage_types.id(name).ok_or(bad())?;
                            let hit = Hit::new(source, 1.0);
                            kind.hurt_with(rules, &mut mob.body, &hit, &mut Vec::new());
                        }
                    } else if what == atoms::struck() {
                        // The first player's melee hit beside its damage:
                        // the mind's hurt, then its family's.
                        let facts = crate::mob_facts::facts()?;
                        let source = facts
                            .damage_types
                            .id("minecraft:player_attack")
                            .ok_or(bad())?;
                        let p = players.first().ok_or(bad())?;
                        think::hurt(
                            mob,
                            Some(Ref {
                                kind: Kind::Player,
                                uuid: p.uuid,
                            }),
                            source,
                        );
                        let who = valimc_core::mobs::combat::Attacker {
                            uuid: p.uuid,
                            entity_id: p.id,
                            player: true,
                            entity_type: "minecraft:player".to_owned(),
                            mainhand: None,
                        };
                        let hit = Hit {
                            attacker: Some(who.clone()),
                            direct: Some(who),
                            ..Hit::new(source, 1.0)
                        };
                        let type_id = facts.entities.id(&mob.body.entity_type).ok_or(bad())?;
                        let kind = kinds.kind(type_id).ok_or(bad())?;
                        kind.hurt(&mut mob.body, &hit, &mut Vec::new());
                    } else if what == atoms::hurt() {
                        let facts = crate::mob_facts::facts()?;
                        let source = facts
                            .damage_types
                            .id("minecraft:player_attack")
                            .ok_or(bad())?;
                        let attacker = players.first().map(|p| Ref {
                            kind: Kind::Player,
                            uuid: p.uuid,
                        });
                        think::hurt(mob, attacker, source);
                    }
                }
            }
            // The owner's claims, events and loot seeds this tick.
            level.pois = valimc_core::mobs::ai::pois::store_claims(
                crate::mob_facts::facts()?,
                mobs.iter(),
                &level.dimension.clone(),
            );
            level.loot_seeds = scene.loot_seeds.iter().copied().collect();
            level.events = scene
                .events
                .iter()
                .filter(|(at, _, _)| *at == tick)
                .filter_map(|&(_, i, seen)| {
                    players
                        .get(i)
                        .map(|p| valimc_core::mobs::ai::brain::Reaction::Anger {
                            player: Ref {
                                kind: Kind::Player,
                                uuid: p.uuid,
                            },
                            seen,
                        })
                })
                .collect();
            let others: Vec<_> = statues
                .iter()
                .filter_map(|(id, m)| think::sensed(&ctx, *id, m))
                .enumerate()
                .map(|(k, row)| (mobs.len() + k, row))
                .collect();
            let collide = scene.collide.get(tick as usize);
            let mut ai = SectionAi::begin(
                ctx,
                level,
                players.clone(),
                items.clone(),
                ids.iter().copied().zip(mobs.iter_mut()),
                others,
            );
            let mut made = Vec::new();
            for i in 0..mobs.len() {
                let id = ids[i];
                let mut effects = ai.think(&mut mobs[i], id, None);
                for e in &effects {
                    if let Some(other) = think::other(e) {
                        if let Some(j) = mobs.iter().position(|m| m.uuid == other) {
                            ai.change_other(e, &mut mobs[j], ids[j]);
                        }
                    }
                }
                let [x, y, z] = mobs[i].position;
                if let Control::MoveTo { target, .. } = mobs[i].body.mob.motion.control {
                    let d = [target[0] - x, target[2] - z];
                    let l = (d[0] * d[0] + d[1] * d[1]).sqrt();
                    if l > 0.0 {
                        let s = l.min(scene.step);
                        mobs[i].position = [x + d[0] / l * s, y, z + d[1] / l * s];
                    }
                }
                let settled = ai.settle(&mut mobs[i], id, [x, z], Moves::default(), None);
                effects.extend(settled);
                if scene.post {
                    let collided = collide.is_some_and(|c| c.contains(&i));
                    effects.extend(post(rules, kinds, &mut mobs[i], ai.level, collided));
                }
                ai.moved(&mobs[i]);
                made.push(effects);
            }
            drop(ai);
            let records = mobs
                .iter()
                .map(|m| mob_term::encode(env, &record::record(m)))
                .collect::<NifResult<Vec<_>>>()?;
            let minds = mobs
                .iter()
                .map(|m| mind(env, m))
                .collect::<NifResult<Vec<_>>>()?;
            let effects = made
                .iter()
                .map(|list| list.iter().map(|e| effect(env, e)).collect())
                .collect::<NifResult<Vec<Vec<_>>>>()?;
            out.push((records, minds, effects, level.random.seed).encode(env));
        }
        Ok(())
    })?;
    Ok(out)
}

fn hand<'a>(env: Env<'a>, h: &Hand) -> NifResult<Term<'a>> {
    Ok(match h {
        Hand::Keep => atoms::keep().encode(env),
        Hand::Use(n) => (rustler::Atom::from_str(env, "use")?, *n).encode(env),
        Hand::Fill(stack) => (atoms::fill(), mob_term::encode(env, stack)?).encode(env),
        Hand::Wear(n) => (atoms::wear(), *n).encode(env),
    })
}

fn interact_event<'a>(env: Env<'a>, e: &InteractEvent) -> Term<'a> {
    match e {
        InteractEvent::Sound {
            sound,
            source,
            volume,
            pitch,
        } => (atoms::sound(), *sound, *source, *volume, *pitch).encode(env),
        InteractEvent::SoundBlock {
            sound,
            source,
            volume,
            pitch,
        } => (atoms::sound_block(), *sound, *source, *volume, *pitch).encode(env),
        InteractEvent::Entity(n) => (atoms::event(), *n).encode(env),
    }
}

/// One interaction on a mob of a record: `{outcome, record}`, the outcome
/// `:pass`, `:consume` or `{:done, hand, swing, events, others, drops,
/// convert, free}` (a conversion's record); `loot` the stacks of each
/// shearing table; `leash_id` holds a recorded lead now.
#[allow(clippy::too_many_arguments)]
#[rustler::nif]
fn mob_parity_interact<'a>(
    env: Env<'a>,
    record_facts: ResourceArc<MobRecordFacts>,
    record: Term<'a>,
    item: Term<'a>,
    player: Option<(Binary<'a>, V3, i32)>,
    infinite: bool,
    leash_id: Option<i32>,
    loot: Vec<(String, Vec<Term<'a>>)>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let value = mob_term::decode(record)?;
    let mut mob = record::restore(&value, &record_facts.0).map_err(|_| bad())?;
    // A lead held now (a record's looks for its holder).
    if let (Some(id), Some(leash)) = (leash_id, mob.body.mob.leash.as_mut()) {
        leash.restored = false;
        leash.id = Some(id);
    }
    let item = if item.is_atom() {
        None
    } else {
        Some(mob_term::decode(item)?)
    };
    let player = match &player {
        None => None,
        Some((who, at, id)) => Some(leads::Player {
            uuid: uuid(who)?,
            holder: Holder {
                position: [at.0, at.1, at.2],
                width: 0.6f32 as f64,
                height: 1.8f32 as f64,
                yaw: 0.0,
                movement: [0.0; 3],
                id: Some(*id),
            },
        }),
    };
    let request = Request {
        item,
        infinite,
        player: player.map(|p| p.uuid),
    };
    let mut tables = Vec::new();
    for (name, stacks) in &loot {
        let stacks = stacks
            .iter()
            .map(|s| mob_term::decode(*s))
            .collect::<NifResult<Vec<_>>>()?;
        tables.push((name.clone(), stacks));
    }
    let mut roll = |table: &str, _props: &[(String, String)]| -> Vec<Value> {
        tables
            .iter()
            .find(|(n, _)| n == table)
            .map(|(_, s)| s.clone())
            .unwrap_or_default()
    };
    let facts = crate::mob_facts::facts()?;
    let type_id = facts.entities.id(&mob.body.entity_type).ok_or(bad())?;
    let kind = crate::mob_facts::kinds()?.kind(type_id).ok_or(bad())?;
    let outcome = {
        let mut i = Interaction {
            rules,
            mob: &mut mob,
            request: &request,
            loot: &mut roll,
        };
        kinds::interact(&mut i, kind, player.as_ref())
    };
    let outcome = match outcome {
        Outcome::Pass => atoms::pass().encode(env),
        Outcome::Consume => atoms::consume().encode(env),
        Outcome::Done(d) => {
            let others = match &d.others {
                None => atoms::nil().encode(env),
                Some(o) => (
                    o.sound,
                    match o.source {
                        Source::Named(name) => name.encode(env),
                        Source::Id(id) => id.encode(env),
                    },
                    o.volume,
                    o.pitch,
                    match o.at {
                        At::Player => atoms::player(),
                        At::Animal => atoms::animal(),
                    },
                )
                    .encode(env),
            };
            let drops = d
                .drops
                .iter()
                .map(|x| {
                    Ok((
                        mob_term::encode(env, &x.stack)?,
                        v3(x.offset),
                        x.add.map(v3),
                    )
                        .encode(env))
                })
                .collect::<NifResult<Vec<_>>>()?;
            let convert = match &d.convert {
                None => atoms::nil().encode(env),
                Some(body) => {
                    let converted = NativeMob {
                        uuid: mob.uuid,
                        position: mob.position,
                        hops: 0,
                        body: (**body).clone(),
                    };
                    mob_term::encode(env, &record::record(&converted))?
                }
            };
            rustler::types::tuple::make_tuple(
                env,
                &[
                    atoms::done().encode(env),
                    hand(env, d.hand())?,
                    d.swing.encode(env),
                    d.events
                        .iter()
                        .map(|e| interact_event(env, e))
                        .collect::<Vec<_>>()
                        .encode(env),
                    others,
                    drops.encode(env),
                    convert,
                    d.free
                        .iter()
                        .map(|c| cell(*c))
                        .collect::<Vec<_>>()
                        .encode(env),
                ],
            )
        }
    };
    Ok((outcome, mob_term::encode(env, &record::record(&mob))?).encode(env))
}

/// `Conversion.convert/4` of a mob of a record into type `to` with `uuid` at
/// the `special` multiplier: the new mob's record where the old one stood.
#[rustler::nif]
fn mob_parity_convert<'a>(
    env: Env<'a>,
    record_facts: ResourceArc<MobRecordFacts>,
    record: Term<'a>,
    new_uuid: Binary<'a>,
    to: String,
    special: f64,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let kinds = crate::mob_facts::kinds()?;
    let value = mob_term::decode(record)?;
    let mob = record::restore(&value, &record_facts.0).map_err(|_| bad())?;
    let uuid = uuid(&new_uuid)?;
    let to = rules.facts.entities.id(&to).ok_or(bad())?;
    let body = kinds::convert(rules, kinds, &mob.body, &uuid, to, special).ok_or(bad())?;
    let converted = NativeMob {
        uuid,
        position: mob.position,
        hops: 0,
        body,
    };
    mob_term::encode(env, &record::record(&converted))
}

/// `death_drops/1` of a mob of a record: its family's own drops.
#[rustler::nif]
fn mob_parity_death_drops<'a>(
    env: Env<'a>,
    record_facts: ResourceArc<MobRecordFacts>,
    record: Term<'a>,
) -> NifResult<Vec<Term<'a>>> {
    let rules = rules()?;
    let value = mob_term::decode(record)?;
    let mob = record::restore(&value, &record_facts.0).map_err(|_| bad())?;
    let type_id = rules
        .facts
        .entities
        .id(&mob.body.entity_type)
        .ok_or(bad())?;
    let kind = crate::mob_facts::kinds()?.kind(type_id).ok_or(bad())?;
    kind.death_drops(&mob.body)
        .iter()
        .map(|stack| mob_term::encode(env, stack))
        .collect()
}

/// `split/2` of a dead mob of a record at its position: the records of the
/// mobs it becomes, each given the uuid `uuids` holds in turn.
#[rustler::nif]
fn mob_parity_split<'a>(
    env: Env<'a>,
    record_facts: ResourceArc<MobRecordFacts>,
    record: Term<'a>,
    uuids: Vec<Binary<'a>>,
) -> NifResult<Vec<Term<'a>>> {
    let rules = rules()?;
    let value = mob_term::decode(record)?;
    let mob = record::restore(&value, &record_facts.0).map_err(|_| bad())?;
    let type_id = rules
        .facts
        .entities
        .id(&mob.body.entity_type)
        .ok_or(bad())?;
    let kind = crate::mob_facts::kinds()?.kind(type_id).ok_or(bad())?;
    kind.split(rules, &mob.body, mob.position)
        .into_iter()
        .zip(&uuids)
        .map(|((body, position), id)| {
            let child = NativeMob {
                uuid: uuid(id)?,
                position,
                hops: 0,
                body,
            };
            mob_term::encode(env, &record::record(&child))
        })
        .collect()
}
