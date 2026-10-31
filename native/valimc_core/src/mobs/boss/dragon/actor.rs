//! The dragon's whole owner-local tick: its
//! ambient growl, healing from its chosen crystal, the phases and flight,
//! the crystal scan, its body breaking through blocks, its wings and head
//! touching what is near, the breath and fireballs, the 200-tick death with
//! its experience bursts, then its body turning with its flight. A
//! destroyed crystal it heals from hits its head, and a holding dragon
//! strafes the player who broke it.

use super::codec::{self, Brain};
use super::flight::{add, Flight};
use super::paths::Graph;
use super::phases::{PhaseEffect, Phases};
use super::{DragonEffect, DragonEvent, Env, Player};
use crate::mobs::ai::fmath::{self, emin, f};
use crate::mobs::ai::mind::MindState;
use crate::mobs::combat::{self, Attacker, Event, Hit, Rules};
use crate::mobs::living::mob as living_mob;
use crate::mobs::model::{Body, Mind, NativeMob};
use crate::mobs::random::LegacyRandom;
use crate::mobs::term::{Map, Value, NIL};

/// `2.5000003E-7F`: the body turns only once it moves more than this.
const STILL: f64 = 2.5000003e-7_f32 as f64;

/// `%Actor{}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Actor {
    pub phases: Phases,
    pub tick: i64,
    pub ambient: i64,
    pub body_yaw: f64,
    pub stable_head: f64,
    pub stable_time: i64,
    /// Its body hit a block it could not break.
    pub wall: bool,
    /// The crystal it heals from.
    pub crystal: Option<Vec<u8>>,
    /// Its breath's cloud.
    pub flame: Option<Vec<u8>>,
    pub graph: Option<Graph>,
    /// The game time it last ticked at (a handoff's resume).
    pub world_tick: Option<i64>,
}

impl Actor {
    fn of(phases: Phases) -> Actor {
        Actor {
            phases,
            tick: 0,
            ambient: 0,
            body_yaw: 0.0,
            stable_head: 0.0,
            stable_time: 0,
            wall: false,
            crystal: None,
            flame: None,
            graph: None,
            world_tick: None,
        }
    }
}

/// What one tick gives its owner: where it is now, what it shows and what
/// it asks.
#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    pub position: [f64; 3],
    pub events: Vec<DragonEvent>,
    pub effects: Vec<DragonEffect>,
}

/// A player who broke a crystal (`crystal_destroyed/6`'s `player`): its
/// phases' view, whether it may be fought, and itself as an attacker.
#[derive(Clone, Debug, PartialEq)]
pub struct Striker {
    pub player: Player,
    pub eligible: bool,
    pub attacker: Attacker,
}

impl Striker {
    /// The term a strafe keeps (`%{id, position, height, eligible,
    /// attacker}`).
    pub fn term(&self) -> Value {
        let a = &self.attacker;
        let attacker = Map::from_atoms([
            ("uuid", Value::Binary(a.uuid.to_vec())),
            ("entity_id", Value::Int(a.entity_id as i64)),
            ("player", Value::bool(a.player)),
            ("type", Value::Binary(a.entity_type.as_bytes().to_vec())),
            ("mainhand", a.mainhand.clone().unwrap_or(NIL)),
        ]);
        Value::Map(Map::from_atoms([
            ("id", Value::Int(self.player.id)),
            ("position", Value::vec3(self.player.position)),
            ("height", Value::Float(self.player.height)),
            ("eligible", Value::bool(self.eligible)),
            ("attacker", Value::Map(attacker)),
        ]))
    }
}

/// The destroyed crystal, as the hit's direct entity.
#[derive(Clone, Debug, PartialEq)]
pub struct CrystalHit {
    pub uuid: [u8; 16],
    pub entity_id: i32,
    pub position: [f64; 3],
}

fn phase_of(body: &Body) -> i64 {
    body.data.get("phase").and_then(Value::as_int).unwrap_or(10)
}

