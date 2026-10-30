//! A turtle (`Valimc.Entity.Animals.Turtle`, vanilla's `Turtle`): an
//! amphibious animal with a home beach (`home`, where it first spawned or
//! hatched). It wanders the beach, takes to the water (and travels far in
//! it) and heads home now and then; on land its move control
//! (`TurtleMoveControl`) keeps it slow. Bred, the mother gets an egg instead
//! of a baby (`has_egg`), goes home and lays one to four eggs on sand there
//! (`laying_egg`); a baby that grows up drops a scute. Hurt, it runs for
//! water within seven blocks.
//!
//! It travels in water as a guardian does, sinking unless it has a target
//! or swims home from afar; its steps shamble every 0.15 blocks and its
//! swims are half again as loud. Going home, its travel's target and its
//! laying count are its mind's own (`TurtleOwn`).

use super::{age, Animal, Species};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, emax, f, lerp, rotlerp};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE};
use crate::mobs::ai::goals::move_to_block::{BlockOptions, BlockTest, MoveToBlock};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{Breed, ItemTest, LookAtPlayer, Panic, RandomStroll, Tempt};
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::navigation::{self, NavKind};
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::ai::{random_pos, spawn};
use crate::mobs::combat::{SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{KindMotion, NavSpec, Registered, Registration};
use crate::mobs::level::{FluidKind, Level};
use crate::mobs::living::mob as living_mob;
use crate::mobs::model::{Body, Control, FamilyData, Impulse, MotionSet, Travel, TravelKind};
use crate::mobs::term::{Atom, Value};

// The family's own tests and actions.
const NO_EGG: Tag = 1;
const EGG: Tag = 2;
const STROLLS: Tag = 3;
const WATER: Tag = 4;
const SAND: Tag = 5;

/// What it keeps beyond its saved data (`Mind.own`): going home, its
/// travel's target and its laying count.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TurtleOwn {
    pub going_home: bool,
    pub travel: Option<[i32; 3]>,
    pub lay: i64,
}

/// Its own state (`Turtle.own/1`).
pub fn own(t: &Turn) -> TurtleOwn {
    t.mind
        .own
        .family::<TurtleOwn>()
        .copied()
        .unwrap_or_default()
}

fn put_own(t: &mut Turn, change: impl FnOnce(&mut TurtleOwn)) {
    let mut o = own(t);
    change(&mut o);
    t.mind.own.family = Some(Box::new(o));
}

