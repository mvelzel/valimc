//! The native mob AI (VMC-081d, `valimc_core::mobs::ai`) against
//! `Valimc.AI`, built only with the `parity` feature. Each runs over a
//! region's store as a mob's level: `mob_parity_ai_think` a mob's goals,
//! navigation and look control tick by tick (its AI step with a scripted
//! move toward its wanted position), `mob_parity_ai_random` random walk
//! targets, and `mob_parity_ai_controls` single look, body rotation and
//! smooth swimming steps. Each answers what the ExUnit test computes with
//! the Elixir: the mob's random state, rotations, mind and effects.

use crate::facts::{PHYSICS, STATES};
use crate::mob_facts::facts;
use crate::region::{with_store, Region};
use rustler::types::tuple::{get_tuple, make_tuple};
use rustler::{Atom, Binary, Encoder, Env, NifMap, NifResult, ResourceArc, Term};
use valimc_core::mobs::ai::control::{look, smooth_swimming};
use valimc_core::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use valimc_core::mobs::ai::goals::*;
use valimc_core::mobs::ai::mind::LookAt;
use valimc_core::mobs::ai::navigation::{self, NavKind, Navigation};
use valimc_core::mobs::ai::paths::NavPath;
use valimc_core::mobs::ai::selector::{self, Selector, Which};
use valimc_core::mobs::ai::{random_pos, DefaultHooks, Effect, Extra, MindState, Turn};
use valimc_core::mobs::facts::MobFacts;
use valimc_core::mobs::level::{self, Difficulty, Level, StoreBlocks};
use valimc_core::mobs::model::*;
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::sensing::{GameMode, Kind, Ref, SensedMob, SensedPlayer, Sensing};

mod atoms {
    rustler::atoms! {
        nil, wait, move_to, strafe, jumping, player, mob, item,
        swing, attack, alert, event, sound, sound_at, shoot, other, main_hand, off_hand,
        ground, water, fly, amphibious,
        survival, creative, adventure, spectator,
        peaceful, easy, normal, hard,
        default, land, away, towards, swimmable, swim_target, land_away, land_towards,
        look, body, swim_move, swim_look,
    }
}

type V3 = (f64, f64, f64);

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

fn v3(v: V3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

fn uuid(b: &Binary) -> NifResult<[u8; 16]> {
    b.as_slice().try_into().map_err(|_| bad())
}

#[derive(NifMap)]
struct MobT<'a> {
    uuid: Binary<'a>,
    id: i32,
    kind: String,
    position: V3,
    yaw: f64,
    pitch: f64,
    head: f64,
    body_yaw: f64,
    on_ground: bool,
    health: f64,
    fire_ticks: i32,
    air: i32,
    water: f64,
    random: u64,
    dimensions: V3,
    navigation: Atom,
    breaching: bool,
    climber: bool,
    home: Option<((i32, i32, i32), i32)>,
    /// An `%ItemStack{}` in its main hand.
    mainhand: Option<Term<'a>>,
    /// An ageable mob's `age` (its family data), else nil.
    age: Option<i64>,
    goals: Vec<Term<'a>>,
    targets: Vec<Term<'a>>,
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
}

#[derive(NifMap)]
struct OtherT<'a> {
    uuid: Binary<'a>,
    id: i32,
    kind: String,
    position: V3,
    dimensions: V3,
    age: i32,
}

#[derive(NifMap)]
struct SceneT<'a> {
    mob: MobT<'a>,
    others: Vec<OtherT<'a>>,
    players: Vec<PlayerT<'a>>,
    time: i64,
    ticks: i32,
    step: f64,
    difficulty: Atom,
    /// `isBrightOutside`.
    bright: bool,
    /// `{tick, player uuid, damage type}`: a hurt before that tick's think.
    hurt: Option<(i32, Binary<'a>, String)>,
}

fn difficulty(a: Atom) -> NifResult<Difficulty> {
    Ok(match a {
        a if a == atoms::peaceful() => Difficulty::Peaceful,
        a if a == atoms::easy() => Difficulty::Easy,
        a if a == atoms::normal() => Difficulty::Normal,
        a if a == atoms::hard() => Difficulty::Hard,
        _ => return Err(bad()),
    })
}

