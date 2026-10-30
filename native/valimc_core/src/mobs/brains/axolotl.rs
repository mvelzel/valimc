//! Axolotls (`Valimc.Entity.Animals.Axolotl` and `Valimc.AI.Brains.Axolotl`,
//! vanilla's `Axolotl` and `AxolotlAi`): an amphibious animal with a brain.
//!
//! - **The animal**: it swims by the smooth swimming controls (in water a
//!   tenth of its speed, on land half), travels in water at its own speed
//!   with 0.9 drag, and dries out on land (6000 ticks of air; water or rain
//!   refills it, then it is hurt by drying out). Hurt in water it may play
//!   dead (`playing_dead`): its controls stop and enemies no longer see it.
//!   Its variant comes with its spawn (two common ones for its group, from
//!   the level's random); a child is blue one time in 1200, else either
//!   parent's.
//! - **Core**: the look and walk sinks; counting down playing dead (back to
//!   idle when it ends) and the temptation cooldown.
//! - **Idle**: now and then looking at a player within six blocks; breeding
//!   with an axolotl in love (`AnimalMakeLove`); following a player holding
//!   its food, or (a baby) an adult (one at random); hunting what it may
//!   attack; finding water within six blocks on land; and with no walk
//!   target, swimming (in water) or strolling (on land) at random or
//!   walking to what it looks at.
//! - **Fight**: dropping a target it can no longer attack (a player who
//!   killed it nearby gets Regeneration and loses Mining Fatigue),
//!   approaching and biting it every 20 ticks; breeding ends it.
//! - **Play dead**: hurt in water, it may lie still for 200 ticks with
//!   Regeneration, unless it breeds.
//!
//! Leaving a fight starts a two-minute hunting cooldown, which its record
//! keeps. Its next try to find water is its mind's own (`AxolotlOwn`).

use crate::mobs::ai::brain::behavior::{self as b, Timer, Trigger};
use crate::mobs::ai::brain::behaviors::{self as bs, Pick, Speed, Test};
use crate::mobs::ai::brain::{fight, sensors};
use crate::mobs::ai::brain::{
    Activity, Brain, BrainFamily, Cond, Conds, Mem, MemValue, Package, Remember, Sensor, Tracker,
};
use crate::mobs::ai::control::smooth_swimming::{self, SmoothSwimming};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::navigation::NavKind;
use crate::mobs::ai::turn::{Seen, Targeting, Turn};
use crate::mobs::ai::Extra;
use crate::mobs::animals::{age, Animal, Species};
use crate::mobs::combat::Hit;
use crate::mobs::facts::{MobFacts, Slot};
use crate::mobs::kinds::{KindMotion, NavSpec, Registered};
use crate::mobs::level::FluidKind;
use crate::mobs::model::{Body, FamilyData, MotionSet, Rung, Travel, TravelKind};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{self, Entity, GameMode, Kind as RefKind, Ref, Uuid};
use crate::mobs::term::{Atom, Value};
use std::any::Any;

pub const AXOLOTL: &str = "minecraft:axolotl";
const COMMONS: [i64; 4] = [0, 1, 2, 3];
const BLUE: i64 = 4;
const NAMES: [&str; 5] = ["lucy", "wild", "gold", "cyan", "blue"];
const CONTROLS: SmoothSwimming = SmoothSwimming {
    max_x: 85.0,
    max_y: 10.0,
    in_water: 0.1,
    out: 0.5,
    gravity: false,
};
/// `CountDownCooldownTicks`' and `FollowTemptation`'s endless run.
const NEVER: i32 = 2_000_000_000;

// Its tests, speeds, finder, stop and sensors (tags).
const IN_WATER: u32 = 1;
const ON_GROUND: u32 = 2;
const WALKS_TO_LOOK: u32 = 3;
const BREEDING: u32 = 4;
const SPEED: u32 = 1;
const CHASING: u32 = 2;
const FIND_TARGET: u32 = 1;
const ON_STOP: u32 = 1;
const ADULT_SENSOR: u32 = 1;
const ATTACKABLES: u32 = 2;
const TEMPTATIONS: u32 = 3;

/// What it keeps beyond its saved state (`Mind.own`): its next try to find
/// water.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AxolotlOwn {
    pub find_liquid: i64,
}

