//! Fish (`Valimc.AI.Mobs.Fish`, `Pufferfish`, `TropicalFish`; vanilla's
//! `AbstractFish`, `AbstractSchoolingFish`, `Cod`, `Salmon`, `Pufferfish`
//! and `TropicalFish`): one family each, sharing the fish's rules.
//!
//! A fish panics when hurt, flees players within eight blocks and swims to
//! random spots in water, steered by its own move control (`FishMoveControl`:
//! it rises while its eyes are in water, eases its speed toward the wanted
//! one and pushes up or down toward its target); it travels as a fish,
//! sinking unless it has a target. Out of water it flops when it lands and
//! loses air, drowning at -20. A dead fish still flops.
//!
//! Cod, salmon and tropical fish school (`FollowLeader`): a fish with no
//! school looks for one now and then, joining a leader with room or leading
//! the loners around it, and swims to its leader while near it. A school is
//! its fishes' own state (`School`: a follower's leader, a leader's size),
//! which others sense; a follower changes its leader's by `Effect::Own`.
//!
//! A salmon's size scales it. A pufferfish puffs up while anything it fears
//! is within two blocks (`Puff`), stinging what it touches, and its puff
//! scales it (`PuffCounters` count up and down). A tropical fish's variant
//! is the spawn's: a common one nine times in ten, else any pattern and
//! colours.

use super::{fields, int, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f, lerp, reduced, rotlerp};
use crate::mobs::ai::goal::{Goal, MOVE};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{AvoidEntity, EntityTest, Panic, RandomStroll};
use crate::mobs::ai::hooks::{Hooks, Tag};
use crate::mobs::ai::mind::Own;
use crate::mobs::ai::navigation::{self, NavKind};
use crate::mobs::ai::turn::{Kinds, Seen, Turn};
use crate::mobs::ai::{spawn, think, Extra, Opaque};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, KindMotion, NavSpec, Registered, Registration};
use crate::mobs::model::{Body, Control, FamilyData, Impulse, MotionSet, Travel, TravelKind};
use crate::mobs::sensing::{inflate, intersects, Entity, GameMode, Kind as RefKind, Ref, Uuid};
use crate::mobs::term::{Atom, Value};
use crate::physics::table::Context;
use crate::physics::Aabb;

pub const COD: &str = "minecraft:cod";
pub const SALMON: &str = "minecraft:salmon";
pub const PUFFERFISH: &str = "minecraft:pufferfish";
pub const TROPICAL_FISH: &str = "minecraft:tropical_fish";

// The family's own test: a fish swims alone (`canRandomSwim`).
const ALONE: Tag = 1;

/// Which fish family.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FishKind {
    /// Cod and salmon (`Mobs.Fish`).
    Plain,
    Pufferfish,
    Tropical,
}

/// A schooling fish's school (`Mind.own`'s `leader` and `school`): the
/// leader it follows, and the size of the school it leads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct School {
    pub leader: Option<Uuid>,
    pub school: i64,
}

impl Default for School {
    fn default() -> School {
        School {
            leader: None,
            school: 1,
        }
    }
}

/// A change of another fish's school (`{:own, uuid, change}`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchoolChange {
    /// `startFollowing`/`stopFollowing`: its leader.
    Leader(Option<Uuid>),
    /// Its school grows or shrinks by one.
    Size(i64),
}

impl SchoolChange {
    fn apply(self, school: &mut School) {
        match self {
            SchoolChange::Leader(l) => school.leader = l,
            SchoolChange::Size(d) => school.school += d,
        }
    }
}

/// A pufferfish's counters (`inflateCounter`, `deflateTimer`; unsaved).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PuffCounters {
    pub inflate: i64,
    pub deflate: i64,
}

/// The school a mind keeps (`Fish.school/1`).
pub fn school(own: &Own) -> School {
    own.family::<School>().copied().unwrap_or_default()
}