fn mode(a: Atom) -> NifResult<GameMode> {
    Ok(match a {
        a if a == atoms::survival() => GameMode::Survival,
        a if a == atoms::creative() => GameMode::Creative,
        a if a == atoms::adventure() => GameMode::Adventure,
        a if a == atoms::spectator() => GameMode::Spectator,
        _ => return Err(bad()),
    })
}

/// A goal from its spec `{name, args...}`.
fn goal(f: &MobFacts, spec: Term) -> NifResult<Box<dyn Goal>> {
    let t = get_tuple(spec)?;
    let name = t.first().ok_or(bad())?.atom_to_string()?;
    let n = |i: usize| -> NifResult<f64> { t.get(i).ok_or(bad())?.decode() };
    let i = |i: usize| -> NifResult<i64> { t.get(i).ok_or(bad())?.decode() };
    let b = |i: usize| -> NifResult<bool> { t.get(i).ok_or(bad())?.decode() };
    let types = |i: usize| -> NifResult<Vec<u16>> {
        let names: Vec<String> = t.get(i).ok_or(bad())?.decode()?;
        names
            .iter()
            .map(|s| f.entities.id(s).ok_or(bad()))
            .collect()
    };
    Ok(match name.as_str() {
        "float" => Box::new(Float::new()),
        "panic" => Box::new(Panic::new(n(1)?, None)),
        "stroll" => Box::new(RandomStroll::new(
            n(1)?,
            random_stroll::StrollOptions {
                water_avoiding: b(2)?,
                interval: i(3)?,
                ..Default::default()
            },
        )),
        "look_at_player" => Box::new(LookAtPlayer::new(n(1)?, n(2)?, false, None)),
        "look_around" => Box::new(RandomLookAround::new()),
        "melee" => Box::new(MeleeAttack::new(n(1)?, b(2)?, b(3)?)),
        "nat_player" => Box::new(NearestAttackableTarget::new(
            TargetKind::Player,
            None,
            b(1)?,
            target::TargetOptions {
                interval: i(2)?,
                ..Default::default()
            },
        )),
        "nat_mob" => Box::new(NearestAttackableTarget::new(
            TargetKind::Mob,
            Some(MobTypes::Types(types(1)?)),
            b(2)?,
            target::TargetOptions::default(),
        )),
        "hurt_by" => Box::new(HurtByTarget::new(b(1)?, types(2)?, vec![])),
        "restriction" => Box::new(MoveTowardsRestriction::new(n(1)?)),
        "towards_target" => Box::new(MoveTowardsTarget::new(n(1)?, n(2)?)),
        "tempt" => Box::new(Tempt::new(n(1)?, ItemTest::One(i(2)? as i32), b(3)?, 2.5)),
        "avoid_players" => Box::new(AvoidEntity::new(EntityTest::Players, n(1)?, n(2)?, n(3)?)),
        "restrict_sun" => Box::new(RestrictSun::new()),
        "flee_sun" => Box::new(FleeSun::new(n(1)?)),
        "leap" => Box::new(LeapAtTarget::new(n(1)?)),
        "breath_air" => Box::new(BreathAir::new()),
        "try_find_liquid" => Box::new(TryFindLiquid::new()),
        "climb_powder_snow" => Box::new(ClimbPowderSnow::new()),
        "ocelot_attack" => Box::new(OcelotAttack::new()),
        "bow" => Box::new(RangedBowAttack::new(n(1)?, i(2)?, n(3)?)),
        "follow_parent" => Box::new(FollowParent::new(n(1)?)),
        "swim" => Box::new(RandomStroll::new(
            n(1)?,
            random_stroll::StrollOptions {
                swim: true,
                interval: i(2)?,
                ..Default::default()
            },
        )),
        "look_at_mobs" => Box::new(LookAtPlayer::new(n(1)?, n(2)?, false, Some(types(3)?))),
        _ => return Err(bad()),
    })
}

fn selector_of(f: &MobFacts, specs: &[Term]) -> NifResult<Selector> {
    let mut goals = Vec::new();
    for spec in specs {
        let (priority, _, g): (i32, Term, Term) = spec.decode()?;
        goals.push((priority, flags_of(spec)?, goal(f, g)?));
    }
    Ok(Selector::new(goals))
}

