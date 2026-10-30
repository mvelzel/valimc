//! Villagers (`Valimc.AI.Mobs.Villager`, `Valimc.Entity.Villager` and
//! `Valimc.AI.Brains.Villager`, vanilla's `Villager` and
//! `VillagerGoalPackages`): no goals, a brain with the core, idle, work,
//! meet, rest, panic and (a baby's) play activities at vanilla's priorities,
//! the daily schedule choosing among them; a navigation that opens doors,
//! floats and paths 48 blocks.
//!
//! - **Core**: swimming, doors, the look and walk sinks, panic at a hostile
//!   or when hurt (asking for a golem every 100 ticks), waking at day,
//!   keeping its job site and potential job site valid, the job site
//!   competition, claiming a job site (a potential one first), walking to
//!   it, yielding it to a villager whose trade holds it, claiming a bed and
//!   the meeting point, taking the profession of its job site and losing it
//!   with it (its brain made again).
//! - **Work**: working at its job site (its work sound), strolling around it
//!   and back to it; **meet**: strolling around the bell, socializing,
//!   trading with another villager (gossip, which may summon a golem);
//!   **rest**: to its bed and asleep in it (the bed occupied), or toward a
//!   bed, a roofed walk or a village; **idle**, **play** and **panic** as
//!   vanilla's, with looks and walks shuffled by their own randoms.
//!
//! Trading with players, breeding, bells' raids and hiding, and farming
//! wait in the Elixir (their behaviours keep their places and never start),
//! so they do here. A villager's POI memories and when it last slept, woke
//! and worked are saved with it; other villagers and golems read its job
//! site, gossip, golem sighting and last sleep.

use crate::mobs::ai::brain::behavior::{self as b, Behavior, Timer, Trigger};
use crate::mobs::ai::brain::behaviors::{self as bs, Pick, Speed, Test};
use crate::mobs::ai::brain::poi::{self, Types};
use crate::mobs::ai::brain::{
    self as brain, mob_ref, Activity, Brain, BrainFamily, Cond, Conds, Global, Mem, MemValue,
    Package, Remember, Sensor, Tracker,
};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::pois::{self, Occupancy};
use crate::mobs::ai::turn::{Kinds, Seen, Turn};
use crate::mobs::ai::{navigation, think, Extra};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, NavSpec, Registered};
use crate::mobs::level::FluidKind;
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::monsters::{entity, fields, int, value};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::{self, Entity, Ref, Uuid};
use crate::mobs::term::{Atom, Map, Value, NIL};
use crate::physics::Aabb;
use std::any::Any;

pub const VILLAGER: &str = "minecraft:villager";
const SPEED: f64 = 0.5;
const NONE: &str = "minecraft:none";
const NITWIT: &str = "minecraft:nitwit";
const BED_HEIGHT: f64 = 0.5625;

// Its tests, picks and sensors (tags).
const NEVER: u32 = 1;
const CREATURE: u32 = 10;
const WATER_CREATURE: u32 = 11;
const AXOLOTLS: u32 = 12;
const UNDERGROUND_WATER_CREATURE: u32 = 13;
const WATER_AMBIENT: u32 = 14;
const MONSTER: u32 = 15;
const NEAREST_BED: u32 = 1;
const HOSTILES: u32 = 2;
const BABIES: u32 = 3;
const SECONDARY_POIS: u32 = 4;
const GOLEMS: u32 = 5;

/// The memories a villager's record saves (`MemoryModuleType.canSerialize`).
const SAVED: &[Mem] = &[
    Mem::Home,
    Mem::JobSite,
    Mem::PotentialJobSite,
    Mem::MeetingPoint,
    Mem::LastSlept,
    Mem::LastWoken,
    Mem::LastWorkedAtPoi,
    Mem::GolemDetectedRecently,
];

/// The memories other villagers and golems read of it.
const SHARED: &[Mem] = &[
    Mem::JobSite,
    Mem::PotentialJobSite,
    Mem::LastGossip,
    Mem::GolemDetectedRecently,
    Mem::LastSlept,
];

/// The hostiles a villager panics at and how near (`VillagerHostilesSensor`).
const HOSTILE_DISTANCES: &[(&str, f64)] = &[
    ("minecraft:drowned", 8.0),
    ("minecraft:evoker", 12.0),
    ("minecraft:husk", 8.0),
    ("minecraft:illusioner", 12.0),
    ("minecraft:pillager", 15.0),
    ("minecraft:ravager", 12.0),
    ("minecraft:vex", 8.0),
    ("minecraft:vindicator", 10.0),
    ("minecraft:zoglin", 10.0),
    ("minecraft:zombie", 8.0),
    ("minecraft:zombie_villager", 8.0),
];

/// Where a golem stands, as `SpawnUtil.Strategy.LEGACY_IRON_GOLEM` and
/// `NaturalSpawner.isValidEmptySpawnBlock` judge it.
struct GolemBlocks {
    refuse: Vec<u16>,
    stained: Vec<u16>,
    leaves: Vec<i32>,
    powder_snow: Option<u16>,
    no_spawn: Vec<i32>,
    dangerous: Vec<u16>,
    campfires: Vec<u16>,
    lava_cauldron: Option<u16>,
}

/// The villager family.
pub struct Villager {
    types: [&'static str; 1],
    /// Villager type and profession protocol ids (`villager_data`).
    type_ids: std::collections::HashMap<String, i32>,
    profession_ids: Vec<(String, i32)>,
    villager: u16,
    cat: u16,
    iron_golem: u16,
    hostiles: Vec<(u16, f64)>,
    golem: GolemBlocks,
}

impl Villager {
    pub fn new(facts: &MobFacts) -> Result<Villager, String> {
        let block = |name: &str| facts.blocks.id(name);
        let blocks = |names: &[&str]| names.iter().filter_map(|n| block(n)).collect::<Vec<u16>>();
        let classes = |names: &[&str]| {
            (0..facts.blocks.blocks.len() as u16)
                .filter(|&id| {
                    facts
                        .blocks
                        .block(id)
                        .is_some_and(|b| names.contains(&b.class.as_str()))
                })
                .collect::<Vec<u16>>()
        };
        let tag = |t: &str| {
            facts
                .tags
                .get("minecraft:block", t)
                .map(<[i32]>::to_vec)
                .unwrap_or_default()
        };
        Ok(Villager {
            types: [VILLAGER],
            type_ids: facts.village.types.clone(),
            profession_ids: facts
                .village
                .professions
                .iter()
                .map(|p| (p.name.clone(), p.id))
                .collect(),
            villager: entity(facts, VILLAGER)?,
            cat: entity(facts, "minecraft:cat")?,
            iron_golem: entity(facts, "minecraft:iron_golem")?,
            hostiles: HOSTILE_DISTANCES
                .iter()
                .filter_map(|&(name, d)| facts.entities.id(name).map(|id| (id, d)))
                .collect(),
            golem: GolemBlocks {
                refuse: blocks(&[
                    "cobweb",
                    "cactus",
                    "glass_pane",
                    "conduit",
                    "ice",
                    "tnt",
                    "glowstone",
                    "beacon",
                    "sea_lantern",
                    "frosted_ice",
                    "tinted_glass",
                    "glass",
                ]),
                stained: classes(&["StainedGlassPaneBlock", "StainedGlassBlock"]),
                leaves: tag("minecraft:leaves"),
                powder_snow: block("powder_snow"),
                no_spawn: tag("minecraft:prevent_mob_spawning_inside"),
                dangerous: blocks(&[
                    "wither_rose",
                    "sweet_berry_bush",
                    "cactus",
                    "powder_snow",
                    "fire",
                    "soul_fire",
                    "lava",
                    "magma_block",
                ]),
                campfires: blocks(&["campfire", "soul_campfire"]),
                lava_cauldron: block("lava_cauldron"),
            },
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("villager_type", Value::Binary(b"minecraft:plains".to_vec())),
            ("profession", Value::Binary(NONE.as_bytes().to_vec())),
            ("level", Value::Int(1)),
            ("finalized", Value::bool(false)),
            ("unhappy", Value::Int(0)),
            ("age", Value::Int(0)),
            ("xp", Value::Int(0)),
            ("sleeping", NIL),
        ])
    }
}

// ## Its data

fn string(data: &FamilyData, key: &str) -> String {
    data.get(key)
        .and_then(Value::as_binary)
        .and_then(|b| std::str::from_utf8(b).ok())
        .unwrap_or("")
        .to_owned()
}

fn profession(data: &FamilyData) -> String {
    string(data, "profession")
}

fn baby(data: &FamilyData) -> bool {
    int(data, "age") < 0
}

/// The bed it lies in.
fn sleeping(data: &FamilyData) -> Option<[i32; 3]> {
    data.get("sleeping")
        .and_then(Value::as_ivec3)
        .map(|p| p.map(|v| v as i32))
}

fn villager<'w>(t: &Turn<'_, 'w>) -> Option<&'w Villager> {
    t.family()?.as_any().downcast_ref::<Villager>()
}

/// A change of another villager's memories.
fn remote(t: &mut Turn, uuid: Uuid, change: Remember) {
    t.effect(Effect::Remote {
        mob: uuid,
        change: Box::new(change),
    });
}

/// `updateActivityFromSchedule` at the day's scheduled activity.
fn schedule(t: &mut Turn) {
    let scheduled = t.level.facts.village.scheduled(t.level.day, baby(t.data()));
    if let Some(a) = Activity::of(scheduled) {
        t.update_from_schedule(a);
    }
}

/// A sensed villager's view: its uuid, place, data and shared memories.
struct Other {
    uuid: Uuid,
    position: [f64; 3],
    profession: String,
    xp: i64,
    memories: Option<Value>,
}

fn other(t: &Turn, r: &Ref, villager: u16) -> Option<Other> {
    match t.sensing.entity(r)? {
        Entity::Mob(m) if m.type_id == villager && m.alive => Some(Other {
            uuid: m.uuid,
            position: m.position,
            profession: m.extra.data.as_ref().map(profession).unwrap_or_default(),
            xp: m.extra.data.as_ref().map_or(0, |d| int(d, "xp")),
            memories: m.extra.memories.clone(),
        }),
        _ => None,
    }
}

fn holds(t: &Turn, profession: &str, poi: &str) -> bool {
    t.level
        .facts
        .village
        .profession(profession)
        .is_some_and(|p| p.held.iter().any(|h| h == poi))
}

fn global_value(g: &Global) -> Value {
    brain::value(&MemValue::Global(g.clone()), None)
}

// ## Its brain

impl Villager {
    /// `gates/2`: a fresh villager's gate randoms, by key, from its uuid.
    fn gates(uuid: &Uuid, baby: bool) -> Vec<(&'static str, LegacyRandom)> {
        let first: [&'static str; 2] = if baby {
            ["5:play:0:0", "5:play:1:0"]
        } else {
            ["5:work:0:0", "5:work:1:0"]
        };
        let keys = first.into_iter().chain([
            "2:meet:0:0",
            "3:meet:2:0",
            "5:meet:0:0",
            "5:rest:0:0",
            "5:rest:1:0",
            "2:idle:0:0",
            "3:idle:3:0",
            "3:idle:4:0",
            "5:idle:0:0",
            "5:panic:0:0",
            "inside_brownian_walk",
        ]);
        let (a, b) = super::halves(uuid);
        keys.enumerate()
            .map(|(i, key)| {
                let seed = a.wrapping_add((i as u64).wrapping_mul(0x9E37_79B9)) ^ b;
                (key, LegacyRandom::new(seed as i64))
            })
            .collect()
    }