/// `Mob.value(type, mob, "minecraft:max_health")` of an axolotl (which
/// wears nothing): its base or the record's, its modifiers, clamped.
struct MaxHealth {
    name: String,
    base: f64,
    min: f64,
    max: f64,
}

impl MaxHealth {
    fn value(&self, mob: &crate::mobs::model::Mob) -> f64 {
        use crate::mobs::ai::fmath::{emax, emin};
        let kept = mob.attributes.get(&self.name);
        let base = kept.and_then(|o| o.base).unwrap_or(self.base);
        let modifiers: Vec<(f64, u8)> = kept
            .map(|o| {
                o.modifiers
                    .iter()
                    .map(|m| (m.amount.as_f64(), m.operation as u8))
                    .collect()
            })
            .unwrap_or_default();
        let added = modifiers
            .iter()
            .fold(base, |acc, &(a, op)| if op == 0 { acc + a } else { acc });
        let result = modifiers.iter().fold(
            added,
            |acc, &(a, op)| if op == 1 { acc + added * a } else { acc },
        );
        let result = modifiers.iter().fold(
            result,
            |acc, &(a, op)| if op == 2 { acc * (1.0 + a) } else { acc },
        );
        emin(self.max, emax(self.min, result))
    }
}

/// The axolotl species.
pub struct Axolotl {
    max_health: MaxHealth,
    regeneration: i32,
    mining_fatigue: i32,
    hostile: Vec<i32>,
    hunt: Vec<i32>,
    swim: &'static str,
}

impl Axolotl {
    pub fn new(facts: &MobFacts) -> Result<Axolotl, String> {
        let tag = |name: &str| {
            facts
                .tags
                .get("minecraft:entity_type", name)
                .map(<[i32]>::to_vec)
                .unwrap_or_default()
        };
        let fact = facts
            .attributes
            .fetch("minecraft:max_health")
            .ok_or("no max health attribute")?;
        let base = facts
            .entities
            .fetch(AXOLOTL)
            .and_then(|t| t.attribute(&fact.name))
            .unwrap_or(fact.default);
        Ok(Axolotl {
            max_health: MaxHealth {
                name: fact.name.clone(),
                base,
                min: fact.min,
                max: fact.max,
            },
            regeneration: crate::mobs::monsters::effect(facts, "minecraft:regeneration")?,
            mining_fatigue: crate::mobs::monsters::effect(facts, "minecraft:mining_fatigue")?,
            hostile: tag("minecraft:axolotl_always_hostiles"),
            hunt: tag("minecraft:axolotl_hunt_targets"),
            swim: "minecraft:entity.axolotl.swim",
        })
    }
}

