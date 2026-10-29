//! A cow (`Valimc.Entity.Animals.Cow`, vanilla's `Cow` and `AbstractCow`):
//! its goals, its temperature and sound variants (`variants`); milking is
//! its interaction.

use super::{variants, Animal, Species};
use crate::mobs::ai::goal::{JUMP, LOOK, MOVE};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{
    Breed, Float, FollowParent, ItemTest, LookAtPlayer, Panic, RandomLookAround, RandomStroll,
    Tempt,
};
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::{SoundKind, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::interact::{At, Done, Hand, Interaction, Other, Outcome};
use crate::mobs::kinds::{Registered, Registration};
use crate::mobs::living::items;
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::term::{Atom, Value};

/// `AbstractCow.registerGoals` for a cow of `type_id` (a mooshroom's too).
pub fn goals(type_id: u16) -> Registered {
    Registered {
        goals: vec![
            Registration::new(0, "FloatGoal", JUMP, Float::new()),
            Registration::new(1, "PanicGoal", MOVE, Panic::new(2.0, None)),
            Registration::new(2, "BreedGoal", MOVE | LOOK, Breed::new(1.0, None, None)),
            Registration::new(
                3,
                "TemptGoal",
                MOVE | LOOK,
                Tempt::new(1.25, ItemTest::Food(type_id), false, 2.5),
            ),
            Registration::new(4, "FollowParentGoal", 0, FollowParent::new(1.25)),
            Registration::new(
                5,
                "WaterAvoidingRandomStrollGoal",
                MOVE,
                RandomStroll::new(
                    1.0,
                    StrollOptions {
                        water_avoiding: true,
                        ..StrollOptions::default()
                    },
                ),
            ),
            Registration::new(
                6,
                "LookAtPlayerGoal",
                LOOK,
                LookAtPlayer::new(6.0, 0.02, false, None),
            ),
            Registration::new(
                7,
                "RandomLookAroundGoal",
                MOVE | LOOK,
                RandomLookAround::new(),
            ),
        ],
        targets: Vec::new(),
    }
}

/// What milking needs.
#[derive(Clone, Copy, Debug)]
pub struct Milk {
    pub bucket: Option<i32>,
    pub milk_bucket: Option<i32>,
    pub sound: i32,
}

impl Milk {
    pub fn new(facts: &MobFacts) -> Milk {
        Milk {
            bucket: super::item(facts, "minecraft:bucket"),
            milk_bucket: super::item(facts, "minecraft:milk_bucket"),
            sound: facts.sounds.id("minecraft:entity.cow.milk").unwrap_or(0),
        }
    }

    /// `AbstractCow.mobInteract`: an adult fills a bucket with milk; the
    /// player hears its own milking, the others hear it at the player.
    pub fn milk(&self, i: &mut Interaction) -> Outcome {
        let adult = super::age(&i.mob.body.data) >= 0;
        match (self.bucket, self.milk_bucket, i.request.item_id()) {
            (Some(bucket), Some(milk), Some(id)) if adult && id == bucket => Outcome::Done(Done {
                hand: Some(Hand::Fill(items::new_stack(milk, 1, None))),
                others: Some(Other {
                    sound: self.sound,
                    source: "player",
                    volume: 1.0,
                    pitch: 1.0,
                    at: At::Player,
                }),
                ..Done::default()
            }),
            _ => Outcome::Pass,
        }
    }
}

pub struct Cow {
    milk: Milk,
    variants: variants::Variants,
}

impl Cow {
    pub fn new(facts: &MobFacts) -> Result<Cow, String> {
        Ok(Cow {
            milk: Milk::new(facts),
            variants: variants::Variants::new(facts, "cow")?,
        })
    }
}

impl Species for Cow {
    const TYPE: &'static str = "minecraft:cow";
    const MODULE: &'static str = "Valimc.Entity.Animals.Cow";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        goals(a.type_id)
    }

    fn defaults(&self) -> Vec<(Atom, Value)> {
        variants::data()
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        self.variants.values(data)
    }

    fn offspring(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        variants::offspring(t, partner)
    }

    fn spawn_part(&self, _a: &Animal<Self>, t: &mut Turn, _reason: &Atom) {
        variants::finalize(t, "cow");
    }

    fn properties(&self, data: &FamilyData) -> Vec<(String, String)> {
        variants::properties("cow", data)
    }

    fn ambient_sound(&self, _a: &Animal<Self>, t: &mut Turn) -> Option<Option<i32>> {
        Some(self.variants.sound(t.data(), "ambient"))
    }

    fn sound(&self, _a: &Animal<Self>, body: &Body, which: SoundKind) -> Option<SoundRef> {
        self.variants.combat_sound(body, which)
    }

    fn interact(&self, _a: &Animal<Self>, i: &mut Interaction) -> Outcome {
        self.milk.milk(i)
    }
}