// The flag atoms of a `{priority, flags, spec}` entry.
fn flags_of(spec: &Term) -> NifResult<u8> {
    let t = get_tuple(*spec)?;
    let list: Vec<Term> = t.get(1).ok_or(bad())?.decode()?;
    let mut out = 0;
    for a in list {
        out |= match a.atom_to_string()?.as_str() {
            "move" => MOVE,
            "look" => LOOK,
            "jump" => JUMP,
            "target" => TARGET,
            _ => return Err(bad()),
        };
    }
    Ok(out)
}

fn navigation_of(m: &MobT) -> NifResult<Navigation> {
    let kind = match m.navigation {
        a if a == atoms::ground() => NavKind::Ground,
        a if a == atoms::water() => NavKind::Water,
        a if a == atoms::fly() => NavKind::Fly,
        a if a == atoms::amphibious() => NavKind::Amphibious,
        _ => return Err(bad()),
    };
    let mut nav = Navigation::new(kind, m.breaching);
    nav.climber = m.climber;
    Ok(nav)
}

/// The native mob of `m` with a fresh mind of `goals` and `targets`.
fn mob_of(f: &MobFacts, m: &MobT) -> NifResult<NativeMob> {
    let motion = MobMotion {
        water: m.water,
        ..MobMotion::default()
    };
    let goals = selector_of(f, &m.goals)?;
    let mut navigation = navigation_of(m)?;
    // A `FloatGoal` makes a ground or flying navigation float (`AI.mind`).
    if goals
        .entries
        .iter()
        .any(|e| e.goal.as_ref().is_some_and(|g| g.is::<Float>()))
        && matches!(navigation.kind, NavKind::Ground | NavKind::Fly)
    {
        navigation.can_float = true;
    }
    let mut state = MindState::new(goals, selector_of(f, &m.targets)?, navigation);
    state.body_yaw = m.body_yaw;
    Ok(NativeMob {
        uuid: uuid(&m.uuid)?,
        position: v3(m.position),
        hops: 0,
        body: Body {
            entity_type: m.kind.clone(),
            yaw: m.yaw,
            pitch: m.pitch,
            head_yaw: m.head,
            velocity: [0.0; 3],
            on_ground: m.on_ground,
            no_gravity: false,
            data: match m.age {
                None => FamilyData::empty(),
                Some(age) => FamilyData::new(vec![(
                    valimc_core::mobs::term::Atom::new("age"),
                    valimc_core::mobs::term::Value::Int(age),
                )])
                .ok_or(bad())?,
            },
            mob: Mob {
                living: Living {
                    health: Health {
                        value: m.health,
                        maximum: m.health,
                        hurt_ticks: 0,
                        death_ticks: 0,
                        cooldown: 0,
                        last_hurt: 0.0,
                    },
                    last_mob_hurt: None,
                    absorption: 0.0,
                    effects: Effects::default(),
                    fire_ticks: m.fire_ticks,
                    air_supply: m.air,
                    freezing: Freezing::default(),
                },
                equipment: {
                    let mut e = Equipment::default();
                    if let Some(stack) = m.mainhand {
                        e.set(Slot::Mainhand, Some(crate::mob_term::decode(stack)?));
                    }
                    e
                },
                attributes: Attributes::default(),
                ai: Some(Mind {
                    random: LegacyRandom::from_state(m.random).ok_or(bad())?,
                    memories: None,
                    state: Some(Box::new(state)),
                }),
                no_ai: false,
                motion,
                hurt_by_player: None,
                player_memory: 0,
                hurt_by: None,
                death: None,
                persistent: false,
                left_handed: false,
                can_pick_up_loot: false,
                drop_chances: DropChances::default(),
                finalize: None,
                leash: None,
                home: m.home.map(|((x, y, z), radius)| Home {
                    center: [x, y, z],
                    radius,
                }),
                using: None,
            },
            custom_name: None,
            preserved: None,
            portal_cooldown: 0,
        },
    })
}