fn silent(body: &Body) -> bool {
    body.data
        .get("silent")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// `restore/2`: its actor from its brain (or a fresh one where it has none)
/// and a live mind.
fn restore(mob: &mut NativeMob) -> Actor {
    let actor = match codec::brain(mob.body.data.get("brain")) {
        Brain::Actor(a) => *a,
        Brain::Phases(p) => Actor::of(*p),
        Brain::None => Actor::of(Phases {
            flight: Flight {
                position: mob.position,
                yaw: mob.body.yaw,
                ..Flight::default()
            },
            ..Phases::default()
        }),
    };
    let uuid = mob.uuid;
    let mind = mob.body.mob.ai.get_or_insert_with(|| Mind {
        random: LegacyRandom::from_uuid(&uuid),
        memories: None,
        state: None,
    });
    mind.state.get_or_insert_with(Default::default);
    actor
}

fn state(body: &mut Body) -> &mut MindState {
    body.mob
        .ai
        .as_mut()
        .and_then(|m| m.state.as_mut())
        .expect("a restored dragon has a live mind")
}

fn random(body: &Body) -> LegacyRandom {
    body.mob
        .ai
        .as_ref()
        .map_or(LegacyRandom { seed: 0 }, |m| m.random)
}

fn put_random(body: &mut Body, random: LegacyRandom) {
    if let Some(m) = body.mob.ai.as_mut() {
        m.random = random;
    }
}

fn store(body: &mut Body, actor: &Actor) {
    body.data.set("brain", codec::actor_value(actor));
}

/// `resume/2`: its mind made again after a handoff within a tick, without
/// ticking twice.
pub fn resume(mob: &mut NativeMob) {
    let actor = restore(mob);
    let s = state(&mut mob.body);
    s.tick = actor.tick;
    s.ambient = actor.ambient;
    s.body_yaw = actor.body_yaw;
    s.stable_head = actor.stable_head;
    s.stable_time = actor.stable_time as i32;
}

/// Whether it already ticked at game time `time` (`world_tick`).
pub fn ticked_at(body: &Body, time: i64) -> bool {
    body.data
        .get("brain")
        .and_then(Value::as_map)
        .and_then(|m| m.get_atom("world_tick"))
        .and_then(Value::as_int)
        == Some(time)
}

fn intersects(a: &[f64; 6], b: &[f64; 6]) -> bool {
    a[0] < b[3] && a[3] > b[0] && a[1] < b[4] && a[4] > b[1] && a[2] < b[5] && a[5] > b[2]
}

fn inflate(b: &[f64; 6], d: [f64; 3], m: [f64; 3]) -> [f64; 6] {
    [
        b[0] - d[0] + m[0],
        b[1] - d[1] + m[1],
        b[2] - d[2] + m[2],
        b[3] + d[0] + m[0],
        b[4] + d[1] + m[1],
        b[5] + d[2] + m[2],
    ]
}

fn distance(a: [f64; 3], b: [f64; 3]) -> f64 {
    (a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2])
}

