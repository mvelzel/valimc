//! A rabbit (`Valimc.Entity.Animals.Rabbit`): its goals (fleeing players,
//! wolves and monsters, raiding grown carrots), its type (`RabbitType`:
//! brown, white, black, white splotched, gold, salt; the killer bunny is
//! 99), the ticks before it raids again (`more_carrots`) and its hops
//! (`RabbitMoveControl`, `RabbitJumpControl` and its
//! `customServerAiStep`). A child takes a type of its biome one time in
//! twenty, else either parent's; the biome's type draws on the level's
//! random first (`getRandomRabbitVariant`).

use super::{Animal, Species};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE};
use crate::mobs::ai::goals::avoid_entity::AvoidEntity;
use crate::mobs::ai::goals::move_to_block::{BlockOptions, BlockTest, MoveToBlock};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{
    Breed, ClimbPowderSnow, EntityTest, Float, ItemTest, LookAtPlayer, Panic, RandomStroll, Tempt,
};
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::navigation;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::Turn;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Registered, Registration};
use crate::mobs::model::{Control, FamilyData, Hop, MobMotion};
use crate::mobs::term::{Atom, Value};

/// The rabbit types by name (`Rabbit.Variant`), in the Elixir map's order.
pub const TYPES: [(&str, i64); 7] = [
    ("black", 2),
    ("brown", 0),
    ("evil", 99),
    ("gold", 4),
    ("salt", 5),
    ("white", 1),
    ("white_splotched", 3),
];

const RAID: Tag = 1;

/// The hop state its mind keeps (`mind.own`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HopState {
    pub jump_ticks: i32,
    pub jump_duration: i32,
    pub was_on_ground: bool,
    pub jump_delay: i32,
    pub can_jump: bool,
}

fn hop_state(t: &Turn) -> HopState {
    t.mind.own.family::<HopState>().copied().unwrap_or_default()
}

fn put_hop(t: &mut Turn, state: HopState) {
    t.mind.own.family = Some(Box::new(state));
}

fn hop<'a>(t: &'a mut Turn<'_, '_>) -> Option<&'a mut Hop> {
    t.mob.body.mob.motion.hop.as_mut()
}

fn kind(data: &FamilyData) -> i64 {
    data.get("type").and_then(Value::as_int).unwrap_or(0)
}

fn more_carrots(data: &FamilyData) -> i64 {
    data.get("more_carrots")
        .and_then(Value::as_int)
        .unwrap_or(0)
}

/// `Rabbit.setSpeedModifier`: its navigation's speed, and its move control
/// wanting where it wanted, at that speed.
pub fn set_speed_modifier(t: &mut Turn, speed: f64) {
    navigation::set_speed(t, speed);
    let wanted = t
        .mob
        .body
        .mob
        .motion
        .hop
        .as_ref()
        .and_then(|h| h.wanted)
        .unwrap_or_else(|| t.pos());
    t.move_to(wanted, speed);
}

pub struct Rabbit {
    jump_sound: Option<i32>,
    wolf: u16,
    carrots: Option<u16>,
}

impl Rabbit {
    pub fn new(facts: &MobFacts) -> Result<Rabbit, String> {
        Ok(Rabbit {
            jump_sound: facts.sounds.id("minecraft:entity.rabbit.jump"),
            wolf: facts.entities.id("minecraft:wolf").ok_or("no wolf")?,
            carrots: facts.blocks.id("carrots"),
        })
    }

    // `startJumping`: jumping for 15 ticks, the jump sound.
    fn start_jumping(&self, t: &mut Turn, state: &mut HopState) {
        if let Some(h) = hop(t) {
            h.jumping = true;
        }
        let a = t.float();
        let b = t.float();
        let pitch = f(f(f(f(a - b) * f(0.2)) + 1.0) * f(0.8));
        if let Some(id) = self.jump_sound {
            let volume = t.facts.volume;
            t.sound_id(id, volume, pitch);
        }
        state.jump_duration = 15;
        state.jump_ticks = 0;
    }