fn playing_dead(data: &FamilyData) -> bool {
    data.get("playing_dead")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn variant(data: &FamilyData) -> i64 {
    data.get("variant").and_then(Value::as_int).unwrap_or(0)
}

fn baby(t: &Turn) -> bool {
    age(t.data()) < 0
}

// `getSpeedModifier`, `getSpeedModifierChasing`.
fn speed(t: &Turn) -> f64 {
    if t.in_water() {
        f(0.5)
    } else {
        f(0.15)
    }
}

fn chasing(t: &Turn) -> f64 {
    if t.in_water() {
        f(0.6)
    } else {
        f(0.15)
    }
}

// `travelInWater`: at its speed, 0.9 drag, no sinking.
fn travel(t: &mut Turn) {
    t.mob.body.mob.motion.travel = Some(Travel {
        kind: TravelKind::Dolphin,
        sink: false,
    });
}

impl Species for Axolotl {
    const TYPE: &'static str = AXOLOTL;
    const MODULE: &'static str = "Valimc.Entity.Animals.Axolotl";

    fn goals(&self, _a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        Registered::default()
    }

    fn defaults(&self) -> Vec<(Atom, Value)> {
        vec![
            (Atom::from_static("variant"), Value::Int(0)),
            (Atom::from_static("playing_dead"), Value::bool(false)),
            (Atom::from_static("from_bucket"), Value::bool(false)),
        ]
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        let flag = |k: &str| data.get(k).and_then(Value::as_bool).unwrap_or(false);
        vec![
            (
                Atom::from_static("axolotl_variant"),
                Value::Int(variant(data)),
                Value::Int(0),
            ),
            (
                Atom::from_static("axolotl_playing_dead"),
                Value::bool(flag("playing_dead")),
                Value::bool(false),
            ),
            (
                Atom::from_static("axolotl_from_bucket"),
                Value::bool(flag("from_bucket")),
                Value::bool(false),
            ),
        ]
    }

    /// `getBreedOffspring`: a blue one time in 1200, else either parent's
    /// variant.
    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        let n = t.int(1200);
        let v = if n == 0 {
            t.int(1);
            BLUE
        } else if t.boolean() {
            variant(t.data())
        } else {
            variant(partner)
        };
        vec![(Atom::from_static("variant"), Value::Int(v))]
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        let name = NAMES.get(variant(data) as usize).copied().unwrap_or("lucy");
        vec![("minecraft:axolotl/variant".to_owned(), name.to_owned())]
    }

    /// `finalizeSpawn`: two common variants for its group, one of them its
    /// own (each from the level's random).
    fn spawn_part(&self, _a: &Animal<Self>, t: &mut Turn, _reason: &Atom) {
        let a = crate::mobs::ai::spawn::level_int(t, COMMONS.len() as i32) as usize;
        let b = crate::mobs::ai::spawn::level_int(t, COMMONS.len() as i32) as usize;
        let i = crate::mobs::ai::spawn::level_int(t, 2);
        let v = if i == 0 { COMMONS[a] } else { COMMONS[b] };
        t.mob.body.data.set("variant", Value::Int(v));
    }

    /// `Axolotl.finalizeSpawn` returns at once for a bucket release.
    fn finalize(&self, a: &Animal<Self>, t: &mut Turn, reason: &Atom) {
        if reason.as_str() == "bucket" {
            return;
        }
        self.spawn_part(a, t, reason);
        crate::mobs::ai::spawn::mob(t, reason);
    }

    /// `customServerAiStep` is its brain's (no love reset).
    fn server_ai_step(&self, _a: &Animal<Self>, _t: &mut Turn) -> bool {
        true
    }

    fn navigation(&self) -> NavSpec {
        NavSpec {
            kind: NavKind::Amphibious,
            ..NavSpec::default()
        }
    }

    /// Its travel when its AI does not choose one (dead, `NoAI`).
    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            fluid_pushed: false,
            travel: (TravelKind::Dolphin, false),
            ..KindMotion::default()
        }
    }

    /// `AxolotlMoveControl`: smooth swimming, held while it plays dead.
    fn move_control(&self, _a: &Animal<Self>, t: &mut Turn) {
        if playing_dead(t.data()) {
            t.mob.body.mob.motion.set = Some(MotionSet::Hold);
        } else {
            smooth_swimming::tick(t, &CONTROLS);
        }
        travel(t);
    }

    /// `AxolotlLookControl`: smooth swimming (20), still while it plays
    /// dead.
    fn look_control(&self, _a: &Animal<Self>, t: &mut Turn) -> bool {
        if !playing_dead(t.data()) {
            smooth_swimming::look(t, 20.0);
        }
        true
    }

    fn swim_sound(&self) -> Option<&'static str> {
        Some(self.swim)
    }

    fn max_air(&self) -> Option<i32> {
        Some(6000)
    }

    /// `Axolotl.handleAirSupply`: wet, full; dry, a tick less, then hurt by
    /// drying out at -20.
    fn air(&self, supply: i32, wet: bool) -> Option<(i32, f64)> {
        Some(if wet {
            (6000, 0.0)
        } else if supply - 1 <= -20 {
            (0, 2.0)
        } else {
            (supply - 1, 0.0)
        })
    }

    /// `isInWaterOrRain`.
    fn wet(&self, _a: &Animal<Self>, t: &Turn) -> Option<bool> {
        Some(t.in_water() || t.level.rain(t.pos(), t.y() + t.height))
    }

    /// `canBeSeenAsEnemy`: not while playing dead.
    fn hidden(&self, body: &Body) -> bool {
        playing_dead(&body.data)
    }

    /// `Axolotl.hurtServer` before its super: in water, hit by something,
    /// one time in three (with a hit greater than a draw of 0 to 2, or below
    /// half its health) and surviving it, it plays dead for 200 ticks.
    fn before_hurt(&self, _a: &Animal<Self>, body: &Body, hit: &Hit) -> Option<Body> {
        let mob = &body.mob;
        if mob.no_ai {
            return None;
        }
        let mind = mob.ai.as_ref()?;
        mind.state.as_ref()?;
        let mut body = body.clone();
        let mind = body.mob.ai.as_mut()?;
        let a = mind.random.int(3);
        let plays = if a == 0 {
            let health = body.mob.living.health.value;
            let max = self.max_health.value(&body.mob);
            let mind = body.mob.ai.as_mut()?;
            let b = mind.random.int(3) as f64;
            (b < hit.amount || f(health / max) < 0.5)
                && hit.amount < health
                && body.mob.motion.water > 0.0
                && (hit.attacker.is_some() || hit.direct.is_some())
                && !playing_dead(&body.data)
        } else {
            false
        };
        if plays {
            if let Some(brain) = body
                .mob
                .ai
                .as_mut()
                .and_then(|m| m.state.as_mut())
                .and_then(|s| s.brain.as_deref_mut())
            {
                brain
                    .memories
                    .set(Mem::PlayDeadTicks, MemValue::Int(200), None);
            }
        }
        Some(body)
    }

    /// `playAttackSound`.
    fn hit(&self, _a: &Animal<Self>, t: &mut Turn, _target: &Seen) {
        t.play("minecraft:entity.axolotl.attack", 1.0, 1.0);
    }

    fn brain(&self) -> Option<&dyn BrainFamily> {
        Some(self)
    }
}

