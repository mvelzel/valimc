//! The AI machinery over small scenes: the selector's semantics with
//! scripted goals, the controls, random walk targets, navigation over a
//! flat floor and a few goals end to end. The ExUnit parity tests compare
//! these against `Valimc.AI` draw for draw over generated terrain.

use super::control::look;
use super::goal::{Goal, LOOK, MOVE, TARGET};
use super::goals::{self, LookAtPlayer, MeleeAttack, RandomLookAround, RandomStroll};
use super::hooks::DefaultHooks;
use super::mind::{LookAt, MindState};
use super::navigation::{self, NavKind, Navigation};
use super::selector::{self, Selector, Which};
use super::turn::Turn;
use super::{random_pos, Effect, Extra};
use crate::mobs::facts::ai::AiMob;
use crate::mobs::facts::tests::fixture;
use crate::mobs::facts::MobFacts;
use crate::mobs::level::tests::physics;
use crate::mobs::level::{Level, Unknown};
use crate::mobs::model::*;
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{GameMode, Kind, Ref, SensedPlayer, Sensing};
use crate::path::{types, PathFacts, FLYABLE, LAND, SWIMMABLE, WATER_BLOCK};
use crate::physics::facts::Facts as PhysicsFacts;
use crate::physics::source::States;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

const ZOMBIE: u16 = 1;
const STONE: u16 = 1;

struct Scene {
    physics: PhysicsFacts,
    states: crate::facts::StateFacts,
    facts: MobFacts,
    paths: PathFacts,
    blocks: States,
    ai: AiMob,
}

fn scene() -> Scene {
    let (physics, states) = physics();
    let mut cells = HashMap::new();
    for x in -20..=20 {
        for z in -20..=20 {
            cells.insert([x, 63, z], STONE);
            for y in 64..=70 {
                cells.insert([x, y, z], 0);
            }
        }
    }
    // A wall across x = 3 from z = -2 to 2.
    for z in -2..=2 {
        cells.insert([3, 64, z], STONE);
        cells.insert([3, 65, z], STONE);
    }
    let paths = PathFacts::new(
        vec![
            types::OPEN,
            types::BLOCKED,
            types::WATER,
            types::FENCE,
            types::BLOCKED,
        ],
        vec![LAND | FLYABLE, 0, SWIMMABLE | WATER_BLOCK, 0, 0],
    )
    .unwrap();
    let mut malus = vec![0.0; types::COUNT];
    malus[types::BLOCKED as usize] = -1.0;
    malus[types::WATER as usize] = 8.0;
    malus[types::FENCE as usize] = -1.0;
    let ai = AiMob {
        max_head_y_rot: 75.0,
        max_head_x_rot: 40.0,
        head_rot_speed: 10.0,
        ambient_sound: None,
        ambient_interval: 80,
        volume: 1.0,
        monster: true,
        malus,
        goals: vec![],
        targets: vec![],
    };
    Scene {
        physics,
        states,
        facts: fixture(),
        paths,
        blocks: States(cells),
        ai,
    }
}

fn uuid(n: u8) -> [u8; 16] {
    let mut u = [0; 16];
    u[0] = n;
    u[15] = n;
    u
}

fn mob(n: u8, position: [f64; 3]) -> NativeMob {
    NativeMob {
        uuid: uuid(n),
        position,
        hops: 0,
        body: Body {
            entity_type: "minecraft:zombie".into(),
            yaw: 0.0,
            pitch: 0.0,
            head_yaw: 0.0,
            velocity: [0.0; 3],
            on_ground: true,
            no_gravity: false,
            data: FamilyData::empty(),
            mob: Mob {
                living: Living {
                    health: Health {
                        value: 20.0,
                        maximum: 20.0,
                        hurt_ticks: 0,
                        death_ticks: 0,
                        cooldown: 0,
                        last_hurt: 0.0,
                    },
                    last_mob_hurt: None,
                    absorption: 0.0,
                    effects: Effects::default(),
                    fire_ticks: -1,
                    air_supply: 300,
                    freezing: Freezing::default(),
                },
                equipment: Equipment::default(),
                attributes: Attributes::default(),
                ai: Some(Mind {
                    random: LegacyRandom::from_uuid(&uuid(n)),
                    memories: None,
                    state: Some(Box::default()),
                }),
                no_ai: false,
                motion: MobMotion::default(),
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
                home: None,
                using: None,
            },
            custom_name: None,
            preserved: None,
            portal_cooldown: 0,
        },
    }
}