fn flag(data: &FamilyData, key: &str) -> bool {
    data.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn baby(t: &Turn) -> bool {
    age(t.data()) < 0
}

/// Its home (`home_pos`).
pub fn home(t: &Turn) -> [i32; 3] {
    t.data()
        .get("home")
        .and_then(Value::as_ivec3)
        .map_or([0; 3], |h| h.map(|v| v as i32))
}

// `BlockPos.closerToCenterThan(position, distance)`.
fn near([x, y, z]: [i32; 3], t: &Turn, d: f64) -> bool {
    let (dx, dy, dz) = (
        x as f64 + 0.5 - t.x(),
        y as f64 + 0.5 - t.y(),
        z as f64 + 0.5 - t.z(),
    );
    dx * dx + dy * dy + dz * dz < d * d
}

/// Whether its home is within `d` blocks of its centre.
pub fn near_home(t: &Turn, d: f64) -> bool {
    near(home(t), t, d)
}

pub struct Turtle {
    sand: Vec<i32>,
    water: Option<u16>,
}

impl Turtle {
    pub fn new(facts: &MobFacts) -> Result<Turtle, String> {
        Ok(Turtle {
            sand: facts
                .tags
                .get("minecraft:block", "minecraft:sand")
                .map(<[i32]>::to_vec)
                .unwrap_or_default(),
            water: facts.blocks.id("minecraft:water"),
        })
    }

    /// `TurtleEggBlock.isSand`.
    fn sand(&self, level: &Level, pos: [i32; 3]) -> bool {
        level
            .block(pos)
            .and_then(|s| level.facts.blocks.block_id(s))
            .is_some_and(|b| self.sand.contains(&(b as i32)))
    }

    /// `TurtleEggBlock.onSand`: sand below.
    fn on_sand(&self, level: &Level, [x, y, z]: [i32; 3]) -> bool {
        self.sand(level, [x, y - 1, z])
    }

    fn water_block(&self, level: &Level, pos: [i32; 3]) -> bool {
        level
            .block(pos)
            .and_then(|s| level.facts.blocks.block_id(s))
            == self.water
            && self.water.is_some()
    }

    /// `TurtleBreedGoal.breed`: an egg for her instead of a baby; both
    /// parents rest (age 6000, no love) and an orb is dropped.
    fn egg(&self, t: &mut Turn, partner: &Seen) {
        let data = &mut t.mob.body.data;
        data.set("has_egg", Value::bool(true));
        data.set_age(6000);
        data.set_in_love(0);
        t.effect(Effect::Bred(partner.reference));
        if t.level.rules.mob_drops {
            let n = t.int(7);
            let at = t.pos();
            t.effect(Effect::Orb { value: n + 1, at });
        }
    }
}

impl Species for Turtle {
    const TYPE: &'static str = "minecraft:turtle";
    const MODULE: &'static str = "Valimc.Entity.Animals.Turtle";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        Registered {
            goals: vec![
                Registration::new(0, "TurtlePanicGoal", MOVE, Panic::new(1.2, Some(7))),
                Registration::new(
                    1,
                    "TurtleBreedGoal",
                    MOVE | LOOK,
                    Breed::new(1.0, Some(NO_EGG), Some(EGG)),
                ),
                Registration::new(
                    1,
                    "TurtleLayEggGoal",
                    MOVE | JUMP,
                    LayEgg(MoveToBlock::new(
                        1.0,
                        16,
                        BlockTest::Family(SAND),
                        BlockOptions::default(),
                    )),
                ),
                Registration::new(
                    2,
                    "TemptGoal",
                    MOVE | LOOK,
                    Tempt::new(1.1, ItemTest::Food(a.type_id), false, 2.5),
                ),
                Registration::new(
                    3,
                    "TurtleGoToWaterGoal",
                    MOVE | JUMP,
                    GoToWater(MoveToBlock::new(
                        1.0,
                        24,
                        BlockTest::Family(WATER),
                        BlockOptions {
                            vertical_start: -1,
                            recalculate: 160,
                            ..BlockOptions::default()
                        },
                    )),
                ),
                Registration::new(4, "TurtleGoHomeGoal", 0, GoHome::default()),
                Registration::new(7, "TurtleTravelGoal", 0, TurtleTravel::default()),
                Registration::new(
                    8,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(8.0, 0.02, false, None),
                ),
                Registration::new(
                    9,
                    "TurtleRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            interval: 100,
                            guard: Some(STROLLS),
                            ..StrollOptions::default()
                        },
                    ),
                ),
            ],
            targets: Vec::new(),
        }
    }

    /// A turtle made without a spawn has its home at the origin.
    fn defaults(&self) -> Vec<(Atom, Value)> {
        vec![
            (Atom::from_static("has_egg"), Value::bool(false)),
            (Atom::from_static("laying_egg"), Value::bool(false)),
            (Atom::from_static("home"), Value::ivec3([0, 0, 0])),
        ]
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        vec![
            (
                Atom::from_static("turtle_has_egg"),
                Value::bool(flag(data, "has_egg")),
                Value::bool(false),
            ),
            (
                Atom::from_static("turtle_laying_egg"),
                Value::bool(flag(data, "laying_egg")),
                Value::bool(false),
            ),
        ]
    }

    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        _partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        let [x, y, z] = t.block();
        vec![(
            Atom::from_static("home"),
            Value::ivec3([x as i64, y as i64, z as i64]),
        )]
    }

    /// `finalizeSpawn`: its home where it spawned.
    fn spawn_part(&self, _a: &Animal<Self>, t: &mut Turn, _reason: &Atom) {
        let [x, y, z] = t.block();
        t.mob
            .body
            .data
            .set("home", Value::ivec3([x as i64, y as i64, z as i64]));
    }

    /// `Turtle.aiStep` after its super: laying, the sand under it crumbles
    /// every five ticks.
    fn settle(&self, _a: &Animal<Self>, t: &mut Turn) {
        let o = own(t);
        if living_mob::alive(&t.mob.body.mob)
            && flag(t.data(), "laying_egg")
            && o.lay >= 1
            && o.lay % 5 == 0
        {
            let [x, y, z] = t.block();
            if self.on_sand(t.level, [x, y, z]) {
                let below = t.level.block([x, y - 1, z]).map_or(0, i32::from);
                t.effect(Effect::LevelEvent {
                    cell: [x, y, z],
                    kind: 2001,
                    data: below,
                });
            }
        }
    }

    /// The age transition drops the growth gift, from the level's doubles.
    fn after_ai(&self, a: &Animal<Self>, t: &mut Turn) {
        let was_baby = baby(t);
        a.settle(t);
        if was_baby && !baby(t) && t.level.rules.mob_drops {
            let a = spawn::level_double(t);
            let b = spawn::level_double(t);
            t.effect(Effect::Gift {
                table: "minecraft:gameplay/turtle_grow".to_owned(),
                velocity: [a * 0.2 - 0.1, 0.2, b * 0.2 - 0.1],
            });
        }
    }

    fn navigation(&self) -> NavSpec {
        NavSpec {
            kind: NavKind::Amphibious,
            ..NavSpec::default()
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            fluid_pushed: false,
            step_gap: Some(f(0.15)),
            ..KindMotion::default()
        }
    }

    fn swim_sound(&self) -> Option<&'static str> {
        Some("minecraft:entity.turtle.swim")
    }

    fn swim_volume(&self) -> f64 {
        1.5
    }

    /// `playStepSound`: a shamble (a baby's own), quiet.
    fn step_sound(&self, _a: &Animal<Self>, t: &mut Turn) {
        let name = if baby(t) {
            "minecraft:entity.turtle.shamble_baby"
        } else {
            "minecraft:entity.turtle.shamble"
        };
        t.play(name, 0.15, 1.0);
    }

    /// `TurtlePathNavigation.isStableDestination`: water while it travels,
    /// else anything but air below.
    fn stable_destination(&self, _a: &Animal<Self>, t: &Turn, pos: [i32; 3]) -> Option<bool> {
        let [x, y, z] = pos;
        Some(if own(t).travel.is_some() {
            self.water_block(t.level, pos)
        } else {
            !t.level.air([x, y - 1, z])
        })
    }

    /// `getWalkTargetValue`: water (unless going home) and sand above all.
    fn walk_value(&self, _a: &Animal<Self>, t: &mut Turn, pos: [i32; 3]) -> Option<f64> {
        Some(
            if (!own(t).going_home && t.level.fluid(pos) == FluidKind::Water)
                || self.on_sand(t.level, pos)
            {
                10.0
            } else {
                f(t.level.light(pos) as f64 - 0.5)
            },
        )
    }

    fn test(&self, _a: &Animal<Self>, t: &mut Turn, tag: Tag) -> bool {
        match tag {
            NO_EGG => !flag(t.data(), "has_egg"),
            STROLLS => !t.in_water() && !own(t).going_home && !flag(t.data(), "has_egg"),
            _ => false,
        }
    }

    fn block(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        tag: Tag,
        cell: [i32; 3],
        _goal: &mut MoveToBlock,
    ) -> bool {
        let [x, y, z] = cell;
        match tag {
            WATER => self.water_block(t.level, cell),
            SAND => t.level.air([x, y + 1, z]) && self.sand(t.level, cell),
            _ => false,
        }
    }

    /// `canFallInLove`: not while carrying an egg.
    fn can_fall_in_love(&self, data: &FamilyData) -> bool {
        !flag(data, "has_egg")
    }

    fn breed(&self, a: &Animal<Self>, t: &mut Turn, breeding: Option<Tag>, partner: &Seen) {
        if breeding == Some(EGG) {
            self.egg(t, partner);
        } else {
            a.breed(t, partner);
        }
    }

    /// `TurtleMoveControl.tick`: in water a little lift (slower far from
    /// home, slower still as a baby), on the ground half speed; toward the
    /// wanted position while it navigates (turning, easing its speed,
    /// rising toward its target), else still. It travels as a guardian
    /// does, sinking unless it has a target or is swimming home from afar.
    fn move_control(&self, _a: &Animal<Self>, t: &mut Turn) {
        let speed = t.speed();
        let (speed, mut impulse) = if t.in_water() {
            let speed = if near_home(t, 16.0) {
                speed
            } else {
                emax(f(speed / 2.0), f(0.08))
            };
            let speed = if baby(t) {
                emax(f(speed / 3.0), f(0.06))
            } else {
                speed
            };
            (speed, vec![[0.0, 0.005, 0.0]])
        } else if t.on_ground() {
            (emax(f(speed / 2.0), f(0.06)), Vec::new())
        } else {
            (speed, Vec::new())
        };
        let speed = match t.mob.body.mob.motion.control {
            Control::MoveTo {
                target: [wx, wy, wz],
                speed: modifier,
            } if !t.mind.navigation.done() => {
                let (xd, yd, zd) = (wx - t.x(), wy - t.y(), wz - t.z());
                let dd = (xd * xd + yd * yd + zd * zd).sqrt();
                if dd < f(1.0e-5) {
                    0.0
                } else {
                    let yd = yd / dd;
                    let yaw = rotlerp(t.yaw(), fmath::yaw(xd, zd), 90.0);
                    t.mob.body.yaw = yaw;
                    t.mind.body_yaw = yaw;
                    let attribute = t.attribute("minecraft:movement_speed");
                    let speed = lerp(f(0.125), speed, f(modifier * attribute));
                    impulse.push([0.0, speed * yd * 0.1, 0.0]);
                    speed
                }
            }
            _ => 0.0,
        };
        let o = own(t);
        let sink = t.mind.target.is_none() && (!o.going_home || !near_home(t, 20.0));
        let motion = &mut t.mob.body.mob.motion;
        motion.set = Some(MotionSet::Speed { speed, lift: false });
        motion.impulse = Impulse::List(impulse);
        motion.travel = Some(Travel {
            kind: TravelKind::Guardian,
            sink,
        });
    }

    /// On land (not as a baby) it calls; in water it is silent.
    fn ambient_sound(&self, _a: &Animal<Self>, t: &mut Turn) -> Option<Option<i32>> {
        Some(if !t.in_water() && t.on_ground() && !baby(t) {
            t.level
                .facts
                .sounds
                .id("minecraft:entity.turtle.ambient_land")
        } else {
            None
        })
    }

    /// A baby's hurt and death sounds are its own.
    fn sound(&self, _a: &Animal<Self>, body: &Body, which: SoundKind) -> Option<SoundRef> {
        let baby = age(&body.data) < 0;
        let name = match (which, baby) {
            (SoundKind::Hurt, true) => "minecraft:entity.turtle.hurt_baby",
            (SoundKind::Hurt, false) => "minecraft:entity.turtle.hurt",
            (SoundKind::Death, true) => "minecraft:entity.turtle.death_baby",
            (SoundKind::Death, false) => "minecraft:entity.turtle.death",
        };
        Some(SoundRef::Name(name.to_owned()))
    }
}