fn player_of(p: &PlayerT) -> NifResult<SensedPlayer> {
    let mut equipment = [None; 6];
    equipment[4] = p.mainhand;
    Ok(SensedPlayer {
        uuid: uuid(&p.uuid)?,
        id: p.id,
        position: v3(p.position),
        yaw: p.yaw,
        pitch: p.pitch,
        eye: 1.62,
        width: 0.6,
        height: 1.8,
        mode: mode(p.mode)?,
        invulnerable: mode(p.mode)? == GameMode::Creative,
        alive: true,
        crouching: false,
        swimming: false,
        invisible: false,
        armor_cover: 0.0,
        equipment,
        movement: [0.0; 3],
        velocity: [0.0; 3],
        health: 20.0,
        effects: vec![],
    })
}

fn sensed(
    uuid: [u8; 16],
    id: i32,
    type_id: u16,
    position: [f64; 3],
    d: [f64; 3],
) -> SensedMob<Extra> {
    SensedMob {
        uuid,
        id,
        type_id,
        position,
        yaw: 0.0,
        pitch: 0.0,
        eye: d[2],
        width: d[0],
        height: d[1],
        own_box: None,
        alive: true,
        recent_mob_hurt: false,
        baby: false,
        huntable: true,
        target: None,
        in_love: 0,
        age: 0,
        in_water: false,
        invulnerable: false,
        killed_by: None,
        panicking: false,
        extra: Extra::default(),
    }
}

/// A region's store as a level.
fn over_region<T>(
    region: &Region,
    zoom_seed: i64,
    f: impl FnOnce(&mut Level) -> NifResult<T>,
) -> NifResult<T> {
    let facts = facts()?;
    let physics = PHYSICS.get().ok_or(bad())?;
    let states = STATES.get().ok_or(bad())?;
    let plains = facts
        .registries
        .id("minecraft:worldgen/biome", "minecraft:plains")
        .ok_or(bad())? as u16;
    let mut result = None;
    with_store(region, |store| {
        let blocks = StoreBlocks(store);
        let environment = level::Store {
            store,
            zoom_seed,
            plains,
        };
        let mut level = Level::new(
            &blocks,
            &environment,
            facts,
            physics,
            states,
            LegacyRandom::new(7),
        );
        result = Some(f(&mut level));
        Ok(())
    })
    .map_err(|a| rustler::Error::Term(Box::new(a)))?;
    result.ok_or(bad())?
}

fn turn<'t, 'w, R>(
    m: &'t mut NativeMob,
    id: i32,
    dims: [f64; 3],
    level: &'t mut Level<'w>,
    sensing: &'t mut Sensing<Extra>,
    run: impl FnOnce(&mut Turn) -> R,
) -> NifResult<R> {
    let f = level.facts;
    let type_id = f.entities.id(&m.body.entity_type).ok_or(bad())?;
    let ai = f.ai.mob(type_id).ok_or(bad())?;
    let paths = crate::path::path_facts().ok_or(bad())?;
    let mut t = Turn::new(
        m,
        id,
        type_id,
        ai,
        dims,
        level,
        sensing,
        paths,
        &DefaultHooks,
    );
    Ok(run(&mut t))
}

fn reference<'a>(env: Env<'a>, r: &Ref) -> Term<'a> {
    let kind = match r.kind {
        Kind::Player => atoms::player(),
        Kind::Mob => atoms::mob(),
        Kind::Item => atoms::item(),
    };
    (kind, crate::binary(env, &r.uuid)).encode(env)
}

fn hand(h: Hand) -> Atom {
    match h {
        Hand::MainHand => atoms::main_hand(),
        Hand::OffHand => atoms::off_hand(),
    }
}

fn effect<'a>(env: Env<'a>, e: &Effect) -> Term<'a> {
    match e {
        Effect::Swing(h) => (atoms::swing(), hand(*h)).encode(env),
        Effect::Attack(r) => (atoms::attack(), reference(env, r)).encode(env),
        Effect::Alert { mob, target } => (
            atoms::alert(),
            crate::binary(env, mob),
            reference(env, target),
        )
            .encode(env),
        Effect::Event(n) => (atoms::event(), *n).encode(env),
        Effect::Sound {
            id, volume, pitch, ..
        } => (atoms::sound(), *id, *volume, *pitch).encode(env),
        Effect::SoundAt {
            id,
            at,
            volume,
            pitch,
            ..
        } => (
            atoms::sound_at(),
            *id,
            (at[0], at[1], at[2]),
            *volume,
            *pitch,
        )
            .encode(env),
        Effect::Shoot(s) => {
            (atoms::shoot(), reference(env, &s.target), s.power, s.pitch).encode(env)
        }
        _ => (atoms::other(),).encode(env),
    }
}