    fn full_look(&self, random: LegacyRandom) -> (i32, Box<dyn Behavior>) {
        let look = |p| bs::look_target(p, 8.0);
        (
            5,
            b::run_one(
                vec![
                    (look(Pick::Type(self.cat)), 8),
                    (look(Pick::Type(self.villager)), 2),
                    (look(Pick::Player), 2),
                    (look(Pick::Family(CREATURE)), 1),
                    (look(Pick::Family(WATER_CREATURE)), 1),
                    (look(Pick::Family(AXOLOTLS)), 1),
                    (look(Pick::Family(UNDERGROUND_WATER_CREATURE)), 1),
                    (look(Pick::Family(WATER_AMBIENT)), 1),
                    (look(Pick::Family(MONSTER)), 1),
                    (b::do_nothing(30, 60), 2),
                ],
                random,
                Conds::NONE,
            ),
        )
    }

    fn minimal_look(&self, random: LegacyRandom) -> (i32, Box<dyn Behavior>) {
        (
            5,
            b::run_one(
                vec![
                    (bs::look_target(Pick::Type(self.villager), 8.0), 2),
                    (bs::look_target(Pick::Player, 8.0), 2),
                    (b::do_nothing(30, 60), 8),
                ],
                random,
                Conds::NONE,
            ),
        )
    }

    fn core(&self) -> Vec<(i32, Box<dyn Behavior>)> {
        use Cond::Present;
        vec![
            (0, bs::swim(0.8)),
            (0, bs::interact_with_door()),
            (0, bs::look_sink(45, 90)),
            (0, b::timed(Conds::NONE, 60, 60, PanicTrigger)),
            (0, b::one_shot(WakeUp)),
            (0, b::one_shot(HeardBell)),
            (0, b::one_shot(SetRaidStatus)),
            (0, poi::validate(Types::Held, Mem::JobSite)),
            (0, poi::validate(Types::Acquirable, Mem::PotentialJobSite)),
            (1, bs::move_sink(150, 250)),
            (2, b::one_shot(CompetitorScan)),
            (3, b::inert("LookAndFollowTradingPlayerSink")),
            (5, bs::go_to_wanted_item(Test::Always, SPEED, false, 4)),
            (
                6,
                poi::acquire(
                    Types::Acquirable,
                    Mem::JobSite,
                    Mem::PotentialJobSite,
                    true,
                    None,
                    false,
                ),
            ),
            (
                7,
                b::timed(
                    Conds::new(&[(Mem::PotentialJobSite, Present)]),
                    1200,
                    1200,
                    GoToJobSite { speed: f(SPEED) },
                ),
            ),
            (8, b::one_shot(YieldJobSite { speed: SPEED })),
            (
                10,
                poi::acquire(
                    Types::Fixed(&["minecraft:home"]),
                    Mem::Home,
                    Mem::Home,
                    false,
                    Some(14),
                    true,
                ),
            ),
            (
                10,
                poi::acquire(
                    Types::Fixed(&["minecraft:meeting"]),
                    Mem::MeetingPoint,
                    Mem::MeetingPoint,
                    true,
                    Some(14),
                    false,
                ),
            ),
            (10, b::one_shot(AssignProfession)),
            (10, b::one_shot(ResetProfession)),
        ]
    }

    fn work(
        &self,
        farmer: bool,
        g: &dyn Fn(&str) -> LegacyRandom,
    ) -> Vec<(i32, Box<dyn Behavior>)> {
        vec![
            self.minimal_look(g("5:work:0:0")),
            (
                5,
                b::run_one(
                    vec![
                        (
                            b::timed(
                                Conds::new(&[
                                    (Mem::JobSite, Cond::Present),
                                    (Mem::LookTarget, Cond::Registered),
                                ]),
                                60,
                                60,
                                WorkAtPoi { last_check: 0 },
                            ),
                            7,
                        ),
                        (b::one_shot(poi::stroll_around(Mem::JobSite, 0.4, 4)), 2),
                        (poi::stroll_to(Mem::JobSite, 0.4, 1, 10), 5),
                        (
                            poi::stroll_to_list(Mem::SecondaryJobSite, SPEED, 1, 6, Mem::JobSite),
                            5,
                        ),
                        (b::inert("HarvestFarmland"), if farmer { 2 } else { 5 }),
                        (b::inert("UseBonemeal"), if farmer { 4 } else { 7 }),
                    ],
                    g("5:work:1:0"),
                    Conds::NONE,
                ),
            ),
            (10, b::inert("ShowTradesToPlayer")),
            (10, bs::look_and_interact(Pick::Player, 4)),
            (2, poi::walk_to_memory(Mem::JobSite, SPEED, 9, 100, 1200)),
            (3, b::inert("GiveGiftToHero")),
            (99, b::one_shot(UpdateSchedule)),
        ]
    }