fn put_school(own: &mut Own, school: School) {
    own.family = Some(Box::new(school));
}

fn counters(own: &Own) -> PuffCounters {
    own.family::<PuffCounters>().copied().unwrap_or_default()
}

/// A fish family.
pub struct Fish {
    kind: FishKind,
    types: &'static [&'static str],
    salmon: u16,
    pufferfish: u16,
    dims: [(u16, [f64; 3]); 2],
    poison: i32,
    flops: Vec<(u16, i32)>,
    swim: &'static str,
}

const PLAIN: [&str; 2] = [COD, SALMON];
const PUFFERFISH_TYPES: [&str; 1] = [PUFFERFISH];
const TROPICAL: [&str; 1] = [TROPICAL_FISH];

/// The schooling types.
pub const SCHOOLING: [&str; 3] = [COD, SALMON, TROPICAL_FISH];

// Tropical fish patterns in vanilla's order: `(base, index)`.
const PATTERNS: [(i64, i64); 12] = [
    (0, 0),
    (0, 1),
    (0, 2),
    (0, 3),
    (0, 4),
    (0, 5),
    (1, 0),
    (1, 1),
    (1, 2),
    (1, 3),
    (1, 4),
    (1, 5),
];

// The 22 common variants: pattern (by `PATTERNS` index), base and pattern
// colours (dye ids).
const COMMON: [(usize, i64, i64); 22] = [
    (7, 1, 7),
    (6, 7, 7),
    (6, 7, 11),
    (11, 0, 7),
    (1, 11, 7),
    (0, 1, 0),
    (5, 6, 3),
    (9, 10, 4),
    (11, 0, 14),
    (5, 0, 4),
    (8, 0, 7),
    (11, 0, 1),
    (3, 9, 6),
    (4, 5, 3),
    (10, 14, 0),
    (2, 7, 14),
    (9, 14, 0),
    (6, 0, 4),
    (0, 14, 0),
    (1, 7, 0),
    (3, 9, 4),
    (6, 4, 4),
];

/// `TropicalFish.packVariant(pattern, base, pattern colour)`.
pub fn pack(pattern: usize, base: i64, color: i64) -> i64 {
    let (kind, index) = PATTERNS[pattern];
    ((kind | (index << 8)) & 0xFFFF) | ((base & 0xFF) << 16) | ((color & 0xFF) << 24)
}

impl Fish {
    pub fn new(facts: &MobFacts, kind: FishKind) -> Result<Fish, String> {
        let entity = |name| super::entity(facts, name);
        let dim = |name| -> Result<(u16, [f64; 3]), String> {
            let id = entity(name)?;
            let t = facts.entities.get(id).ok_or("bad entity id")?;
            Ok((id, [f(t.width), f(t.height), f(t.eye_height)]))
        };
        let mut flops = Vec::new();
        for (name, sound) in [
            (COD, "minecraft:entity.cod.flop"),
            (SALMON, "minecraft:entity.salmon.flop"),
            (PUFFERFISH, "minecraft:entity.puffer_fish.flop"),
            (TROPICAL_FISH, "minecraft:entity.tropical_fish.flop"),
        ] {
            flops.push((entity(name)?, super::sound(facts, sound)?));
        }
        Ok(Fish {
            kind,
            types: match kind {
                FishKind::Plain => &PLAIN,
                FishKind::Pufferfish => &PUFFERFISH_TYPES,
                FishKind::Tropical => &TROPICAL,
            },
            salmon: entity(SALMON)?,
            pufferfish: entity(PUFFERFISH)?,
            dims: [dim(SALMON)?, dim(PUFFERFISH)?],
            poison: super::effect(facts, "minecraft:poison")?,
            flops,
            swim: "minecraft:entity.fish.swim",
        })
    }