fn control<'a>(env: Env<'a>, c: &Control) -> Term<'a> {
    match c {
        Control::Wait => atoms::wait().encode(env),
        Control::MoveTo { target, speed } => {
            (atoms::move_to(), (target[0], target[1], target[2]), *speed).encode(env)
        }
        Control::Jumping { speed } => (atoms::jumping(), *speed).encode(env),
        Control::Strafe {
            forward,
            right,
            speed,
        } => (atoms::strafe(), *forward, *right, *speed).encode(env),
    }
}

fn look_term<'a>(env: Env<'a>, l: &Option<LookAt>) -> Term<'a> {
    match l {
        None => atoms::nil().encode(env),
        Some(l) => make_tuple(
            env,
            &[
                l.x.encode(env),
                l.y.encode(env),
                l.z.encode(env),
                l.y_max.encode(env),
                l.x_max.encode(env),
                l.cooldown.encode(env),
            ],
        ),
    }
}

fn path_term<'a>(env: Env<'a>, nav: &Navigation) -> Term<'a> {
    match &nav.path {
        None => atoms::nil().encode(env),
        Some(p) => {
            let nodes: Vec<(i32, i32, i32)> = p.nodes.iter().map(|n| (n[0], n[1], n[2])).collect();
            (p.index, nodes, nav.speed).encode(env)
        }
    }
}

/// What a step leaves: `{random, position, {yaw, pitch, head, body_yaw},
/// look, control, path, target, aggressive, jump, running goals, running
/// targets, effects}`.
fn observe<'a>(env: Env<'a>, t: &Turn, effects: &[Effect]) -> Term<'a> {
    let m = &t.mind;
    let running = |s: &Selector| -> Vec<&'static str> { s.running().map(|g| g.name()).collect() };
    let target = match &m.target {
        None => atoms::nil().encode(env),
        Some(r) => reference(env, r),
    };
    make_tuple(
        env,
        &[
            t.random.seed.encode(env),
            (t.x(), t.y(), t.z()).encode(env),
            (t.yaw(), t.pitch(), t.head(), m.body_yaw).encode(env),
            look_term(env, &m.look),
            control(env, &t.mob.body.mob.motion.control),
            path_term(env, &m.navigation),
            target,
            m.aggressive.encode(env),
            m.jump.encode(env),
            running(&m.goals).encode(env),
            running(&m.targets).encode(env),
            effects
                .iter()
                .map(|e| effect(env, e))
                .collect::<Vec<_>>()
                .encode(env),
        ],
    )
}