    fn carrot(&self, t: &Turn, cell: [i32; 3]) -> bool {
        match (t.level.block(cell), self.carrots) {
            (Some(s), Some(c)) => t.level.facts.blocks.block_id(s) == Some(c),
            _ => false,
        }
    }
}

/// `getRandomRabbitVariant`: the type of the biome at the mob, drawn from
/// the level's random.
pub fn biome_type(t: &mut Turn) -> i64 {
    let facts = t.level.facts;
    let biome = Some(t.level.biome(t.block()));
    let n = spawn::level_int(t, 100);
    if facts.biome_in(biome, "minecraft:spawns_white_rabbits") {
        if n < 80 {
            1
        } else {
            3
        }
    } else if facts.biome_in(biome, "minecraft:spawns_gold_rabbits") {
        4
    } else if n < 50 {
        0
    } else if n < 90 {
        5
    } else {
        2
    }
}

impl Species for Rabbit {
    const TYPE: &'static str = "minecraft:rabbit";
    const MODULE: &'static str = "Valimc.Entity.Animals.Rabbit";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        let avoid = |test, distance| RabbitAvoid(AvoidEntity::new(test, distance, 2.2, 2.2));
        Registered {
            goals: vec![
                Registration::new(1, "FloatGoal", JUMP, Float::new()),
                Registration::new(
                    1,
                    "ClimbOnTopOfPowderSnowGoal",
                    JUMP,
                    ClimbPowderSnow::new(),
                ),
                Registration::new(
                    1,
                    "RabbitPanicGoal",
                    MOVE,
                    RabbitPanic(Panic::new(2.2, None)),
                ),
                Registration::new(2, "BreedGoal", MOVE | LOOK, Breed::new(0.8, None, None)),
                Registration::new(
                    3,
                    "TemptGoal",
                    MOVE | LOOK,
                    Tempt::new(1.0, ItemTest::Food(a.type_id), false, 2.5),
                ),
                Registration::new(
                    4,
                    "RabbitAvoidEntityGoal",
                    MOVE,
                    avoid(EntityTest::Players, 8.0),
                ),
                Registration::new(
                    4,
                    "RabbitAvoidEntityGoal",
                    MOVE,
                    avoid(EntityTest::Mobs(vec![self.wolf]), 10.0),
                ),
                Registration::new(
                    4,
                    "RabbitAvoidEntityGoal",
                    MOVE,
                    avoid(EntityTest::Monsters, 4.0),
                ),
                Registration::new(5, "RaidGardenGoal", MOVE | JUMP, RaidGarden::new()),
                Registration::new(
                    6,
                    "WaterAvoidingRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        0.6,
                        StrollOptions {
                            water_avoiding: true,
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    11,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(10.0, 0.02, false, None),
                ),
            ],
            targets: Vec::new(),
        }
    }