    fn play(&self, g: &dyn Fn(&str) -> LegacyRandom) -> Vec<(i32, Box<dyn Behavior>)> {
        vec![
            (0, bs::move_sink(80, 120)),
            self.full_look(g("5:play:1:0")),
            (5, b::inert("PlayTagWithOtherKids")),
            (
                5,
                b::run_one(
                    vec![
                        (
                            b::one_shot(bs::interact_with(Pick::Type(self.villager), 8, SPEED, 2)),
                            2,
                        ),
                        (
                            b::one_shot(bs::interact_with(Pick::Type(self.cat), 8, SPEED, 2)),
                            1,
                        ),
                        (b::one_shot(poi::village_stroll(SPEED, 10, 7)), 1),
                        (
                            bs::walk_to_look_target(Test::Always, Speed::of(SPEED), 2),
                            1,
                        ),
                        (jump_on_bed(SPEED), 2),
                        (b::do_nothing(20, 40), 2),
                    ],
                    g("5:play:0:0"),
                    Conds::new(&[(Mem::VisibleVillagerBabies, Cond::Absent)]),
                ),
            ),
            (99, b::one_shot(UpdateSchedule)),
        ]
    }

    fn rest(&self, g: &dyn Fn(&str) -> LegacyRandom) -> Vec<(i32, Box<dyn Behavior>)> {
        use Cond::Registered;
        vec![
            (2, poi::walk_to_memory(Mem::Home, SPEED, 1, 150, 1200)),
            (
                3,
                poi::validate(Types::Fixed(&["minecraft:home"]), Mem::Home),
            ),
            (
                3,
                b::forever(
                    Conds::new(&[
                        (Mem::Home, Cond::Present),
                        (Mem::LastWoken, Registered),
                        (Mem::LastSlept, Registered),
                        (Mem::WalkTarget, Registered),
                        (Mem::CantReachWalkTargetSince, Registered),
                    ]),
                    Sleep { next: 0 },
                ),
            ),
            (
                5,
                b::run_one(
                    vec![
                        (b::one_shot(poi::walk_to_closest_home(SPEED)), 1),
                        (
                            b::one_shot(BrownianWalk {
                                speed: SPEED,
                                random: g("inside_brownian_walk"),
                            }),
                            4,
                        ),
                        (b::one_shot(poi::go_to_village(SPEED, 4)), 2),
                        (b::do_nothing(20, 40), 2),
                    ],
                    g("5:rest:0:0"),
                    Conds::new(&[(Mem::Home, Cond::Absent)]),
                ),
            ),
            self.minimal_look(g("5:rest:1:0")),
            (99, b::one_shot(UpdateSchedule)),
        ]
    }

    fn meet(&self, g: &dyn Fn(&str) -> LegacyRandom) -> Vec<(i32, Box<dyn Behavior>)> {
        vec![
            (
                2,
                b::trigger_gate(
                    vec![
                        (
                            b::one_shot(poi::stroll_around(Mem::MeetingPoint, 0.4, 40)),
                            2,
                        ),
                        (b::one_shot(SocializeAtBell), 2),
                    ],
                    g("2:meet:0:0"),
                ),
            ),
            (10, b::inert("ShowTradesToPlayer")),
            (10, bs::look_and_interact(Pick::Player, 4)),
            (
                2,
                poi::walk_to_memory(Mem::MeetingPoint, SPEED, 6, 100, 200),
            ),
            (3, b::inert("GiveGiftToHero")),
            (
                3,
                poi::validate(Types::Fixed(&["minecraft:meeting"]), Mem::MeetingPoint),
            ),
            (
                3,
                b::gate(
                    vec![(trade_with_villager(), 1)],
                    g("3:meet:2:0"),
                    Conds::NONE,
                    &[Mem::InteractionTarget],
                    true,
                ),
            ),
            self.full_look(g("5:meet:0:0")),
            (99, b::one_shot(UpdateSchedule)),
        ]
    }

    fn idle(&self, g: &dyn Fn(&str) -> LegacyRandom) -> Vec<(i32, Box<dyn Behavior>)> {
        let mut breed = bs::interact_with(Pick::Type(self.villager), 8, SPEED, 2);
        breed.memory = Mem::BreedTarget;
        breed.own = Test::Family(NEVER);
        breed.target = Pick::Family(NEVER);
        vec![
            (
                2,
                b::run_one(
                    vec![
                        (
                            b::one_shot(bs::interact_with(Pick::Type(self.villager), 8, SPEED, 2)),
                            2,
                        ),
                        (b::one_shot(breed), 1),
                        (
                            b::one_shot(bs::interact_with(Pick::Type(self.cat), 8, SPEED, 2)),
                            1,
                        ),
                        (b::one_shot(poi::village_stroll(SPEED, 10, 7)), 1),
                        (
                            bs::walk_to_look_target(Test::Always, Speed::of(SPEED), 2),
                            1,
                        ),
                        (jump_on_bed(SPEED), 1),
                        (b::do_nothing(30, 60), 1),
                    ],
                    g("2:idle:0:0"),
                    Conds::NONE,
                ),
            ),
            (3, b::inert("GiveGiftToHero")),
            (3, bs::look_and_interact(Pick::Player, 4)),
            (3, b::inert("ShowTradesToPlayer")),
            (
                3,
                b::gate(
                    vec![(trade_with_villager(), 1)],
                    g("3:idle:3:0"),
                    Conds::NONE,
                    &[Mem::InteractionTarget],
                    true,
                ),
            ),
            (
                3,
                b::gate(
                    vec![(b::inert("VillagerMakeLove"), 1)],
                    g("3:idle:4:0"),
                    Conds::NONE,
                    &[Mem::BreedTarget],
                    true,
                ),
            ),
            self.full_look(g("5:idle:0:0")),
            (99, b::one_shot(UpdateSchedule)),
        ]
    }

    fn panic(&self, g: &dyn Fn(&str) -> LegacyRandom) -> Vec<(i32, Box<dyn Behavior>)> {
        let runaway = f(f(SPEED) * 1.5);
        vec![
            (0, b::one_shot(CalmDown)),
            (
                1,
                bs::walk_away_from(Mem::NearestHostile, runaway, 6, false),
            ),
            (1, bs::walk_away_from(Mem::HurtByEntity, runaway, 6, false)),
            (3, b::one_shot(poi::village_stroll(runaway, 2, 2))),
            self.minimal_look(g("5:panic:0:0")),
        ]
    }

    /// `Villager.refreshBrain`: every behaviour stops, the brain is made
    /// again with the memories it had, and the schedule picks the activity.
    fn refresh(&self, t: &mut Turn) {
        brain::stop_all(t);
        let facts = t.level.facts;
        let uuid = t.uuid;
        let data = t.data().clone();
        // An oracle's brain takes the gates it was given for its next
        // remaking, and keeps its activity order.
        let (gates, order, rest) = match t.brain() {
            Some(b) if !b.refresh.is_empty() => (
                Some(b.refresh[0].clone()),
                b.order.clone(),
                b.refresh[1..].to_vec(),
            ),
            Some(b) => (None, b.order.clone(), Vec::new()),
            None => (None, Vec::new(), Vec::new()),
        };
        let mut fresh = match gates {
            Some(gates) => self.build(&data, &mut t.random, &gates, &order),
            None if !order.is_empty() => {
                let gates: Vec<(String, LegacyRandom)> = Villager::gates(&uuid, baby(&data))
                    .into_iter()
                    .map(|(k, r)| (k.to_owned(), r))
                    .collect();
                self.build(&data, &mut t.random, &gates, &order)
            }
            None => BrainFamily::brain(self, facts, &uuid, &data, &mut t.random),
        };
        fresh.refresh = rest;
        if let Some(old) = t.brain() {
            fresh.memories = old.memories.clone();
        }
        t.mind.brain = Some(Box::new(fresh));
        schedule(t);
    }

    // ## Golems

    /// `Villager.spawnGolemIfNeeded(level, now, agree)`.
    fn spawn_golem_if_needed(&self, t: &mut Turn, agree: usize) {
        let now = t.level.time;
        if !own_wants_golem(t, now) {
            return;
        }
        let around = sensing::inflate(&t.bbox(), 10.0, 10.0, 10.0);
        let near = t.mobs_in(Kinds::Types(&[self.villager]), &around);
        let wanting = near
            .iter()
            .filter(|v| {
                if v.uuid() == t.uuid {
                    own_wants_golem(t, now)
                } else {
                    wants_golem(t, &v.reference, now)
                }
            })
            .take(5)
            .count();
        if wanting < agree {
            return;
        }
        let Some(golem) = self.golem_spot(t) else {
            return;
        };
        t.effect(Effect::Spawn {
            type_id: self.iron_golem,
            options: golem,
        });
        for v in near {
            if v.uuid() == t.uuid {
                t.remember_for(Mem::GolemDetectedRecently, MemValue::True, 599);
            } else {
                remote(
                    t,
                    v.uuid(),
                    Remember(vec![(
                        Mem::GolemDetectedRecently,
                        Some((MemValue::True, Some(599))),
                    )]),
                );
            }
        }
    }