/// One AI step as the ExUnit test runs it: the tick count, the item in use,
/// idle time and
/// sight cache, the target and goal selectors (a full update on alternate
/// ticks by id), navigation and the look control, then a scripted move
/// toward the wanted position by at most `step` (horizontally) and the body
/// rotation control.
fn step(t: &mut Turn, step: f64) {
    t.mind.tick += 1;
    // `updatingUsingItem`'s count (the base tick's, before the AI step).
    let mob = &mut t.mob.body.mob;
    if let Some(u) = &mut mob.using {
        let slot = match u.hand {
            Hand::MainHand => Slot::Mainhand,
            Hand::OffHand => Slot::Offhand,
        };
        if mob.equipment.get(slot).is_none() {
            mob.using = None;
        } else {
            u.ticks += 1;
        }
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
    navigation::tick(t);
    look::tick(t);
    let [x, y, z] = t.pos();
    if let Control::MoveTo { target, .. } = t.mob.body.mob.motion.control {
        let d = [target[0] - x, target[2] - z];
        let l = (d[0] * d[0] + d[1] * d[1]).sqrt();
        if l > 0.0 {
            let s = l.min(step);
            t.mob.position = [x + d[0] / l * s, y, z + d[1] / l * s];
        }
    }
    look::body(t, [x, z]);
}

/// `{tick observations}` of `scene` over the region's store.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_parity_ai_think<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    zoom_seed: i64,
    scene: SceneT<'a>,
) -> NifResult<Vec<Term<'a>>> {
    let f = facts()?;
    let mut mob = mob_of(f, &scene.mob)?;
    let type_id = f.entities.id(&scene.mob.kind).ok_or(bad())?;
    let dims = v3(scene.mob.dimensions);
    let players = scene
        .players
        .iter()
        .map(player_of)
        .collect::<NifResult<Vec<_>>>()?;
    let mut me = sensed(mob.uuid, scene.mob.id, type_id, mob.position, dims);
    me.age = scene.mob.age.unwrap_or(0) as i32;
    let mut mobs = vec![me];
    for o in &scene.others {
        let ty = f.entities.id(&o.kind).ok_or(bad())?;
        let mut row = sensed(uuid(&o.uuid)?, o.id, ty, v3(o.position), v3(o.dimensions));
        row.age = o.age;
        mobs.push(row);
    }
    let mut sensing = Sensing::new(players, vec![], mobs);
    let hurt_damage = match &scene.hurt {
        Some((_, _, name)) => Some(f.damage_types.id(name).ok_or(bad())?),
        None => None,
    };
    let difficulty = difficulty(scene.difficulty)?;
    let mut out = Vec::new();
    over_region(&region, zoom_seed, |level| {
        level.difficulty = difficulty;
        level.bright = scene.bright;
        for i in 0..scene.ticks {
            level.time = scene.time + i as i64;
            let obs = turn(&mut mob, scene.mob.id, dims, level, &mut sensing, |t| {
                if let (Some((at, who, _)), Some(source)) = (&scene.hurt, hurt_damage) {
                    if *at == i {
                        let attacker = Ref {
                            kind: Kind::Player,
                            uuid: uuid(who).unwrap_or([0; 16]),
                        };
                        t.mind.hurt(Some(attacker), source);
                    }
                }
                step(t, scene.step);
                let effects = std::mem::take(&mut t.effects);
                let obs = observe(env, t, &effects);
                t.mind.jump = false;
                obs
            })?;
            let at = mob.position;
            sensing.resense(&mob.uuid, |m| m.position = at);
            out.push(obs);
        }
        Ok(())
    })?;
    Ok(out)
}

/// Random walk targets: each case `{op, mob, args}` answers `{position |
/// nil, random}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_parity_ai_random<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    zoom_seed: i64,
    cases: Vec<(Atom, MobT<'a>, Term<'a>)>,
) -> NifResult<Vec<Term<'a>>> {
    let f = facts()?;
    over_region(&region, zoom_seed, |level| {
        let mut out = Vec::new();
        for (op, m, args) in &cases {
            let mut mob = mob_of(f, m)?;
            let mut sensing = Sensing::default();
            let a = get_tuple(*args)?;
            let n = |i: usize| -> NifResult<i32> { a.get(i).ok_or(bad())?.decode() };
            let p = |i: usize| -> NifResult<[f64; 3]> { Ok(v3(a.get(i).ok_or(bad())?.decode()?)) };
            let r = |i: usize| -> NifResult<f64> { a.get(i).ok_or(bad())?.decode() };
            let (h, v) = (n(0)?, n(1)?);
            let op = *op;
            let from = if a.len() > 2 { Some(p(2)?) } else { None };
            let radians = if a.len() > 3 { Some(r(3)?) } else { None };
            let found = turn(&mut mob, m.id, v3(m.dimensions), level, &mut sensing, |t| {
                Ok(match op {
                    o if o == atoms::default() => random_pos::default(t, h, v),
                    o if o == atoms::land() => random_pos::land(t, h, v),
                    o if o == atoms::away() => {
                        random_pos::default_away(t, h, v, from.ok_or(bad())?)
                    }
                    o if o == atoms::towards() => random_pos::default_towards(
                        t,
                        h,
                        v,
                        from.ok_or(bad())?,
                        radians.ok_or(bad())?,
                    ),
                    o if o == atoms::swimmable() => random_pos::swimmable(t, h, v),
                    o if o == atoms::swim_target() => random_pos::swim_target(t),
                    o if o == atoms::land_away() => {
                        random_pos::land_away(t, h, v, from.ok_or(bad())?)
                    }
                    o if o == atoms::land_towards() => {
                        random_pos::land_towards(t, h, v, from.ok_or(bad())?)
                    }
                    _ => return Err(bad()),
                })
            })??;
            let random = mob.body.mob.ai.as_ref().ok_or(bad())?.random.seed;
            let pos = match found {
                None => atoms::nil().encode(env),
                Some([x, y, z]) => (x, y, z).encode(env),
            };
            out.push((pos, random).encode(env));
        }
        Ok(out)
    })
}