    fn defaults(&self) -> Vec<(Atom, Value)> {
        vec![
            (Atom::from_static("type"), Value::Int(0)),
            (Atom::from_static("more_carrots"), Value::Int(0)),
        ]
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        vec![(
            Atom::from_static("rabbit_type"),
            Value::Int(kind(data)),
            Value::Int(0),
        )]
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        let k = kind(data);
        let name = TYPES
            .iter()
            .find(|(_, id)| *id == k)
            .map_or("brown", |(n, _)| n);
        vec![("minecraft:rabbit/variant".into(), name.into())]
    }

    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        let biome = biome_type(t);
        let n = t.int(20);
        let k = if n != 0 {
            if t.boolean() {
                kind(partner)
            } else {
                kind(t.data())
            }
        } else {
            biome
        };
        vec![(Atom::from_static("type"), Value::Int(k))]
    }

    fn spawn_part(&self, _a: &Animal<Self>, t: &mut Turn, _reason: &Atom) {
        let k = biome_type(t);
        t.mob.body.data.set("type", Value::Int(k));
    }

    fn motion(&self) -> MobMotion {
        MobMotion {
            hop: Some(Hop {
                jumping: false,
                wanted: Some([0.0; 3]),
                speed: 0.0,
                next_speed: 0.0,
                path_up: None,
                outcome: None,
            }),
            control: Control::MoveTo {
                target: [0.0; 3],
                speed: 0.0,
            },
            ..MobMotion::default()
        }
    }

    /// `Rabbit.customServerAiStep`: its landing delay and carrot hunger
    /// count down; landing ends its hop and waits 10 ticks (3 when
    /// fleeing); on the ground, with somewhere to go and no delay, it faces
    /// its path's next node (or where it wants to go) and starts a hop.
    fn server_ai_step(&self, _a: &Animal<Self>, t: &mut Turn) -> bool {
        let mut state = hop_state(t);
        if state.jump_delay > 0 {
            state.jump_delay -= 1;
        }
        let more = more_carrots(t.data());
        if more > 0 {
            let n = t.int(3) as i64;
            t.mob
                .body
                .data
                .set("more_carrots", Value::Int((more - n).max(0)));
        }
        if t.on_ground() {
            if !state.was_on_ground {
                let speed = t.mob.body.mob.motion.hop.as_ref().map_or(0.0, |h| h.speed);
                let delay = if speed < 2.2 { 10 } else { 3 };
                if let Some(h) = hop(t) {
                    h.jumping = false;
                }
                state.jump_delay = delay;
                state.can_jump = false;
            }
            let wanted = match t.mob.body.mob.motion.control {
                Control::MoveTo { target, .. } => Some(target),
                _ => None,
            };
            match wanted {
                Some(wanted) if !t.mind.jump && state.jump_delay == 0 => {
                    let [x, _, z] = navigation::next_entity_position(t).unwrap_or(wanted);
                    let yaw = f(f(fmath::atan2(z - t.z(), x - t.x()) * 57.2957763671875) - 90.0);
                    t.mob.body.yaw = yaw;
                    self.start_jumping(t, &mut state);
                }
                _ if t.mind.jump && !state.can_jump => state.can_jump = true,
                _ => {}
            }
        }
        state.was_on_ground = t.on_ground();
        put_hop(t, state);
        // What `getJumpPower` reads of its path: the next node above it.
        let up = navigation::next_entity_position(t).is_some_and(|[_, y, _]| y > t.y() + 0.5);
        if let Some(h) = hop(t) {
            h.path_up = Some(up);
        }
        true
    }

    /// `Rabbit.aiStep` after the move: a hop its jump control started this
    /// tick (its sound), the navigation speed its move control set, the hop
    /// event, then its hop's ticks run out.
    fn settle(&self, _a: &Animal<Self>, t: &mut Turn) {
        let mut state = hop_state(t);
        let outcome = t
            .mob
            .body
            .mob
            .motion
            .hop
            .as_ref()
            .and_then(|h| h.outcome.clone());
        if outcome.as_ref().is_some_and(|o| o.started) {
            self.start_jumping(t, &mut state);
        }
        if let Some(speed) = outcome.as_ref().and_then(|o| o.nav_speed) {
            navigation::set_speed(t, speed);
        }
        if outcome.as_ref().is_some_and(|o| o.jumped) {
            t.effect(Effect::Event(1));
        }
        if let Some(h) = hop(t) {
            h.outcome = None;
            h.path_up = None;
        }
        if state.jump_ticks != state.jump_duration {
            state.jump_ticks += 1;
        } else if state.jump_duration != 0 {
            if let Some(h) = hop(t) {
                h.jumping = false;
            }
            state.jump_ticks = 0;
            state.jump_duration = 0;
        }
        put_hop(t, state);
    }

    // `RaidGardenGoal.isValidTarget`: farmland under a grown carrot, while
    // it wants food and has not found one.
    fn block(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        tag: Tag,
        cell: [i32; 3],
        goal: &mut MoveToBlock,
    ) -> bool {
        if tag != RAID {
            return false;
        }
        let Some(raid) = goal
            .own
            .as_ref()
            .and_then(|o| o.as_any().downcast_ref::<Raid>())
            .copied()
        else {
            return false;
        };
        if !(raid.wants && !raid.can_raid) {
            return false;
        }
        let facts = t.level.facts;
        let [x, y, z] = cell;
        let floor = t
            .level
            .block(cell)
            .and_then(|s| facts.blocks.block_id(s))
            .is_some_and(|b| facts.block_tag(b, "minecraft:supports_crops"));
        if !floor {
            return false;
        }
        let crop = [x, y + 1, z];
        let grown = t
            .level
            .block(crop)
            .is_some_and(|s| facts.blocks.property(s, "age") == Some("7"));
        if !(self.carrot(t, crop) && grown) {
            return false;
        }
        goal.own = Some(Box::new(Raid {
            can_raid: true,
            ..raid
        }));
        true
    }
}