    fn data_of(&self, type_id: u16) -> Vec<(Atom, Value)> {
        let mut data = fields(&[("from_bucket", Value::bool(false))]);
        match self.kind {
            FishKind::Plain if type_id == self.salmon => {
                data.extend(fields(&[("size", Value::Int(1))]))
            }
            FishKind::Plain => {}
            FishKind::Pufferfish => data.extend(fields(&[("puff", Value::Int(0))])),
            FishKind::Tropical => data.extend(fields(&[("variant", Value::Int(0))])),
        }
        data
    }

    /// `EntityDimensions.scale(f)` of a type's dimensions.
    fn scaled(&self, type_id: u16, factor: f64) -> Option<[f32; 3]> {
        let (_, [w, h, e]) = self.dims.iter().find(|(id, _)| *id == type_id)?;
        let factor = f(factor);
        Some([
            (w * factor) as f32,
            (h * factor) as f32,
            (e * factor) as f32,
        ])
    }

    fn puff_scale(puff: i64) -> f64 {
        match puff {
            0 => 0.5,
            1 => 0.7,
            _ => 1.0,
        }
    }

    fn schooling(&self) -> bool {
        self.kind != FishKind::Pufferfish
    }

    fn max_school(&self, type_id: u16) -> i64 {
        if type_id == self.salmon {
            5
        } else {
            8
        }
    }

    // ## Its tick

    /// `AbstractFish.aiStep` before its super: one out of water that landed
    /// flops up with a little sideways motion and its flop sound.
    fn flop(&self, t: &mut Turn) {
        if t.in_water() || !t.on_ground() || !t.mob.body.mob.motion.vertical_collision {
            return;
        }
        let a = t.float();
        let b = t.float();
        let side = |v: f64| f(f(f(v * 2.0) - 1.0) * f(0.05));
        let [vx, vy, vz] = t.velocity();
        t.mob.body.velocity = [vx + side(a), vy + f(0.4), vz + side(b)];
        t.mob.body.on_ground = false;
        let ty = t.type_id;
        if let Some(&(_, sound)) = self.flops.iter().find(|(id, _)| *id == ty) {
            think::make_sound(t, sound);
        }
    }

    /// `FishMoveControl.tick`: toward the wanted position while it navigates
    /// (speed eased an eighth of the way, a vertical push, its body turning
    /// with it), else still; it sinks unless it has a target.
    fn move_control(&self, t: &mut Turn) {
        match t.mob.body.mob.motion.control {
            Control::MoveTo { target, speed } if !t.mind.navigation.done() => {
                self.steer(t, target, speed)
            }
            _ => set(t, 0.0, None),
        }
        let sink = t.mind.target.is_none();
        t.mob.body.mob.motion.travel = Some(Travel {
            kind: TravelKind::Fish,
            sink,
        });
    }

    fn steer(&self, t: &mut Turn, [wx, wy, wz]: [f64; 3], modifier: f64) {
        let attribute = t.attribute("minecraft:movement_speed");
        let target = f(modifier * attribute);
        let speed = lerp(f(0.125), t.speed(), target);
        let (xd, yd, zd) = (wx - t.x(), wy - t.y(), wz - t.z());
        let push = (yd != 0.0).then(|| {
            let dd = (xd * xd + yd * yd + zd * zd).sqrt();
            speed * (yd / dd) * 0.1
        });
        if xd != 0.0 || zd != 0.0 {
            let yaw = rotlerp(t.yaw(), fmath::yaw(xd, zd), 90.0);
            t.mob.body.yaw = yaw;
            t.mind.body_yaw = yaw;
        }
        set(t, speed, push);
    }

    /// `AbstractSchoolingFish.tick` after its super: a leader alone now and
    /// then (one in 200 of the level's draws) finds its school gone.
    fn school_tick(&self, t: &mut Turn) {
        let mine = school(&t.mind.own);
        if mine.school <= 1 {
            return;
        }
        if spawn::level_int(t, 200) == 1 {
            let b = inflate(&t.bbox(), 8.0, 8.0, 8.0);
            let ty = t.type_id;
            if t.mobs_in(Kinds::Types(&[ty]), &b).len() <= 1 {
                let alone = School {
                    school: 1,
                    ..school(&t.mind.own)
                };
                put_school(&mut t.mind.own, alone);
            }
        }
    }

