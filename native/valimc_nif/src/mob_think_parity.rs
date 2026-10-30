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
use valimc_core::mobs::combat::{AiMind, Rules};
use valimc_core::mobs::kinds::interact::{At, Hand, InteractEvent, Interaction, Outcome, Request};
use valimc_core::mobs::kinds::{self, leads};
use valimc_core::mobs::model::{Control, NativeMob};
use valimc_core::mobs::record;
use valimc_core::mobs::sensing::{Kind, Ref, SensedPlayer};
use valimc_core::mobs::term::Value;

mod atoms {
    rustler::atoms! {
        nil, love, feed, hurt, sound, sound_at, event, eat_block, dirt, destroy, offspring,
        bred, orb, lay, lead, knot_free, make_knot, raid_carrot, other, living, player,
        mob, item, keep, fill, wear, pass, consume, done, animal, sound_block,
        jump_ticks, jump_duration, was_on_ground, jump_delay, can_jump, move_to, wait,
        jumping, strafe, pickup, drop, swing, attack, alert
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
}

#[derive(NifMap)]
struct RulesT {
    mob_griefing: bool,
    mob_drops: bool,
    entity_drops: bool,
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
        swimming: false,
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
        Effect::Living(_) => (atoms::living(),).encode(env),
        _ => (atoms::other(),).encode(env),
    })
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
    let own = match s.own.family::<HopState>() {
        None => atoms::nil().encode(env),
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
        ],
    ))
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
    let mut players = scene
        .players
        .iter()
        .map(player_of)
        .collect::<NifResult<Vec<_>>>()?;
    let difficulty = difficulty(scene.difficulty)?;
    let mut out = Vec::new();
    over_region(&region, zoom_seed, |level| {
        level.difficulty = difficulty;
        level.bright = scene.bright;
        level.day = scene.day;
        level.rules.mob_griefing = scene.rules.mob_griefing;
        level.rules.mob_drops = scene.rules.mob_drops;
        level.rules.entity_drops = scene.rules.entity_drops;
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
            let mut ai = SectionAi::begin(
                ctx,
                level,
                players.clone(),
                vec![],
                ids.iter().copied().zip(mobs.iter_mut()),
                vec![],
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
                ai.moved(&mobs[i]);
                effects.extend(settled);
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
                    o.source,
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