fn player(n: u8, position: [f64; 3]) -> SensedPlayer {
    SensedPlayer {
        uuid: uuid(n),
        id: 100 + n as i32,
        position,
        yaw: 0.0,
        pitch: 0.0,
        eye: 1.62,
        width: 0.6,
        height: 1.8,
        mode: GameMode::Survival,
        invulnerable: false,
        alive: true,
        crouching: false,
        swimming: false,
        invisible: false,
        armor_cover: 0.0,
        equipment: [None; 6],
        movement: [0.0; 3],
        velocity: [0.0; 3],
        health: 20.0,
        effects: vec![],
    }
}

fn run<R>(
    s: &Scene,
    m: &mut NativeMob,
    sensing: &mut Sensing<Extra>,
    time: i64,
    f: impl FnOnce(&mut Turn) -> R,
) -> R {
    let mut level = Level::new(
        &s.blocks,
        &Unknown,
        &s.facts,
        &s.physics,
        &s.states,
        LegacyRandom::new(7),
    );
    level.time = time;
    let mut t = Turn::new(
        m,
        1,
        ZOMBIE,
        &s.ai,
        [0.6, 1.95, 1.74],
        &mut level,
        sensing,
        &s.paths,
        &DefaultHooks,
    );
    f(&mut t)
}

fn state(m: &NativeMob) -> &MindState {
    m.body.mob.ai.as_ref().unwrap().state.as_ref().unwrap()
}

// ## Selector

type Log = Arc<Mutex<Vec<String>>>;

/// A goal answering scripted `can_use` and `can_continue` values.
#[derive(Clone, Debug)]
struct Scripted {
    tag: &'static str,
    usable: bool,
    keep: bool,
    every: bool,
    interruptable: bool,
    log: Log,
}

impl PartialEq for Scripted {
    fn eq(&self, other: &Scripted) -> bool {
        self.tag == other.tag
    }
}

impl Scripted {
    fn new(tag: &'static str, usable: bool, log: &Log) -> Scripted {
        Scripted {
            tag,
            usable,
            keep: true,
            every: false,
            interruptable: true,
            log: log.clone(),
        }
    }

    fn note(&self, what: &str) {
        self.log.lock().unwrap().push(format!("{}:{what}", self.tag));
    }
}

impl Goal for Scripted {
    fn can_use(&mut self, _t: &mut Turn) -> bool {
        self.usable
    }

    fn can_continue(&mut self, _t: &mut Turn) -> bool {
        self.keep
    }

    fn start(&mut self, _t: &mut Turn) {
        self.note("start");
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.note("stop");
    }

    fn tick(&mut self, _t: &mut Turn) {
        self.note("tick");
    }

    fn every_tick(&self) -> bool {
        self.every
    }

    fn interruptable(&self) -> bool {
        self.interruptable
    }

    fn name(&self) -> &'static str {
        self.tag
    }
}

fn with_goals(m: &mut NativeMob, goals: Vec<(i32, u8, Box<dyn Goal>)>) {
    let s = m.body.mob.ai.as_mut().unwrap().state.as_mut().unwrap();
    s.goals = Selector::new(goals);
}

fn taken(log: &Log) -> Vec<String> {
    std::mem::take(&mut *log.lock().unwrap())
}