    // ## Puffing

    /// `Pufferfish.tick` before its super: puffing up and down.
    fn puff_tick(&self, t: &mut Turn) {
        let PuffCounters { inflate, deflate } = counters(&t.mind.own);
        let puff = int(t.data(), "puff");
        if inflate > 0 {
            if puff == 0 {
                self.puff(t, 1, "minecraft:entity.puffer_fish.blow_up");
            } else if inflate > 40 && puff == 1 {
                self.puff(t, 2, "minecraft:entity.puffer_fish.blow_up");
            }
            put_counters(t, |c| c.inflate = inflate + 1);
        } else if puff != 0 {
            if deflate > 60 && puff == 2 {
                self.puff(t, 1, "minecraft:entity.puffer_fish.blow_out");
            } else if deflate > 100 && puff == 1 {
                self.puff(t, 0, "minecraft:entity.puffer_fish.blow_out");
            }
            put_counters(t, |c| c.deflate = deflate + 1);
        }
    }

    fn puff(&self, t: &mut Turn, state: i64, sound: &str) {
        if let Some(id) = t.level.facts.sounds.id(sound) {
            think::make_sound(t, id);
        }
        let old = int(t.data(), "puff");
        t.mob.body.data.set("puff", Value::Int(state));
        if state > old {
            self.fudge(t, old);
        }
    }

    /// `refreshDimensions` as it grows: it searches around the old center
    /// for room, then with the old height when growing in both dimensions
    /// could not find a full-size fit.
    fn fudge(&self, t: &mut Turn, old: i64) {
        let ty = self.pufferfish;
        let dims = |puff| {
            self.scaled(ty, Fish::puff_scale(puff))
                .map_or([0.0; 3], |d| d.map(f64::from))
        };
        let [old_width, old_height, _] = dims(old);
        let [width, height, eye] = dims(int(t.data(), "puff"));
        let dx = fmath::emax(0.0, f(width - old_width)) + 1.0e-6;
        let dy = fmath::emax(0.0, f(height - old_height)) + 1.0e-6;
        let center = [t.x(), t.y() + old_height / 2.0, t.z()];
        t.width = width;
        t.height = height;
        t.eye = eye;
        let context = Context {
            entity: true,
            bottom: t.y(),
            descending: false,
            placement: false,
            entity_present: true,
            fall_distance: t.mob.body.mob.motion.fall_distance,
            falling_block: false,
            powder_snow_walkable: false,
            lava_walker: false,
            noclip: None,
        };
        let find = |t: &Turn, dy: f64, height: f64| {
            let [x, y, z] = center;
            let space = Aabb {
                min: [x - dx / 2.0, y - dy / 2.0, z - dx / 2.0],
                max: [x + dx / 2.0, y + dy / 2.0, z + dx / 2.0],
            };
            crate::mobs::ai::shapes::free_position(
                t.level,
                space,
                center,
                [width, height, width],
                &context,
            )
        };
        if let Some([x, y, z]) = find(t, dy, height) {
            t.mob.position = [x, y - height / 2.0, z];
        } else if let Some([x, y, z]) = find(t, 1.0e-6, old_height) {
            t.mob.position = [x, y - old_height / 2.0 + 1.0e-6, z];
        }
    }