    // `SpawnUtil.trySpawnMob(IRON_GOLEM, ...)`: a golem made on a spot it
    // may stand on, kept where nothing obstructs it.
    fn golem_spot(&self, t: &mut Turn) -> Option<Value> {
        let [sx, sy, sz] = t.block();
        for _ in 0..10 {
            let dx = t.level_int(17);
            let dz = t.level_int(17);
            let (x, z) = (sx + dx - 8, sz + dz - 8);
            let Some(pos) = self.down_to_spot(t, [x, sy + 6, z]) else {
                continue;
            };
            let golem = made(t, pos);
            if self.fits_golem(t, pos) {
                return Some(golem);
            }
        }
        None
    }

    // `moveToPossibleSpawnPosition`: down from 6 above to 6 below, the
    // first block the strategy stands it on, one above it.
    fn down_to_spot(&self, t: &Turn, [x, y, z]: [i32; 3]) -> Option<[i32; 3]> {
        let mut above = t.level.block([x, y, z]);
        let mut y = y;
        for _ in 0..13 {
            y -= 1;
            let state = t.level.block([x, y, z])?;
            if self.stands_on(t, state, above) {
                return Some([x, y + 1, z]);
            }
            above = Some(state);
        }
        None
    }

    // `SpawnUtil.Strategy.LEGACY_IRON_GOLEM`.
    fn stands_on(&self, t: &Turn, state: u16, above: Option<u16>) -> bool {
        let blocks = &t.level.facts.blocks;
        let Some(block) = blocks.block_id(state) else {
            return false;
        };
        let g = &self.golem;
        if g.refuse.contains(&block)
            || g.stained.contains(&block)
            || g.leaves.contains(&(block as i32))
        {
            return false;
        }
        let above_ok = above.is_some_and(|a| {
            t.level.state_flag(a, crate::mobs::level::AIR)
                || t.level.state_flag(a, crate::mobs::level::LIQUID)
        });
        above_ok
            && (t.level.state_flag(state, crate::mobs::level::SOLID)
                || Some(block) == g.powder_snow)
    }

    // `checkSpawnRules` and `checkSpawnObstruction`: a floor it stands on,
    // two empty spawn cells above, and no living thing in its way.
    fn fits_golem(&self, t: &Turn, [x, y, z]: [i32; 3]) -> bool {
        let below = t.level.block([x, y - 1, z]);
        below.is_some_and(|b| t.level.state_flag(b, crate::mobs::level::COLLISION_UP))
            && self.empty_spawn(t, [x, y + 1, z], true)
            && self.empty_spawn(t, [x, y + 2, z], true)
            && self.empty_spawn(t, [x, y, z], false)
            && unobstructed(t, [x, y, z])
    }

    // `NaturalSpawner.isValidEmptySpawnBlock` for an iron golem.
    fn empty_spawn(&self, t: &Turn, pos: [i32; 3], fluid: bool) -> bool {
        let Some(state) = t.level.block(pos) else {
            return false;
        };
        let blocks = &t.level.facts.blocks;
        let block = blocks.block_id(state);
        let g = &self.golem;
        let burning = block.is_some_and(|b| {
            (g.campfires.contains(&b) && blocks.property(state, "lit") == Some("true"))
                || Some(b) == g.lava_cauldron
        });
        !t.level
            .state_flag(state, crate::mobs::level::FULL_COLLISION)
            && !t.level.state_flag(state, crate::mobs::level::SIGNAL_SOURCE)
            && (!fluid || t.level.fluid_of(state) == FluidKind::Empty)
            && !block.is_some_and(|b| g.no_spawn.contains(&(b as i32)))
            && !block.is_some_and(|b| g.dangerous.contains(&b))
            && !burning
    }

    // ## Sleeping

    /// `LivingEntity.startSleeping(bed)`: it lies on the bed, the bed's
    /// `occupied` set (`Effect::Bed`, the owner's), and its sleeping place.
    fn start_sleeping(&self, t: &mut Turn, bed: [i32; 3]) -> bool {
        let Some(state) = t.level.block(bed) else {
            return false;
        };
        if !bed_block(t, state) {
            return false;
        }
        let [x, y, z] = bed;
        t.mob.position = [
            x as f64 + 0.5,
            y as f64 + BED_HEIGHT + 0.125,
            z as f64 + 0.5,
        ];
        t.mob.body.velocity = [0.0; 3];
        t.effect(Effect::Bed {
            cell: bed,
            occupied: true,
        });
        t.mob
            .body
            .data
            .set("sleeping", Value::ivec3(bed.map(|v| v as i64)));
        true
    }

    /// `Villager.stopSleeping`: off the bed (its `occupied` cleared,
    /// standing up where the bed lets it, facing the bed), and when it woke.
    fn stop_sleeping(&self, t: &mut Turn) {
        let Some(bed) = sleeping(t.data()) else {
            return;
        };
        if let Some(state) = t.level.block(bed).filter(|&s| bed_block(t, s)) {
            let facing = match t.level.facts.blocks.property(state, "facing") {
                Some("north") => 0,
                Some("south") => 1,
                Some("west") => 2,
                _ => 3,
            };
            let [bx, by, bz] = bed;
            let stand = t
                .level
                .environment
                .stand_up(t.type_id, bed, facing, t.yaw())
                .unwrap_or([bx as f64 + 0.5, (by + 1) as f64 + 0.1, bz as f64 + 0.5]);
            let (lx, lz) = (bx as f64 + 0.5 - stand[0], bz as f64 + 0.5 - stand[2]);
            // `(float)Mth.wrapDegrees(Mth.atan2(z, x) * RAD_TO_DEG - 90)`.
            let angle = fmath::atan2(lz, lx) * 57.2957763671875 - 90.0;
            t.mob.body.yaw = f(wrap(angle));
            t.mob.body.pitch = 0.0;
            t.mob.position = stand;
            t.effect(Effect::Bed {
                cell: bed,
                occupied: false,
            });
        }
        t.mob.body.data.set("sleeping", NIL);
        let now = t.level.time;
        t.remember(Mem::LastWoken, MemValue::Int(now));
    }
}

fn bed_block(t: &Turn, state: u16) -> bool {
    let blocks = &t.level.facts.blocks;
    blocks
        .block_id(state)
        .and_then(|b| blocks.block(b))
        .is_some_and(|b| b.class == "BedBlock")
}

fn wrap(degrees: f64) -> f64 {
    let d = degrees % 360.0;
    if d >= 180.0 {
        d - 360.0
    } else if d < -180.0 {
        d + 360.0
    } else {
        d
    }
}

fn own_wants_golem(t: &Turn, now: i64) -> bool {
    !t.has(Mem::GolemDetectedRecently)
        && t.mem_int(Mem::LastSlept)
            .is_some_and(|at| now - at < 24_000)
}

/// `Villager.wantsToSpawnGolem` of a sensed villager: it slept within a day
/// and has seen no golem lately.
fn wants_golem(t: &Turn, r: &Ref, now: i64) -> bool {
    let Some(Entity::Mob(m)) = t.sensing.entity(r) else {
        return false;
    };
    let memories = m.extra.memories.as_ref();
    if brain::sensed_memory(memories, Mem::GolemDetectedRecently).is_some() {
        return false;
    }
    brain::sensed_memory(memories, Mem::LastSlept)
        .and_then(Value::as_int)
        .is_some_and(|at| now - at < 24_000)
}

// `EntityType.create` and `Mob.finalizeSpawn` of a golem at a spot, drawn
// from the level's random as vanilla draws them (even for one it then
// discards): its yaw, follow range bonus and handedness.
fn made(t: &mut Turn, [x, y, z]: [i32; 3]) -> Value {
    let yaw = t.level_float();
    let a = crate::mobs::ai::spawn::level_double(t);
    let b = crate::mobs::ai::spawn::level_double(t);
    let left = t.level_float();
    Value::Map(Map::from_atoms([
        ("summoned", Value::bool(true)),
        (
            "position",
            Value::vec3([x as f64 + 0.5, y as f64, z as f64 + 0.5]),
        ),
        ("yaw", Value::Float(f(wrap(f(yaw * 360.0))))),
        ("follow_bonus", Value::Float(0.11485000000000001 * (a - b))),
        ("left_handed", Value::bool(left < f(0.05))),
    ]))
}

// `level.isUnobstructed(golem)`: no living mob's box (as the tick began)
// or player's meets the golem's.
fn unobstructed(t: &Turn, [x, y, z]: [i32; 3]) -> bool {
    let (cx, cz) = (x as f64 + 0.5, z as f64 + 0.5);
    let golem = Aabb::new(
        [cx - 0.7, y as f64, cz - 0.7],
        [cx + 0.7, y as f64 + 2.7, cz + 0.7],
    );
    let mobs = t.sensing.mobs().iter().any(|m| {
        let s = crate::mobs::ai::Start::of(m);
        s.alive && sensing::intersects(&s.bbox, &golem)
    });
    let players = t.sensing.players.iter().any(|p| {
        p.alive && sensing::intersects(&Entity::<Extra>::Player(p).bounding_box(), &golem)
    });
    !mobs && !players
}

impl Villager {
    /// `Villager.brain/4`: its brain with `gates` (by key) and the activity
    /// `order` (empty: its activities' order), its sensors' countdowns drawn
    /// from `random`.
    pub fn build(
        &self,
        data: &FamilyData,
        random: &mut LegacyRandom,
        gates: &[(String, LegacyRandom)],
        order: &[(i32, Vec<Activity>)],
    ) -> Brain {
        let baby = baby(data);
        let g = |key: &str| -> LegacyRandom {
            gates
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, r)| *r)
                .unwrap_or_else(|| LegacyRandom::new(0))
        };
        let profession = profession(data);
        let farmer = profession == "minecraft:farmer";
        let mut activities = Vec::new();
        if baby {
            activities.push(Package::each(
                Activity::Play,
                self.play(&g),
                Conds::NONE,
                &[],
            ));
        } else {
            activities.push(Package::each(
                Activity::Work,
                self.work(farmer, &g),
                Conds::new(&[(Mem::JobSite, Cond::Present)]),
                &[],
            ));
        }
        activities.push(Package::each(Activity::Core, self.core(), Conds::NONE, &[]));
        activities.push(Package::each(
            Activity::Meet,
            self.meet(&g),
            Conds::new(&[(Mem::MeetingPoint, Cond::Present)]),
            &[],
        ));
        activities.push(Package::each(
            Activity::Rest,
            self.rest(&g),
            Conds::NONE,
            &[],
        ));
        activities.push(Package::each(
            Activity::Idle,
            self.idle(&g),
            Conds::NONE,
            &[],
        ));
        activities.push(Package::each(
            Activity::Panic,
            self.panic(&g),
            Conds::NONE,
            &[],
        ));
        Brain::ordered(
            &[
                (Sensor::NearestLiving, 20),
                (Sensor::Players, 20),
                (Sensor::Items, 20),
                (Sensor::Family(NEAREST_BED), 20),
                (Sensor::HurtBy, 20),
                (Sensor::Family(HOSTILES), 20),
                (Sensor::Family(BABIES), 20),
                (Sensor::Family(SECONDARY_POIS), 40),
                (Sensor::Family(GOLEMS), 200),
            ],
            activities,
            random,
            Some(SAVED),
            SHARED,
            order,
        )
    }

    /// A villager's activity at day time `day` by its schedule
    /// (`registerBrainGoals`' and the brain update's), started at game time
    /// `time`: what an oracle's seeded brain starts with.
    pub fn start(facts: &MobFacts, brain: &mut Brain, data: &FamilyData, day: i64, time: i64) {
        let scheduled = facts.village.scheduled(day, baby(data));
        if let Some(a) = Activity::of(scheduled) {
            brain.schedule(time, a);
        }
    }
}