// ## Goals

/// `TurtleGoToWaterGoal` (`Turtle.GoToWater`): out of water (not going home
/// nor carrying an egg, or as a baby), it walks to the nearest water block
/// within 24 around, one below its feet; it gives up after 1200 ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct GoToWater(MoveToBlock);

impl Goal for GoToWater {
    fn every_tick(&self) -> bool {
        true
    }

    fn can_use(&mut self, t: &mut Turn) -> bool {
        let o = own(t);
        if (baby(t) && !t.in_water())
            || (!o.going_home && !t.in_water() && !flag(t.data(), "has_egg"))
        {
            self.0.can_use(t)
        } else {
            false
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if !t.in_water() && self.0.tries <= 1200 {
            let cell = self.0.cell;
            self.0.valid(t, cell)
        } else {
            false
        }
    }

    fn start(&mut self, t: &mut Turn) {
        self.0.start(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.0.tick(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Turtle.GoToWater"
    }
}

/// `TurtleLayEggGoal` (`Turtle.LayEgg`): carrying an egg within nine blocks
/// of home, it walks to sand with air above within 16 blocks; there, out of
/// water, it starts laying and after 200 ticks lays one to four eggs (with
/// the laying sound), then falls in love again for 600 ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct LayEgg(MoveToBlock);

impl LayEgg {
    fn lay(t: &mut Turn, on: bool) {
        t.mob.body.data.set("laying_egg", Value::bool(on));
        put_own(t, |o| o.lay = if on { 1 } else { 0 });
    }

    // The eggs on the sand's top (one to four), the laying sound (a pitch
    // from the level's random) and love for 600 ticks.
    fn lay_eggs(t: &mut Turn, [x, y, z]: [i32; 3]) {
        let roll = spawn::level_float(t);
        let pitch = f(f(0.9) + f(roll * f(0.2)));
        let n = t.int(4);
        let seed = t.next_seed();
        if let Some(id) = t.level.facts.sounds.id("minecraft:entity.turtle.lay_egg") {
            t.effect(Effect::SoundBlock(Value::Tuple(vec![
                Value::Int(id as i64),
                Value::Binary(b"blocks".to_vec()),
                Value::Float(f(0.3)),
                Value::Float(pitch),
                Value::Int(seed),
            ])));
        }
        t.effect(Effect::LayEggs(Value::Tuple(vec![
            Value::ivec3([x as i64, y as i64 + 1, z as i64]),
            Value::Int(n as i64 + 1),
        ])));
        let data = &mut t.mob.body.data;
        data.set("has_egg", Value::bool(false));
        data.set_in_love(600);
    }
}

impl Goal for LayEgg {
    fn every_tick(&self) -> bool {
        true
    }

    fn can_use(&mut self, t: &mut Turn) -> bool {
        if flag(t.data(), "has_egg") && near_home(t, 9.0) {
            self.0.can_use(t)
        } else {
            false
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.0.can_continue(t) && flag(t.data(), "has_egg") && near_home(t, 9.0)
    }

    fn start(&mut self, t: &mut Turn) {
        self.0.start(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.0.tick(t);
        if !t.in_water() && self.0.reached {
            let lay = own(t).lay;
            if lay < 1 {
                LayEgg::lay(t, true);
            } else if lay > self.adjusted(200) {
                LayEgg::lay_eggs(t, self.0.cell);
                LayEgg::lay(t, false);
            }
            if flag(t.data(), "laying_egg") {
                put_own(t, |o| o.lay += 1);
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Turtle.LayEgg"
    }
}

const TENTH: f64 = std::f64::consts::PI / 10.0;
const QUARTER: f64 = std::f64::consts::PI / 2.0;

/// `TurtleGoHomeGoal` (`Turtle.GoHome`): carrying an egg, or now and then
/// when more than 64 blocks from home, it heads home in steps toward it; it
/// stops within seven blocks, stuck, or after trying 600 ticks close by.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GoHome {
    stuck: bool,
    close: i64,
}

impl GoHome {
    fn water(t: &Turn, [x, y, z]: [f64; 3]) -> bool {
        let pos = [fmath::floor(x), fmath::floor(y), fmath::floor(z)];
        let water = t.level.facts.blocks.id("minecraft:water");
        water.is_some()
            && t.level
                .block(pos)
                .and_then(|s| t.level.facts.blocks.block_id(s))
                == water
    }
}

impl Goal for GoHome {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if baby(t) {
            false
        } else if flag(t.data(), "has_egg") {
            true
        } else {
            let n = t.int(fmath::reduced(700) as i32);
            n == 0 && !near_home(t, 64.0)
        }
    }

    fn start(&mut self, t: &mut Turn) {
        put_own(t, |o| o.going_home = true);
        self.stuck = false;
        self.close = 0;
    }

    fn stop(&mut self, t: &mut Turn) {
        put_own(t, |o| o.going_home = false);
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        !near_home(t, 7.0) && !self.stuck && self.close <= self.adjusted(600)
    }

    fn tick(&mut self, t: &mut Turn) {
        let close = near_home(t, 16.0);
        if close {
            self.close += 1;
        }
        if !t.mind.navigation.done() {
            return;
        }
        let [hx, hy, hz] = home(t);
        let target = [hx as f64 + 0.5, hy as f64, hz as f64 + 0.5];
        let mut next = random_pos::default_towards(t, 16, 3, target, f(TENTH));
        if next.is_none() {
            next = random_pos::default_towards(t, 8, 7, target, f(QUARTER));
        }
        if let Some(p) = next {
            if !close && !GoHome::water(t, p) {
                next = random_pos::default_towards(t, 16, 5, target, f(QUARTER));
            }
        }
        match next {
            None => self.stuck = true,
            Some(p) => {
                navigation::move_to(t, p, 1.0);
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Turtle.GoHome"
    }
}

/// `TurtleTravelGoal` (`Turtle.Travel`): in water (not going home nor
/// carrying an egg) it sets out for a spot up to 512 blocks away (no higher
/// than the sea) and swims toward it in steps until stuck, in love or going
/// home.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TurtleTravel {
    stuck: bool,
}

impl TurtleTravel {
    // `hasChunksAt` 34 blocks around the next spot: every chunk there
    // readable.
    fn loaded(t: &Turn, [x, _, z]: [f64; 3]) -> bool {
        let (xc, zc) = (fmath::floor(x), fmath::floor(z));
        let y = fmath::floor(t.y());
        ((xc - 34).div_euclid(16)..=(xc + 34).div_euclid(16)).all(|cx| {
            ((zc - 34).div_euclid(16)..=(zc + 34).div_euclid(16))
                .all(|cz| t.level.chunk((cx, cz), y))
        })
    }
}

impl Goal for TurtleTravel {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        !own(t).going_home && !flag(t.data(), "has_egg") && t.in_water()
    }

    fn start(&mut self, t: &mut Turn) {
        let xt = t.int(1025) - 512;
        let yt = t.int(9) - 4;
        let zt = t.int(1025) - 512;
        let yt = if yt as f64 + t.y() > (t.level.sea_level - 1) as f64 {
            0
        } else {
            yt
        };
        let target = [
            fmath::floor(xt as f64 + t.x()),
            fmath::floor(yt as f64 + t.y()),
            fmath::floor(zt as f64 + t.z()),
        ];
        put_own(t, |o| o.travel = Some(target));
        self.stuck = false;
    }

    fn stop(&mut self, t: &mut Turn) {
        put_own(t, |o| o.travel = None);
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        let o = own(t);
        !t.mind.navigation.done()
            && !self.stuck
            && !o.going_home
            && t.data().in_love().unwrap_or(0) <= 0
            && !flag(t.data(), "has_egg")
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some([tx, ty, tz]) = own(t).travel else {
            self.stuck = true;
            return;
        };
        if !t.mind.navigation.done() {
            return;
        }
        let target = [tx as f64 + 0.5, ty as f64, tz as f64 + 0.5];
        let mut next = random_pos::default_towards(t, 16, 3, target, f(TENTH));
        if next.is_none() {
            next = random_pos::default_towards(t, 8, 7, target, f(QUARTER));
        }
        match next.filter(|&p| TurtleTravel::loaded(t, p)) {
            None => self.stuck = true,
            Some(p) => {
                navigation::move_to(t, p, 1.0);
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Turtle.Travel"
    }
}