    /// `Pufferfish.aiStep` after its super: puffed, it stings the players
    /// and mobs it touches (a player by its own touch, `playerTouch`).
    fn sting(&self, t: &mut Turn) {
        let puff = int(t.data(), "puff");
        if puff <= 0 {
            return;
        }
        let own = t.bbox();
        let reach = inflate(&own, 0.3, 0.3, 0.3);
        let facts = t.level.facts;
        let mut touched: Vec<Ref> = t
            .sensing
            .players
            .iter()
            .map(Entity::<Extra>::Player)
            .filter(|&p| {
                scary(facts, p) && intersects(&inflate(&p.bounding_box(), 1.0, 0.5, 1.0), &own)
            })
            .map(|p| p.reference())
            .collect();
        touched.extend(
            t.sensing
                .mobs()
                .iter()
                .map(Entity::Mob)
                .filter(|&m| {
                    m.uuid() != t.uuid && scary(facts, m) && intersects(&m.bounding_box(), &reach)
                })
                .map(|m| m.reference()),
        );
        for target in touched {
            let poison = Value::List(vec![Value::Tuple(vec![
                Value::atom("add"),
                Value::Int(self.poison as i64),
                Value::List(vec![Value::Tuple(vec![
                    Value::Int(60 * puff),
                    Value::Int(0),
                    Value::bool(false),
                    Value::bool(true),
                    Value::bool(true),
                ])]),
            ])]);
            t.effect(Effect::Hurt {
                target,
                kind: Value::atom("mob_attack"),
                amount: 1.0 + puff as f64,
                actions: poison,
            });
        }
    }
}

fn put_counters(t: &mut Turn, change: impl FnOnce(&mut PuffCounters)) {
    let mut c = counters(&t.mind.own);
    change(&mut c);
    t.mind.own.family = Some(Box::new(c));
}

// `setSpeed` with its eyes lifting it, and the move control's push.
fn set(t: &mut Turn, speed: f64, push: Option<f64>) {
    let motion = &mut t.mob.body.mob.motion;
    motion.set = Some(MotionSet::Speed { speed, lift: true });
    motion.impulse = Impulse::One([0.0, push.unwrap_or(0.0), 0.0]);
}

/// `Pufferfish.SCARY_MOB`: a player outside creative and spectator, or a
/// living mob of a type pufferfish fear.
fn scary<X>(facts: &MobFacts, e: Entity<'_, X>) -> bool {
    match e {
        Entity::Player(p) => p.alive && !matches!(p.mode, GameMode::Creative | GameMode::Spectator),
        Entity::Mob(m) => m.alive && !facts.entity_tag(m.type_id, "not_scary_for_pufferfish"),
        Entity::Item(_) => false,
    }
}

// ## Schools

/// `isFollower`: a leader that is alive.
fn follower(t: &Turn, school: &School) -> bool {
    match school.leader {
        None => false,
        Some(uuid) => t
            .entity(Some(&Ref {
                kind: RefKind::Mob,
                uuid,
            }))
            .is_some_and(|l| l.alive),
    }
}

/// The school others sense of a fish (itself as it is now).
fn sensed_school(t: &Turn, uuid: &Uuid) -> School {
    if *uuid == t.uuid {
        return school(&t.mind.own);
    }
    t.sensing
        .mob(uuid)
        .and_then(|m| m.extra.own.as_deref())
        .and_then(|o| o.as_any().downcast_ref::<School>())
        .copied()
        .unwrap_or_default()
}

// A change to fish `uuid`'s school: its own at once, another's by effect.
fn alter(t: &mut Turn, uuid: Uuid, change: SchoolChange) {
    if uuid == t.uuid {
        let mut mine = school(&t.mind.own);
        change.apply(&mut mine);
        put_school(&mut t.mind.own, mine);
    } else {
        t.effect(Effect::Own {
            mob: uuid,
            change: Box::new(change),
        });
    }
}

/// `follower.startFollowing(leader)`: its leader, and the leader's school
/// grows.
fn follow(t: &mut Turn, follower: Uuid, leader: Uuid) {
    alter(t, follower, SchoolChange::Leader(Some(leader)));
    alter(t, leader, SchoolChange::Size(1));
}

/// `stopFollowing`: it leaves its leader, whose school shrinks.
fn unfollow(t: &mut Turn) {
    let mine = school(&t.mind.own);
    put_school(
        &mut t.mind.own,
        School {
            leader: None,
            ..mine
        },
    );
    if let Some(leader) = mine.leader {
        alter(t, leader, SchoolChange::Size(-1));
    }
}

