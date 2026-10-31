//! A cat (`Valimc.Entity.Animals.Cat`, vanilla's `Cat`), a stray: it creeps
//! toward a player holding cod or salmon (`CatTemptGoal`, now and then not
//! scared of that player), creeps and then sprints away from players
//! (`CatAvoidEntityGoal`), hunts rabbits and baby turtles
//! (`NonTameRandomTargetGoal`, `LeapAtTargetGoal`, `OcelotAttackGoal`),
//! strolls and looks about. Its variant is the spawn's (a swamp hut's are
//! black, some are black at full moon), its sounds its sound variant's. It
//! crouches while its move control creeps and sprints at a sprint's speed
//! (`customServerAiStep`); a stray being tempted begs for food.
//!
//! The goals of a tamed cat are registered as vanilla's are and never
//! start (`Idle`): taming is not modelled, so a stray takes the fish it is
//! offered and its taming always fails.

use super::{variants, Animal, Species};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::{follow, TargetOptions};
use crate::mobs::ai::goals::{
    AvoidEntity, Breed, EntityTest, Float, Idle, ItemTest, LeapAtTarget, LookAtPlayer, MobTypes,
    NearestAttackableTarget, OcelotAttack, Panic, RandomStroll, TargetKind, Tempt,
};
use crate::mobs::ai::turn::{Targeting, Turn};
use crate::mobs::combat::{SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::interact::{Done, Hand, InteractEvent, Interaction, Outcome};
use crate::mobs::kinds::{Registered, Registration};
use crate::mobs::model::{Body, Control, FamilyData, Modifier, Number};
use crate::mobs::sensing::Ref;
use crate::mobs::term::{Atom, Value, NIL};

const VARIANTS: &str = "minecraft:cat_variant";
const SOUNDS: &str = "minecraft:cat_sound_variant";
const SPEED: &str = "minecraft:movement_speed";
/// `LivingEntity.SPEED_MODIFIER_SPRINTING`: 0.3F, `ADD_MULTIPLIED_TOTAL`.
const SPRINTING: &str = "minecraft:sprinting";

fn flag(data: &FamilyData, key: &str) -> bool {
    data.get(key).and_then(Value::as_bool).unwrap_or(false)
}

pub struct Cat {
    variants: variants::Variants,
    rabbit: u16,
    turtle: u16,
}

impl Cat {
    pub fn new(facts: &MobFacts) -> Result<Cat, String> {
        Ok(Cat {
            variants: variants::Variants::new(facts, "cat")?,
            rabbit: facts.entities.id("minecraft:rabbit").ok_or("no rabbit")?,
            turtle: facts.entities.id("minecraft:turtle").ok_or("no turtle")?,
        })
    }

    fn id(&self, table: Option<i64>) -> Value {
        table.map_or(NIL, Value::Int)
    }

    // `LivingEntity.setSprinting`: its flag and the sprint speed modifier.
    fn sprint(t: &mut Turn, on: bool) {
        let entry = t.mob.body.mob.attributes.entry(SPEED);
        entry.modifiers.retain(|m| m.id != SPRINTING);
        if on {
            entry.modifiers.push(Modifier {
                id: SPRINTING.to_owned(),
                amount: Number::Float(0.30000001192092896),
                operation: 2,
            });
        }
        t.mob.body.data.set("sprinting", Value::bool(on));
    }
}

impl Species for Cat {
    const TYPE: &'static str = "minecraft:cat";
    const MODULE: &'static str = "Valimc.Entity.Animals.Cat";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        let hunt = |prey: u16| {
            Registration::new(
                1,
                "NonTameRandomTargetGoal",
                TARGET,
                Hunt(NearestAttackableTarget::new(
                    TargetKind::Mob,
                    Some(MobTypes::Types(vec![prey])),
                    false,
                    TargetOptions::default(),
                )),
            )
        };
        Registered {
            goals: vec![
                Registration::new(1, "FloatGoal", JUMP, Float::new()),
                Registration::new(1, "TamableAnimalPanicGoal", MOVE, Panic::new(1.5, None)),
                Registration::new(
                    2,
                    "SitWhenOrderedToGoal",
                    MOVE | JUMP,
                    Idle::new("SitWhenOrderedToGoal"),
                ),
                Registration::new(
                    3,
                    "CatRelaxOnOwnerGoal",
                    0,
                    Idle::new("CatRelaxOnOwnerGoal"),
                ),
                Registration::new(
                    4,
                    "CatTemptGoal",
                    MOVE | LOOK,
                    CatTempt {
                        tempt: Tempt::new(0.6, ItemTest::Food(a.type_id), true, 2.5),
                        selected: None,
                    },
                ),
                Registration::new(
                    5,
                    "CatLieOnBlockGoal",
                    MOVE | JUMP,
                    Idle::new("CatLieOnBlockGoal"),
                ),
                Registration::new(
                    6,
                    "FollowOwnerGoal",
                    MOVE | LOOK,
                    Idle::new("FollowOwnerGoal"),
                ),
                Registration::new(
                    7,
                    "CatSitOnBlockGoal",
                    MOVE | JUMP,
                    Idle::new("CatSitOnBlockGoal"),
                ),
                Registration::new(8, "LeapAtTargetGoal", MOVE | JUMP, LeapAtTarget::new(0.3)),
                Registration::new(9, "OcelotAttackGoal", MOVE | LOOK, OcelotAttack::new()),
                Registration::new(10, "BreedGoal", MOVE | LOOK, Breed::new(0.8, None, None)),
                Registration::new(
                    11,
                    "WaterAvoidingRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        0.8,
                        StrollOptions {
                            water_avoiding: true,
                            probability: 1.0000001e-5,
                            ..StrollOptions::default()
                        },
                    ),
                ),
                Registration::new(
                    12,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(10.0, 0.02, false, None),
                ),
                // `reassessTameGoals`: a stray avoids players (added after
                // the rest).
                Registration::new(
                    4,
                    "CatAvoidEntityGoal",
                    MOVE,
                    AvoidEntity::new(EntityTest::Players, 16.0, 0.8, 1.33),
                ),
            ],
            targets: vec![hunt(self.rabbit), hunt(self.turtle)],
        }
    }

    fn defaults(&self) -> Vec<(Atom, Value)> {
        let text = |s: &str| Value::Binary(s.as_bytes().to_vec());
        vec![
            (Atom::from_static("variant"), text("minecraft:black")),
            (
                Atom::from_static("sound_variant"),
                text("minecraft:classic"),
            ),
            (Atom::from_static("collar"), Value::Int(14)),
            (Atom::from_static("lying"), Value::bool(false)),
            (Atom::from_static("relax"), Value::bool(false)),
            (Atom::from_static("tame"), Value::bool(false)),
            (Atom::from_static("sitting"), Value::bool(false)),
            (Atom::from_static("crouching"), Value::bool(false)),
            (Atom::from_static("sprinting"), Value::bool(false)),
        ]
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        let v = &self.variants;
        let flags = flag(data, "sitting") as i64 + if flag(data, "tame") { 4 } else { 0 };
        let variant = variants::text(data, "variant").unwrap_or("minecraft:black");
        let sound = variants::text(data, "sound_variant").unwrap_or("minecraft:classic");
        let collar = data.get("collar").cloned().unwrap_or(Value::Int(14));
        vec![
            (
                Atom::from_static("tamable_flags"),
                Value::Int(flags),
                Value::Int(0),
            ),
            (Atom::from_static("tamable_owner"), NIL, NIL),
            (
                Atom::from_static("cat_variant"),
                self.id(v.variant_id(variant)),
                self.id(v.variant_id("minecraft:black")),
            ),
            (
                Atom::from_static("cat_lying"),
                Value::bool(flag(data, "lying")),
                Value::bool(false),
            ),
            (
                Atom::from_static("cat_relax_state_one"),
                Value::bool(flag(data, "relax")),
                Value::bool(false),
            ),
            (
                Atom::from_static("cat_collar_color"),
                collar,
                Value::Int(14),
            ),
            (
                Atom::from_static("cat_sound_variant"),
                self.id(v.sound_variant_id(sound)),
                self.id(v.sound_variant_id("minecraft:classic")),
            ),
        ]
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        variants::properties("cat", data)
    }

    /// A child's variant: either parent's (a stray's child has no owner or
    /// collar).
    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        variants::offspring(t, partner)
    }

    /// `Cat.finalizeSpawn`: `Mob`'s part first, then the variant to spawn
    /// and a random sound variant, from the level's random.
    fn finalize(&self, _a: &Animal<Self>, t: &mut Turn, reason: &Atom) {
        crate::mobs::ai::spawn::mob(t, reason);
        let variant = variants::pick_variant(t, VARIANTS);
        let sound = variants::pick_random(t, SOUNDS);
        let data = &mut t.mob.body.data;
        if let Some(v) = variant {
            data.set("variant", Value::Binary(v.into_bytes()));
        }
        if let Some(s) = sound {
            data.set("sound_variant", Value::Binary(s.into_bytes()));
        }
    }

    /// `Cat.customServerAiStep` (in place of `Animal`'s): crouching while its
    /// move control creeps (speed 0.6), sprinting at 1.33, standing
    /// otherwise.
    fn server_ai_step(&self, _a: &Animal<Self>, t: &mut Turn) -> bool {
        let (crouching, sprinting) = match t.mob.body.mob.motion.control {
            Control::MoveTo { speed: 0.6, .. } => (true, false),
            Control::MoveTo { speed: 1.33, .. } => (false, true),
            _ => (false, false),
        };
        Cat::sprint(t, sprinting);
        t.mob.body.data.set("crouching", Value::bool(crouching));
        true
    }

    /// `Entity.baseTick`'s sprint particles: a sprinting cat out of water
    /// and not crouching draws for one each tick.
    fn tick_start(&self, _a: &Animal<Self>, t: &mut Turn) {
        let data = t.data();
        if flag(data, "sprinting") && !flag(data, "crouching") && !t.in_water() {
            t.sprint_particle();
        }
    }

    /// `Cat.tick` after its super: a stray being tempted begs for food
    /// every 100 ticks.
    fn after_tick(&self, _a: &Animal<Self>, t: &mut Turn) {
        if t.mind.tick % 100 == 0 && !flag(t.data(), "tame") && t.mind.goals.runs::<CatTempt>() {
            if let Some(id) = self.variants.sound(t.data(), "beg_for_food") {
                t.sound_id(id, 1.0, 1.0);
            }
        }
    }

    /// `getAmbientSound`: a stray's meow.
    fn ambient_sound(&self, _a: &Animal<Self>, t: &mut Turn) -> Option<Option<i32>> {
        Some(self.variants.sound(t.data(), "stray_ambient"))
    }

    fn sound(&self, _a: &Animal<Self>, body: &Body, which: SoundKind) -> Option<SoundRef> {
        self.variants.combat_sound(body, which)
    }

    /// `Cat.mobInteract` of a stray with its food: it takes one
    /// (`usePlayerItem`) and `tryToTame` fails, with its smoke (event 6);
    /// taming itself is not modelled.
    fn interact(&self, a: &Animal<Self>, i: &mut Interaction) -> Outcome {
        let food = i.rules.facts.animal.food(a.type_id, i.request.item_id());
        if !flag(&i.mob.body.data, "tame") && food {
            Outcome::Done(Done {
                hand: Some(Hand::Use(1)),
                swing: true,
                events: vec![InteractEvent::Entity(6)],
                ..Done::default()
            })
        } else {
            Outcome::Pass
        }
    }
}