impl BrainFamily for Villager {
    fn as_any(&self) -> &dyn Any {
        self
    }

    fn brain(
        &self,
        facts: &MobFacts,
        uuid: &Uuid,
        data: &FamilyData,
        random: &mut LegacyRandom,
    ) -> Brain {
        let _ = facts;
        let gates: Vec<(String, LegacyRandom)> = Villager::gates(uuid, baby(data))
            .into_iter()
            .map(|(k, r)| (k.to_owned(), r))
            .collect();
        self.build(data, random, &gates, &[])
    }

    /// `registerBrainGoals` when a villager is made: the schedule picks its
    /// activity.
    fn started(&self, t: &mut Turn) {
        schedule(t);
    }

    /// `Villager.customServerAiStep` after the brain: one in a hundred ticks
    /// it looks for a raid (none yet), drawn from its random.
    fn update_activity(&self, t: &mut Turn) {
        t.int(100);
    }

    /// `Villager.getAmbientSound`: none asleep.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if sleeping(t.data()).is_some() {
            None
        } else {
            t.level.facts.sounds.id("minecraft:entity.villager.ambient")
        }
    }

    /// After the move: `AgeableMob.aiStep`'s ageing (a baby growing up makes
    /// its brain again) and `Villager.tick`'s unhappy counter.
    fn pick_up(&self, t: &mut Turn) {
        let data = &mut t.mob.body.data;
        let age = int(data, "age");
        let (age, grown) = if age < 0 {
            (age + 1, age + 1 == 0)
        } else if age > 0 {
            (age - 1, false)
        } else {
            (0, false)
        };
        let unhappy = (int(data, "unhappy") - 1).max(0);
        data.set("age", Value::Int(age));
        data.set("unhappy", Value::Int(unhappy));
        if grown {
            self.refresh(t);
        }
    }

    fn scan(&self, t: &mut Turn, tag: u32) {
        match tag {
            NEAREST_BED => nearest_bed(t),
            HOSTILES => self.hostiles(t),
            BABIES => self.babies(t),
            SECONDARY_POIS => secondary_pois(t),
            GOLEMS => self.golems(t),
            _ => {}
        }
    }

    fn test(&self, _t: &mut Turn, _tag: u32) -> bool {
        // `AgeableMob::canBreed` of a villager: food it has none of yet.
        false
    }

    fn select(&self, t: &Turn, tag: u32, e: Entity<'_, Extra>) -> bool {
        let category = match tag {
            CREATURE => "creature",
            WATER_CREATURE => "water_creature",
            AXOLOTLS => "axolotls",
            UNDERGROUND_WATER_CREATURE => "underground_water_creature",
            WATER_AMBIENT => "water_ambient",
            MONSTER => "monster",
            _ => return false,
        };
        match e {
            Entity::Mob(m) => t
                .level
                .facts
                .entities
                .get(m.type_id)
                .is_some_and(|ty| ty.category == category),
            _ => false,
        }
    }

    fn young(&self, t: &Turn) -> bool {
        baby(t.data())
    }
}

impl Villager {
    /// `VillagerHostilesSensor`: the nearest visible hostile within its
    /// distance.
    fn hostiles(&self, t: &mut Turn) {
        let table = &self.hostiles;
        let hostile = crate::mobs::ai::brain::sensors::visible_closest(t, |t, e| match e {
            Entity::Mob(m) => table
                .iter()
                .find(|(ty, _)| *ty == m.type_id)
                .is_some_and(|&(_, d)| t.distance_sq(m.position) <= d * d),
            _ => false,
        });
        t.remember_opt(
            Mem::NearestHostile,
            hostile.map(|h| MemValue::Ref(h.reference)),
        );
    }

    /// `VillagerBabiesSensor`.
    fn babies(&self, t: &mut Turn) {
        let seen = crate::mobs::ai::brain::sensors::visible_all(t);
        let babies: Vec<Ref> = seen
            .into_iter()
            .filter(|r| match t.sensing.entity(r) {
                Some(Entity::Mob(m)) => {
                    m.type_id == self.villager
                        && m.extra.data.as_ref().is_some_and(|d| int(d, "age") < 0)
                }
                _ => false,
            })
            .collect();
        t.remember(Mem::VisibleVillagerBabies, MemValue::Refs(babies));
    }

    /// `GolemSensor`: an iron golem among the living near it.
    fn golems(&self, t: &mut Turn) {
        let golem = t.mem_refs(Mem::NearestLivingEntities).iter().any(|r| {
            t.entity(Some(r))
                .is_some_and(|e| e.type_id == Some(self.iron_golem))
        });
        if golem {
            t.remember_for(Mem::GolemDetectedRecently, MemValue::True, 599);
        }
    }
}