#[test]
fn selector_starts_by_priority_and_flags() {
    let s = scene();
    let log: Log = Arc::default();
    let mut m = mob(1, [0.5, 64.0, 0.5]);
    with_goals(
        &mut m,
        vec![
            (2, MOVE, Box::new(Scripted::new("walk", true, &log))),
            (1, MOVE | LOOK, Box::new(Scripted::new("chase", false, &log))),
            (3, LOOK, Box::new(Scripted::new("look", true, &log))),
        ],
    );
    let mut sensing = Sensing::default();
    run(&s, &mut m, &mut sensing, 0, |t| selector::tick(t, Which::Goals));
    assert_eq!(
        taken(&log),
        ["walk:start", "look:start", "walk:tick", "look:tick"]
    );
    assert_eq!(state(&m).goals.lock(MOVE), Some(0));
    assert_eq!(state(&m).goals.lock(LOOK), Some(2));

    // A usable goal of a lower priority number stops both holders.
    m.body
        .mob
        .ai
        .as_mut()
        .unwrap()
        .state
        .as_mut()
        .unwrap()
        .goals
        .change::<Scripted>(|g| {
            if g.tag == "chase" {
                g.usable = true;
            }
        });
    run(&s, &mut m, &mut sensing, 0, |t| selector::tick(t, Which::Goals));
    assert_eq!(
        taken(&log),
        ["walk:stop", "look:stop", "chase:start", "chase:tick"]
    );
    assert_eq!(state(&m).goals.lock(MOVE), Some(1));
    assert_eq!(state(&m).goals.lock(LOOK), Some(1));
    let running: Vec<_> = state(&m).goals.running().map(|g| g.name()).collect();
    assert_eq!(running, ["chase"]);
}

#[test]
fn selector_cleans_up_and_respects_interruption() {
    let s = scene();
    let log: Log = Arc::default();
    let mut m = mob(1, [0.5, 64.0, 0.5]);
    let mut breath = Scripted::new("breath", true, &log);
    breath.interruptable = false;
    let mut every = Scripted::new("float", true, &log);
    every.every = true;
    with_goals(
        &mut m,
        vec![
            (5, MOVE, Box::new(breath)),
            (1, MOVE, Box::new(Scripted::new("chase", false, &log))),
            (0, TARGET, Box::new(every)),
        ],
    );
    let mut sensing = Sensing::default();
    run(&s, &mut m, &mut sensing, 0, |t| selector::tick(t, Which::Goals));
    taken(&log);
    // The uninterruptable holder keeps its flag from a better goal.
    m.body.mob.ai.as_mut().unwrap().state.as_mut().unwrap().goals.change::<Scripted>(|g| {
        if g.tag == "chase" {
            g.usable = true;
        }
    });
    run(&s, &mut m, &mut sensing, 0, |t| selector::tick_running(t, Which::Goals, false));
    assert_eq!(taken(&log), ["float:tick"]);
    run(&s, &mut m, &mut sensing, 0, |t| selector::tick(t, Which::Goals));
    assert_eq!(taken(&log), ["breath:tick", "float:tick"]);
    // One that cannot continue stops and frees its flag; a disabled flag
    // stops what holds it.
    m.body.mob.ai.as_mut().unwrap().state.as_mut().unwrap().goals.change::<Scripted>(|g| {
        if g.tag == "breath" {
            g.keep = false;
            g.usable = false;
        }
    });
    run(&s, &mut m, &mut sensing, 0, |t| selector::tick(t, Which::Goals));
    assert_eq!(
        taken(&log),
        ["breath:stop", "chase:start", "chase:tick", "float:tick"]
    );
    run(&s, &mut m, &mut sensing, 0, |t| {
        t.mind.disabled = MOVE;
        selector::tick(t, Which::Goals)
    });
    assert_eq!(taken(&log), ["chase:stop", "float:tick"]);
    assert_eq!(state(&m).goals.lock(MOVE), None);
    assert!(state(&m).goals.runs::<Scripted>());
}