/// `tick/3`: one tick after its living timers.
pub fn tick(rules: &Rules, mob: &mut NativeMob, env: &mut Env) -> Step {
    let facts = env.facts;
    let origin = mob.position;
    let mut actor = restore(mob);
    actor.tick += 1;
    if actor.graph.is_none() {
        actor.graph = Some(env.graph.clone());
    }
    actor.world_tick = Some(env.level.time);
    let body = &mut mob.body;
    {
        let s = state(body);
        s.tick = actor.tick;
        s.ambient = actor.ambient;
    }
    let phase = phase_of(body);
    let end_flame = actor.phases.phase != phase && actor.phases.flame_live;
    actor.phases.set(phase);
    actor.phases.flight.position = origin;
    actor.phases.flight.velocity = body.velocity;
    actor.phases.flight.yaw = body.yaw;
    actor.phases.head_yaw = body.head_yaw;
    actor.phases.pitch = body.pitch;
    actor.phases.random = random(body);
    let no_ai = body.mob.no_ai;

    let (events, effects) = if living_mob::alive(&body.mob) {
        let events = ambient(facts, &mut actor, silent(body));
        heal(body, &mut actor, env);
        if let Some(graph) = &actor.graph {
            env.graph = graph.clone();
        }
        env.wall = actor.wall;
        let old = actor.phases.flight.boxes(facts);
        actor.phases.tick(env, no_ai);
        if end_flame {
            actor.phases.effects.insert(0, PhaseEffect::EndFlame);
        }
        if actor.phases.effects.contains(&PhaseEffect::ScanCrystals) {
            scan(rules, &mut actor, env, origin, body);
        }
        for e in &actor.phases.effects {
            if let PhaseEffect::Health(v) = e {
                body.mob.living.health.value = *v;
            }
        }
        let walls = if no_ai {
            Vec::new()
        } else {
            walls(&mut actor, env)
        };
        let contacts = if !no_ai && body.mob.living.health.hurt_ticks == 0 {
            contacts(&actor, &old, env)
        } else {
            Vec::new()
        };
        let mut effects = Vec::new();
        if !silent(body) {
            let cell = fmath::block(origin);
            for e in &actor.phases.effects {
                if let PhaseEffect::Fireball { .. } = e {
                    effects.push(DragonEffect::LevelEvent {
                        cell,
                        kind: 1017,
                        data: 0,
                    });
                }
            }
        }
        effects.extend(contacts);
        effects.extend(walls);
        for e in actor.phases.effects.clone() {
            effects.push(match e {
                PhaseEffect::Flame(at) => {
                    actor.flame = Some(env.flame_uuid.to_vec());
                    DragonEffect::Flame {
                        uuid: env.flame_uuid,
                        at,
                    }
                }
                PhaseEffect::EndFlame => DragonEffect::EndFlame(actor.flame.take()),
                PhaseEffect::ScanCrystals => DragonEffect::ScanCrystals,
                PhaseEffect::Health(v) => DragonEffect::Health(v),
                PhaseEffect::Fireball { at, direction } => DragonEffect::Fireball { at, direction },
            });
        }
        (events, effects)
    } else {
        death(&mut actor, env, body)
    };

    let flight = actor.phases.flight.clone();
    let alive = living_mob::alive(&body.mob);
    let (body_yaw, stable_head, stable_time) = turn_body(
        [flight.position[0], flight.position[2]],
        flight.yaw,
        body.head_yaw,
        (
            if alive && !no_ai {
                flight.yaw
            } else {
                actor.body_yaw
            },
            actor.stable_head,
            actor.stable_time,
        ),
        [origin[0], origin[2]],
        facts.max_head_y_rot,
    );
    let (head, body_yaw) = body_yaw;
    actor.body_yaw = body_yaw;
    actor.stable_head = stable_head;
    actor.stable_time = stable_time;
    actor.phases.head_yaw = head;
    body.velocity = flight.velocity;
    body.yaw = flight.yaw;
    body.head_yaw = head;
    body.data.set("phase", Value::Int(actor.phases.phase));
    put_random(body, actor.phases.random);
    {
        let s = state(body);
        s.ambient = actor.ambient;
        s.body_yaw = body_yaw;
        s.stable_head = stable_head;
        s.stable_time = stable_time as i32;
    }
    store(body, &actor);
    Step {
        position: flight.position,
        events,
        effects,
    }
}

/// `Look.body/2` with the dragon's limit: `((head, body yaw), stable head,
/// stable time)`.
fn turn_body(
    [x, z]: [f64; 2],
    yaw: f64,
    head: f64,
    (body_yaw, stable_head, stable_time): (f64, f64, i64),
    [xo, zo]: [f64; 2],
    limit: f64,
) -> ((f64, f64), f64, i64) {
    let (dx, dz) = (x - xo, z - zo);
    if dx * dx + dz * dz > STILL {
        let head = fmath::rotate_if_necessary(head, yaw, limit);
        ((head, yaw), head, 0)
    } else if f(head - stable_head).abs() > 15.0 {
        let body = fmath::rotate_if_necessary(body_yaw, head, limit);
        ((head, body), head, 0)
    } else {
        let time = stable_time + 1;
        let body = if time > 10 {
            let fraction = fmath::clamp(f((time - 10) as f64 / 10.0), 0.0, 1.0);
            let remaining = f(limit * f(1.0 - fraction));
            fmath::rotate_if_necessary(body_yaw, head, remaining)
        } else {
            body_yaw
        };
        ((head, body), stable_head, time)
    }
}

/// `ambient/2`: its growl when a draw falls below its clock.
fn ambient(facts: &super::DragonFacts, actor: &mut Actor, silent: bool) -> Vec<DragonEvent> {
    let n = actor.phases.random.int(1000) as i64;
    if n < actor.ambient {
        let pitch = actor.phases.random.voice_pitch(1.0) as f64;
        actor.ambient = -facts.ambient_interval;
        if silent {
            Vec::new()
        } else {
            vec![DragonEvent::Ambient { pitch }]
        }
    } else {
        actor.ambient += 1;
        Vec::new()
    }
}

/// `heal/3`: a point every ten ticks while its crystal stands; it forgets
/// one that is gone.
fn heal(body: &mut Body, actor: &mut Actor, env: &Env) {
    let Some(crystal) = &actor.crystal else {
        return;
    };
    if env
        .crystal_bodies
        .iter()
        .any(|c| c.uuid.as_slice() == crystal.as_slice())
    {
        let health = &mut body.mob.living.health;
        if actor.tick.rem_euclid(10) == 0 {
            health.value = emin(health.maximum, f(health.value + 1.0));
        }
    } else {
        actor.crystal = None;
    }
}