/// `NearestBedSensor`: a baby looks for a bed it can reach (five a try).
fn nearest_bed(t: &mut Turn) {
    if !baby(t.data()) {
        return;
    }
    let n = t.level_int(20) as i64;
    let last = t.level.time + n;
    let mut cache = match t.memory(Mem::BedCache) {
        Some(MemValue::Cache(c)) => c.clone(),
        _ => Vec::new(),
    };
    let found = pois::in_range(t.level, &["minecraft:home"], t.block(), 48, Occupancy::Any);
    let (taken, tried) = poi::cached_search(&mut cache, found, last);
    let path = if taken.is_empty() {
        None
    } else {
        navigation::path_to_any(t, taken, 1)
    };
    match path {
        Some(p) if p.reached && pois::type_at(t.level, p.target).is_some() => {
            t.remember(Mem::NearestBed, MemValue::Pos(p.target));
            t.remember(Mem::BedCache, MemValue::Cache(cache));
        }
        _ if tried < 5 => {
            cache.retain(|(_, until)| *until >= last);
            t.remember(Mem::BedCache, MemValue::Cache(cache));
        }
        _ => t.remember(Mem::BedCache, MemValue::Cache(cache)),
    }
}

/// `SecondaryPoiSensor`: its profession's secondary blocks (a farmer's
/// farmland) 4 around and 2 up and down; none found erases the memory.
fn secondary_pois(t: &mut Turn) {
    let registry = &t.level.facts.blocks;
    let blocks: Vec<u16> = t
        .level
        .facts
        .village
        .profession(&profession(t.data()))
        .map(|p| p.secondary.iter().filter_map(|b| registry.id(b)).collect())
        .unwrap_or_default();
    let [cx, cy, cz] = t.block();
    let mut sites = Vec::new();
    if !blocks.is_empty() {
        for x in -4..=4 {
            for y in -2..=2 {
                for z in -4..=4 {
                    let pos = [cx + x, cy + y, cz + z];
                    let block = t
                        .level
                        .block(pos)
                        .and_then(|state| t.level.facts.blocks.block_id(state));
                    if block.is_some_and(|b| blocks.contains(&b)) {
                        sites.push(poi::global(t, pos));
                    }
                }
            }
        }
    }
    if sites.is_empty() {
        t.forget(Mem::SecondaryJobSite);
    } else {
        t.remember(Mem::SecondaryJobSite, MemValue::Globals(sites));
    }
}

// ## Its behaviours

/// `UpdateActivityFromSchedule`.
#[derive(Clone, Debug, PartialEq)]
struct UpdateSchedule;

impl Trigger for UpdateSchedule {
    fn conditions(&self) -> Conds {
        Conds::NONE
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        schedule(t);
        true
    }
}

/// `SetRaidStatus`: one in 20 ticks it looks for a raid (there are none).
#[derive(Clone, Debug, PartialEq)]
struct SetRaidStatus;

impl Trigger for SetRaidStatus {
    fn conditions(&self) -> Conds {
        Conds::NONE
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        t.level_int(20) == 0
    }
}

/// A bell heard (raids are not yet): never starts.
#[derive(Clone, Debug, PartialEq)]
struct HeardBell;

impl Trigger for HeardBell {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::HeardBellTime, Cond::Present)])
    }

    fn trigger(&mut self, _t: &mut Turn) -> bool {
        false
    }
}

/// `VillagerPanicTrigger`.
#[derive(Clone, Debug, PartialEq)]
struct PanicTrigger;

fn scared(t: &Turn) -> bool {
    t.has(Mem::HurtBy) || t.has(Mem::NearestHostile)
}

impl Timer for PanicTrigger {
    fn start(&mut self, t: &mut Turn) {
        if !scared(t) {
            return;
        }
        if !t.active(Activity::Panic) {
            for m in [
                Mem::Path,
                Mem::WalkTarget,
                Mem::LookTarget,
                Mem::BreedTarget,
                Mem::InteractionTarget,
            ] {
                t.forget(m);
            }
        }
        t.set_active_if_possible(Activity::Panic);
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        scared(t)
    }

    // Every 100 ticks a panicking villager asks for a golem (three must
    // agree).
    fn tick(&mut self, t: &mut Turn) {
        if t.level.time.rem_euclid(100) == 0 {
            if let Some(v) = villager(t) {
                v.spawn_golem_if_needed(t, 3);
            }
        }
    }
}

/// `VillagerCalmDown`.
#[derive(Clone, Debug, PartialEq)]
struct CalmDown;

impl Trigger for CalmDown {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::HurtBy, Cond::Registered),
            (Mem::HurtByEntity, Cond::Registered),
            (Mem::NearestHostile, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let attacker = t.remembered(Mem::HurtByEntity);
        let near = attacker.is_some_and(|a| bs::distance_sq(t, &a) <= 36.0);
        if !(scared(t) || near) {
            t.forget(Mem::HurtBy);
            t.forget(Mem::HurtByEntity);
            schedule(t);
        }
        true
    }
}

/// `WakeUp`.
#[derive(Clone, Debug, PartialEq)]
struct WakeUp;

impl Trigger for WakeUp {
    fn conditions(&self) -> Conds {
        Conds::NONE
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if !t.active(Activity::Rest) && sleeping(t.data()).is_some() {
            if let Some(v) = villager(t) {
                v.stop_sleeping(t);
            }
            true
        } else {
            false
        }
    }
}

/// `PoiCompetitorScan`: of the villagers that hold its job site with a
/// profession for it, the one with less experience loses it (ties lose to
/// the later one).
#[derive(Clone, Debug, PartialEq)]
struct CompetitorScan;

impl Trigger for CompetitorScan {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::JobSite, Cond::Present),
            (Mem::NearestLivingEntities, Cond::Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some(job) = t.mem_global(Mem::JobSite) else {
            return true;
        };
        let Some(ty) = pois::type_at(t.level, job.pos).map(str::to_owned) else {
            return true;
        };
        let Some(v) = villager(t) else { return true };
        let job_value = global_value(&job);
        let rivals: Vec<Other> = t
            .mem_refs(Mem::NearestLivingEntities)
            .iter()
            .filter_map(|r| other(t, r, v.villager))
            .filter(|o| o.uuid != t.uuid)
            .filter(|o| brain::sensed_memory(o.memories.as_ref(), Mem::JobSite) == Some(&job_value))
            .filter(|o| holds(t, &o.profession, &ty))
            .collect();
        // `reduce(body, selectWinner)`: the loser of each pair forgets it.
        let mut winner: Option<(Uuid, i64)> = None;
        for rival in rivals {
            let winner_xp = winner.map_or_else(|| int(t.data(), "xp"), |(_, xp)| xp);
            if winner_xp > rival.xp {
                remote(t, rival.uuid, Remember::erase(Mem::JobSite));
            } else {
                match winner {
                    None => t.forget(Mem::JobSite),
                    Some((uuid, _)) => remote(t, uuid, Remember::erase(Mem::JobSite)),
                }
                winner = Some((rival.uuid, rival.xp));
            }
        }
        true
    }
}

/// `GoToPotentialJobSite(speed)`: 1200 ticks.
#[derive(Clone, Debug, PartialEq)]
struct GoToJobSite {
    speed: f64,
}

impl Timer for GoToJobSite {
    fn extra(&mut self, t: &mut Turn) -> bool {
        matches!(
            t.activity(),
            Some(Activity::Idle) | Some(Activity::Work) | Some(Activity::Play) | None
        )
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        t.has(Mem::PotentialJobSite)
    }

    fn tick(&mut self, t: &mut Turn) {
        if let Some(g) = t.mem_global(Mem::PotentialJobSite) {
            bs::walk_and_look(t, g.pos, self.speed, 1);
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        poi::release(t, Mem::PotentialJobSite);
    }
}

/// `YieldJobSite`: an unemployed adult gives its potential job site to a
/// villager near whose trade holds it and who has none, or walks there.
#[derive(Clone, Debug, PartialEq)]
struct YieldJobSite {
    speed: f64,
}

impl Trigger for YieldJobSite {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::PotentialJobSite, Cond::Present),
            (Mem::JobSite, Cond::Absent),
            (Mem::NearestLivingEntities, Cond::Present),
            (Mem::WalkTarget, Cond::Registered),
            (Mem::LookTarget, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if baby(t.data()) || profession(t.data()) != NONE {
            return false;
        }
        let Some(g) = t.mem_global(Mem::PotentialJobSite) else {
            return false;
        };
        let pos = g.pos;
        let Some(ty) = pois::type_at(t.level, pos).map(str::to_owned) else {
            return true;
        };
        let Some(v) = villager(t) else { return true };
        let candidate = t
            .mem_refs(Mem::NearestLivingEntities)
            .iter()
            .filter_map(|r| other(t, r, v.villager))
            .find(|o| o.uuid != t.uuid && wants_job(t, o, &ty, pos));
        let Some(o) = candidate else {
            return true;
        };
        t.forget(Mem::WalkTarget);
        t.forget(Mem::LookTarget);
        poi::release(t, Mem::PotentialJobSite);
        pois::take(t.level, pos);
        let global = poi::global(t, pos);
        if brain::sensed_memory(o.memories.as_ref(), Mem::JobSite).is_none() {
            let tracker = Tracker::block(pos);
            remote(
                t,
                o.uuid,
                Remember(vec![
                    (Mem::LookTarget, Some((MemValue::Tracker(tracker), None))),
                    (
                        Mem::WalkTarget,
                        Some((bs::walk(tracker, f(self.speed), 1), None)),
                    ),
                    (
                        Mem::PotentialJobSite,
                        Some((MemValue::Global(global), None)),
                    ),
                ]),
            );
        }
        true
    }
}