// ## Its brain

impl Axolotl {
    // `findNearestValidAttackTarget`: what it may attack, unless breeding.
    fn find_target(&self, t: &Turn) -> Option<Seen> {
        if t.has(Mem::BreedTarget) {
            None
        } else {
            t.remembered(Mem::NearestAttackable)
        }
    }

    /// `AdultSensor`: the nearest visible adult of its own type.
    fn adult(&self, t: &mut Turn) {
        if !t.has(Mem::NearestVisibleLivingEntities) {
            return;
        }
        let own = t.type_id;
        let adult = sensors::visible_closest(t, |_, e| match e {
            Entity::Mob(m) => m.type_id == own && m.age >= 0,
            _ => false,
        });
        t.remember_opt(
            Mem::NearestVisibleAdult,
            adult.map(|a| MemValue::Ref(a.reference)),
        );
    }

    /// `AxolotlAttackablesSensor`: the nearest visible entity within eight
    /// blocks in water that it always fights, or hunts when off cooldown,
    /// and may attack.
    fn attackables(&self, t: &mut Turn) {
        let refs = match t.memory(Mem::NearestVisibleLivingEntities) {
            Some(MemValue::Visible(v)) => v.entities.clone(),
            _ => return,
        };
        let hunting = !t.has(Mem::HasHuntingCooldown);
        let mut found = None;
        for r in refs {
            let Some(e) = t.sensing.entity(&r) else {
                continue;
            };
            let id = e.type_id().map(|id| id as i32);
            let in_water = matches!(e, Entity::Mob(m) if m.in_water);
            let near = t.distance_sq(e.position()) <= 64.0;
            let wanted = id.is_some_and(|id| {
                self.hostile.contains(&id) || (hunting && self.hunt.contains(&id))
            });
            if near
                && in_water
                && wanted
                && sensors::visible_contains(t, &r)
                && sensors::attackable(t, &r)
            {
                found = Some(r);
                break;
            }
        }
        t.remember_opt(Mem::NearestAttackable, found.map(MemValue::Ref));
    }

    /// `TemptingSensor.forAnimal`: the nearest player holding its food (seen
    /// or not).
    fn temptations(&self, t: &mut Turn) {
        let range = t.attribute("minecraft:tempt_range");
        let targeting = Targeting::new(false).range(range).sight(false);
        let facts = t.level.facts;
        let pos = t.pos();
        let mut tempting = Vec::new();
        for i in 0..t.sensing.players.len() {
            let p = &t.sensing.players[i];
            let r = Entity::<Extra>::Player(p).reference();
            let food = [Slot::MainHand, Slot::OffHand].into_iter().any(|s| {
                p.equipped(s)
                    .is_some_and(|item| facts.animal.food(t.type_id, Some(item)))
            });
            let (mode, at) = (p.mode, p.position);
            let ok = t.test(&r, &targeting);
            if ok && food && mode != GameMode::Spectator {
                tempting.push((sensing::distance_sq(pos, at), r));
            }
        }
        tempting.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        t.remember_opt(
            Mem::TemptingPlayer,
            tempting.first().map(|(_, r)| MemValue::Ref(*r)),
        );
    }

