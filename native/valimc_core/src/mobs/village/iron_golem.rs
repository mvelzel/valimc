//! Iron golems (`Valimc.AI.Mobs.IronGolem`, vanilla's `IronGolem`): they
//! guard villages.
//!
//! - **Goals** walk it at monsters (not creepers) near it and at a player
//!   it is angry with, back toward the village when outside one, and about
//!   the village toward villagers that want a golem or claimed POIs (the
//!   level's random choosing); now and then by day it offers a villager a
//!   flower (`OfferFlower`).
//! - **Fights**: its hit is half its attack damage and up to that again
//!   (its random), throws the target up and shows its attack (event 4,
//!   its sound); a hurt that changes its crackiness sounds. It stays angry
//!   with a player who hurt it (`NeutralMob`, 20 to 39 seconds), never
//!   targets players when a player built it, and a monster it pushes
//!   becomes its target one time in twenty.
//!
//! Its own data: whether a player built it (entity data bit 0). Its own
//! mind fields (`GolemOwn`) beside its anger: its attack and flower
//! animation timers, each absent until set as the Elixir's `own` keys.

use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::{Goal, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::{TargetFields, TargetOptions};
use crate::mobs::ai::goals::{
    neutral, HurtByTarget, LookAtPlayer, MeleeAttack, MobTypes, MoveTowardsTarget,
    NearestAttackableTarget, RandomLookAround, RandomStroll, ResetUniversalAnger, TargetKind,
    TargetTest,
};
use crate::mobs::ai::hooks::{attribute, Hooks, Tag};
use crate::mobs::ai::mind::Anger;
use crate::mobs::ai::turn::{Eyes, Kinds, Seen, Targeting, Turn};
use crate::mobs::ai::{pois, random_pos, spawn, Extra};
use crate::mobs::combat::{Event, Family, Rules, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::level::Level;
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::monsters::{entity, fields, flag, value};
use crate::mobs::sensing::{inflate, intersects, Entity, Kind as RefKind, Ref};
use crate::mobs::term::{Atom, Map, Value, NIL};

pub const IRON_GOLEM: &str = "minecraft:iron_golem";

/// `PERSISTENT_ANGER_TIME`: 20 to 39 seconds.
const ANGER: (i64, i64) = (400, 780);

const OUTSIDE: Tag = 1;
const BACK: Tag = 2;
const IN_VILLAGE: Tag = 3;
const ENEMY: Tag = 4;
const GIFT: Tag = 5;

/// An iron golem's own mind fields beside its anger.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GolemOwn {
    pub attack: Option<i64>,
    pub flower: Option<i64>,
}

/// The iron golem family.
pub struct IronGolem {
    types: [&'static str; 1],
    type_id: u16,
    creeper: u16,
    villager: u16,
    attack: i32,
    damage: i32,
}

impl IronGolem {
    pub fn new(facts: &MobFacts) -> Result<IronGolem, String> {
        let sound = |name: &str| {
            facts
                .sounds
                .id(name)
                .ok_or_else(|| format!("unknown sound {name}"))
        };
        Ok(IronGolem {
            types: [IRON_GOLEM],
            type_id: entity(facts, IRON_GOLEM)?,
            creeper: entity(facts, "minecraft:creeper")?,
            villager: entity(facts, "minecraft:villager")?,
            attack: sound("minecraft:entity.iron_golem.attack")?,
            damage: sound("minecraft:entity.iron_golem.damage")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[("player_created", Value::bool(false))])
    }

    // `target instanceof Enemy && !(target instanceof Creeper)`.
    fn enemy(&self, level: &Level, type_id: u16) -> bool {
        type_id != self.creeper && level.facts.entities.get(type_id).is_some_and(|e| e.enemy)
    }

    fn source(&self, facts: &MobFacts) -> i32 {
        facts.combat.mob_sounds(self.type_id).source
    }
}

// ## Its own mind fields

fn own(t: &Turn) -> GolemOwn {
    t.mind.own.family::<GolemOwn>().cloned().unwrap_or_default()
}

/// `ensure/1`: a fresh mind's own fields, the neutral ones with its own.
fn ensure(t: &mut Turn) {
    if t.mind.own.is_empty() {
        t.mind.own.anger = Some(Anger::default());
        t.mind.own.family = Some(Box::new(GolemOwn {
            attack: Some(0),
            flower: Some(0),
        }));
    }
}

fn put(t: &mut Turn, f: impl FnOnce(&mut GolemOwn)) {
    ensure(t);
    let mut o = own(t);
    f(&mut o);
    t.mind.own.family = Some(Box::new(o));
}

/// `IronGolem.Crackiness`: from its health's fraction.
fn crackiness(f: f64) -> u8 {
    if f < 0.25 {
        3
    } else if f < 0.5 {
        2
    } else if f < 0.75 {
        1
    } else {
        0
    }
}

/// `wants_golem?/2` of a sensed villager: no golem detected recently, and
/// it slept within the day.
fn wants_golem(extra: &Extra, now: i64) -> bool {
    let Some(memories) = extra.memories.as_ref().and_then(Value::as_map) else {
        return false;
    };
    if memories.get_atom("golem_detected_recently").is_some() {
        return false;
    }
    let at = memories
        .get_atom("last_slept")
        .and_then(Value::as_tuple)
        .and_then(|v| v.first())
        .and_then(Value::as_int);
    at.is_some_and(|at| now - at < 24_000)
}

impl IronGolem {
    // `MoveBackToVillageGoal.getPosition`: toward the nearest section
    // closer to a village, or nowhere.
    fn back_to_village(&self, t: &mut Turn) -> Option<[f64; 3]> {
        let section = pois::section(t.block());
        let [sx, sy, sz] = pois::closest_village_section(t.level, section, 2);
        if [sx, sy, sz] == section {
            return None;
        }
        let towards = [
            (sx * 16) as f64 + 8.5,
            (sy * 16) as f64 + 8.0,
            (sz * 16) as f64 + 8.5,
        ];
        random_pos::default_towards(t, 10, 7, towards, f(std::f64::consts::PI / 2.0))
    }

    // `GolemRandomStrollInVillageGoal.getPosition`, its draws from the
    // level's random.
    fn in_village(&self, t: &mut Turn) -> Option<[f64; 3]> {
        if spawn::level_float(t) < f(0.3) {
            return random_pos::land(t, 10, 7);
        }
        let target = if spawn::level_float(t) < f(0.7) {
            self.toward_villager(t).or_else(|| self.toward_poi(t))
        } else {
            self.toward_poi(t).or_else(|| self.toward_villager(t))
        };
        target.or_else(|| random_pos::land(t, 10, 7))
    }

    fn toward_villager(&self, t: &mut Turn) -> Option<[f64; 3]> {
        let b = inflate(&t.bbox(), 32.0, 32.0, 32.0);
        let now = t.level.time;
        let villagers: Vec<Seen> = t
            .mobs_in(Kinds::Types(&[self.villager]), &b)
            .into_iter()
            .filter(|v| {
                t.sensing
                    .mob(&v.uuid())
                    .is_some_and(|m| wants_golem(&m.extra, now))
            })
            .collect();
        if villagers.is_empty() {
            return None;
        }
        let i = spawn::level_int(t, villagers.len() as i32) as usize;
        random_pos::land_towards(t, 10, 7, villagers[i].position)
    }

    fn toward_poi(&self, t: &mut Turn) -> Option<[f64; 3]> {
        let sections: Vec<[i32; 3]> = pois::cube(pois::section(t.block()), 2)
            .into_iter()
            .filter(|&s| pois::sections_to_village(t.level, s) == 0)
            .collect();
        if sections.is_empty() {
            return None;
        }
        let i = spawn::level_int(t, sections.len() as i32) as usize;
        let [sx, sy, sz] = sections[i];
        let center = [sx * 16 + 8, sy * 16 + 8, sz * 16 + 8];
        let found = pois::occupied_in_range(t.level, center, 8);
        if found.is_empty() {
            return None;
        }
        let j = spawn::level_int(t, found.len() as i32) as usize;
        let [x, y, z] = found[j];
        random_pos::land_towards(t, 10, 7, [x as f64 + 0.5, y as f64, z as f64 + 0.5])
    }

    // `pushEntities`'s `doPush`: each pushable monster its box meets; one in
    // twenty becomes its target.
    fn pushes(&self, t: &mut Turn) {
        let b = t.bbox();
        let pushed: Vec<Ref> = t
            .sensing
            .mobs()
            .iter()
            .filter(|m| {
                m.uuid != t.uuid
                    && m.alive
                    && self.enemy(t.level, m.type_id)
                    && intersects(&Entity::Mob(m).bounding_box(), &b)
            })
            .map(|m| Ref {
                kind: RefKind::Mob,
                uuid: m.uuid,
            })
            .collect();
        for r in pushed {
            if t.int(20) == 0 {
                t.set_target(Some(r));
            }
        }
    }
}

impl Hooks for IronGolem {
    fn test(&self, t: &mut Turn, tag: Tag) -> bool {
        tag == OUTSIDE && !pois::village(t.level, t.block())
    }

    fn position(&self, t: &mut Turn, tag: Tag) -> Option<[f64; 3]> {
        match tag {
            BACK => self.back_to_village(t),
            IN_VILLAGE => self.in_village(t),
            _ => None,
        }
    }

    fn mob_type(&self, level: &Level, tag: Tag, type_id: u16) -> bool {
        match tag {
            ENEMY => self.enemy(level, type_id),
            GIFT => level
                .facts
                .entity_tag(type_id, "candidate_for_iron_golem_gift"),
            _ => false,
        }
    }

    /// `canAttack`: no player when a player built it, never a creeper.
    fn can_attack(&self, eyes: &Eyes, target: Entity<'_, Extra>) -> bool {
        !(flag(eyes.data, "player_created") && target.kind() == RefKind::Player)
            && target.type_id() != Some(self.creeper)
    }

    /// `doHurtTarget`: the attack shown (event 4, its timer at 10), a hit
    /// of half its attack damage and up to that again (drawn from its
    /// random) in place of a mob's, that throws the target up (0.4, less
    /// its knockback resistance) without the extra knockback, and its
    /// attack sound.
    fn hit(&self, t: &mut Turn, target: &Seen) {
        put(t, |o| o.attack = Some(10));
        t.effect(Effect::Event(4));
        let damage = f(t.attribute("minecraft:attack_damage"));
        let whole = damage.trunc() as i32;
        let amount = if whole > 0 {
            let n = t.int(whole);
            f(f(damage / 2.0) + n as f64)
        } else {
            damage
        };
        let extras = Map::from_atoms([
            ("amount", Value::Float(amount)),
            ("lift", Value::Float(f(0.4))),
            ("extra_knockback", NIL),
        ]);
        t.effect(Effect::AttackExtra(target.reference, Value::Map(extras)));
        let source = self.source(t.level.facts);
        let seed = t.next_seed();
        t.effect(Effect::Sound {
            id: self.attack,
            source,
            volume: 1.0,
            pitch: 1.0,
            seed,
        });
    }
}

impl Family for IronGolem {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(IronGolem::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let created = flag(&body.data, "player_created");
        vec![value(
            "iron_golem_flags",
            Value::Int(created as i64),
            Value::Int(0),
        )]
    }

    /// A hurt that changes its crackiness (below three quarters, half and a
    /// quarter of its health) plays its damage sound.
    fn hurt_events_with(&self, rules: &Rules, body: &Body, before: f64) -> Vec<Event> {
        let max = attribute(rules.facts, self.type_id, &body.mob, "minecraft:max_health");
        let now = body.mob.living.health.value;
        if crackiness(f(now / max)) == crackiness(f(before / max)) {
            return Vec::new();
        }
        vec![Event::Sound {
            sound: SoundRef::Id(self.damage),
            source: self.source(rules.facts),
            volume: 1.0,
            pitch: 1.0,
        }]
    }
}

impl Kind for IronGolem {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.IronGolem"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(
                    1,
                    "MeleeAttackGoal",
                    MOVE | LOOK,
                    MeleeAttack::new(1.0, true, false),
                ),
                Registration::new(
                    2,
                    "MoveTowardsTargetGoal",
                    MOVE,
                    MoveTowardsTarget::new(0.9, 32.0),
                ),
                Registration::new(
                    2,
                    "MoveBackToVillageGoal",
                    MOVE,
                    RandomStroll::new(
                        0.6,
                        StrollOptions {
                            interval: 10,
                            check_idle: false,
                            guard: Some(OUTSIDE),
                            position: Some(BACK),
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    4,
                    "GolemRandomStrollInVillageGoal",
                    MOVE,
                    RandomStroll::new(
                        0.6,
                        StrollOptions {
                            interval: 240,
                            check_idle: false,
                            position: Some(IN_VILLAGE),
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    5,
                    "OfferFlowerGoal",
                    MOVE | LOOK,
                    OfferFlower {
                        entity: None,
                        tick: 0,
                    },
                ),
                Registration::new(
                    7,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(6.0, 0.02, false, None),
                ),
                Registration::new(
                    8,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
            ],
            targets: vec![
                Registration::new(
                    1,
                    "DefendVillageTargetGoal",
                    TARGET,
                    DefendVillage {
                        fields: TargetFields::new(false),
                        villager: self.villager,
                        potential: None,
                    },
                ),
                Registration::new(
                    2,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(false, Vec::new(), Vec::new()),
                ),
                Registration::new(
                    3,
                    "NearestAttackableTargetGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Player,
                        None,
                        true,
                        TargetOptions {
                            selector: Some(TargetTest::AngryAt),
                            ..TargetOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    3,
                    "NearestAttackableTargetGoal",
                    TARGET,
                    NearestAttackableTarget::new(
                        TargetKind::Mob,
                        Some(MobTypes::Family(ENEMY)),
                        false,
                        TargetOptions {
                            interval: 5,
                            ..TargetOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    4,
                    "ResetUniversalAngerTargetGoal",
                    0,
                    ResetUniversalAnger::new(ANGER),
                ),
            ],
        }
    }

    fn leashable(&self) -> bool {
        true
    }

    /// `Entity.baseTick`'s `canSpawnSprintParticle`, which a golem
    /// overrides: a golem moving (more than a tiny speed) draws on its
    /// random each tick.
    fn tick_start(&self, t: &mut Turn) {
        let [vx, _, vz] = t.velocity();
        if vx * vx + vz * vz > f(2.5000003e-7) && t.int(5) == 0 {
            t.sprint_particle();
        }
    }

    /// `IronGolem.aiStep` after the move: the monsters it pushes, its
    /// timers run down, its anger kept up (staying angry while it has a
    /// target).
    fn after_ai(&self, t: &mut Turn) {
        ensure(t);
        self.pushes(t);
        let o = own(t);
        put(t, |n| {
            n.attack = Some((o.attack.unwrap_or(0) - 1).max(0));
            n.flower = Some((o.flower.unwrap_or(0) - 1).max(0));
        });
        neutral::update(t, true, ANGER);
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        IronGolem::data_of()
    }
}

/// `OfferFlowerGoal` (`IronGolem.OfferFlower`): by day, one tick in 8000, a
/// villager within 6 blocks; it holds out a flower for 400 ticks looking at
/// it.
#[derive(Clone, Debug, PartialEq)]
pub struct OfferFlower {
    entity: Option<Ref>,
    tick: i64,
}

fn set_flower(t: &mut Turn, n: i64) {
    let mut o = own(t);
    o.flower = Some(n);
    t.mind.own.family = Some(Box::new(o));
}

impl Goal for OfferFlower {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if !t.level.bright || t.int(8000) != 0 {
            return false;
        }
        let b = inflate(&t.bbox(), 6.0, 2.0, 6.0);
        let targeting = Targeting::new(false).range(6.0);
        let point = t.pos();
        let found = t.nearest_mob(Kinds::Family(GIFT), &b, &targeting, point);
        self.entity = found.map(|e| e.reference);
        found.is_some()
    }

    fn can_continue(&mut self, _t: &mut Turn) -> bool {
        self.tick > 0
    }

    fn start(&mut self, t: &mut Turn) {
        set_flower(t, 400);
        t.effect(Effect::Event(11));
        self.tick = self.adjusted(400);
    }

    fn stop(&mut self, t: &mut Turn) {
        set_flower(t, 0);
        t.effect(Effect::Event(34));
        self.entity = None;
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(e) = t.entity(self.entity.as_ref()) {
            t.look_at([e.x(), e.eye_y(), e.z()], 30.0, 30.0);
        }
        self.tick -= 1;
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.IronGolem.OfferFlower"
    }
}

/// `DefendVillageTargetGoal` (VMC-044c1): a player any villager within its
/// box (10 blocks out, 8 up and down) holds at reputation -100 or worse,
/// both attackable and in sight within 64 blocks, becomes its target. The
/// last such player stays its potential target (vanilla never clears it);
/// a creative or spectator one is never taken.
#[derive(Clone, Debug, PartialEq)]
pub struct DefendVillage {
    fields: TargetFields,
    villager: u16,
    potential: Option<Ref>,
}

impl Goal for DefendVillage {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let grow = inflate(&t.bbox(), 10.0, 8.0, 10.0);
        let targeting = Targeting::new(true).range(64.0);
        let villagers: Vec<Seen> = t
            .mobs_in(Kinds::Types(&[self.villager]), &grow)
            .into_iter()
            .filter(|v| v.alive)
            .collect();
        let players: Vec<(Ref, [f64; 3])> = t
            .sensing
            .players
            .iter()
            .map(|p| {
                (
                    Ref {
                        kind: RefKind::Player,
                        uuid: p.uuid,
                    },
                    p.position,
                )
            })
            .collect();
        let inside = |[x, y, z]: [f64; 3]| {
            x >= grow.min[0]
                && x < grow.max[0]
                && y >= grow.min[1]
                && y < grow.max[1]
                && z >= grow.min[2]
                && z < grow.max[2]
        };
        for v in &villagers {
            if !t.test(&v.reference, &targeting) {
                continue;
            }
            let gossips = match t.sensing.entity(&v.reference) {
                Some(Entity::Mob(m)) => crate::mobs::village::gossip::Gossips::of(
                    m.extra.data.as_ref().and_then(|d| d.get("gossips")),
                ),
                _ => continue,
            };
            for (r, at) in &players {
                if inside(*at) && t.test(r, &targeting) && gossips.reputation(&r.uuid) <= -100 {
                    self.potential = Some(*r);
                }
            }
        }
        match self.potential {
            Some(r) => match t.sensing.entity(&r) {
                Some(Entity::Player(p)) => !matches!(
                    p.mode,
                    crate::mobs::sensing::GameMode::Creative
                        | crate::mobs::sensing::GameMode::Spectator
                ),
                _ => true,
            },
            None => false,
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.fields.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        t.set_target(self.potential);
        self.fields.start();
    }

    fn stop(&mut self, t: &mut Turn) {
        self.fields.stop(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.DefendVillageTarget"
    }
}