/// `scan/4`: the crystal nearest its position among those within 32
/// blocks of its box.
fn scan(rules: &Rules, actor: &mut Actor, env: &Env, origin: [f64; 3], body: &Body) {
    let [width, height, _] = match rules.of(&body.entity_type) {
        Some(ty) => crate::mobs::living::body::dimensions(rules, ty, body),
        None => [0.0; 3],
    };
    let half = width / 2.0;
    let [x, y, z] = origin;
    let area = [
        x - half - 32.0,
        y - 32.0,
        z - half - 32.0,
        x + half + 32.0,
        y + height + 32.0,
        z + half + 32.0,
    ];
    let mut best: Option<(&super::Crystal, f64)> = None;
    for c in env.crystal_bodies {
        if !intersects(&area, &c.bbox) {
            continue;
        }
        let d = distance(c.position, origin);
        if best.is_none_or(|(_, b)| d < b) {
            best = Some((c, d));
        }
    }
    actor.crystal = best.map(|(c, _)| c.uuid.to_vec());
}

/// `contacts/3`: its wings push (and, in flight, hurt) what they touch;
/// its head and neck as they were before the move bite.
fn contacts(actor: &Actor, old: &[[f64; 6]; 8], env: &Env) -> Vec<DragonEffect> {
    let boxes = actor.phases.flight.boxes(env.facts);
    let b = boxes[2];
    let (cx, cz) = ((b[0] + b[3]) / 2.0, (b[2] + b[5]) / 2.0);
    let sitting = env.facts.phase(actor.phases.phase).sitting;
    let mut out = Vec::new();
    for i in [6, 7] {
        let wing = inflate(&boxes[i], [4.0, 2.0, 4.0], [0.0, -2.0, 0.0]);
        for t in &env.targets {
            if !intersects(&wing, &t.bbox) {
                continue;
            }
            let [x, _, z] = t.position;
            let (dx, dz) = (x - cx, z - cz);
            let dd = fmath::emax(dx * dx + dz * dz, 0.1);
            let amount = if !sitting && !t.recent { 5.0 } else { 0.0 };
            out.push(DragonEffect::Contact {
                target: t.target,
                push: [dx / dd * 4.0, f(0.2), dz / dd * 4.0],
                amount,
                wing: true,
            });
        }
    }
    for b in &old[..2] {
        let head = inflate(b, [1.0; 3], [0.0; 3]);
        for t in &env.targets {
            if intersects(&head, &t.bbox) {
                out.push(DragonEffect::Contact {
                    target: t.target,
                    push: [0.0; 3],
                    amount: 10.0,
                    wing: false,
                });
            }
        }
    }
    out
}

/// `walls/2`: its head, neck and body break what they pass through (with
/// mob griefing, but immune blocks), or else it hits a wall.
fn walls(actor: &mut Actor, env: &Env) -> Vec<DragonEffect> {
    let facts = env.level.facts;
    let boxes = actor.phases.flight.boxes(env.facts);
    let mut wall = false;
    let mut removed: Vec<[i32; 3]> = Vec::new();
    let mut effects = Vec::new();
    for b in &boxes[..3] {
        let [x0, y0, z0, x1, y1, z1] = b.map(|v| v.floor() as i32);
        let mut edits = Vec::new();
        for x in x0..=x1 {
            for y in y0..=y1 {
                for z in z0..=z1 {
                    let cell = [x, y, z];
                    let Some(state) = env.level.block(cell) else {
                        continue;
                    };
                    let id = facts.blocks.block_id(state).map_or(-1, |id| id as i32);
                    if removed.contains(&cell)
                        || env.air_state(state)
                        || facts
                            .tags
                            .has("minecraft:block", "minecraft:dragon_transparent", id)
                    {
                        continue;
                    }
                    if env.level.rules.mob_griefing
                        && !facts
                            .tags
                            .has("minecraft:block", "minecraft:dragon_immune", id)
                    {
                        removed.push(cell);
                        edits.push(DragonEffect::Break { cell, state });
                    } else {
                        wall = true;
                    }
                }
            }
        }
        if !edits.is_empty() {
            let dx = actor.phases.random.int(x1 - x0 + 1);
            let dy = actor.phases.random.int(y1 - y0 + 1);
            let dz = actor.phases.random.int(z1 - z0 + 1);
            effects.extend(edits);
            effects.push(DragonEffect::LevelEvent {
                cell: [x0 + dx, y0 + dy, z0 + dz],
                kind: 2008,
                data: 0,
            });
        }
    }
    actor.wall = wall;
    effects
}