// `nearbyWantsJobsite`: one without a job site wants it when it stands
// within its search's range.
fn wants_job(t: &Turn, o: &Other, ty: &str, pos: [i32; 3]) -> bool {
    let memories = o.memories.as_ref();
    if brain::sensed_memory(memories, Mem::PotentialJobSite).is_some() {
        return false;
    }
    if !holds(t, &o.profession, ty) {
        return false;
    }
    match brain::sensed_memory(memories, Mem::JobSite) {
        Some(job) => job
            .as_tuple_n::<2>()
            .and_then(|[_, p]| p.as_ivec3())
            .is_some_and(|p| p.map(|v| v as i32) == pos),
        None => pois::dist_sq(pos, fmath::block(o.position)) <= 48 * 48,
    }
}

/// `AssignProfessionFromJobSite`: within 2 blocks of the potential job site
/// it becomes its job site (entity event 14); an unemployed villager takes
/// the first profession holding it, and its brain is made again.
#[derive(Clone, Debug, PartialEq)]
struct AssignProfession;

impl Trigger for AssignProfession {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::PotentialJobSite, Cond::Present),
            (Mem::JobSite, Cond::Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some(global) = t.mem_global(Mem::PotentialJobSite) else {
            return false;
        };
        let pos = global.pos;
        if !bs::near_center(pos, t.pos(), 2.0) {
            return false;
        }
        t.forget(Mem::PotentialJobSite);
        t.remember(Mem::JobSite, MemValue::Global(global));
        t.effect(Effect::Event(14));
        if profession(t.data()) != NONE {
            return true;
        }
        let found = pois::type_at(t.level, pos)
            .and_then(|ty| t.level.facts.village.profession_for(ty))
            .map(|p| p.name.clone());
        if let Some(p) = found {
            t.mob
                .body
                .data
                .set("profession", Value::Binary(p.into_bytes()));
            if let Some(v) = villager(t) {
                v.refresh(t);
            }
        }
        true
    }
}

/// `ResetProfession`: without a job site, an inexperienced villager of a
/// trade (not a nitwit) loses it.
#[derive(Clone, Debug, PartialEq)]
struct ResetProfession;

impl Trigger for ResetProfession {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::JobSite, Cond::Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let data = t.data();
        let p = profession(data);
        if p != NONE && p != NITWIT && int(data, "xp") == 0 && int(data, "level") <= 1 {
            t.mob
                .body
                .data
                .set("profession", Value::Binary(NONE.as_bytes().to_vec()));
            if let Some(v) = villager(t) {
                v.refresh(t);
            }
            true
        } else {
            false
        }
    }
}

/// `TradeWithVillager`: with a villager it sees as its interaction target,
/// both look at and walk to each other; close, they gossip.
#[derive(Clone, Debug, PartialEq)]
struct TradeWithVillager;

fn trade_with_villager() -> Box<dyn Behavior> {
    b::timed(
        Conds::new(&[
            (Mem::InteractionTarget, Cond::Present),
            (Mem::NearestVisibleLivingEntities, Cond::Present),
        ]),
        60,
        60,
        TradeWithVillager,
    )
}

fn trade_target(t: &Turn) -> Option<Seen> {
    t.remembered(Mem::InteractionTarget)
}

// `BehaviorUtils.targetIsValid`: a living villager it sees.
fn trade_valid(t: &mut Turn) -> bool {
    let Some(v) = villager(t) else { return false };
    match trade_target(t) {
        Some(e) if e.type_id == Some(v.villager) && e.alive => {
            crate::mobs::ai::brain::sensors::visible_contains(t, &e.reference)
        }
        _ => false,
    }
}

/// `BehaviorUtils.lockGazeAndWalkToEachOther(body, other, 0.5, 2)`.
fn lock_gaze(t: &mut Turn, other: Ref) {
    let speed = f(0.5);
    let me = mob_ref(t.uuid);
    bs::look_at_entity(t, other);
    bs::walk_to_entity(t, other, speed, 2);
    remote(
        t,
        other.uuid,
        Remember(vec![
            (
                Mem::LookTarget,
                Some((MemValue::Tracker(Tracker::entity(me, true)), None)),
            ),
            (
                Mem::WalkTarget,
                Some((bs::walk(Tracker::entity(me, false), speed, 2), None)),
            ),
        ]),
    );
}

impl Timer for TradeWithVillager {
    fn extra(&mut self, t: &mut Turn) -> bool {
        trade_valid(t)
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some(o) = trade_target(t) {
            lock_gaze(t, o.reference);
        }
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        trade_valid(t)
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(o) = trade_target(t) else { return };
        if bs::distance_sq(t, &o) > 5.0 {
            return;
        }
        lock_gaze(t, o.reference);
        gossip(t, &o);
    }

    fn stop(&mut self, t: &mut Turn) {
        t.forget(Mem::InteractionTarget);
    }
}

/// `Villager.gossip(level, other, now)`: once in 1200 ticks for both, they
/// share gossip (reputations wait) and it asks for a golem (five must
/// agree).
fn gossip(t: &mut Turn, o: &Seen) {
    let now = t.level.time;
    let mine = t.mem_int(Mem::LastGossip).unwrap_or(0);
    let theirs = match t.sensing.entity(&o.reference) {
        Some(Entity::Mob(m)) => brain::sensed_memory(m.extra.memories.as_ref(), Mem::LastGossip)
            .and_then(Value::as_int)
            .unwrap_or(0),
        _ => 0,
    };
    if (now < mine || now >= mine + 1200) && (now < theirs || now >= theirs + 1200) {
        t.remember(Mem::LastGossip, MemValue::Int(now));
        remote(
            t,
            o.uuid(),
            Remember::set(Mem::LastGossip, MemValue::Int(now)),
        );
        if let Some(v) = villager(t) {
            v.spawn_golem_if_needed(t, 5);
        }
    }
}

/// `WorkAtPoi`.
#[derive(Clone, Debug, PartialEq)]
struct WorkAtPoi {
    last_check: i64,
}

fn near_job_site(t: &Turn) -> bool {
    t.mem_global(Mem::JobSite)
        .is_some_and(|g| g.dimension == t.level.dimension && bs::near_center(g.pos, t.pos(), 1.73))
}

impl Timer for WorkAtPoi {
    fn extra(&mut self, t: &mut Turn) -> bool {
        let now = t.level.time;
        if now - self.last_check < 300 {
            return false;
        }
        if t.level_int(2) != 0 {
            return false;
        }
        self.last_check = now;
        near_job_site(t)
    }

    fn start(&mut self, t: &mut Turn) {
        let Some(g) = t.mem_global(Mem::JobSite) else {
            return;
        };
        let now = t.level.time;
        t.remember(Mem::LastWorkedAtPoi, MemValue::Int(now));
        t.remember(Mem::LookTarget, MemValue::Tracker(Tracker::block(g.pos)));
        // `playWorkSound` (a nitwit's or an unemployed one's is none).
        let sound = t
            .level
            .facts
            .village
            .profession(&profession(t.data()))
            .and_then(|p| p.work_sound.clone())
            .and_then(|s| t.level.facts.sounds.id(&s));
        if let Some(id) = sound {
            think::make_sound(t, id);
        }
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        t.has(Mem::JobSite) && near_job_site(t)
    }
}

/// `SocializeAtBell`: near the bell, now and then, a villager it sees.
#[derive(Clone, Debug, PartialEq)]
struct SocializeAtBell;