impl Hooks for Fish {
    /// `canRandomSwim`: a schooling fish swims alone when it follows no one.
    fn test(&self, t: &mut Turn, tag: Tag) -> bool {
        if tag != ALONE {
            return false;
        }
        !self.schooling() || !follower(t, &school(&t.mind.own))
    }
}

impl Family for Fish {
    fn data(&self, type_id: u16) -> FamilyData {
        FamilyData::new(self.data_of(type_id)).unwrap_or_else(FamilyData::empty)
    }

    fn own_air(&self) -> bool {
        true
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        let bucket = data
            .get("from_bucket")
            .cloned()
            .unwrap_or(Value::bool(false));
        let mut values = vec![value("fish_from_bucket", bucket, Value::bool(false))];
        match self.kind {
            FishKind::Plain if body.entity_type == SALMON => values.push(value(
                "salmon_type",
                Value::Int(int(data, "size")),
                Value::Int(1),
            )),
            FishKind::Plain => {}
            FishKind::Pufferfish => values.push(value(
                "puff_state",
                Value::Int(int(data, "puff")),
                Value::Int(0),
            )),
            FishKind::Tropical => values.push(value(
                "tropical_fish_variant",
                Value::Int(int(data, "variant")),
                Value::Int(0),
            )),
        }
        values
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        match self.kind {
            FishKind::Plain if body.entity_type == SALMON => {
                let factor = match int(&body.data, "size") {
                    0 => 0.5,
                    1 => 1.0,
                    _ => 1.5,
                };
                self.scaled(self.salmon, factor)
            }
            FishKind::Pufferfish => {
                self.scaled(self.pufferfish, Fish::puff_scale(int(&body.data, "puff")))
            }
            _ => None,
        }
    }
}