// ## Turn

#[test]
fn turn_detaches_and_restores_the_mind() {
    let s = scene();
    let mut m = mob(1, [0.5, 64.0, 0.5]);
    let mut sensing = Sensing::default();
    let (a, b) = run(&s, &mut m, &mut sensing, 0, |t| {
        t.mind.tick = 5;
        (t.int(100), t.gaussian())
    });
    let mut r = LegacyRandom::from_uuid(&uuid(1));
    assert_eq!(a, r.int(100));
    let mut held = None;
    assert_eq!(b, r.gaussian(&mut held));
    let mind = m.body.mob.ai.as_ref().unwrap();
    assert_eq!(mind.random, r);
    assert_eq!(mind.state.as_ref().unwrap().gaussian, held);
    assert_eq!(state(&m).tick, 5);
}

#[test]
fn look_control_turns_head_and_pitch() {
    let s = scene();
    let mut m = mob(1, [0.5, 64.0, 0.5]);
    let mut sensing = Sensing::default();
    run(&s, &mut m, &mut sensing, 0, |t| {
        t.mind.look = Some(LookAt {
            x: 10.5,
            y: 70.0,
            z: 0.5,
            y_max: 10.0,
            x_max: 40.0,
            cooldown: 2,
        });
        look::tick(t);
    });
    // Facing +x is yaw -90: at most ten degrees a tick.
    assert_eq!(m.body.head_yaw, -10.0);
    assert!(m.body.pitch < 0.0 && m.body.pitch >= -40.0);
    assert_eq!(state(&m).look.unwrap().cooldown, 1);
    // A still body follows its head after ten ticks, over ten more.
    run(&s, &mut m, &mut sensing, 0, |t| {
        t.mob.body.head_yaw = 60.0;
        t.mind.stable_head = 60.0;
        for _ in 0..15 {
            look::body(t, [0.5, 0.5]);
        }
    });
    let b = state(&m).body_yaw;
    assert!(b > 0.0 && b < 60.0, "{b}");
}

// ## Random walk targets and navigation

#[test]
fn random_targets_stand_on_the_floor() {
    let s = scene();
    let mut sensing = Sensing::default();
    let mut m = mob(2, [0.5, 64.0, 0.5]);
    for _ in 0..20 {
        let p = run(&s, &mut m, &mut sensing, 0, |t| random_pos::default(t, 10, 7));
        if let Some([x, y, z]) = p {
            assert_eq!(y, 64.0, "{x} {z}");
            assert_eq!((x - 0.5).rem_euclid(1.0), 0.0);
        }
    }
    let p = run(&s, &mut m, &mut sensing, 0, |t| random_pos::land(t, 10, 7));
    assert!(p.is_some());
}

#[test]
fn navigation_follows_a_path_around_a_wall() {
    let s = scene();
    let mut sensing = Sensing::default();
    let mut m = mob(3, [0.5, 64.0, 0.5]);
    let started = run(&s, &mut m, &mut sensing, 100, |t| {
        navigation::move_to(t, [6.5, 64.0, 0.5], 1.0)
    });
    assert!(started);
    let path = state(&m).navigation.path.clone().unwrap();
    assert_eq!(path.target, [6, 64, 0]);
    assert!(path.reached);
    assert!(path.nodes.iter().all(|n| n[0] != 3 || n[2].abs() > 2));
    // Walking it node by node: each tick sets the wanted position at the
    // next node's floor and passes nodes it stands at.
    for tick in 0..200 {
        let done = run(&s, &mut m, &mut sensing, 101 + tick, |t| {
            navigation::tick(t);
            if let Control::MoveTo { target, .. } = t.mob.body.mob.motion.control {
                let p = t.pos();
                let d = [target[0] - p[0], target[2] - p[2]];
                let l = (d[0] * d[0] + d[1] * d[1]).sqrt().max(1e-9);
                let step = l.min(0.3);
                t.mob.position = [p[0] + d[0] / l * step, 64.0, p[2] + d[1] / l * step];
            }
            t.mind.navigation.done()
        });
        if done {
            break;
        }
    }
    assert!(state(&m).navigation.done());
    let [x, _, z] = m.position;
    assert!((x - 6.5).abs() < 1.0 && (z - 0.5).abs() < 1.5, "{x} {z}");
}