// ## Goals

/// `Cat.CatTemptGoal` (`Cat.Tempt`): `TemptGoal` (0.6, scared by a moving
/// player) for a stray. While tempted it now and then picks the player as
/// one it is not scared of (one update in `adjustedTickDelay(600)`) and
/// forgets it (one in `adjustedTickDelay(500)`).
#[derive(Clone, Debug, PartialEq)]
pub struct CatTempt {
    tempt: Tempt,
    selected: Option<Ref>,
}

impl Goal for CatTempt {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        !flag(t.data(), "tame") && self.tempt.can_use(t)
    }

    /// `canScare`: not by the player it picked.
    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.tempt.scare = self.selected.is_none() || self.selected != self.tempt.player;
        let ok = self.tempt.can_continue(t);
        self.tempt.scare = true;
        ok
    }

    fn start(&mut self, t: &mut Turn) {
        self.tempt.start(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.tempt.stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.tempt.tick(t);
        let picked = self.selected.is_none() && t.int(self.adjusted(600) as i32) == 0;
        if picked {
            self.selected = self.tempt.player;
        } else if t.int(self.adjusted(500) as i32) == 0 {
            self.selected = None;
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Cat.Tempt"
    }
}

/// `NonTameRandomTargetGoal` (`Cat.Hunt`, one update in ten, not needing
/// sight): a stray targets the nearest mob of its types; it keeps it while
/// the targeting conditions hold (alive, attackable, within the follow
/// range).
#[derive(Clone, Debug, PartialEq)]
pub struct Hunt(NearestAttackableTarget);

impl Goal for Hunt {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        !flag(t.data(), "tame") && self.0.can_use(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        let targeting = Targeting::new(true).range(follow(t));
        match self.0.found {
            Some(r) if t.entity(Some(&r)).is_some() => t.test(&r, &targeting),
            _ => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        self.0.start(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.0.stop(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Cat.Hunt"
    }
}