    // `canSetWalkTargetFromLookTarget`: the look target's block is water as
    // much as the axolotl is in water.
    fn walks_to_look(&self, t: &Turn) -> bool {
        let Some(target) = t.mem_tracker(Mem::LookTarget) else {
            return false;
        };
        match bs::block(t, &target) {
            None => false,
            Some(pos) => (t.level.fluid(pos) == FluidKind::Water) == t.in_water(),
        }
    }
}

impl BrainFamily for Axolotl {
    fn as_any(&self) -> &dyn Any {
        self
    }

    fn brain(
        &self,
        _facts: &MobFacts,
        uuid: &Uuid,
        _data: &FamilyData,
        random: &mut LegacyRandom,
    ) -> Brain {
        let [gate] = super::gates(uuid, [0x5A17]);
        use Cond::{Absent, Present, Registered};
        let core = vec![
            bs::look_sink(45, 90),
            bs::move_sink(150, 250),
            b::one_shot(ValidatePlayDead),
            b::timed(
                Conds::new(&[(Mem::TemptationCooldownTicks, Present)]),
                NEVER,
                NEVER,
                CountDown {
                    memory: Mem::TemptationCooldownTicks,
                },
            ),
        ];
        let idle = vec![
            (0, bs::look_sometimes(Pick::Player, 6.0, (30, 60))),
            (
                1,
                b::timed(
                    Conds::new(&[
                        (Mem::NearestVisibleLivingEntities, Present),
                        (Mem::BreedTarget, Absent),
                        (Mem::WalkTarget, Registered),
                        (Mem::LookTarget, Registered),
                        (Mem::IsPanicking, Absent),
                    ]),
                    110,
                    110,
                    MakeLove {
                        speed: f(0.2),
                        close: 2,
                        at: 0,
                    },
                ),
            ),
            (
                2,
                b::run_one(
                    vec![
                        (
                            b::timed(
                                Conds::new(&[
                                    (Mem::LookTarget, Registered),
                                    (Mem::WalkTarget, Registered),
                                    (Mem::TemptationCooldownTicks, Absent),
                                    (Mem::TemptingPlayer, Present),
                                    (Mem::BreedTarget, Absent),
                                    (Mem::IsPanicking, Absent),
                                ]),
                                NEVER,
                                NEVER,
                                FollowTemptation,
                            ),
                            1,
                        ),
                        (bs::baby_follow_adult(5, 16, Speed::Family(CHASING)), 1),
                    ],
                    gate,
                    Conds::NONE,
                ),
            ),
            (3, fight::start_attacking(Test::Always, FIND_TARGET)),
            (
                3,
                b::one_shot(TryFindLiquid {
                    range: 6,
                    speed: f(0.15),
                }),
            ),
            (
                4,
                b::try_all_gate(
                    Conds::new(&[(Mem::WalkTarget, Absent)]),
                    vec![
                        bs::swim_stroll(f(0.5)),
                        bs::stroll(f(0.15), 10, 7, Test::Not(IN_WATER)),
                        bs::walk_to_look_target(
                            Test::Family(WALKS_TO_LOOK),
                            Speed::Family(SPEED),
                            3,
                        ),
                        bs::check(Test::Family(IN_WATER)),
                        bs::check(Test::Family(ON_GROUND)),
                    ],
                ),
            ),
        ];
        let fight_list = vec![
            fight::stop_if_invalid(None, true, Some(ON_STOP)),
            fight::walk_to_target(Speed::Family(CHASING)),
            fight::melee(Test::Always, 20),
            fight::erase_if(Test::Family(BREEDING), Mem::AttackTarget),
        ];
        let play_dead = vec![
            (
                0,
                b::timed(
                    Conds::new(&[(Mem::PlayDeadTicks, Present), (Mem::HurtByEntity, Present)]),
                    200,
                    200,
                    PlayDead {
                        regeneration: self.regeneration,
                    },
                ),
            ),
            (
                1,
                fight::erase_if(Test::Family(BREEDING), Mem::PlayDeadTicks),
            ),
        ];
        Brain::new(
            &[
                (Sensor::NearestLiving, 20),
                (Sensor::Family(ADULT_SENSOR), 20),
                (Sensor::HurtBy, 20),
                (Sensor::Family(ATTACKABLES), 20),
                (Sensor::Family(TEMPTATIONS), 20),
            ],
            vec![
                Package::from(Activity::Core, 0, core, Conds::NONE, &[]),
                Package::each(Activity::Idle, idle, Conds::NONE, &[]),
                Package::from(
                    Activity::Fight,
                    0,
                    fight_list,
                    Conds::new(&[(Mem::AttackTarget, Present)]),
                    &[Mem::AttackTarget],
                ),
                Package::each(
                    Activity::PlayDead,
                    play_dead,
                    Conds::new(&[(Mem::PlayDeadTicks, Present)]),
                    &[Mem::PlayDeadTicks],
                ),
            ],
            random,
            Some(&[Mem::HasHuntingCooldown]),
            &[],
        )
    }