impl Kind for Fish {
    fn module(&self) -> &'static str {
        match self.kind {
            FishKind::Plain => "Valimc.AI.Mobs.Fish",
            FishKind::Pufferfish => "Valimc.AI.Mobs.Pufferfish",
            FishKind::Tropical => "Valimc.AI.Mobs.TropicalFish",
        }
    }

    fn types(&self) -> &[&'static str] {
        self.types
    }

    fn goals(&self, _facts: &MobFacts, type_id: u16) -> Registered {
        let mut goals = vec![
            Registration::new(0, "PanicGoal", MOVE, Panic::new(1.25, None)),
            Registration::new(
                2,
                "AvoidEntityGoal",
                MOVE,
                AvoidEntity::new(EntityTest::Players, 8.0, 1.6, 1.4),
            ),
            Registration::new(
                4,
                "FishSwimGoal",
                MOVE,
                RandomStroll::new(
                    1.0,
                    StrollOptions {
                        interval: 40,
                        swim: true,
                        guard: Some(ALONE),
                        ..StrollOptions::default()
                    },
                ),
            ),
        ];
        if self.schooling() {
            goals.push(Registration::new(
                5,
                "FollowFlockLeaderGoal",
                0,
                FollowLeader::new(self.max_school(type_id)),
            ));
        } else {
            goals.push(Registration::new(1, "PufferfishPuffGoal", 0, Puff));
        }
        Registered {
            goals,
            targets: Vec::new(),
        }
    }

    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec {
            kind: NavKind::Water,
            ..NavSpec::default()
        }
    }

    /// Its travel when its AI does not choose one (dead, `NoAI`): no target.
    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            fluid_pushed: false,
            travel: (TravelKind::Fish, true),
            ..KindMotion::default()
        }
    }

    fn sensed_own(&self) -> bool {
        self.schooling()
    }

    /// `finalizeSpawn`: a salmon's size from vanilla's weights (small 30,
    /// medium 50, large 15) before `Mob`'s part; a tropical fish's variant
    /// after it, from the level's random.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        if t.type_id == self.salmon {
            let n = t.int(95);
            let size = if n < 30 {
                0
            } else if n < 80 {
                1
            } else {
                2
            };
            t.mob.body.data.set("size", Value::Int(size));
        }
        spawn::mob(t, reason);
        if self.kind == FishKind::Tropical {
            let school = spawn::level_float(t) < f(0.9);
            spawn_variant(t, school);
        }
    }

    fn tick_start(&self, t: &mut Turn) {
        if self.kind == FishKind::Pufferfish {
            self.puff_tick(t);
        }
    }

    fn before_ai(&self, t: &mut Turn) {
        self.flop(t);
    }

    fn move_control(&self, t: &mut Turn) {
        Fish::move_control(self, t);
    }

    fn after_ai(&self, t: &mut Turn) {
        if self.kind == FishKind::Pufferfish {
            self.sting(t);
        }
    }

    fn after_tick(&self, t: &mut Turn) {
        if self.schooling() {
            self.school_tick(t);
        }
    }

    /// `WaterAnimal.handleAirSupply`: full in water, else down to drowning.
    fn air(&self, supply: i32, wet: bool) -> Option<(i32, f64)> {
        Some(if wet {
            (300, 0.0)
        } else if supply - 1 <= -20 {
            (0, 2.0)
        } else {
            (supply - 1, 0.0)
        })
    }

    fn dying(&self) -> bool {
        true
    }

    fn still(&self) -> bool {
        self.kind == FishKind::Pufferfish
    }

    fn swim_sound(&self) -> Option<&'static str> {
        Some(self.swim)
    }

    fn own_change(&self, own: &mut Own, change: &dyn Opaque) {
        if let Some(c) = change.as_any().downcast_ref::<SchoolChange>() {
            let mut mine = school(own);
            c.apply(&mut mine);
            put_school(own, mine);
        }
    }

    fn fresh_data(&self, type_id: u16) -> Vec<(Atom, Value)> {
        self.data_of(type_id)
    }
}

/// `TropicalFish.spawn_variant/2`: the variant after the spawn's school
/// decision, from the level's random (`Util.getRandom` draws).
pub fn spawn_variant(t: &mut Turn, school: bool) {
    let variant = if school {
        let (p, b, c) = COMMON[spawn::level_int(t, COMMON.len() as i32) as usize];
        let (kind, index) = PATTERNS[p];
        kind + (index << 8) + (b << 16) + (c << 24)
    } else {
        let p = spawn::level_int(t, PATTERNS.len() as i32) as usize;
        let b = spawn::level_int(t, 16) as i64;
        let c = spawn::level_int(t, 16) as i64;
        pack(p, b, c)
    };
    t.mob.body.data.set("variant", Value::Int(variant));
}

// ## Goals

/// `FollowFlockLeaderGoal` (`Fish.FollowLeader`): a fish that leads no
/// school follows its leader, re-pathing every ten updates while within
/// eleven blocks of it; one with neither looks, every 100 to 109 updates,
/// for a leader with room among the fish of its kind eight blocks around,
/// or makes itself the leader of the loners there.
#[derive(Clone, Debug, PartialEq)]
pub struct FollowLeader {
    /// Its type's largest school (`getMaxSchoolSize`).
    max: i64,
    next: i64,
    recalc: i64,
}

impl FollowLeader {
    /// `nextStartTick` as made (vanilla draws it before the mob's random is
    /// seeded; a fresh mind starts with the delay's least).
    pub fn new(max: i64) -> FollowLeader {
        FollowLeader {
            max,
            next: reduced(200),
            recalc: 0,
        }
    }
}

fn followable(school: &School, max: i64) -> bool {
    school.school > 1 && school.school < max
}

fn leader_of(t: &Turn) -> Option<Seen> {
    let uuid = school(&t.mind.own).leader?;
    t.entity(Some(&Ref {
        kind: RefKind::Mob,
        uuid,
    }))
    .filter(|l| l.alive)
}