/// `RabbitPanicGoal`: a panic that sets the rabbit's speed each update.
#[derive(Clone, Debug, PartialEq)]
pub struct RabbitPanic(pub Panic);

impl Goal for RabbitPanic {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.0.can_use(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.0.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.0.start(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.0.stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        set_speed_modifier(t, self.0.speed);
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Rabbit.Panic"
    }
}

/// `RabbitAvoidEntityGoal`: avoiding, unless it is the killer bunny.
#[derive(Clone, Debug, PartialEq)]
pub struct RabbitAvoid(pub AvoidEntity);

impl Goal for RabbitAvoid {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if kind(t.data()) == 99 {
            return false;
        }
        self.0.can_use(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.0.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.0.start(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.0.stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.0.tick(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Rabbit.Avoid"
    }
}

/// `RaidGardenGoal`'s own fields.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Raid {
    pub wants: bool,
    pub can_raid: bool,
}

/// `RaidGardenGoal`: while mobs may grief, a rabbit that wants food walks
/// to a grown carrot on farmland within sixteen blocks and eats a stage of
/// it (`RaidCarrot`); it wants food again 40 ticks later.
#[derive(Clone, Debug, PartialEq)]
pub struct RaidGarden(pub MoveToBlock);

impl RaidGarden {
    pub fn new() -> RaidGarden {
        let mut inner = MoveToBlock::new(0.7, 16, BlockTest::Family(RAID), BlockOptions::default());
        inner.own = Some(Box::new(Raid::default()));
        RaidGarden(inner)
    }

    fn raid(&self) -> Raid {
        self.0
            .own
            .as_ref()
            .and_then(|o| o.as_any().downcast_ref::<Raid>())
            .copied()
            .unwrap_or_default()
    }

    fn put_raid(&mut self, raid: Raid) {
        self.0.own = Some(Box::new(raid));
    }
}

impl Default for RaidGarden {
    fn default() -> RaidGarden {
        RaidGarden::new()
    }
}

impl Goal for RaidGarden {
    fn every_tick(&self) -> bool {
        true
    }

    fn can_use(&mut self, t: &mut Turn) -> bool {
        if self.0.next > 0 {
            return self.0.can_use(t);
        }
        if !t.level.rules.mob_griefing {
            return false;
        }
        let wants = more_carrots(t.data()) <= 0;
        self.put_raid(Raid {
            can_raid: false,
            wants,
        });
        self.0.can_use(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if !self.raid().can_raid {
            return false;
        }
        self.0.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.0.start(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.0.tick(t);
        let [x, y, z] = self.0.cell;
        let x_max = t.facts.max_head_x_rot;
        t.look_at(
            [x as f64 + 0.5, y as f64 + 1.0, z as f64 + 0.5],
            10.0,
            x_max,
        );
        if self.0.reached {
            let crop = [x, y + 1, z];
            let raid = self.raid();
            let carrot = match (t.level.block(crop), t.level.facts.blocks.id("carrots")) {
                (Some(s), Some(c)) => t.level.facts.blocks.block_id(s) == Some(c),
                _ => false,
            };
            if raid.can_raid && carrot {
                t.effect(Effect::RaidCarrot(crop));
                t.mob.body.data.set("more_carrots", Value::Int(40));
            }
            self.put_raid(Raid {
                can_raid: false,
                ..raid
            });
            self.0.next = 10;
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Rabbit.RaidGarden"
    }
}