    /// `AxolotlAi.updateActivity` (not while playing dead): play dead,
    /// fight or idle, the first valid; leaving a fight starts the hunting
    /// cooldown; then whether it plays dead.
    fn update_activity(&self, t: &mut Turn) {
        let old = t.activity();
        if old != Some(Activity::PlayDead) {
            t.first_valid(&[Activity::PlayDead, Activity::Fight, Activity::Idle]);
            if old == Some(Activity::Fight) && t.activity() != Some(Activity::Fight) {
                t.remember_for(Mem::HasHuntingCooldown, MemValue::True, 2400);
            }
        }
        // Its target is its attack target (`getTargetFromBrain`), while valid.
        let target = t.mem_ref(Mem::AttackTarget);
        t.put_target(target);
        let valid = t.target().map(|e| e.reference);
        t.put_target(valid);
        let playing = t.mem_int(Mem::PlayDeadTicks).is_some_and(|n| n > 0);
        t.mob.body.data.set("playing_dead", Value::bool(playing));
    }

    /// `playAmbientSound`: not while playing dead.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if playing_dead(t.data()) {
            return None;
        }
        let name = if t.in_water() {
            "minecraft:entity.axolotl.idle_water"
        } else {
            "minecraft:entity.axolotl.idle_air"
        };
        t.level.facts.sounds.id(name)
    }

    fn scan(&self, t: &mut Turn, tag: u32) {
        match tag {
            ADULT_SENSOR => self.adult(t),
            ATTACKABLES => self.attackables(t),
            TEMPTATIONS => self.temptations(t),
            _ => {}
        }
    }

    fn test(&self, t: &mut Turn, tag: u32) -> bool {
        match tag {
            IN_WATER => t.in_water(),
            ON_GROUND => t.on_ground(),
            WALKS_TO_LOOK => self.walks_to_look(t),
            BREEDING => t.has(Mem::BreedTarget),
            _ => false,
        }
    }

    fn find(&self, t: &mut Turn, _tag: u32) -> Option<Seen> {
        self.find_target(t)
    }

    fn speed(&self, t: &Turn, tag: u32) -> f64 {
        match tag {
            SPEED => speed(t),
            _ => chasing(t),
        }
    }

    /// `Axolotl.onStopAttacking`: a target that died of a player's hit near
    /// it (within 20 blocks) leaves that player Regeneration and no Mining
    /// Fatigue.
    fn on_stop(&self, t: &mut Turn, _tag: u32, target: Option<&Seen>) {
        let Some(target) = target else { return };
        if target.alive {
            return;
        }
        let Some(Entity::Mob(m)) = t.sensing.entity(&target.reference) else {
            return;
        };
        let Some(killer) = m.killed_by else { return };
        let r = Ref {
            kind: RefKind::Player,
            uuid: killer,
        };
        let Some(player) = t.entity(Some(&r)) else {
            return;
        };
        let near = sensing::inflate(&t.bbox(), 20.0, 20.0, 20.0);
        if sensing::intersects(&near, &player.bbox) {
            let support = Value::tuple([
                Value::atom("support"),
                Value::Int(self.regeneration as i64),
                Value::Int(self.mining_fatigue as i64),
            ]);
            t.effect(Effect::GiveEffect {
                target: r,
                actions: Value::List(vec![support]),
            });
        }
    }

    fn young(&self, t: &Turn) -> bool {
        baby(t)
    }
}

// ## Its behaviours

/// `ValidatePlayDead`: counting down; at zero it forgets who hurt it and
/// goes back to idle.
#[derive(Clone, Debug, PartialEq)]
struct ValidatePlayDead;