/// `death/3`: rising, exploding and paying out experience for 200 ticks,
/// then the fight won and the body gone.
fn death(actor: &mut Actor, env: &Env, body: &mut Body) -> (Vec<DragonEvent>, Vec<DragonEffect>) {
    let time = body
        .data
        .get("death_time")
        .and_then(Value::as_int)
        .unwrap_or(0)
        + 1;
    let mut events = Vec::new();
    if (180..=200).contains(&time) {
        events.push(particle(actor, "minecraft:explosion_emitter"));
    }
    let total = if env.previous_kill { 500 } else { 12_000 };
    let drops = env.level.rules.mob_drops;
    let mut effects = Vec::new();
    if time == 1 && !silent(body) {
        effects.push(DragonEffect::GlobalEvent(1028));
    }
    if drops && time > 150 && time % 5 == 0 {
        effects.push(DragonEffect::Xp {
            amount: f(total as f64 * f(0.08)).floor() as i64,
            at: actor.phases.flight.position,
        });
    }
    let delta = [0.0, f(0.1), 0.0];
    let flight = &mut actor.phases.flight;
    flight.position = add(flight.position, delta);
    flight.parts = flight.parts.map(|p| add(p, delta));
    if time >= 200 {
        if drops {
            effects.push(DragonEffect::Xp {
                amount: f(total as f64 * f(0.2)).floor() as i64,
                at: actor.phases.flight.position,
            });
        }
        effects.push(DragonEffect::Killed);
        effects.push(DragonEffect::Discard);
    } else {
        events.push(particle(actor, "minecraft:explosion"));
    }
    body.data.set("death_time", Value::Int(time));
    (events, effects)
}

/// `particle/2`: an explosion within four blocks around and two above.
fn particle(actor: &mut Actor, name: &'static str) -> DragonEvent {
    let r = &mut actor.phases.random;
    let x = r.float() as f64;
    let y = r.float() as f64;
    let z = r.float() as f64;
    let offset = [
        f(f(x - 0.5) * 8.0),
        2.0 + f(f(y - 0.5) * 4.0),
        f(f(z - 0.5) * 8.0),
    ];
    DragonEvent::Particles {
        name,
        at: add(actor.phases.flight.position, offset),
    }
}

/// `crystal_destroyed/6`: the crystal it heals from explodes into its head
/// (ten explosion damage, from the player who broke it); a holding dragon
/// then strafes an eligible player who did. Its hurt's events.
pub fn crystal_destroyed(
    rules: &Rules,
    mob: &mut NativeMob,
    crystal: &[u8; 16],
    direct: &CrystalHit,
    player: Option<&Striker>,
    env: &mut Env,
) -> Vec<Event> {
    let mut actor = restore(mob);
    if actor.graph.is_none() {
        actor.graph = Some(env.graph.clone());
    }
    store(&mut mob.body, &actor);
    let mut events = Vec::new();
    if actor.crystal.as_deref() == Some(crystal.as_slice()) {
        if let Some(source) = rules.facts.damage_types.id("minecraft:explosion") {
            let hit = Hit {
                dragon_part: Some(0),
                attacker: player.map(|p| p.attacker.clone()),
                direct: Some(Attacker {
                    uuid: direct.uuid,
                    entity_id: direct.entity_id,
                    player: false,
                    entity_type: "minecraft:end_crystal".to_owned(),
                    mainhand: None,
                    luck: 0.0,
                }),
                position: Some(direct.position),
                ..Hit::new(source, 10.0)
            };
            events = combat::hit_body(rules, mob, &hit).0;
        }
    }
    if let Some(p) = player.filter(|p| p.eligible) {
        if phase_of(&mob.body) == 0 {
            let mut actor = match codec::brain(mob.body.data.get("brain")) {
                Brain::Actor(a) => *a,
                _ => actor,
            };
            actor.phases.random = random(&mob.body);
            actor.phases.flight.position = mob.position;
            if let Some(graph) = &actor.graph {
                env.graph = graph.clone();
            }
            actor.phases.strafe(&p.player, p.term(), env);
            mob.body.data.set("phase", Value::Int(actor.phases.phase));
            put_random(&mut mob.body, actor.phases.random);
            store(&mut mob.body, &actor);
        }
    }
    events
}