/// Control steps: each case `{op, mob, args}` (`:look` with `{look |
/// nil, navigating}`, `:body` with `{xo, zo, stable_head, stable_time}`,
/// `:swim_move` with `{max_x, max_y, in_water, out, gravity, wanted,
/// speed, navigating}`, `:swim_look` with `{look | nil, navigating,
/// max_from_center}`) answers `{yaw, pitch, head, body_yaw, stable_head,
/// stable_time, look, set}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_parity_ai_controls<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    zoom_seed: i64,
    cases: Vec<(Atom, MobT<'a>, Term<'a>)>,
) -> NifResult<Vec<Term<'a>>> {
    let f = facts()?;
    let look_of = |t: Term| -> NifResult<Option<LookAt>> {
        if t.is_atom() {
            return Ok(None);
        }
        let (x, y, z, y_max, x_max, cooldown): (f64, f64, f64, f64, f64, i32) = t.decode()?;
        Ok(Some(LookAt {
            x,
            y,
            z,
            y_max,
            x_max,
            cooldown,
        }))
    };
    let navigating = |t: &mut Turn, on: bool| {
        t.mind.navigation.path = on.then(|| NavPath {
            nodes: vec![[0, 0, 0]],
            types: vec![0],
            index: 0,
            target: [0, 0, 0],
            reached: false,
        });
    };
    over_region(&region, zoom_seed, |level| {
        let mut out = Vec::new();
        for (op, m, args) in &cases {
            let mut mob = mob_of(f, m)?;
            let mut sensing = Sensing::default();
            let a = get_tuple(*args)?;
            let at = |i: usize| a.get(i).copied().ok_or(bad());
            let op = *op;
            let result = turn(&mut mob, m.id, v3(m.dimensions), level, &mut sensing, |t| {
                if op == atoms::look() {
                    t.mind.look = look_of(at(0)?)?;
                    navigating(t, at(1)?.decode()?);
                    look::tick(t);
                } else if op == atoms::body() {
                    let (xo, zo, head, time): (f64, f64, f64, i32) = (
                        at(0)?.decode()?,
                        at(1)?.decode()?,
                        at(2)?.decode()?,
                        at(3)?.decode()?,
                    );
                    t.mind.stable_head = head;
                    t.mind.stable_time = time;
                    look::body(t, [xo, zo]);
                } else if op == atoms::swim_move() {
                    let controls = smooth_swimming::SmoothSwimming {
                        max_x: at(0)?.decode()?,
                        max_y: at(1)?.decode()?,
                        in_water: at(2)?.decode()?,
                        out: at(3)?.decode()?,
                        gravity: at(4)?.decode()?,
                    };
                    let wanted: Option<V3> = at(5)?.decode()?;
                    if let Some(w) = wanted {
                        t.move_to(v3(w), at(6)?.decode()?);
                    }
                    navigating(t, at(7)?.decode()?);
                    smooth_swimming::tick(t, &controls);
                } else if op == atoms::swim_look() {
                    t.mind.look = look_of(at(0)?)?;
                    navigating(t, at(1)?.decode()?);
                    smooth_swimming::look(t, at(2)?.decode()?);
                } else {
                    return Err(bad());
                }
                let set = match &t.mob.body.mob.motion.set {
                    Some(MotionSet::Inputs { speed, inputs, .. }) => {
                        (*speed, inputs[0], inputs[1], inputs[2]).encode(env)
                    }
                    _ => atoms::nil().encode(env),
                };
                Ok(make_tuple(
                    env,
                    &[
                        t.yaw().encode(env),
                        t.pitch().encode(env),
                        t.head().encode(env),
                        t.mind.body_yaw.encode(env),
                        t.mind.stable_head.encode(env),
                        t.mind.stable_time.encode(env),
                        look_term(env, &t.mind.look),
                        set,
                    ],
                ))
            })??;
            out.push(result);
        }
        Ok(out)
    })
}