impl Trigger for ValidatePlayDead {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::PlayDeadTicks, Cond::Present),
            (Mem::HurtByEntity, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let ticks = t.mem_int(Mem::PlayDeadTicks).unwrap_or(0);
        if ticks <= 0 {
            t.forget(Mem::PlayDeadTicks);
            t.forget(Mem::HurtByEntity);
            t.default_activity();
        } else {
            t.remember(Mem::PlayDeadTicks, MemValue::Int(ticks - 1));
        }
        true
    }
}

/// `CountDownCooldownTicks(memory)`.
#[derive(Clone, Debug, PartialEq)]
struct CountDown {
    memory: Mem,
}

impl Timer for CountDown {
    fn still(&mut self, t: &mut Turn) -> bool {
        t.mem_int(self.memory).is_some_and(|n| n > 0)
    }

    fn tick(&mut self, t: &mut Turn) {
        let n = t.mem_int(self.memory).unwrap_or(0);
        t.remember(self.memory, MemValue::Int(n - 1));
    }

    fn stop(&mut self, t: &mut Turn) {
        t.forget(self.memory);
    }
}

/// `PlayDead` (200 ticks): in water, still, with Regeneration.
#[derive(Clone, Debug, PartialEq)]
struct PlayDead {
    regeneration: i32,
}

impl Timer for PlayDead {
    fn extra(&mut self, t: &mut Turn) -> bool {
        t.in_water()
    }

    fn start(&mut self, t: &mut Turn) {
        t.forget(Mem::WalkTarget);
        t.forget(Mem::LookTarget);
        t.add_effect(
            self.regeneration,
            Rung {
                ticks: 200,
                amplifier: 0,
                ambient: false,
                particles: true,
                icon: true,
            },
        );
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        t.in_water() && t.has(Mem::PlayDeadTicks)
    }
}

/// `FollowTemptation(getSpeedModifier)`.
#[derive(Clone, Debug, PartialEq)]
struct FollowTemptation;

impl Timer for FollowTemptation {
    fn still(&mut self, t: &mut Turn) -> bool {
        t.has(Mem::TemptingPlayer) && !t.has(Mem::BreedTarget) && !t.has(Mem::IsPanicking)
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(player) = t.remembered(Mem::TemptingPlayer) else {
            return;
        };
        let r = player.reference;
        bs::look_at_entity(t, r);
        if bs::distance_sq(t, &player) < 2.5 * 2.5 {
            t.forget(Mem::WalkTarget);
        } else {
            let speed = speed(t);
            bs::walk_to_entity(t, r, speed, 2);
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        t.remember(Mem::TemptationCooldownTicks, MemValue::Int(100));
        t.forget(Mem::WalkTarget);
        t.forget(Mem::LookTarget);
    }
}

/// `AnimalMakeLove(AXOLOTL, speed, close)` (110 ticks at most).
#[derive(Clone, Debug, PartialEq)]
struct MakeLove {
    speed: f64,
    close: i32,
    at: i64,
}

impl MakeLove {
    fn partner(&self, t: &Turn) -> Option<Seen> {
        let refs = match t.memory(Mem::NearestVisibleLivingEntities) {
            Some(MemValue::Visible(v)) => v.entities.clone(),
            _ => return None,
        };
        refs.iter().find_map(|r| {
            let e = t.entity(Some(r))?;
            (e.type_id == Some(t.type_id) && !e.panicking && can_mate(t, &e)).then_some(e)
        })
    }

    // `BehaviorUtils.lockGazeAndWalkToEachOther`: both look at and walk to
    // each other.
    fn lock_gaze(&self, t: &mut Turn, partner: Ref) {
        let me = crate::mobs::ai::brain::mob_ref(t.uuid);
        bs::look_at_entity(t, partner);
        bs::walk_to_entity(t, partner, self.speed, self.close);
        remember(
            t,
            partner,
            Mem::LookTarget,
            Some(MemValue::Tracker(Tracker::entity(me, true))),
        );
        remember(
            t,
            partner,
            Mem::WalkTarget,
            Some(bs::walk(Tracker::entity(me, false), self.speed, self.close)),
        );
    }
}

// `Animal.canMate`: another adult in love.
fn can_mate(t: &Turn, other: &Seen) -> bool {
    other.uuid() != t.uuid
        && t.data().in_love().unwrap_or(0) > 0
        && other.in_love > 0
        && other.age == 0
}

// A memory of the partner's set (or erased) at once, as vanilla's behaviour
// sets it.
fn remember(t: &mut Turn, other: Ref, m: Mem, value: Option<MemValue>) {
    let change = match value {
        Some(v) => Remember::set(m, v),
        None => Remember::erase(m),
    };
    t.effect(Effect::Remote {
        mob: other.uuid,
        change: Box::new(change),
    });
}

impl Timer for MakeLove {
    fn extra(&mut self, t: &mut Turn) -> bool {
        t.data().in_love().unwrap_or(0) > 0 && self.partner(t).is_some()
    }