impl Goal for FollowLeader {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let mine = school(&t.mind.own);
        if mine.school > 1 {
            return false;
        }
        if follower(t, &mine) {
            return true;
        }
        if self.next > 0 {
            self.next -= 1;
            return false;
        }
        let n = t.int(200);
        self.next = reduced(200 + (n % 20) as i64);
        let b = inflate(&t.bbox(), 8.0, 8.0, 8.0);
        let ty = t.type_id;
        let max = self.max;
        let candidates: Vec<(Uuid, School)> = t
            .mobs_in(Kinds::Types(&[ty]), &b)
            .iter()
            .map(|m| (m.uuid(), sensed_school(t, &m.uuid())))
            .filter(|(_, s)| followable(s, max) || !follower(t, s))
            .collect();
        let leader = candidates
            .iter()
            .find(|(_, s)| followable(s, max))
            .copied()
            .unwrap_or((t.uuid, mine));
        let loners: Vec<Uuid> = candidates
            .iter()
            .filter(|(_, s)| !follower(t, s))
            .map(|(u, _)| *u)
            .collect();
        // `leader.addFollowers(loners)`: as many as its school has room for,
        // in order, but itself.
        let room = (max - leader.1.school).max(0) as usize;
        for loner in loners.into_iter().take(room) {
            if loner != leader.0 {
                follow(t, loner, leader.0);
            }
        }
        follower(t, &school(&t.mind.own))
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match leader_of(t) {
            Some(l) => t.distance_sq(l.position) <= 121.0,
            None => false,
        }
    }

    fn start(&mut self, _t: &mut Turn) {
        self.recalc = 0;
    }

    fn stop(&mut self, t: &mut Turn) {
        unfollow(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        let recalc = self.recalc - 1;
        if recalc <= 0 {
            self.recalc = self.adjusted(10);
            if let Some(leader) = leader_of(t) {
                navigation::move_to_entity(t, &leader, 1.0, 1);
            }
        } else {
            self.recalc = recalc;
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Fish.FollowLeader"
    }
}

/// `PufferfishPuffGoal` (`Pufferfish.Puff`): runs while anything the
/// pufferfish fears is within two blocks of its box; starting it starts
/// the puffing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Puff;

impl Goal for Puff {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let b = inflate(&t.bbox(), 2.0, 2.0, 2.0);
        let facts = t.level.facts;
        t.sensing
            .players
            .iter()
            .map(Entity::<Extra>::Player)
            .any(|p| scary(facts, p) && intersects(&p.bounding_box(), &b))
            || t.sensing
                .mobs()
                .iter()
                .map(Entity::Mob)
                .any(|m| m.uuid() != t.uuid && scary(facts, m) && intersects(&m.bounding_box(), &b))
    }

    fn start(&mut self, t: &mut Turn) {
        put_counters(t, |c| {
            c.inflate = 1;
            c.deflate = 0;
        });
    }

    fn stop(&mut self, t: &mut Turn) {
        put_counters(t, |c| c.inflate = 0);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Pufferfish.Puff"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variants_pack_as_vanilla_packs_them() {
        // Stripey, orange on gray.
        assert_eq!(pack(7, 1, 7), 1 + (1 << 8) + (1 << 16) + (7 << 24));
        // Kob, white on white: the default.
        assert_eq!(pack(0, 0, 0), 0);
        let (p, b, c) = COMMON[0];
        assert_eq!(pack(p, b, c), 1 + (1 << 8) + (1 << 16) + (7 << 24));
    }

    #[test]
    fn school_changes_apply() {
        let mut s = School::default();
        SchoolChange::Size(1).apply(&mut s);
        SchoolChange::Leader(Some([1; 16])).apply(&mut s);
        assert_eq!(
            s,
            School {
                leader: Some([1; 16]),
                school: 2
            }
        );
    }
}