#[test]
fn navigation_detects_a_stuck_mob() {
    let s = scene();
    let mut sensing = Sensing::default();
    let mut m = mob(4, [0.5, 64.0, 0.5]);
    run(&s, &mut m, &mut sensing, 0, |t| {
        t.mob.body.mob.motion.speed = 0.25;
        navigation::move_to(t, [-10.5, 64.0, 0.5], 1.0);
        for _ in 0..102 {
            navigation::tick(t);
        }
        assert!(t.mind.navigation.stuck);
        assert!(t.mind.navigation.done());
    });
}

// ## Goals

#[test]
fn goals_look_at_and_attack_a_player() {
    let s = scene();
    let mut sensing = Sensing::new(vec![player(9, [1.5, 64.0, 0.5])], vec![], vec![]);
    let mut m = mob(5, [0.5, 64.0, 0.5]);
    let mut look = LookAtPlayer::new(8.0, 1.0, false, None);
    let used = run(&s, &mut m, &mut sensing, 0, |t| {
        let used = look.can_use(t);
        look.start(t);
        look.tick(t);
        used
    });
    assert!(used);
    assert_eq!(look.look_at.unwrap().kind, Kind::Player);
    let target = state(&m).look.unwrap();
    assert_eq!((target.x, target.z), (1.5, 0.5));

    let mut melee = MeleeAttack::new(1.0, false, true);
    let effects = run(&s, &mut m, &mut sensing, 100, |t| {
        t.mind.target = Some(Ref {
            kind: Kind::Player,
            uuid: uuid(9),
        });
        assert!(melee.can_use(t));
        melee.start(t);
        melee.tick(t);
        std::mem::take(&mut t.effects)
    });
    assert!(effects.contains(&Effect::Swing(Hand::MainHand)));
    assert!(effects.contains(&Effect::Attack(Ref {
        kind: Kind::Player,
        uuid: uuid(9)
    })));
    assert_eq!(melee.cooldown, 20);
    assert!(!state(&m).aggressive);
}

#[test]
fn goals_stroll_and_look_around_draw_from_the_mob() {
    let s = scene();
    let mut sensing = Sensing::default();
    let mut m = mob(6, [0.5, 64.0, 0.5]);
    let mut stroll = RandomStroll::new(1.0, goals::random_stroll::StrollOptions::default());
    stroll.trigger();
    run(&s, &mut m, &mut sensing, 0, |t| {
        assert!(stroll.can_use(t));
        stroll.start(t);
    });
    assert!(!state(&m).navigation.done());
    let mut around = RandomLookAround::new();
    let before = m.body.mob.ai.as_ref().unwrap().random;
    run(&s, &mut m, &mut sensing, 0, |t| {
        around.start(t);
        around.tick(t);
    });
    let mut r = before;
    let d = r.double();
    let n = r.int(20);
    assert_eq!(around.time, 20 + n as i64 - 1);
    let (_, cos) = super::fmath::java_sin_cos(std::f64::consts::PI * 2.0 * d);
    assert_eq!(around.x, cos);
}

#[test]
fn navigation_kinds_choose_their_evaluator() {
    let water = Navigation::new(NavKind::Water, true);
    assert!(!water.can_pass_doors);
    assert_eq!(
        water.evaluator,
        crate::path::Evaluator::Swim { breaching: true }
    );
    assert!(Navigation::default().done());
}