    fn start(&mut self, t: &mut Turn) {
        let Some(partner) = self.partner(t) else {
            return;
        };
        let r = partner.reference;
        t.remember(Mem::BreedTarget, MemValue::Ref(r));
        let me = crate::mobs::ai::brain::mob_ref(t.uuid);
        remember(t, r, Mem::BreedTarget, Some(MemValue::Ref(me)));
        self.lock_gaze(t, r);
        let n = t.int(50) as i64;
        self.at = t.level.time + 60 + n;
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        match t.remembered(Mem::BreedTarget) {
            Some(partner) if partner.type_id == Some(t.type_id) && partner.alive => {
                let visible = sensors::visible_contains(t, &partner.reference);
                can_mate(t, &partner)
                    && visible
                    && t.level.time <= self.at
                    && !t.has(Mem::IsPanicking)
                    && !partner.panicking
            }
            _ => false,
        }
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(partner) = t.remembered(Mem::BreedTarget) else {
            return;
        };
        let r = partner.reference;
        self.lock_gaze(t, r);
        if bs::distance_sq(t, &partner) < 9.0 && t.level.time >= self.at {
            let hooks = t.hooks;
            hooks.breed(t, None, &partner);
            t.forget(Mem::BreedTarget);
            remember(t, r, Mem::BreedTarget, None);
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        t.forget(Mem::BreedTarget);
        t.forget(Mem::WalkTarget);
        t.forget(Mem::LookTarget);
        self.at = 0;
    }
}

/// `TryFindLiquid.create(range, speed, AXOLOTL_TRIES_TO_FIND)`: on land,
/// the first water within `range` (not in its own column) with air above,
/// else the first not right beside it; tried again after 40 ticks (22 while
/// waiting).
#[derive(Clone, Debug, PartialEq)]
struct TryFindLiquid {
    range: i32,
    speed: f64,
}

fn next_try(t: &Turn) -> i64 {
    t.mind
        .own
        .family::<AxolotlOwn>()
        .map_or(0, |o| o.find_liquid)
}

fn put_next_try(t: &mut Turn, at: i64) {
    t.mind.own.family = Some(Box::new(AxolotlOwn { find_liquid: at }));
}

impl Trigger for TryFindLiquid {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AttackTarget, Cond::Absent),
            (Mem::WalkTarget, Cond::Absent),
            (Mem::LookTarget, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let at = t.block();
        if t.level.fluid(at) == FluidKind::Water {
            return false;
        }
        let now = t.level.time;
        if now < next_try(t) {
            put_next_try(t, now + 22);
            return true;
        }
        let water = t.level.facts.blocks.id("minecraft:water");
        let [bx, _, bz] = at;
        let mut found = None;
        for pos in crate::mobs::level::manhattan(at, self.range, self.range, self.range) {
            let [x, y, z] = pos;
            if x == bx && z == bz {
                continue;
            }
            let liquid = t
                .level
                .block(pos)
                .is_some_and(|s| water.is_some() && t.level.facts.blocks.block_id(s) == water);
            if !liquid {
                continue;
            }
            if t.level.air([x, y + 1, z]) {
                found = Some(pos);
                break;
            }
            if found.is_none() && !bs::near_center(pos, t.pos(), 1.5) {
                found = Some(pos);
            }
        }
        if let Some(pos) = found {
            let tracker = Tracker::block(pos);
            t.remember(Mem::LookTarget, MemValue::Tracker(tracker));
            t.remember(Mem::WalkTarget, bs::walk(tracker, self.speed, 0));
        }
        put_next_try(t, now + 40);
        true
    }
}