impl Trigger for SocializeAtBell {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::WalkTarget, Cond::Registered),
            (Mem::LookTarget, Cond::Registered),
            (Mem::MeetingPoint, Cond::Present),
            (Mem::NearestVisibleLivingEntities, Cond::Present),
            (Mem::InteractionTarget, Cond::Absent),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let n = t.level_int(100);
        let Some(g) = t.mem_global(Mem::MeetingPoint) else {
            return false;
        };
        if n != 0 || g.dimension != t.level.dimension || !bs::near_center(g.pos, t.pos(), 4.0) {
            return false;
        }
        let Some(v) = villager(t) else { return false };
        let ty = v.villager;
        let any =
            crate::mobs::ai::brain::sensors::visible_closest(t, |_, e| e.type_id() == Some(ty));
        if any.is_none() {
            return false;
        }
        let near = crate::mobs::ai::brain::sensors::visible_closest(t, |t, e| {
            e.type_id() == Some(ty) && t.distance_sq(e.position()) <= 32.0
        });
        if let Some(m) = near {
            let r = m.reference;
            t.remember(Mem::InteractionTarget, MemValue::Ref(r));
            bs::look_at_entity(t, r);
            bs::walk_to_entity(t, r, f(0.3), 1);
        }
        true
    }
}

/// `InsideBrownianWalk`: under a roof, a random neighbouring block it can
/// stand on under it too.
#[derive(Clone, Debug, PartialEq)]
struct BrownianWalk {
    speed: f64,
    /// `Collections.shuffle`'s own random.
    random: LegacyRandom,
}

impl Trigger for BrownianWalk {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Cond::Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let [x, y, z] = t.block();
        if t.level.sky([x, y, z]) {
            return false;
        }
        let mut cells = Vec::with_capacity(27);
        for dz in -1..=1 {
            for dy in -1..=1 {
                for dx in -1..=1 {
                    cells.push([x + dx, y + dy, z + dz]);
                }
            }
        }
        for i in (1..cells.len()).rev() {
            let j = self.random.int(i as i32 + 1) as usize;
            cells.swap(i, j);
        }
        let target = cells.into_iter().find(|&c| {
            !t.level.sky(c)
                && t.level
                    .block(c)
                    .is_some_and(|s| t.level.state_flag(s, crate::mobs::level::STURDY_UP))
        });
        if let Some(c) = target {
            if t.level.fits(&t.bbox()) {
                t.remember(
                    Mem::WalkTarget,
                    bs::walk(Tracker::block(c), f(self.speed), 0),
                );
            }
        }
        true
    }
}

/// `SleepInBed`.
#[derive(Clone, Debug, PartialEq)]
struct Sleep {
    next: i64,
}

impl Timer for Sleep {
    fn extra(&mut self, t: &mut Turn) -> bool {
        let Some(home) = t.mem_global(Mem::Home) else {
            return false;
        };
        let now = t.level.time;
        let woken = t.mem_int(Mem::LastWoken).is_some_and(|at| {
            let d = now - at;
            d > 0 && d < 100
        });
        let bed = t.level.block(home.pos);
        home.dimension == t.level.dimension
            && !woken
            && bs::near_center(home.pos, t.pos(), 2.0)
            && bed.is_some_and(|s| poi::sleeps_on(t, s) && !poi::occupied(t, s))
    }

    fn start(&mut self, t: &mut Turn) {
        if t.level.time <= self.next {
            return;
        }
        let Some(home) = t.mem_global(Mem::Home) else {
            return;
        };
        if let Some(MemValue::Globals(doors)) = t.memory(Mem::DoorsToClose) {
            let doors = doors.clone();
            bs::close_doors(t, None, None, doors);
        }
        let slept = villager(t).is_some_and(|v| v.start_sleeping(t, home.pos));
        if slept {
            let now = t.level.time;
            t.remember(Mem::LastSlept, MemValue::Int(now));
        }
        t.forget(Mem::WalkTarget);
        t.forget(Mem::CantReachWalkTargetSince);
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        match t.mem_global(Mem::Home) {
            Some(home) => {
                t.active(Activity::Rest)
                    && t.y() > home.pos[1] as f64 + 0.4
                    && bs::near_center(home.pos, t.pos(), 1.14)
            }
            None => false,
        }
    }

    fn stop(&mut self, t: &mut Turn) {
        if sleeping(t.data()).is_some() {
            self.next = t.level.time + 40;
            if let Some(v) = villager(t) {
                v.stop_sleeping(t);
            }
        }
    }
}

/// `JumpOnBed`.
#[derive(Clone, Debug, PartialEq)]
struct JumpOnBed {
    speed: f64,
    bed: Option<[i32; 3]>,
    reach: i32,
    jumps: i32,
    cooldown: i32,
}

fn jump_on_bed(speed: f64) -> Box<dyn Behavior> {
    b::forever(
        Conds::new(&[
            (Mem::NearestBed, Cond::Present),
            (Mem::WalkTarget, Cond::Absent),
        ]),
        JumpOnBed {
            speed: f(speed),
            bed: None,
            reach: 0,
            jumps: 0,
            cooldown: 0,
        },
    )
}

fn jumpable(t: &Turn, pos: [i32; 3]) -> bool {
    let facts = t.level.facts;
    t.level.block(pos).is_some_and(|s| {
        facts.blocks.block_id(s).is_some_and(|b| {
            facts.tags.has(
                "minecraft:block",
                "minecraft:villager_babies_can_jump_on_bed",
                b as i32,
            )
        })
    })
}

fn over_bed(t: &Turn) -> bool {
    let [x, y, z] = t.block();
    jumpable(t, [x, y, z]) || jumpable(t, [x, y - 1, z])
}

impl Timer for JumpOnBed {
    fn extra(&mut self, t: &mut Turn) -> bool {
        baby(t.data()) && (over_bed(t) || t.has(Mem::NearestBed))
    }

    fn start(&mut self, t: &mut Turn) {
        let Some(bed) = t.mem_pos(Mem::NearestBed) else {
            return;
        };
        let n = t.level_int(4);
        t.remember(
            Mem::WalkTarget,
            bs::walk(Tracker::block(bed), self.speed, 0),
        );
        self.bed = Some(bed);
        self.reach = 100;
        self.jumps = 3 + n;
        self.cooldown = 0;
    }

    fn still(&mut self, t: &mut Turn) -> bool {
        let over = over_bed(t);
        baby(t.data())
            && self.bed.is_some_and(|b| jumpable(t, b))
            && !(!over && self.reach <= 0)
            && !(over && self.jumps <= 0)
    }

    fn tick(&mut self, t: &mut Turn) {
        if !over_bed(t) {
            self.reach -= 1;
        } else if self.cooldown > 0 {
            self.cooldown -= 1;
        } else if jumpable(t, t.block()) {
            self.jumps -= 1;
            self.cooldown = 5;
            t.jump();
        }
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.bed = None;
        self.reach = 0;
        self.jumps = 0;
        self.cooldown = 0;
    }
}

// ## The mob

impl Hooks for Villager {
    fn brain(&self) -> Option<&dyn BrainFamily> {
        Some(self)
    }
}

impl Family for Villager {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Villager::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let d = &body.data;
        let type_id = |name: &str| self.type_ids.get(name).copied().unwrap_or(0) as i64;
        let profession_id = |name: &str| {
            self.profession_ids
                .iter()
                .find(|(n, _)| n == name)
                .map_or(0, |&(_, id)| id) as i64
        };
        vec![
            value("ageable_baby", Value::bool(baby(d)), Value::bool(false)),
            value(
                "villager_unhappy",
                Value::Int(int(d, "unhappy")),
                Value::Int(0),
            ),
            value(
                "villager_data",
                Value::tuple([
                    Value::Int(type_id(&string(d, "villager_type"))),
                    Value::Int(profession_id(&profession(d))),
                    Value::Int(int(d, "level")),
                ]),
                Value::tuple([
                    Value::Int(type_id("minecraft:plains")),
                    Value::Int(0),
                    Value::Int(1),
                ]),
            ),
            value(
                "villager_data_finalized",
                Value::bool(d.get("finalized").and_then(Value::as_bool).unwrap_or(false)),
                Value::bool(false),
            ),
        ]
    }
}

impl Kind for Villager {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Villager"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    /// A brain mob registers no goals.
    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered::default()
    }

    /// Its constructor: `setCanOpenDoors`, `setCanFloat`,
    /// `setRequiredPathLength(48)`.
    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec {
            can_open_doors: true,
            can_float: true,
            required_length: Some(48),
            ..NavSpec::default()
        }
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Villager::data_of()
    }
}
